import AppKit
import SwiftUI

/// 起動時に出す権限オンボーディング。
///
/// Mihari は本人の顔と画面を Discord に送るアプリなので、
/// 「どの権限が何に使われるか」を最初に見せることを画面の役割の中心に置いている。
///
/// プロンプトの自動発火はしない。画面表示と同時に TCC ダイアログを連打すると
/// 読む前に判断を迫ることになるため、「まとめて許可を求める」など明示操作でのみ要求する。
public struct OnboardingView: View {
    @ObservedObject var model: PermissionsModel
    /// iPhone スクショに必要な tunneld の常駐状態。TCC の権限ではないが、
    /// 「最初に 1 回だけ承認する」という意味でこの画面に並べる。
    /// 解除(ON→OFF)は `AppCoordinator` がトグル購読で行うため、こちらで持たない。
    @ObservedObject var tunneld: TunneldModel
    /// セーフティー設定。不足の必須権限を OFF にして進む逃げ道に使う。
    /// 渡さなければ従来どおりゲートのみ(設定タブなど)。
    private var safety: SafetySettingsStore?
    /// 「始める」を押したときの処理。必須権限が揃うまでボタンは押せない(旧フロー用)。
    private let onStart: (() -> Void)?
    /// 新フロー用の「次へ」。不足があっても「OFFにして進む」で先へ行ける。
    private let onNext: (() -> Void)?
    /// 「閉じる」を押したときの処理。すでに見張っている状態で開き直したときに使う。
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - onStart: 渡すと「始める」ボタンを出す。必須権限が揃うまで押せない(旧フロー)。
    ///   - onNext: 渡すと「次へ」ボタンを出す。不足時は「OFFにして進む」も出す(新フロー)。
    ///   - safety: 不足分を OFF にして進むために使う。新フロー・起動時フローで渡す。
    ///   - onClose: 渡すと「閉じる」ボタンを出す。`onStart`/`onNext` を渡したときはそちらが優先される。
    public init(
        model: PermissionsModel,
        tunneld: TunneldModel,
        safety: SafetySettingsStore? = nil,
        onStart: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.model = model
        self.tunneld = tunneld
        self.safety = safety
        self.onStart = onStart
        self.onNext = onNext
        self.onClose = onClose
    }

