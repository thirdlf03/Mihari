import AppKit
import SwiftUI

/// セーフティーの「モードを選ぶ画面」(オンボーディング 1 枚目)と「設定画面」。
///
/// 見た目は designer 提案(design-54.md)に従う。カードの文言は `SafetyFeature` の
/// `title` / `summary` / `destination` / `permissionNote` をそのまま使い、この View に
/// 文言を書かない。Toggle の操作は必ず `safety.request` を通し、結果の表示は
/// `SafetyModeViewModel` の純粋関数に委ねる(テストはそちらに対して書く)。
@MainActor
public struct SafetyModeView: View {

    /// この画面が置かれる場所。フッターと「設定画面のみ」の表示を出し分ける。
    public enum Context {
        /// オンボーディングの 1 枚目。ボタンで次へ進む。
        ///
        /// キャプションとボタンの文言は呼び側(`OnboardingFlowView`)が決める。権限
        /// ステップを飛ばせるときは「次へ」ではなく、そこで終わることが分かる文言になる。
        case onboarding(caption: String, nextTitle: String, onNext: () -> Void)
        /// 右クリックメニューから開く設定画面。「閉じる」で閉じる。
        case settings(onClose: () -> Void)
    }

    @ObservedObject private var safety: SafetySettingsStore
    /// カードの権限行に出す TCC 権限の状態。ON にした直後にプロンプトを断られても
    /// 気づけるように、静的な案内ではなくこのモデルの状態を出す。
    @ObservedObject private var permissions: PermissionsModel
    /// カードの権限行に出す tunneld の常駐状態(iphoneScreenshot 用)。
    @ObservedObject private var tunneld: TunneldModel
    /// いま監視中か。呼び側が渡す(オンボーディングでは常に false)。
    /// 値の変化は呼び側が `@ObservedObject` 経由で View を作り直して映す。
    private let isWatching: Bool
    /// 終了ロックの解除時刻。ロック中でなければ nil(オンボーディングでは常に nil)。
    ///
    /// ロック中は監視を止めていても #5 を OFF にできないが、それを「監視中」と書くと
    /// 監視を止めた人を混乱させるので、監視とロックは分けて受け取る(#52)。
    private let lockedUntil: Date?
    private let context: Context
    private let onFeatureEnabled: (SafetyFeature) -> Void
    /// 「Mihari をアンインストール…」を押したときの処理。設定画面だけ渡す
    /// (オンボーディングでは nil で、ボタン自体を出さない)。#55
    private let onUninstall: (() -> Void)?
    /// アンインストールできるか。quitLock が ON のロック中は false で、
    /// ボタンを押せなくして理由を隣に出す。オンボーディングでは false。#55
    private let canUninstall: Bool

