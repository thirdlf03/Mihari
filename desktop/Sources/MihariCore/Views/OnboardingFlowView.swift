import Combine
import SwiftUI

/// 初回起動のオンボーディング。丁寧な5ステップ。
///
/// 0. ようこそ(`OnboardingWelcomeView`): Mihariが何者か・所要時間
/// 1. コース選択(`OnboardingCourseView`): おためし/おすすめ/本気のプリセット
/// 2. 微調整(任意・`SafetyModeView`): 7トグルを1つずつ選びたい人向け
/// 3. 権限の確認(`OnboardingView`): ONにした機能に必要な権限だけ。不要なら飛ばす
/// 4. 終了ロックの確認(`OnboardingQuitLockConfirmView`): quitLock ONのときだけ割り込む
/// 5. 完了(`OnboardingCompletionView`): 何が起きるかを渡してから開始
///
/// 以前は初手が7トグルの `SafetyModeView` だったが、価値提示なしにリスク判断を
/// 迫る形だったためプリセット制にした。`SafetyModeView` は微調整ステップに残す。
@MainActor
public struct OnboardingFlowView: View {

    private enum Step {
        case welcome
        case course
        case fineTune
        case permissions
        case quitLockConfirm
        case done
    }

    @ObservedObject private var safety: SafetySettingsStore
    @ObservedObject private var permissions: PermissionsModel
    /// iPhone スクショが ON になったときに tunneld を登録するためのモデル。
    /// 画面表示は既存 `OnboardingView` が自分で持つモデルで行う。
    @ObservedObject private var tunneld: TunneldModel
    /// オンボーディングを終えて見張り始める処理。`AppCoordinator` 側が
    /// モード選択完了の記録 → ウィンドウを閉じる → `begin()` を行う。
    private let onStart: () -> Void
    /// 「Discord に晒す」を ON にした人が、完了画面から設定へ飛べるようにする二次導線。
    private let onOpenDiscordSettings: (() -> Void)?

    @State private var step: Step = .welcome

    /// - Parameters:
    ///   - safety: セーフティートグル。コース選択とステップスキップ判定に使う。
    ///   - permissions: 権限確認ステップのモデル。
    ///   - tunneld: iphoneScreenshot を ON にしたときの登録に使う。
    ///   - onStart: オンボーディングを終えてアプリ本体へ進む処理。
    public init(
        safety: SafetySettingsStore,
        permissions: PermissionsModel,
        tunneld: TunneldModel,
        onStart: @escaping () -> Void,
        onOpenDiscordSettings: (() -> Void)? = nil
    ) {
        self.safety = safety
        self.permissions = permissions
        self.tunneld = tunneld
        self.onStart = onStart
        self.onOpenDiscordSettings = onOpenDiscordSettings
    }