    public var body: some View {
        // 権限の行数だけ縦に伸びるので、ウィンドウを縮めてもヘッダーが見切れないようスクロールさせる。
        ScrollView {
            content
        }
        .task {
            model.refresh()
            await tunneld.refresh()
            // 初回でも自動でプロンプトを出さない。読む前に TCC ダイアログを連打すると
            // 判断できないまま拒否されがちなので、明示操作でのみ要求する。
            // (`PermissionsModel.requestOnFirstLaunchIfNeeded` は後方互換のため残す)
        }
        // システム設定で許可してから戻ってきたときに、押し直さなくても反映されるようにする。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
            Task { await tunneld.refresh() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 0) {
                ForEach(Array(model.relevantKinds.enumerated()), id: \.element.id) { index, kind in
                    PermissionRow(
                        kind: kind,
                        state: model.state(for: kind),
                        onRequest: { Task { await model.request(kind) } },
                        onOpenSettings: { model.openSettings(for: kind) }
                    )
                    if index < model.relevantKinds.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if model.settings.isEnabled(.iphoneScreenshot) {
                tunneldSection
            }

            if model.settings.isEnabled(.discordExposure) {
                // 設定ウィンドウの「権限」タブとして開いたときは「開始後に」が文脈に合わない。
                // 同じウィンドウの隣にある Discord タブで今すぐ設定できるため、出さない。
                if !isSettingsContext {
                    discordNote
                }
            }

            if let message = model.lastMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            footer

            notes
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画面を閉じて先へ進むためのボタン。呼び出し側が渡した処理に応じて出し分ける。
    @ViewBuilder private var footer: some View {
        if let onNext {
            // 新フロー: 不足があっても詰ませない。「OFFにして進む」の逃げ道を出す。
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("次へ", action: onNext)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.isRequiredSatisfied)
                    Spacer()
                }
                if !model.isRequiredSatisfied {
                    Text("必須の権限が足りません: \(model.missingRequired.map(\.title).joined(separator: " / "))")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("拒否したまま進めます。該当の機能を OFF にして先へ進み、あとから設定画面で変えられます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if safety != nil {
                        Button("不足分の機能を OFF にして進む") {
                            disableMissingFeatures()
                            onNext()
                        }
                        .controlSize(.small)
                    } else {
                        Text("進むには「戻る」で機能を OFF にしてください。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let onStart {
            // 旧フロー(起動時の権限ウィンドウ): 同じ逃げ道を出す。
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("始める", action: onStart)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.isRequiredSatisfied)
                    Spacer()
                }
                if !model.isRequiredSatisfied {
                    Text("必須の権限が足りません: \(model.missingRequired.map(\.title).joined(separator: " / "))")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if safety != nil {
                        Button("不足分の機能を OFF にして始める") {
                            disableMissingFeatures()
                            onStart()
                        }
                        .controlSize(.small)
                    }
                }
            }
        } else if let onClose {
            HStack {
                Button("閉じる", action: onClose)
                    .controlSize(.large)
                Spacer()
            }
        }
    }

    /// 不足している必須権限に対応する機能を OFF にする。
    ///
    /// `PermissionKind.feature` からトグルを逆引きして OFF にする。
    /// 拒否した権限で詰ませないための逃げ道。OFF 方向は常に即時なので安全側。
    private func disableMissingFeatures() {
        guard let safety else { return }
        for kind in model.missingRequired {
            guard let feature = kind.feature else { continue }
            _ = safety.request(.disable(feature), isWatching: false)
        }
        model.apply(settings: safety.settings)
        model.refresh()
    }

    /// 設定ウィンドウとして開いているときは、注記が「設定画面で登録」と自分自身を
    /// 指す循環になるため、その場で登録できる旨に言い換える。
    private var tunneldCaption: String {
        if isSettingsContext {
            return "iOS 17+ のスクショに必要なトンネルです。このまま「登録する…」で登録できます(管理者パスワードが 1 回だけ必要です)。"
        }
        return "iOS 17+ のスクショに必要なトンネルを OS に常駐させます。登録は管理者パスワードで 1 回だけです。スキップして後から設定画面で登録もできます。"
    }

    /// iPhone スクショ(iOS 17+)に必要な tunneld の常駐を、この画面から登録できるようにする。
    /// tunneld は root でしか動かせないため、管理者パスワードダイアログを 1 回だけ出して
    /// launchd(LaunchDaemon)に任せる。以後は再起動しても自動で立ち上がる。
    private var tunneldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone スクショの常駐(tunneld)").font(.headline)
                    Text(tunneldCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch tunneld.status {
                case .running:
                    Label("常駐中", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .installing:
                    ProgressView().controlSize(.small)
                case .checking, .unknown:
                    Text("確認中…").font(.callout).foregroundStyle(.secondary)
                case .notRunning:
                    Button("登録する…") { Task { await tunneld.install() } }
                }
            }
            if let message = tunneld.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Discord を ON にした人への案内。Bot 設定はデーモン起動前にはできないため、
    /// この画面では「後で設定画面から」の旨だけ伝える。
    private var discordNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Discord の Bot 設定は開始後に")
                    .font(.callout).bold()
                Text("Bot トークンと投稿先チャンネルは、開始後に 設定… → Discord タブから設定します。今はスキップして大丈夫です(未設定の間は投稿されません)。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("権限の確認").font(.title2).bold()
            Text("ON にした機能に必要な権限だけ確認します。許可を求めるのはボタンを押したときだけです。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let names = enabledFeatureNames {
                Text("ON にした機能: \(names)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("まとめて許可を求める") { Task { await model.requestAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRequesting)

                Button("すべて再チェック") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRequesting)

                Spacer()
            }
            // 最終チェック時刻と要約は 600 幅だと 1 行に収まらないので、ボタンの下の行に置く。
            HStack(spacing: 12) {
                if let at = model.lastCheckedAt {
                    Text("最終チェック: \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(model.pending.isEmpty ? .green : .orange)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    /// 設定ウィンドウの「権限」タブとして開いているか。
    ///
    /// `openSettings` は `onClose` だけを渡して開く。起動時の「始める」フロー
    /// (`onStart`)やオンボーディングの権限ステップ(`onNext`)では false になる。
    private var isSettingsContext: Bool {
        onStart == nil && onNext == nil
    }

    /// ON にしている機能の名前を並べた 1 行。1 つも ON でなければ nil。
    ///
    /// 「何のためにこの権限を聞かれているのか」は、ON にした機能を並べて示す。
    private var enabledFeatureNames: String? {
        let names = SafetyFeature.allCases
            .filter { model.settings.isEnabled($0) }
            .map(\.title)
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var summary: String {
        let pending = model.pending
        if pending.isEmpty {
            return "すべて許可済み"
        }
        return "未許可: \(pending.map(\.title).joined(separator: " / "))"
    }

    /// TCC の挙動についての注記。開発者向けなので `MIHARI_DEBUG_UI=1` のときだけ出す。
    @ViewBuilder private var notes: some View {
        if AppCoordinator.isDebugUIRequested {
            VStack(alignment: .leading, spacing: 6) {
                noteText(
                    "TCC の許可はプロセスではなくバンドルの署名単位で記録されます。ad-hoc 署名は再ビルドで署名が変わりうるため、一度許可した権限が再ビルド後に効かなくなることがあります。その場合はシステム設定から一度削除して登録し直してください。"
                )
                noteText(
                    "「画面収録」は事前照会の API が CGPreflightScreenCaptureAccess しかなく、未決定と拒否済みを区別できません。false のときは灰色で出ます。"
                )
                noteText(
                    "「オートメーション」は Music と Spotify を別々に照会し、どちらかが許可なら足ります。対象アプリが起動していないと判定できません。プロンプトは実際に命令を送った瞬間にだけ出ます。"
                )
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