    /// カードの状態行に 3 秒だけ出す文言。機能ごとに持つ。
    @State private var cardMessages: [SafetyFeature: String] = [:]
    /// 3 秒後の消去タスク。前のが残っているうちに次の操作をしたら張り直す。
    @State private var messageTasks: [SafetyFeature: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - permissions: TCC 権限の状態。カードの権限行に映す。
    ///   - tunneld: tunneld の常駐状態。カードの権限行に映し、「登録する…」から使う。
    ///   - isWatching: いま監視中か。設定画面では `AppCoordinator` の `isWatching` を映す。
    ///   - lockedUntil: 終了ロックの解除時刻。ロック中でなければ nil。
    ///   - onFeatureEnabled: ON に成功した(`.apply` で新たに ON になった)機能ごとに呼ばれる。
    ///     呼び側が権限要求・tunneld 登録に使う。
    ///   - onUninstall: 「Mihari をアンインストール…」の処理。設定画面だけ渡し、
    ///     オンボーディングでは nil。
    ///   - canUninstall: アンインストールできるか。オンボーディングでは false。
    public init(
        safety: SafetySettingsStore,
        permissions: PermissionsModel,
        tunneld: TunneldModel,
        isWatching: Bool,
        lockedUntil: Date?,
        context: Context,
        onFeatureEnabled: @escaping (SafetyFeature) -> Void,
        onUninstall: (() -> Void)?,
        canUninstall: Bool
    ) {
        self.safety = safety
        self.permissions = permissions
        self.tunneld = tunneld
        self.isWatching = isWatching
        self.lockedUntil = lockedUntil
        self.context = context
        self.onFeatureEnabled = onFeatureEnabled
        self.onUninstall = onUninstall
        self.canUninstall = canUninstall
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.bar)
            Divider()
            ScrollView {
                scrollContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .task {
            // 開いた時点の状態を映す。ここで見に行かないと、別の場所で拒否・解除された
            // 権限が古いまま「許可済み」に見えてしまう。
            permissions.refresh()
            if safety.isEnabled(.iphoneScreenshot) {
                await tunneld.refresh()
            }
        }
    }

    // MARK: - 固定ヘッダー

    /// モード名・モードの一言・7 個のインジケータ。どれもスクロールしない。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    safety.mode.label,
                    systemImage: SafetyModeViewModel.modeIcon(for: safety.mode)
                )
                .font(.title2.bold())
                .foregroundStyle(Self.modeColor(for: safety.mode))
                // モードが変わるとき、色とアイコンだけ 0.15 秒で滑らかに切り替える。
                .animation(.easeInOut(duration: 0.15), value: safety.mode)

                Spacer()

                Button("全部 ON(終了ロックを含む)") { applyAllOn() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(safety.settings.enabled.count == SafetyFeature.total)
                Button("全部 OFF") { applyAllOff() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(safety.settings.enabled.isEmpty)
            }

            Text(SafetyModeViewModel.modeSubtitle(for: safety.mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            indicators
                // インジケータの色もモードが変わるときだけ 0.15 秒で滑らかにする。
                .animation(.easeInOut(duration: 0.15), value: safety.mode)
        }
    }

    /// 7 個のインジケータ。ON = アクセント、OFF = 薄いグレー、
    /// 依存で無効 = 輪郭のみ、予約中 = オレンジ。
    private var indicators: some View {
        HStack(spacing: 10) {
            ForEach(SafetyFeature.allCases, id: \.self) { feature in
                indicator(for: feature)
            }
        }
    }

    private func indicator(for feature: SafetyFeature) -> some View {
        VStack(spacing: 2) {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundStyle(indicatorFill(for: feature))
                .overlay {
                    if isDependencyDisabled(feature) {
                        Circle().strokeBorder(Color.secondary, lineWidth: 1)
                    }
                }
            Text(SafetyModeViewModel.shortFeatureName(for: feature))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
    }

    private func indicatorFill(for feature: SafetyFeature) -> Color {
        if isPending(feature) {
            return .orange
        }
        if safety.isEnabled(feature) {
            return .accentColor
        }
        if isDependencyDisabled(feature) {
            return .clear
        }
        return Color.secondary.opacity(0.35)
    }

    // MARK: - カード一覧

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // このトグルは「ON にする操作を 24 時間後にする」という影響の大きい設定なので、
            // カードより先に見せる(design-54.md / 視線誘導)。カードの下にあると、
            // 後から ON にしたとき予約になることを知らないまま押してしまう。
            changeLaterRow

            Divider()

            ForEach(SafetyFeature.allCases, id: \.self) { feature in
                card(for: feature)
            }

            if case .settings = context, isPending {
                bottomPendingBand
            }
        }
    }

