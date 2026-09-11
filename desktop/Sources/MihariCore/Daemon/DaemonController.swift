import Foundation
import SwiftUI
import os

/// デーモンの起動・接続・再起動を束ねる。
///
/// 画面はこの型の `@Published` だけを見る。プロセスと HTTP の面倒はここで完結させる。
@MainActor
public final class DaemonController: ObservableObject {

    /// アプリから見たデーモンの状態。
    public enum State: Equatable {
        case stopped
        case starting
        case running(port: Int, pid: Int)
        case failed(message: String)

        public var label: String {
            switch self {
            case .stopped: return "停止中"
            case .starting: return "起動中…"
            case .running(let port, let pid): return "稼働中 (port \(port) / pid \(pid))"
            case .failed(let message): return "失敗: \(message)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "daemon-controller")

    /// 画面に残すイベントの件数。古いものから捨てる。
    public static let eventHistoryLimit = 50

    /// 予期しない終了から再起動するまでの待ち時間の初期値。
    /// 立て続けに落ちたときはここから倍々に延び、`restartMaxDelay` で頭打ちになる。
    public static let restartDelay: Duration = .seconds(2)

    /// SSE を張り直すまでの待ち時間の初期値。
    static let streamReconnectBaseDelay: Duration = .seconds(1)

    /// SSE を張り直すまでの待ち時間の上限。接続自体に失敗し続けるときにここまで延びる。
    static let streamReconnectMaxDelay: Duration = .seconds(30)

    /// 予期しない終了から再起動するまでの待ち時間の上限。
    static let restartMaxDelay: Duration = .seconds(60)

    /// これだけ生きていたデーモンの終了は「たまたま落ちた」とみなし、
    /// 再起動のバックオフを初期値に戻す。
    static let stableUptimeResetThreshold: TimeInterval = 30

    /// この回数だけ立て続けに落ちたら自動再起動を諦める。
    static let maxRestartAttempts = 8

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var isStreamConnected = false
    @Published public private(set) var events: [DaemonEvent] = []
    @Published public private(set) var devices: [DeviceSummary] = []
    @Published public private(set) var lastError: String?

    private var process: DaemonProcess?
    private var client: DaemonClient?
    private var streamTask: Task<Void, Never>?
    /// 明示的に止めたのか、落ちたのかを区別する。落ちたときだけ再起動する。
    private var stoppedIntentionally = false
    /// 直近にデーモンが起き上がった時刻。落ちるまでの時間でバックオフをリセットするか決める。
    private var lastStartAt: Date?
    /// 立て続けに落ちた回数。再起動の待ち時間を伸ばし、上限回数で諦めるために数える。
    private var restartAttempts = 0

    public init() {}

    /// 他のコントローラに渡すための接続済みクライアント。デーモンが動いていなければ `nil`。
    public var connectedClient: DaemonClient? { client }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// デーモンを起動し、イベントの購読を始める。
    public func start() async {
        guard case .stopped = state else { return }
        state = .starting
        stoppedIntentionally = false
        lastError = nil

        let process = DaemonProcess()
        process.onTermination = { [weak self] status in
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }
        self.process = process

        do {
            let announcement = try await process.start()
            guard let baseURL = announcement.baseURL else {
                throw DaemonError.announcementUnreadable(message: "接続先を組み立てられない")
            }
            client = DaemonClient(baseURL: baseURL, token: process.token)
            state = .running(port: announcement.port, pid: announcement.pid)
            lastStartAt = Date()
            startStreaming()
        } catch {
            let message = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("daemon start failed: \(message, privacy: .public)")
            state = .failed(message: message)
            lastError = message
            self.process = nil
        }
    }

    /// デーモンを止める。アプリ終了時にも必ず通る。
    public func stop() {
        stoppedIntentionally = true
        // 手動で起動し直すときにバックオフを引きずらないよう、ここで畳む。
        restartAttempts = 0
        streamTask?.cancel()
        streamTask = nil
        isStreamConnected = false
        process?.terminate()
        process = nil
        client = nil
        devices = []
        state = .stopped
    }

    public func restart() async {
        stop()
        await start()
    }

    /// iPhone の一覧を取り直す。
    public func refreshDevices(wifi: Bool = true) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            devices = try await client.devices(wifi: wifi).devices
            lastError = nil
        } catch {
            devices = []
            lastError = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 経路が端から端まで通っているかを確かめる。Python 側から SSE でイベントが返ってくる。
    public func sendTestEvent() async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            try await client.publishTestEvent(name: "test.ping", payload: ["from": "app"])
            lastError = nil
        } catch {
            lastError = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startStreaming() {
        guard let client else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            // 切断のたびに張り直す。接続自体に失敗し続けるときだけ倍々に待つ。
            // デーモンごと死んだ場合は handleTermination がこの Task を cancel するので、
            // ここでは無条件に再試行してよい。
            var reconnectDelay = Self.streamReconnectBaseDelay
            while !Task.isCancelled {
                let didConnect = await consumeEvents(client: client)
                isStreamConnected = false
                guard !Task.isCancelled else { return }
                reconnectDelay =
                    didConnect
                    ? Self.streamReconnectBaseDelay
                    : min(reconnectDelay * 2, Self.streamReconnectMaxDelay)
                Self.logger.error("event stream ended; reconnecting")
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    /// 1 回接続して、切れるまでイベントを消費する。
    ///
    /// - Returns: 一度でも接続できたか。`openEventStream` の失敗や非 2xx は `false`、
    ///   接続したあとにストリームが終わった・例外で切れた場合は `true`。
    ///   張り直しの待ち時間を決めるために使う。
    private func consumeEvents(client: DaemonClient) async -> Bool {
        var didConnect = false
        do {
            let (bytes, status) = try await client.openEventStream()

            guard (200..<300).contains(status) else {
                lastError = DaemonError.requestFailed(status: status, message: "SSE に接続できない").errorDescription
                return false
            }

            didConnect = true
            isStreamConnected = true
            // つないだ直後に iPhone の状態を 1 回取りに行く。デーモン側の監視ループは
            // その GET で初めて起動するうえ、SSE には変化しか流れてこないので、
            // 呼ばないと状態が一生分からない。切れて張り直したときの取り直しにもなる。
            Task { [weak self] in
                await self?.primeIPhoneState(client: client)
            }

            var parser = ServerSentEventParser()
            var lines = LineAccumulator()
            // bytes.lines は空行を捨ててしまい SSE のフレーム区切りが取れないため、自前で行に切る。
            for try await byte in bytes {
                guard let line = lines.consume(byte: byte) else { continue }
                guard let frame = parser.consume(line: line) else { continue }
                append(frame: frame)
            }
        } catch {
            if !Task.isCancelled {
                Self.logger.error("event stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        isStreamConnected = false
        return didConnect
    }

    /// iPhone の状態を 1 回取りに行き、SSE で届いたものと同じ形にして流す。
    ///
    /// 取れなかったときは記録だけ残す。`lastError` は画面に出る値なので、
    /// 裏でやっているこの取り直しでは触らない。
    private func primeIPhoneState(client: DaemonClient) async {
        do {
            let state = try await client.iphoneState()
            guard let event = Self.makeIPhoneStateEvent(from: state, existing: events) else { return }
            append(event: event)
        } catch {
            let message = (error as? DaemonError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("iphone state fetch failed: \(message, privacy: .public)")
        }
    }

    /// 取ってきた状態を `iphone.state` のイベントに組み替える。
    ///
    /// GET は監視を起動した時点の初期値(`unresponsive`)を即座に返すが、監視ループは
    /// その直後に実機へつないで本当の状態を SSE で流す。どちらが先に手元へ届くかは
    /// 決まっていないので、すでにある `iphone.state` より新しいときだけイベントにする。
    ///
    /// - Returns: 流すべきイベント。古い、または時刻を解釈できないときは `nil`。
    nonisolated static func makeIPhoneStateEvent(
        from state: IPhoneStateResponse,
        existing events: [DaemonEvent]
    ) -> DaemonEvent? {
        guard let updatedAt = DaemonEvent.parseTimestamp(state.updatedAt) else { return nil }
        let newest = events.filter { $0.name == "iphone.state" }.map(\.createdAt).max()
        if let newest, updatedAt <= newest { return nil }

        // キー名と値の書き方は SSE の payload に合わせる。受け取る側は区別しない。
        var payload = ["activity": state.activity]
        if let udid = state.udid { payload["udid"] = udid }
        if let level = state.batteryLevel { payload["battery_level"] = String(level) }
        if let charging = state.batteryCharging { payload["battery_charging"] = String(charging) }
        if let bundleId = state.foregroundBundleId { payload["foreground_bundle_id"] = bundleId }
        if let appName = state.foregroundAppName { payload["foreground_app_name"] = appName }
        return DaemonEvent(name: "iphone.state", payload: payload, createdAt: updatedAt)
    }

    private func append(frame: ServerSentEventParser.Frame) {
        guard let data = frame.data.data(using: .utf8) else { return }
        guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: data) else {
            Self.logger.error("イベントを解釈できない: \(frame.data, privacy: .public)")
            return
        }
        append(event: event)
    }

    /// 新しいイベントを先頭に足し、上限を超えたぶんを古い方から捨てる。
    private func append(event: DaemonEvent) {
        events.insert(event, at: 0)
        if events.count > Self.eventHistoryLimit {
            events.removeLast(events.count - Self.eventHistoryLimit)
        }
    }

    private func handleTermination(status: Int32) {
        isStreamConnected = false
        guard !stoppedIntentionally else { return }

        // 落ちた。状態を落としてから、少し待って起動し直す。
        let message = "デーモンが終了した (status=\(status))"
        Self.logger.error("\(message, privacy: .public)")
        lastError = message
        streamTask?.cancel()
        streamTask = nil
        process = nil
        client = nil
        state = .stopped

        // 再起動の待ち時間は立て続けに落ちるほど倍々に延ばす(上限あり)。
        // しばらく生きていたデーモンの終了は「たまたま落ちた」とみなして初期値に戻し、
        // 上限回数を超えて落ち続けるなら自動再起動を諦める(手動の restart() で復帰できる)。
        let uptime = lastStartAt.map { Date().timeIntervalSince($0) } ?? .infinity
        restartAttempts = uptime < Self.stableUptimeResetThreshold ? restartAttempts + 1 : 0
        guard restartAttempts <= Self.maxRestartAttempts else {
            state = .failed(message: "繰り返し失敗したため自動再起動を止めた")
            return
        }
        let delay = Duration.milliseconds(Int(min(2000 * pow(2.0, Double(restartAttempts)), 60_000)))

        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.stoppedIntentionally else { return }
            await self.start()
        }
    }
}