    public var body: some View {
        ZStack {
            switch step {
            case .welcome:
                OnboardingWelcomeView {
                    step = .course
                }
                .transition(.move(edge: .trailing))
            case .course:
                OnboardingCourseView(
                    safety: safety,
                    onNext: goForwardFromCourse,
                    onFineTune: { step = .fineTune },
                    onBack: { step = .welcome },
                    progressLabel: progressLabel
                )
                .transition(.move(edge: .trailing))
            case .fineTune:
                fineTuneStep
                    .transition(.move(edge: .trailing))
            case .permissions:
                permissionsStep
                    .transition(.move(edge: .trailing))
            case .quitLockConfirm:
                OnboardingQuitLockConfirmView(
                    onBack: { step = .course },
                    onConfirm: { step = .done },
                    progressLabel: progressLabel
                )
                .transition(.move(edge: .trailing))
            case .done:
                OnboardingCompletionView(
                    enabledNames: SafetyFeature.allCases
                        .filter { safety.isEnabled($0) }
                        .map(\.title),
                    showsDiscordNote: safety.isEnabled(.discordExposure),
                    onBack: goBackFromDone,
                    onStart: onStart,
                    onOpenDiscordSettings: onOpenDiscordSettings,
                    progressLabel: progressLabel
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        // 必須権限はトグルから導出するので、コース・微調整でトグルを動かすたびに
        // 権限モデルへ流し込む。`AppCoordinator.observeSafety()` は `begin()` 後にしか
        // 配線されず、オンボーディング中の変更を拾えない(#51)。
        .onReceive(safety.$settings) { settings in
            permissions.apply(settings: settings)
        }
    }

    /// コース選択の「次へ」。権限ステップが不要なら飛ばす。
    private func goForwardFromCourse() {
        permissions.apply(settings: safety.settings)
        if shouldSkipPermissionsStep {
            goForwardFromPermissions()
        } else {
            step = .permissions
        }
    }

    /// 権限ステップの次。quitLock が ON なら確認を割り込ませる。
    private func goForwardFromPermissions() {
        if safety.isEnabled(.quitLock) {
            step = .quitLockConfirm
        } else {
            step = .done
        }
    }

    /// 完了画面の「戻る」。来た道に戻す(権限を飛ばした人はコースへ)。
    private func goBackFromDone() {
        if safety.isEnabled(.quitLock) {
            step = .quitLockConfirm
        } else if shouldSkipPermissionsStep {
            step = .course
        } else {
            step = .permissions
        }
    }

    /// 権限画面に見せるものが無いか。
    private var shouldSkipPermissionsStep: Bool {
        SafetyModeViewModel.shouldSkipPermissionsStep(
            relevantKinds: permissions.relevantKinds,
            isIPhoneScreenshotEnabled: safety.isEnabled(.iphoneScreenshot)
        )
    }

    /// 数字を振る主ステップの列。権限を飛ばすかで列が変わる(終了ロック確認は完了の前段)。
    private var numberedSteps: [Step] {
        var steps: [Step] = [.course]
        if !shouldSkipPermissionsStep {
            steps.append(.permissions)
        }
        steps.append(.done)
        return steps
    }

    /// いま数字を振った何番目のステップにいるか。
    private var numberedStepIndex: Int {
        switch step {
        case .welcome: return 0
        case .course, .fineTune: return 0
        case .permissions: return 1
        case .quitLockConfirm, .done: return numberedSteps.count - 1
        }
    }

    /// ヘッダーに出すステップ表示(例「1/3」)。
    private var progressLabel: String {
        "\(numberedStepIndex + 1)/\(numberedSteps.count)"
    }

    /// 微調整ステップ(既存 `SafetyModeView` の流用)。
    ///
    /// コースでプリセットを当てたあと、1つずつ変えたい人だけが来る。
    /// フッターは権限ステップの要否で文言を切り替える。
    @ViewBuilder
    private var fineTuneStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left") {
                    step = .course
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("細かく選ぶ(任意)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            SafetyModeView(
                safety: safety,
                permissions: permissions,
                tunneld: tunneld,
                isWatching: false,
                // オンボーディングの時点ではまだ見張り始めていないので、ロックも無い。
                lockedUntil: nil,
                context: .onboarding(
                    caption: shouldSkipPermissionsStep
                        ? "このまま進むと権限の確認なしに完了画面へ進みます。"
                        : "ON にした機能に必要な権限を次の画面で確認します。",
                    nextTitle: shouldSkipPermissionsStep ? "完了画面へ" : "次へ(権限の確認)",
                    onNext: {
                        permissions.apply(settings: safety.settings)
                        if shouldSkipPermissionsStep {
                            goForwardFromPermissions()
                        } else {
                            step = .permissions
                        }
                    }
                ),
                onFeatureEnabled: { feature in
                    Task { await enableFeature(feature) }
                },
                // オンボーディングにはアンインストールの入り口を置かない。#55
                onUninstall: nil,
                canUninstall: false
            )
        }
    }

    @ViewBuilder
    private var permissionsStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left") {
                    step = .course
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text("\(progressLabel) 権限の確認")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // ステップ 1 と同じ tunneld インスタンスを渡す。別インスタンスだと、
            // 「登録する…」が二重の管理者パスワードダイアログを呼んでしまうため。
            OnboardingView(
                model: permissions,
                tunneld: tunneld,
                safety: safety,
                onNext: goForwardFromPermissions
            )
        }
    }

    /// コース・微調整で ON になった機能の事後処理。`AppCoordinator` 側の
    /// `onFeatureEnabled` と同じ意味の動きを、このフロー専用に持つ。
    ///
    /// 権限プロンプトの自動発火はしない(`OnboardingView` 側で明示操作に寄せた)。
    /// ここでは状態の再チェックだけ行い、tunneld の自動登録もしない
    /// (権限画面でユーザーが「登録する…」を押したときだけ)。
    private func enableFeature(_ feature: SafetyFeature) async {
        permissions.refresh()
        if feature == .iphoneScreenshot {
            await tunneld.refresh()
        }
    }
}