    /// 1 枚のカード。前提がまだ ON でない従属(iphonePresence が ON でないときの
    /// iphoneScreenshot)は、親カードの下辺から吊り線でぶら下がる形にする。
    ///
    /// 前提が予約中なら従属も同じ予約に積めるので、吊り線と 1 行の説明は出すが、
    /// 沈めない(押せるカードなので)。
    @ViewBuilder
    private func card(for feature: SafetyFeature) -> some View {
        if let note = dependencyNote(for: feature) {
            VStack(alignment: .leading, spacing: 0) {
                // 吊り線: 親カードの下辺から縦 12pt、横 22pt。カード間の 12pt をまたいで
                // 親の下辺に届くよう、ブロックの上端から 12pt 上へずらし、横線はカードの
                // 上端の高さに合わせる。
                HStack(alignment: .bottom, spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 2, height: 12)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 22, height: 2)
                    Spacer(minLength: 0)
                }
                .offset(y: -12)

                // この行だけ opacity 1(選べないときのカード本体は 0.5 で沈める)。
                Label(note, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
                    .padding(.bottom, 4)

                cardBody(for: feature)
                    .padding(.leading, 24)
                    .opacity(isDependencyDisabled(feature) ? 0.5 : 1)
            }
        } else {
            cardBody(for: feature)
        }
    }

    private func cardBody(for feature: SafetyFeature) -> some View {
        HStack(spacing: 0) {
            // 左端の 3pt バー。ON のときだけアクセント、予約中はオレンジ、それ以外は透明。
            Rectangle()
                .fill(leftBarColor(for: feature))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let note = lockedRowNote(for: feature) {
                        Label(note, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: toggleBinding(for: feature))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(isToggleDisabled(for: feature))
                }

                // 注意帯。iphoneScreenshot と quitLock の 2 枚だけ。
                if let notice = SafetyModeViewModel.notice(for: feature) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("送り先")
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.secondary)
                        Text(feature.destination)
                            .font(.callout)
                    }
                    GridRow {
                        Text("権限")
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.secondary)
                        permissionValue(for: feature)
                    }
                }

                statusRow(for: feature)
            }
            .padding(14)
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            // 従属(前提が OFF)で選べないときは、点線の縁取りで「押せない」ことを
            // はっきり示す(opacity 0.5 だけでは沈みが弱く、前後のカードと紛れる)。
            if isDependencyDisabled(feature) {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4])
                    )
            }
        }
    }

    /// カードの「権限」行の中身。
    ///
    /// トグルが OFF のうちは何が要るかの静的な案内、ON にしたあとはいまの許可状態を出す。
    /// 未許可・未登録のときは、そこから先へ進めるボタンを添える。
    @ViewBuilder
    private func permissionValue(for feature: SafetyFeature) -> some View {
        switch permissionRowState(for: feature) {
        case .staticNote(let text):
            Text(text)
                .font(.callout)
        case .satisfied(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .working(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .missing(let text, let actionTitle, let action):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                // このカードの主たる行動なので、余白の警告文より目立たせる。
                Button(actionTitle) { perform(action, for: feature) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func permissionRowState(for feature: SafetyFeature) -> SafetyModeViewModel.PermissionRowState {
        let kind = permissionKind(for: feature)
        return SafetyModeViewModel.permissionRow(
            for: feature,
            isEnabled: safety.isEnabled(feature),
            kind: kind,
            grant: kind.map { permissions.state(for: $0).grant },
            tunneld: feature == .iphoneScreenshot
                ? SafetyModeViewModel.readiness(of: tunneld.status)
                : nil
        )
    }

    /// この機能が要求する TCC 権限。要らない機能では nil。
    private func permissionKind(for feature: SafetyFeature) -> PermissionKind? {
        PermissionKind.allCases.first { $0.feature == feature }
    }

    /// 権限行のボタンを押したとき。
    private func perform(_ action: SafetyModeViewModel.PermissionRowAction, for feature: SafetyFeature) {
        switch action {
        case .openSystemSettings:
            // 一度断られた TCC はアプリから再要求できないので、システム設定へ送る。
            guard let kind = permissionKind(for: feature) else { return }
            permissions.openSettings(for: kind)
        case .installTunneld:
            Task { await tunneld.install() }
        }
    }

    /// 状態行。操作の結果の文言を出す。
    ///
    /// 予約(発効待ち)の表示は `bottomPendingBand` に 1 本にまとめる。カード内に出すと
    /// 発効が近い何枚かに同じ予約が並び、視線が分散するため。
    @ViewBuilder
    private func statusRow(for feature: SafetyFeature) -> some View {
        if let message = cardMessages[feature] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// 予約帯(取り消しボタン付き)。カード内と設定画面の最下部で同じ見た目にする。
    private func pendingBand(text: String, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "clock")
            Spacer()
            Button("取り消す", action: onCancel)
                .controlSize(.small)
        }
        .font(.caption)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 設定画面の最下部の予約帯。カードの予約帯より上に「取り消す」の意味を
    /// 1 本にまとめたいときは閉じる側でカード側を隠すこともできるが、design-54.md は
    /// 両方出す形なのでそのままにする。
    @ViewBuilder
    private var bottomPendingBand: some View {
        if let pending = safety.settings.pendingChange {
            pendingBand(text: SafetyModeViewModel.pendingStatusText(for: pending)) {
                _ = safety.request(.cancelPendingChange, isWatching: isRestricted)
            }
        }
    }

    // MARK: - 最下部の行

    /// 「あとで設定を変えられるようにする」。OFF の間は緩める変更が 24 時間後の予約になる。
    ///
    /// 影響の大きさ(ON を予約にする)を伝えるため、カードより先に見える位置に置き、
    /// 見出しを大きくして背景を敷いてカード相当の目立ち方にする。
    private var changeLaterRow: some View {
        Toggle(isOn: changeLaterBinding) {
            VStack(alignment: .leading, spacing: 4) {
                Text("あとで設定を変えられるようにする")
                    .font(.headline)
                Text(changeLaterCaption)
                    .font(.callout)
                    .foregroundStyle(safety.settings.canChangeLater ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 「あとで設定を変えられるようにする」の説明文。
    ///
    /// ON に戻す操作は予約になり、トグルは OFF のまま戻る。何も起きなかったように
    /// 見えてしまうので、予約中はその旨と発効時刻を書く。
    ///
    /// OFF にすると何が起きるかは、いまの状態にかかわらず必ず添える。ON のうちに
    /// 読めなければ、押したあとで初めて 24 時間待たされることを知ることになる。
    private var changeLaterCaption: String {
        let consequence = "OFF にすると、設定を緩める変更と、この設定を戻す操作が 24 時間後に発効します(予約は取り消せます)。"
        if safety.settings.canChangeLater {
            return "いつでも設定を変えられます。\n\(consequence)"
        }
        if let pending = safety.settings.pendingChange, pending.restoresChangeability {
            let time = SafetyModeViewModel.pendingTimeText(effectiveAt: pending.effectiveAt)
            return "ON に戻す予約中(\(time))\n\(consequence)"
        }
        return consequence
    }

    private var changeLaterBinding: Binding<Bool> {
        Binding(
            get: { safety.settings.canChangeLater },
            set: { enabled in
                _ = safety.request(.setCanChangeLater(enabled), isWatching: isRestricted)
            }
        )
    }

    // MARK: - 固定フッター

    @ViewBuilder
    private var footer: some View {
        switch context {
        case .onboarding(let caption, let nextTitle, let onNext):
            HStack {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(nextTitle, action: onNext)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .settings(let onClose):
            HStack {
                voiceCredit
                Spacer()
                uninstallSection
                Button("閉じる", action: onClose)
                    .controlSize(.large)
            }
        }
    }

    /// 同封音声・live 合成のどちらも VOICEVOX の冥鳴ひまりなので、規約が求める
    /// クレジットをアプリ内にも出す。設定画面のフッターの左端に置く。
    private var voiceCredit: some View {
        Text("音声: VOICEVOX:冥鳴ひまり")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 設定画面の「Mihari をアンインストール…」。フッターの「閉じる」の左に出す。#55
    ///
    /// quitLock が ON のロック中は押せない。押せない理由はキャプションで隣に示し、
    /// ツールチップにも同じ文言を出す。オンボーディングには渡らない(`onUninstall` が nil)。
    @ViewBuilder
    private var uninstallSection: some View {
        if let onUninstall {
            if !canUninstall {
                Text("監視中(ロック中)はアンインストールできません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Mihari をアンインストール…", role: .destructive, action: onUninstall)
                .disabled(!canUninstall)
                .help(canUninstall ? "" : "監視中(ロック中)はアンインストールできません")
        }
    }

    // MARK: - 操作

    /// カードの Toggle を操作したとき。ポリシーに問い合わせて、結果に応じて
    /// 状態行を見せ、ON になった機能を呼び出し側へ知らせる。
    private func handleToggle(for feature: SafetyFeature, turningOn: Bool) {
        clearMessages()
        let previous = safety.settings
        let decision = safety.request(
            SafetyModeViewModel.toggleChange(for: feature, turningOn: turningOn),
            isWatching: isRestricted
        )
        handleDecision(decision, from: previous, affectedFeature: feature)
    }

    private func applyAllOn() {
        clearMessages()
        // 「全部 ON」は終了ロック(quitLock)まで含む強い操作で、必要な許可も複数飛ぶので
        // 確認してから。断っても OFF 方向はいつでも戻せることを添える。
        let alert = NSAlert()
        alert.messageText = "「全部 ON」にしますか?"
        alert.informativeText = [
            "7 つの機能をすべて ON にします。",
            "・「監視中は終了させない」が入り、既定 4 時間はアプリを終了できなくなります",
            "・必要な許可(カメラ / iPhone の画面を撮るの tunneld 登録)がこのあと順に求められます",
            "",
            "許可を断っても、OFF にする操作(一部を除く)はいつでも戻せます。",
        ].joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "全部 ON にする")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let previous = safety.settings
        let decision = safety.request(.enableAll, isWatching: isRestricted)
        // 拒否は起こり得ない(ON はいつでも通る)が、来たときの出し先が要るだけ。
        handleDecision(decision, from: previous, affectedFeature: .macCamera)
    }

    private func applyAllOff() {
        clearMessages()
        let previous = safety.settings
        let decision = safety.request(.disableAll, isWatching: isRestricted)
        handleDecision(decision, from: previous, affectedFeature: .macCamera)
    }

    private func handleDecision(
        _ decision: SafetyDecision,
        from previous: SafetySettings,
        affectedFeature: SafetyFeature
    ) {
        switch decision {
        case .apply(let newSettings, let skipped):
            // ON に成功した機能ごとに、呼び側の権限要求・tunneld 登録を促す。
            // セットのままだと順序が不定で複数のダイアログが重なるので、
            // トグルの並び順(`allCases`)に揃えて「その場で 1 つずつ」に倒す。
            for feature in SafetyFeature.allCases
            where newSettings.enabled.contains(feature) && !previous.enabled.contains(feature) {
                onFeatureEnabled(feature)
            }
            for feature in skipped {
                // 頼んだとおりにできなかった報せなので、成功と違って自分からは消さない。
                showMessage(
                    SafetyModeViewModel.statusMessage(for: decision, lockedUntil: lockedUntil) ?? "",
                    on: feature,
                    transient: false
                )
            }
        case .schedule(let newSettings, _):
            // 予約は最下部の帯に出すが、押したカードにも「いつ ON になるか」を残す。
            // 帯だけだとトグルが戻っただけに見えて、予約の存在に気づけないことがある。
            if let pending = newSettings.pendingChange,
                pending.enabling.contains(affectedFeature)
            {
                showMessage(
                    SafetyModeViewModel.pendingFeatureText(effectiveAt: pending.effectiveAt),
                    on: affectedFeature,
                    transient: false
                )
            }
        case .reject:
            if let message = SafetyModeViewModel.statusMessage(
                for: decision,
                lockedUntil: lockedUntil
            ) {
                showMessage(message, on: affectedFeature, transient: false)
            }
        }
    }

    /// 状態行にメッセージを出す。前のが残っていれば取り消して張り直す。
    ///
    /// - Parameter transient: 3 秒で自分から消えてよいか。断った理由やエラーは消さずに
    ///   次の操作まで残す ―― 3 秒で消えると、拒否されたこと自体に気づけない。
    private func showMessage(_ message: String, on feature: SafetyFeature, transient: Bool) {
        cardMessages[feature] = message
        messageTasks[feature]?.cancel()
        messageTasks[feature] = nil
        guard transient else { return }
        // タスクは @State に持つので、ビューが作り直されても消えない。self は
        // 値型のコピーを捉えるだけで循環はしない。
        messageTasks[feature] = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.cardMessages[feature] = nil
        }
    }

    /// 残っているメッセージを全部消す。次の操作を始める前に呼ぶ。
    private func clearMessages() {
        for task in messageTasks.values {
            task.cancel()
        }
        messageTasks = [:]
        cardMessages = [:]
    }

    private func toggleBinding(for feature: SafetyFeature) -> Binding<Bool> {
        Binding(
            get: { safety.isEnabled(feature) },
            set: { turningOn in handleToggle(for: feature, turningOn: turningOn) }
        )
    }

    // MARK: - 状態

    /// #5 を OFF にできない状態か。監視中か、監視を止めていても終了ロックが残っているとき。
    ///
    /// `SafetyPolicy` に渡す「監視中」はこの値。ロック中に監視だけ止めて縛りごと
    /// 外す抜け道を作らないため、ロック中も監視中として扱う(#52)。
    private var isRestricted: Bool {
        isWatching || lockedUntil != nil
    }

    /// 予約中(発効待ち)か。予約の対象になっている機能と設定画面の最下部で使う。
    private var isPending: Bool {
        safety.settings.pendingChange != nil
    }

    private func isPending(_ feature: SafetyFeature) -> Bool {
        safety.settings.pendingChange?.enabling.contains(feature) == true
    }

    /// 前提(`requires`)のトグルが ON でも予約中でもなく、選べない機能か。
    ///
    /// 前提が予約中(発効待ちの ON に載っている)なら、ポリシーは従属も同じ予約に
    /// 積むことを認める(`SafetyPolicy.decideEnable`)ので、選べないとは扱わない。
    private func isDependencyDisabled(_ feature: SafetyFeature) -> Bool {
        guard let required = feature.requires else { return false }
        return !safety.isEnabled(required) && !isPending(required)
    }

    /// 従属のカードに添える 1 行。前提が ON なら何も添えない。
    private func dependencyNote(for feature: SafetyFeature) -> String? {
        guard let required = feature.requires else { return nil }
        return SafetyModeViewModel.dependencyNote(
            isRequiredEnabled: safety.isEnabled(required),
            isRequiredPending: isPending(required)
        )
    }

    /// Toggle 左に出す錠の行の文言。出るのは #5(quitLock)が ON の監視中だけ。
    ///
    /// ほかのトグルは監視中でも ON も OFF もできるので、錠は出さない。
    ///
    /// - Returns: 出す文言。#5 以外か、OFF にできる状態なら nil。
    private func lockedRowNote(for feature: SafetyFeature) -> String? {
        guard feature == .quitLock, isRestricted, safety.isEnabled(.quitLock) else { return nil }
        return SafetyModeViewModel.quitLockRestrictionNote(
            isWatching: isWatching,
            lockedUntil: lockedUntil
        )
    }

    /// Toggle を押せなくするか。
    ///
    /// 押せないのは前提(`requires`)が OFF の従属だけ。ON はいつでも即時に通り、OFF も
    /// 常に即時なので、監視中・ロック中を理由に押せなくはしない。quitLock が ON の
    /// 監視中は OFF が拒否されるが、その理由を状態行で見せるためあえて押せるままにする。
    private func isToggleDisabled(for feature: SafetyFeature) -> Bool {
        isDependencyDisabled(feature)
    }

    private func leftBarColor(for feature: SafetyFeature) -> Color {
        if isPending(feature) {
            return .orange
        }
        return safety.isEnabled(feature) ? .accentColor : .clear
    }

    /// モードのシンボルカラー。design-54.md の 3 段階をそのまま映す。
    private static func modeColor(for mode: SafetyMode) -> Color {
        switch mode {
        case .safety: return .green
        case .custom: return .accentColor
        case .unlimited: return .orange
        }
    }
}
