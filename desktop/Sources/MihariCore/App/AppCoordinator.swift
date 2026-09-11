import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// アプリ全体の取りまとめ役。
///
/// ここが唯一「全機能を知っている」場所。各機能は互いを知らずに作ってあり、
/// 検知エンジンの実行部にそれぞれを差し込むことで初めて 1 つのアプリになる。
/// 画面(ペット・補助ウィンドウ・メニュー)からの操作もすべてここを通る。
@MainActor
public final class AppCoordinator: ObservableObject, PetMenuActions {

    /// 検証用の 10 タブ画面を出すかどうかを決める環境変数。
    static let debugUIEnvironmentKey = "MIHARI_DEBUG_UI"

    // extension(QuitLock / Escape / Uninstall / Ceremony)からも触るため internal。
    static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "app-coordinator")

    public let permissions: PermissionsModel
    public let daemon = DaemonController()
    /// iPhone スクショ(iOS 17+)に必要な tunneld の常駐。`OnboardingView` に渡して登録させ、
    /// セーフティートグル `iphoneScreenshot` を OFF にしたらこちらから解除する。
    public let tunneld = TunneldModel()
    public let voice: VoiceController
    /// 同封音声か live か。ペット・検知・説教のすべてがここを見る。
    public let voiceModeStore: VoiceModeStore
    /// セーフティートグルの設定とポリシー。#49。
    public let safety: SafetySettingsStore
    public let discord = DiscordController()
    public let attendance: AttendanceModel
    public let detection: DetectionEngine
    public let pet: LivePetPresenter
    public let questioner = HeadGestureQuestioner()
    /// 執行猶予脱出(宣言・10 分待ち・冷却・自動復帰)の進行。#52。
    public let escape = EscapeController()

    /// 音楽を止めて聞かせる全画面オーバーレイ。
    ///
    /// セリフの取得と読み上げを注入するため、`self` を参照できる `lazy var` にしてある。
    /// 注入しないと、音楽が鳴っている場面(`interrupt` 経路)で一言も喋らないまま暗転する。
    public lazy var overlay: OverlayModel = makeOverlay()

    // 以下は検証用の 10 タブ画面でしか使わないので、開かれるまで作らない。
    public lazy var capture = CaptureViewModel(
        service: CaptureService(camera: CameraCaptureService(gate: safety.gate)),
        iphoneScreenshot: { [daemon, gate = safety.gate] in
            // デバッグ経路もトグルを越えられない。bridge 側の 403 と二重防御にする(#58)。
            try gate.check(.iphoneScreenshot)
            guard let client = await daemon.connectedClient else { throw DaemonError.notRunning }
            return try await client.iphoneScreenshot()
        },
        speak: { [voice, daemon] request in
            // 喋れなかったときに前回の記録を返してしまわないよう、成否を先に見る。
            guard await voice.speak(request, using: daemon.connectedClient) != nil else { return nil }
            return voice.history.first
        }
    )
    public lazy var vision = FaceVisionViewModel()
    public lazy var headGesture = HeadGestureController()

    /// 監視中か。メニューの表示に使う。
    @Published public private(set) var isWatching = false
    /// 休憩中か。メニューの表示に使う。
    @Published public private(set) var isOnBreak = false
    /// 状態パネルを出しているか。メニューの表示に使う。
    @Published public private(set) var isStatusPanelVisible = false
    /// スクショに写り込むか。メニューの表示に使う。セーフティートグル(.photobomb)を映す。
    public var isPhotobombEnabled: Bool {
        safety.isEnabled(.photobomb)
    }
    /// アンインストールの進行中か。終了確認(`confirmQuit`)を素通しするためのフラグ。#55
    public internal(set) var isUninstalling = false
    /// 消す作業そのものの Task。終了要求はこれの完了を待ってから通す。#55
    ///
    /// 待たずに通すと、SIGTERM 経路が `exit(0)` で即死して、消しかけの登録とファイルが
    /// 残ったままになる。
    var uninstallTask: Task<Void, Never>?

    /// 在席スタンプのカットインを出す層。
    let cutIn: AttendanceCutInPresenting = AttendanceCutInPresenter()
    /// 在席スタンプ / 疑い 1 の演出をしている最中か。押し直しでカットインが重なるのを防ぐ。
    var isStampCeremonyRunning = false
    /// 演出の世代。畳まれたら 1 つ進めて、結末の演出を出さずにカットインだけ閉じる。
    var ceremonyGeneration = 0

    /// カットインを出してから認証ダイアログを出すまでの間(秒)。
    static let cutInLeadInSeconds: TimeInterval = 0.45
    /// 結末の絵に差し替えてからカットインを閉じるまでの時間(秒)。
    static let cutInHoldSeconds: TimeInterval = 1.8

    /// 音を出す口。検知のセリフとペットのひとりごとで 1 つを共有する。
    private let speechPlayer: SpeechPlayer
    /// アプリの外(Claude Code のフックなど)からの合図の受け口。
    private let externalTrigger = ExternalTriggerListener()
    /// スクリーンショットが保存されたのを見張る。
    let photobombWatcher = ScreenshotPhotobombWatcher()
    /// 保存されたスクショにペットのスプライトを描き足す層。
    ///
    /// セリフをペットの吹き出しに繋ぐため、`self` を参照できる `lazy var` にしてある。
    private lazy var photobomb = ScreenshotPhotobombCompositor(
        say: { [weak self] line in
            self?.pet.controller.say(line)
        },
        currentLook: { [weak self] in
            guard let self, let definition = self.pet.controller.currentPet else { return nil }
            return (definition, self.pet.controller.wardrobeSelection)
        }
    )
    let windows = AuxiliaryWindows()
    /// 設定ウィンドウで選ばれているタブ。ウィンドウを閉じても覚えておき、
    /// 次に `openSettings(tab: nil)` で開いたときは前回のタブのまま出す。
    private let settingsTabSelection = SettingsTabSelection()
    private let statusPanel = StatusPanelController()
    /// 監視中はディスプレイ/システムのアイドルスリープを止める。
    let sleepPreventer: SleepPreventing
    /// `quitTimeLock` に渡す既定のロック時間。デーモン(Discord の `/watch lock`)から
    /// 取れなかったときのフォールバック。
    static let defaultLockHours: Double = 4
    /// ロックの解除時刻(`quitTimeLock.unlockAt`)をまたいで覚えておく UserDefaults のキー。
    /// 値は `Date`。kill されて再起動しても、宣言した解除時刻を引き継ぐために置いておく(#52)。
    static let quitLockDeadlineKey = "quitLock.unlockAt"
    /// kill されて落ちても次回ログインで自動的に立ち上がるよう登録する。
    let loginItemRegistrar: LoginItemRegistering
    /// 本体が kill されても、こちらの監視プロセスが数秒以内に起こす。
    let watchdogRegistrar: WatchdogRegistering
    /// 前回、正常に終了できていたか(kill されて起こされたのかを見分けるため)。
    private let lifecycleMarker: AppLifecycleMarking
    /// 起動してからの終了ロック。`begin()` の経路でセットされ、ロックが解けるまで
    /// 終了とアンインストールを拒む。#55 の `canUninstall` もここを見る。
    var quitTimeLock: QuitTimeLock
    private var cancellables: Set<AnyCancellable> = []
    /// すでに見張り始めたか。`begin()` を何度呼んでも 1 回しか効かないようにする。
    var hasBegun = false
    /// 監視プロセスの登録を定期的に見直すループ。`launchctl bootout` で外から
    /// 消されても、Touch ID を経ずには長続きさせないためのもの。
    var watchdogReassertionTask: Task<Void, Never>?
    /// 上の見直しの間隔。短すぎると無駄に `launchctl` を叩き、長すぎると
    /// 「外から消されてから戻るまで」のすきまが意味を持ち始める。
    static let watchdogReassertionInterval: Duration = .seconds(20)
    /// quitLock トグルのひとつ前の ON/OFF。購読直後は「いまの状態」を覚えるだけで
    /// 何もしない(begin() が適用済みのため)。
    private var quitLockPolicyState: Bool?
    /// 前回の執行猶予脱出からの復帰で「戻ってきた」か。デーモン接続後の投稿までためておく。
    var pendingEscapeReturn: Bool?
    /// 「逃げた」の投稿を待つ Task。終了要求はこれの完了を待ってから通す。#52
    ///
    /// 投稿を投げっぱなしにすると、直後の Cmd+Q / SIGTERM で接続ごと消えて投稿が飛ぶ。
    var escapePostTask: Task<Void, Never>?
    /// ON にした機能の事後処理を直列に流すための連鎖。複数の機能が同じタイミングで
    /// ON になったとき(「全部 ON」など)に、権限要求と tunneld 登録が重ならないようにする。
    private var featureEnableTask: Task<Void, Never>?
    /// 「逃げた」の投稿を待つ上限。ここまで待って返らなければ投稿を諦めて終了する。
    static let escapePostTimeout: Duration = .seconds(10)
    /// quitLock の解除時刻などの保存先。
    let defaults: UserDefaults

    /// - Parameters:
    ///   - sleepPreventer: スリープ防止の実体。テストでは呼び出し回数だけ記録するスタブに差し替える。
    ///   - loginItemRegistrar: ログイン項目への登録処理。テストでは何もしないスタブに差し替える。
    ///   - watchdogRegistrar: 監視プロセスの登録処理。テストでは何もしないスタブに差し替える。
    ///   - lifecycleMarker: 前回の終了が正常だったかの記録。テストでは固定値を返すスタブに差し替える。
    ///   - safety: セーフティートグルの設定。テストでは `UserDefaults(suiteName:)` の store を渡す。
    ///   - defaults: quitLock の解除時刻などの保存先。テストでは `UserDefaults(suiteName:)` を渡す。
    ///   - quitTimeLock: 終了ロックの本体。テストではロック済みのインスタンスを渡して
    ///     `canUninstall` の「ロック中は false」を確かめられるようにする。#55
    public init(
        sleepPreventer: SleepPreventing = IOPMSleepPreventer(),
        loginItemRegistrar: LoginItemRegistering = SMAppServiceLoginItemRegistrar(),
        watchdogRegistrar: WatchdogRegistering = LaunchAgentWatchdogRegistrar(),
        lifecycleMarker: AppLifecycleMarking = UserDefaultsLifecycleMarker(),
        safety: SafetySettingsStore = SafetySettingsStore(),
        defaults: UserDefaults = .standard,
        quitTimeLock: QuitTimeLock = QuitTimeLock()
    ) {
        let player = SpeechPlayer()
        let attendance = AttendanceModel()
        self.speechPlayer = player
        self.attendance = attendance
        self.permissions = PermissionsModel()
        self.voice = VoiceController(player: player)
        self.voiceModeStore = VoiceModeStore()
        self.safety = safety
        // 在席スタンプ直後の猶予を効かせるため、検知エンジンに在席の記録を渡す。
        self.detection = DetectionEngine(attendance: attendance)
        self.pet = LivePetPresenter(controller: PetController(speechPlayer: player))
        self.isStatusPanelVisible = statusPanel.isVisible
        self.sleepPreventer = sleepPreventer
        self.loginItemRegistrar = loginItemRegistrar
        self.watchdogRegistrar = watchdogRegistrar
        self.lifecycleMarker = lifecycleMarker
        self.defaults = defaults
        self.quitTimeLock = quitTimeLock
        observeVoiceMode()
    }

    /// 音声モードの切り替えを、喋る側すべてに配る。
    ///
    /// メニューから切り替えた瞬間に効かせたいので、`@Published` を購読して押し込む。
    private func observeVoiceMode() {
        voiceModeStore.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 検知のセリフは同封音声で固定なので、切り替えるのはペットのひとりごとと説教。
                    self.pet.controller.voiceMode = mode
                    // メニューバー側のチェックを描き直させる。
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 起動

    /// 起動直後に一度だけ呼ぶ。まずセーフティートグルから要求範囲を絞り、
    /// 未選択ならモード選択 → 権限のオンボーディング、揃っていなければ権限画面、
    /// どちらも不要なら見張りを始める。
    public func launch() {
        // 必須権限はセーフティートグルから導出する。トグルを変えたあとの起動にも正しく反映させる。
        permissions.apply(settings: safety.settings)
        permissions.refresh()

        if Self.isDebugUIRequested {
            showDebugWindow()
        }

        // モード選択を済ませていなければ、全 OFF のまま 1 回だけオンボーディングを
        // 見せる。既存インストールのアップデート後もここに来る。
        if !safety.hasCompletedModeSelection {
            showOnboardingFlow()
        } else if !permissions.isRequiredSatisfied {
            // 必須権限が欠けているうちは見張らない。
            // 撮れも送れもしない状態で常駐しても、黙って失敗し続けるだけになる。
            showPermissionWindow()
        } else {
            begin()
        }
    }

    /// ペットを出して見張り始める。2 回目以降は何もしない。
    public func begin() {
        guard !hasBegun else { return }
        hasBegun = true

        // 前回、執行猶予脱出で終了していれば、復帰の判定を済ませておく。
        // 投稿はデーモンに繋がってからにするので、ここでは「戻ってきたか」まで(#52)。
        handleEscapeReturnIfNeeded()

        // quitLock トグルに従って、常駐の仕掛け(スリープ防止・ログイン項目・watchdog・
        // 解除時刻)を一式そろえる。OFF なら以前 ON だったときの登録を掃除する(#52)。
        applyQuitLockPolicy()

        // 前回、正常に終了できていなければ(= kill か crash で消えたのを監視プロセスに
        // 起こされたのなら)、記録を上書きする前に見ておく。
        let wasKilled = !lifecycleMarker.wasPreviousSessionGraceful()
        lifecycleMarker.markSessionStarted()

        // 右クリックメニューはウィンドウを作る前に差し込む。
        pet.controller.contextMenuBuilder = { [weak self] in
            guard let self else { return NSMenu() }
            return PetContextMenu.makeMenu(PetMenuEntries.make(actions: self, presenter: pet))
        }
        pet.show()
        if wasKilled {
            pet.controller.say(RevivalAngerLine.random())
        }
        statusPanel.restore { statusPanelView }
        observeDetection()
        observeDaemonEvents()
        observeSafety()
        wireEscape()

        // Claude Code の Stop フック(notifyutil -p)からの「応答を終えた」合図。
        externalTrigger.listen(name: ExternalTriggerListener.claudeDoneName) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pet.controller.say("終わったよー")
            }
        }

        // 保存されたスクショに、あとからペットのスプライトを描き足して写り込む。
        if isPhotobombEnabled {
            startPhotobombWatching()
        }

        Task { [weak self] in
            guard let self else { return }
            await daemon.start()
            // セーフティートグルをデーモンへ伝える。サーバ側の受信は #50 で実装される。
            pushSafetyToDaemon()
            wireDetection()
            // 常駐して見張るアプリなので、始めたら見張り続ける。
            detection.start()

            // 前回の執行猶予脱出からの復帰を、デーモンに繋がったいま投稿する(#52)。
            postEscapeReturnIfPending()

            // ロックの解除時刻は、デーモンに繋がってから確定させる。保存値の引き継ぎ
            // (applyQuitLockPolicy)で既にロック済みなら、ここでは何もしない(#52)。
            if safety.isEnabled(.quitLock) {
                await establishFreshQuitLockDeadline()
            }
        }
    }

    /// 終了時の後片付け。見張りを止めて、子プロセスのデーモンも落とす。
    public func shutdown() {
        detection.stop()
        photobombWatcher.stop()
        daemon.stop()
        sleepPreventer.stop()
        watchdogReassertionTask?.cancel()
        watchdogReassertionTask = nil
    }

    /// 終了(Cmd+Q・Dock「終了」・kill によるシグナル)してよいか。
    ///
    /// - quitLock OFF: 見張り中の対話的な終了(Cmd+Q など)にだけ「監視中です。終了しますか?」
    ///   の確認を 1 枚出し、OK なら true。非対話(シグナル)か監視外なら素通しする。
    ///   watchdog / ログイン項目は登録していないので解除しない(呼んでも害はない)。
    /// - quitLock ON: 従来どおり、ロック中は認証のふりをせず断る(ペットのセリフ)。
    ///   ただし執行猶予脱出のカウントダウンが終わっている(`escape.isReadyToTerminate`)なら
    ///   true —— そのとき watchdog / ログイン項目は**解除しない**。宣言時刻に復帰するための
    ///   仕掛けを残しておく。ロックが解けていれば従来どおり登録を解いて true。
    ///
    /// - Parameter interactive: ユーザーが画面から操作した終了か。シグナル経由なら false。
    public func confirmQuit(interactive: Bool) async -> Bool {
        // アンインストールの流れは確認を挟み終えているので、素通しする。
        // ここで止まると、消したはずのファイルと登録を残したままアプリが残る。
        // ただし消し終える前に終わってしまうと中途半端に残るので、作業の完了は待つ。
        if isUninstalling {
            await uninstallTask?.value
            return true
        }
        guard hasBegun else { return true }

        if safety.isEnabled(.quitLock) {
            let allowed = escape.isReadyToTerminate || quitTimeLock.isUnlocked()
            guard allowed else {
                if let remaining = quitTimeLock.remainingDescription() {
                    pet.controller.say("まだロック中。\(remaining)は消せないよ。")
                }
                return false
            }
            // 「逃げた」の投稿中に終了すると投稿が飛ぶ。上限つきで待ってから通す(#52)。
            await escapePostTask?.value
            // 脱出の完了による終了は、監視プロセスとログイン項目を残したまま終わる
            // (宣言時刻に自動で戻って監視を再開させるため、ここでは解除しない)。
            if !escape.isReadyToTerminate {
                watchdogRegistrar.unregister()
                loginItemRegistrar.unregister()
            }
            lifecycleMarker.markGracefulShutdown()
            return true
        }

        // quitLock OFF。見張っている最中に対話的な終了を頼まれたら、確認を 1 枚出す。
        var allowed = true
        if interactive && isWatching {
            let alert = NSAlert()
            alert.messageText = "監視中です。終了しますか?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "終了する")
            alert.addButton(withTitle: "キャンセル")
            allowed = alert.runModal() == .alertFirstButtonReturn
        }
        guard allowed else { return false }
        // 登録はしていないが、残っていた登録を掃除する(呼んでも害はない)。
        watchdogRegistrar.unregister()
        loginItemRegistrar.unregister()
        lifecycleMarker.markGracefulShutdown()
        return true
    }

    /// Dock のアイコンがクリックされた。
    ///
    /// - Returns: AppKit に既定の処理(ウィンドウを開き直す)を続けさせるか。
    ///   見張り始めたあとはペットを出すだけで、ウィンドウは開かない。
    public func handleReopen() -> Bool {
        // まだ見張り始めていない(オンボーディング / 初回権限)ときは、出すべきウィンドウを
        // 現在の状態から決め直す。ウィザード化で×は隠したが、クラッシュや強制終了・
        // Dock 再クリックで取り残されないための復帰導線にする。
        guard hasBegun else {
            showPreBeginWindow()
            return false
        }
        pet.show()
        return false
    }

    /// まだ見張り始めていないときに、出すべき初回ウィンドウを決めて出す。
    ///
    /// `launch()` と同じ分岐。`hasCompletedModeSelection` を見るので、オンボーディングを
    /// 途中で閉じても Dock 再クリックで復帰できる。
    private func showPreBeginWindow() {
        if !safety.hasCompletedModeSelection {
            showOnboardingFlow()
        } else if !permissions.isRequiredSatisfied {
            showPermissionWindow()
        } else {
            begin()
        }
    }

    /// 検証用の 10 タブ画面が要求されているか。
    ///
    /// 開発者向けの注記(TCC・API 名)を出すかの判定にも使うので、同じモジュールの
    /// View から読めるようにしてある。
    static var isDebugUIRequested: Bool {
        ProcessInfo.processInfo.environment[debugUIEnvironmentKey] == "1"
    }

    /// デバッグメニューを出すか(メニュー項目の露出制御)。
    public var isDebugMenuVisible: Bool {
        Self.isDebugUIRequested
    }

    // MARK: - ウィンドウ

    /// 起動時の「始める」フロー用に、権限の確認画面を出す。
    ///
    /// 必須権限が欠けていて見張り始められないときだけ出す初回導線。設定としての権限確認は
    /// 設定ウィンドウの「権限」タブ側にあるので、こちらは「始める」ボタンだけを出す。
    private func showPermissionWindow() {
        windows.showPermissions {
            OnboardingView(
                model: permissions,
                tunneld: tunneld,
                safety: safety,
                onStart: { [weak self] in
                    guard let self else { return }
                    windows.closePermissions()
                    begin()
                }
            )
        }
    }

    private func showDebugWindow() {
        windows.showDebug { RootView(coordinator: self) }
    }

    /// セーフティーのモード選択 → 権限確認のオンボーディングを出す。
    ///
    /// 「次へ」でオンボーディングを終えるとき、モード選択を済ませたことを記録して
    /// ウィンドウを閉じ、そのまま見張りを始める。
    private func showOnboardingFlow() {
        windows.showOnboarding {
            OnboardingFlowView(
                safety: safety,
                permissions: permissions,
                tunneld: tunneld,
                onStart: { [weak self] in
                    guard let self else { return }
                    safety.markModeSelectionCompleted()
                    windows.closeOnboarding()
                    begin()
                },
                onOpenDiscordSettings: { [weak self] in
                    // 完了画面の「Discord を設定してから始める」。オンボーディングのまま
                    // 設定ウィンドウを開いて、Discord タブに直行させる。
                    self?.openSettings(tab: .discord)
                }
            )
        }
    }

    // MARK: - PetMenuActions

    public func startWatching() {
        // 「監視を再開する」を押した相手を休憩中のまま放置しない。
        if isOnBreak { detection.endBreak() }
        detection.start()
    }

    public func stopWatching() {
        // 休憩には触れない。休憩と監視の開始 / 停止は別の話。
        detection.stop()
    }

    public func startBreak() {
        detection.startBreak()
    }

    public func endBreak() {
        detection.endBreak()
    }

    /// 設定画面(セーフティー / Discord / 権限のタブ)を開く。
    ///
    /// セーフティータブは、監視中に変えた `isWatching` を画面に映すため、コーディネーターを
    /// 観察するラッパー経由で `SafetyModeView` を組み立て直す。
    ///
    /// - Parameter tab: 開くタブ。`nil` なら前回開いていたタブのまま出す(初回は `.safety`)。
    public func openSettings(tab: SettingsTab?) {
        if let tab { settingsTabSelection.tab = tab }
        windows.showSettings {
            SettingsView(
                selection: settingsTabSelection,
                safety: { SafetySettingsHost(coordinator: self) },
                discord: { DiscordView(discord: discord, daemon: daemon) },
                permissions: {
                    // 設定から開く権限タブは「始める」ではなく「閉じる」。起動時の
                    // 「始める」フローは `showPermissionWindow()` の側に残してある。
                    OnboardingView(
                        model: permissions,
                        tunneld: tunneld,
                        onClose: { [weak self] in self?.closeSettings() }
                    )
                }
            )
        }
    }

    /// 設定画面を閉じる。`SafetyModeView` と `OnboardingView` の「閉じる」から呼ばれる。
    func closeSettings() {
        windows.closeSettings()
    }

    /// 設定画面で ON にした機能の事後処理。オンボーディング側(`OnboardingFlowView`)
    /// にも同じ意味の動きがある。
    func handleFeatureEnabled(_ feature: SafetyFeature) {
        let previous = featureEnableTask
        featureEnableTask = Task { [previous] in
            // 前の処理が終わってから次へ。許可ダイアログや管理者パスワードを 1 枚ずつにする。
            await previous?.value
            await permissions.request(for: feature)
            guard feature == .iphoneScreenshot else { return }
            // すでに常駐していれば管理者パスワードダイアログは出さない。
            if tunneld.status != .running {
                await tunneld.install()
            }
        }
    }

    public func toggleStatusPanel() {
        statusPanel.toggle { statusPanelView }
        isStatusPanelVisible = statusPanel.isVisible
    }

    /// スクショへの写り込みを入れる / 切る。
    ///
    /// フラグはセーフティートグル(.photobomb)として扱う。ON も OFF も監視中に通るが、
    /// 「あとで設定を変えられるようにする」が OFF なら ON は 24 時間後の予約になるので、
    /// 切り替え結果はメニューのチェックが次に組み立てられるときに映る。
    public func setPhotobombEnabled(_ enabled: Bool) {
        safety.request(
            enabled ? .enable(.photobomb) : .disable(.photobomb),
            isWatching: isWatchingForSafety
        )
        // メニューのチェックを描き直させる。
        objectWillChange.send()
    }

    /// ロック中は、監視していなくても「監視中」として扱う。SafetyPolicy への問い合わせに使う。
    ///
    /// ロックは監視を外すための仕掛けなので、検知を止めた状態(= 監視外)でトグルを弄って
    /// 終了ブロックごと外す抜け道を作らない(#52)。ロックが解けたらもとの判定に戻る。
    /// `SafetySettingsHost`(同じファイル内の設定画面ラッパー)からも、設定画面に映す
    /// 「監視中」の値を同じ判定で渡すために使う。
    fileprivate var isWatchingForSafety: Bool {
        isWatching || (hasBegun && !quitTimeLock.isUnlocked())
    }

    /// 終了ロックの解除時刻。ロック中でなければ nil。
    ///
    /// 設定画面に「監視中か」と「ロック中か」を分けて渡すために使う。監視を止めても
    /// ロックが残っている状態を「監視中」と表示すると混乱させるため(#52)。
    fileprivate var safetyLockUntil: Date? {
        guard hasBegun, !quitTimeLock.isUnlocked() else { return nil }
        return quitTimeLock.unlockAt
    }

    /// 保存されたスクショを見張り始める。すでに見張っていれば何も起きない。
    private func startPhotobombWatching() {
        photobombWatcher.start { [weak self] url in
            Task { @MainActor [weak self] in
                await self?.photobomb.photobomb(url)
            }
        }
    }

    public var voiceMode: VoiceMode { voiceModeStore.mode }

    public func setVoiceMode(_ mode: VoiceMode) {
        voiceModeStore.set(mode)
    }

    public var focusStreakIntervalSeconds: TimeInterval {
        detection.thresholds.focusStreakIntervalSeconds
    }

    public func setFocusStreakInterval(_ seconds: TimeInterval) {
        detection.thresholds = detection.thresholds.withFocusStreakInterval(seconds)
        objectWillChange.send()
    }

    public var isFastThresholds: Bool {
        detection.thresholds == .fast
    }

    /// 検知の閾値を preset ごと差し替える。
    /// 「集中継続の間隔」で個別に変えていた値も preset の値に戻る。
    public func setFastThresholds(_ enabled: Bool) {
        detection.thresholds = enabled ? .fast : .standard
        objectWillChange.send()
    }

    public func replayFocusStreak() {
        pet.sayFocusStreak()
    }

    public func runDetectionStep(_ step: DetectionDebugStep) {
        detection.runDebugStep(step)
    }

    /// いまのセーフティーモードの 1 行表示。メニューの最上段に出す。
    public var safetyStatusLine: String {
        var line = "モード: \(safety.mode.label)"
        if let pending = safety.settings.pendingChange {
            line += " ・変更予約 \(StatusPanelSnapshot.pendingChangeText(until: pending.effectiveAt, now: Date()))"
        }
        return line
    }

    /// 説教オーバーレイを組み立てる。セリフの取得と読み上げの停止はこのアプリのものを渡す。
    private func makeOverlay() -> OverlayModel {
        let voice = self.voice
        let daemon = self.daemon
        let modes = self.voiceModeStore
        let player = self.speechPlayer
        return OverlayModel(
            presenter: ScreenSaverOverlayPresenter(),
            speak: { request in
                // 同封音声のときは bridge に作らせず、同封の説教から 1 本選んでその場で鳴らす。
                if modes.mode == .bundled {
                    guard let sermon = BundledVoiceLines.shared.pick(.sermon) else { return nil }
                    if let audio = sermon.audio { player.play(audio: audio, priority: .detection) }
                    return sermon.text
                }
                return await voice.speak(request, using: daemon.connectedClient)
            },
            stopSpeaking: { [weak voice] in voice?.stopSpeaking() },
            // トグルが OFF なら音楽停止も含めて何もしない(検知側には知らせない)。
            gate: safety.gate
        )
    }

    /// 状態パネルの中身。エンジンとデーモンとセーフティー設定の `@Published` をそのまま映す。
    private var statusPanelView: StatusPanelView {
        StatusPanelView(engine: detection, daemon: daemon, safety: safety)
    }

    // MARK: - 配線

    /// 検知エンジンの実行部に、実際の機能を配線する。
    ///
    /// どの実行部も「失敗したら諦めて次へ」に倒してある。カメラが使えない、
    /// VOICEVOX が起動していない、Discord のトークンが無い、はどれも起こりうる。
    /// 1 つ転んだせいで見張りが死ぬのが一番まずい。
    private func wireDetection() {
        // セーフティートグル(.macCamera)の OFF は撮影の先頭で弾かれる。
        let capture = CaptureService(camera: CameraCaptureService(gate: safety.gate))
        // セーフティートグル。証拠の取り先と Discord 投稿の可否をエンジンがここで見る。
        detection.safetyGate = safety.gate
        detection.actions = DetectionEngine.Actions(
            captureMacPhoto: { await Self.photoData(from: capture) },
            captureIPhoneScreenshot: { [daemon] in
                try? await daemon.connectedClient?.iphoneScreenshot()
            },
            speak: { [voice, daemon] request in
                // 音声はここでは鳴らさない。吹き出しが出る瞬間に鳴らせるよう、ペットまで運ぶ。
                guard let line = await voice.fetchLine(request, using: daemon.connectedClient) else {
                    return nil
                }
                return SpokenSpeech(text: line.text, audio: line.audioData, screen: line.screen)
            },
            readScreen: { [daemon] request in
                guard let client = await daemon.connectedClient else { return nil }
                return try? await client.readScreen(request)
            },
            interrupt: { [overlay] request in
                await MainActor.run { overlay.show(request: request) }
            },
            post: { [discord, daemon] text, image, filename, mention in
                await discord.post(
                    text: text,
                    image: image,
                    filename: filename,
                    mention: mention,
                    using: daemon.connectedClient
                )
            },
            classify: { data in
                Self.visionLabel(for: data)
            },
            askHeadGesture: { [questioner] question, answerWindow in
                await questioner.ask(prompt: question, answerWindow: answerWindow)
            },
            confirmPresence: { [weak self] onPhone in
                guard let self else { return .unavailable }
                return await self.confirmPresence(onPhone: onPhone)
            },
            cancelPresenceCheck: { [weak self] in
                await MainActor.run { self?.cancelPresenceCheck() }
            }
        )
        detection.onEvent = { [pet] event in
            pet.present(event)
        }
        detection.onPromptDismissed = { [pet] in
            pet.dismissPrompt()
        }
        detection.onFocusStreak = { [pet] in
            pet.sayFocusStreak()
        }
    }

    /// 監視の状態をペットとメニューに映す。
    private func observeDetection() {
        detection.$isWatching
            .combineLatest(detection.$breakUntil)
            .sink { [weak self] isWatching, breakUntil in
                MainActor.assumeIsolated {
                    self?.applyMonitoring(isWatching: isWatching, breakUntil: breakUntil)
                }
            }
            .store(in: &cancellables)
    }

    private func applyMonitoring(isWatching: Bool, breakUntil: Date?) {
        let onBreak = breakUntil.map { Date() < $0 } ?? false
        self.isWatching = isWatching
        self.isOnBreak = onBreak

        if onBreak {
            pet.setMonitoring(.onBreak)
        } else if isWatching {
            pet.setMonitoring(.watching)
        } else {
            pet.setMonitoring(.paused)
        }
    }

    /// SSE で届いたイベントを検知エンジンに反映する。
    ///
    /// `@Published` の通知は値が入る**前**に来るので、`daemon.events` を読み直さず
    /// 流れてきた値をそのまま使う。
    private func observeDaemonEvents() {
        daemon.$events
            .compactMap(\.first)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)
    }

    private func handle(_ event: DaemonEvent) {
        switch event.name {
        case "iphone.state":
            // iphonePresence が OFF のあいだは、届いたイベントを拾わない。
            // bridge 側(#50)も流さないが、遅れて届いたり既に持っていたりする
            // 値を引きずらないよう、Swift 側でも二重に塞ぐ。
            guard safety.isEnabled(.iphonePresence) else {
                detection.iphoneState = .unreachable
                detection.iphoneForegroundApp = nil
                return
            }
            applyIPhoneState(event)
        case "watch.start":
            // Discord の /watch から始めた場合。すでに見張っていれば何も起きない。
            detection.start()
        case "watch.stop":
            detection.stop()
        default:
            break
        }
    }

    /// セーフティートグルの変化を、実行部とデーモンへ配る。
    private func observeSafety() {
        // photobomb が ON になったら写り込みの見張りを始め、OFF になったら止める。
        // `begin()` は自分で一度 `startPhotobombWatching()` を呼ぶので、ここで拾うのは
        // 始めたあとの変化だけ。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if settings.isEnabled(.photobomb) {
                        guard self.hasBegun else { return }
                        self.startPhotobombWatching()
                    } else {
                        self.photobombWatcher.stop()
                    }
                }
            }
            .store(in: &cancellables)

        // iphonePresence が OFF になった瞬間から、検知エンジンの iPhone 情報を
        // 固定する。ON に戻ったら SSE のイベントがまた流れ始めるので、ここで
        // 立て直す必要はない。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self, !settings.isEnabled(.iphonePresence) else { return }
                    self.detection.iphoneState = .unreachable
                    self.detection.iphoneForegroundApp = nil
                }
            }
            .store(in: &cancellables)

        // トグルの変化をデーモンへ伝える。初回の配信は現在値で、begin() が明示的に
        // 送るぶんと重なるので落とす。
        safety.$settings
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pushSafetyToDaemon()
                }
            }
            .store(in: &cancellables)

        // トグルの変化を権限モデルへ流し込む。必須権限はトグルから導出するので、
        // 設定が変わったら必ず追従させる(#51)。初回配信は `launch()` が apply 済み。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    self?.permissions.apply(settings: settings)
                }
            }
            .store(in: &cancellables)

        // iPhone スクショのトグルを OFF にしたら tunneld の LaunchDaemon を解除する。
        // 登録は管理者パスワードで行う以上、OFF にした機能の常駐をこっそり残さない。
        // ON に戻したときはオンボーディング画面から登録し直す。#51。
        safety.$settings
            .map { $0.isEnabled(.iphoneScreenshot) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self, !enabled else { return }
                    Task { await self.tunneld.uninstall() }
                }
            }
            .store(in: &cancellables)

        // quitLock の ON/OFF に合わせて、終了ブロックの仕掛けを入れ / 解く。
        // ON→OFF はロック中には起きない(SafetyPolicy が弾く)。begin() 自身も
        // applyQuitLockPolicy() を呼んでいるので、初回の配信は状態を覚えるだけ。
        safety.$settings
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let isOn = settings.isEnabled(.quitLock)
                    guard let previous = self.quitLockPolicyState else {
                        self.quitLockPolicyState = isOn
                        return
                    }
                    guard previous != isOn else { return }
                    self.quitLockPolicyState = isOn
                    self.applyQuitLockPolicy()
                    if isOn {
                        // デーモンは起動済みなので、そのまま解除時刻を確定できる。
                        Task { await self.establishFreshQuitLockDeadline() }
                    }
                }
            }
            .store(in: &cancellables)

        // デーモン(SSE)の接続が回復したときにも再送する。接続はデーモンの再起動の
        // たびに切れて張り直されるので、その間に変わった設定を取り戻す。
        daemon.$isStreamConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pushSafetyToDaemon()
                }
            }
            .store(in: &cancellables)
    }

    /// いまのセーフティートグルをデーモンへ伝える。
    ///
    /// サーバ側の受信は #50 で実装される。まだ実装されていなくても失敗するだけで、
    /// 送る側は握りつぶして続ける(次に設定が変わるか接続が戻ったときに再送される)。
    /// 失敗の理由だけはログに残す。
    private func pushSafetyToDaemon() {
        let client = daemon.connectedClient
        let payload = safety.daemonPayload
        Task {
            do {
                try await client?.updateSafety(payload)
            } catch {
                Self.logger.error(
                    "セーフティー設定をデーモンに送れなかった: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func applyIPhoneState(_ event: DaemonEvent) {
        guard let raw = event.payload["activity"] else { return }
        switch raw {
        case "active": detection.iphoneState = .active
        case "idle": detection.iphoneState = .idle
        // Python 側は状態取得を "unresponsive"、セリフ生成を "unreachable" と呼んでいる。
        // どちらも「iPhone から返事が無い」で、Swift では同じ 1 つの値に寄せる。
        default: detection.iphoneState = .unreachable
        }
        // 触っていないときの「前に開いていたアプリ」は古い情報でしかない。持ち越さない。
        guard raw == "active" else {
            detection.iphoneForegroundApp = nil
            return
        }
        detection.iphoneForegroundApp =
            Self.payloadText(event.payload["foreground_app_name"])
            ?? Self.payloadText(event.payload["foreground_bundle_id"])
    }

    /// payload の文字列から「中身のある値」だけを取り出す。
    ///
    /// `DaemonEvent` は payload を表示用の文字列に潰すので、JSON の null は `"null"` という
    /// 文字列で届く。空文字と併せて、無かったことにする。
    private static func payloadText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        return trimmed
    }

    // Vision の解析は画面の都合と無関係なので、メインアクタから外して実行する。
    nonisolated private static func photoData(from capture: CaptureService) async -> Data? {
        guard let artifact = try? await capture.capturePhoto() else { return nil }
        let data = try? Data(contentsOf: artifact.url)
        // 送信のあとに残す理由がない。読み終えたらすぐ消す。
        try? artifact.delete()
        return data
    }

    nonisolated private static func visionLabel(for data: Data) -> SpeechRequest.VisionLabel {
        guard let image = try? CaptureImageCodec.decode(data) else { return .unknown }
        return VisionLabelClassifier.classify(outcome: FaceVisionAnalyzer.analyze(image))
    }
}

/// セーフティー設定画面のルート View。
///
/// `isWatching` は設定画面を開いている間に変わりうる(メニューから監視を止める /
/// 再開するため)。コーディネーターを `@ObservedObject` で観察して `SafetyModeView` を
/// 組み立て直すことで、開いたままの `isWatching` の変化を画面に映す。
/// オンボーディングは常に false なので、このラッパーは設定画面専用。
@MainActor
private struct SafetySettingsHost: View {
    @ObservedObject var coordinator: AppCoordinator
    /// quitLock トグルなど設定の変化で `canUninstall` / `isWatching` を再評価するための
    /// 観察対象。`SafetyModeView` 自身も `safety` を観察して body を作り直されるが、
    /// init で受け取った `canUninstall` の値はホストが body を作り直さないと更新されない。
    @ObservedObject private var safety: SafetySettingsStore

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        safety = coordinator.safety
    }

    var body: some View {
        SafetyModeView(
            safety: safety,
            permissions: coordinator.permissions,
            tunneld: coordinator.tunneld,
            isWatching: coordinator.isWatching,
            lockedUntil: coordinator.safetyLockUntil,
            context: .settings(onClose: { [weak coordinator] in
                coordinator?.closeSettings()
            }),
            onFeatureEnabled: { [weak coordinator] feature in
                coordinator?.handleFeatureEnabled(feature)
            },
            onUninstall: { [weak coordinator] in
                coordinator?.uninstall()
            },
            canUninstall: coordinator.canUninstall
        )
    }
}
