import SwiftUI

/// オンボーディングで選べる3コース。
///
/// 7トグルのフル設定(`SafetyModeView`)を初手に見せないためのプリセット。
/// 細かい調整はコース選択後の「微調整」(既存 `SafetyModeView` の流用)で行う。
public enum OnboardingCourse: String, CaseIterable, Identifiable {
    /// おためし: 全 OFF。権限不要でペットと声だけ。
    case trial
    /// おすすめ: 撮る→晒す→説教の基本ループ。カメラ権限のみ。
    case recommended
    /// 本気: 全部 ON。終了ロックあり。
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trial: return "おためし"
        case .recommended: return "おすすめ"
        case .full: return "本気(全部 ON)"
        }
    }

    public var icon: String {
        switch self {
        case .trial: return "leaf.fill"
        case .recommended: return "star.fill"
        case .full: return "flame.fill"
        }
    }

    public var headline: String {
        switch self {
        case .trial: return "権限なしで、まずペットと暮らす"
        case .recommended: return "サボりを撮って、晒して、説教される"
        case .full: return "終了もできない本気の監視"
        }
    }

    public var description: String {
        switch self {
        case .trial:
            return "撮らない・晒さない・縛らない。サボると吹き出しと声で注意するだけです。あとからいつでも強くできます。"
        case .recommended:
            return "サボり確定でカメラ撮影→Discord投稿→全画面説教の基本ループが回ります。iPhone監視や終了ロックは含みません。"
        case .full:
            return "7機能すべてON。iPhone監視・終了ロック(既定4時間)まで効きます。初回はおすすめしません。"
        }
    }

    /// このコースで ON になる機能。
    public var features: Set<SafetyFeature> {
        switch self {
        case .trial: return []
        case .recommended: return [.macCamera, .discordExposure, .sermonTakeover]
        case .full: return Set(SafetyFeature.allCases)
        }
    }

    /// カードに添える権限メモ。
    public var permissionNote: String {
        switch self {
        case .trial: return "必要な権限: なし"
        case .recommended: return "必要な権限: カメラ(必須)・オートメーション(任意)"
        case .full: return "必要な権限: カメラ・tunneld登録(管理者パスワード)ほか"
        }
    }

    /// 推定される保存値から、いま選ばれているコースを逆算する(表示用)。
    public static func matching(_ enabled: Set<SafetyFeature>) -> OnboardingCourse? {
        for course in OnboardingCourse.allCases {
            if course.features == enabled { return course }
        }
        return nil
    }
}

// MARK: - Welcome

/// ようこそ画面。Mihariが何者かを3行で説明してから設定に入る。
public struct OnboardingWelcomeView: View {
    private let onNext: () -> Void

    public init(onNext: @escaping () -> Void) {
        self.onNext = onNext
    }

    public var body: some View {
        // ウィンドウは 600×520 に固定(ウィザード)。フォントサイズの大きな環境でも
        // はみ出さないようスクロールできるようにしてある。
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Mihari へようこそ", systemImage: "pawprint.fill")
                    .font(.title.bold())

                Text("サボりを検知して声で絡み、証拠を Discord に晒す macOS 常駐アプリです。見守るのはデスクトップのペットです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    welcomeRow(
                        icon: "shield.checkmark.fill",
                        title: "既定は全 OFF(セーフティー)",
                        body: "カメラ・Discord・終了ブロックは、あなたが ON にしたものだけ動きます。何も選ばなければ権限も要りません。"
                    )
                    welcomeRow(
                        icon: "slider.horizontal.3",
                        title: "強さは3コースから選ぶだけ",
                        body: "細かい7トグルの調整は後からいつでもできます(設定画面の「セーフティー」タブ)。"
                    )
                    welcomeRow(
                        icon: "clock.fill",
                        title: "所要時間は1〜2分",
                        body: "コース選択 → 権限の確認(必要な場合のみ) → 開始です。終了ロックを選んだ場合だけ確認が1枚増えます。"
                    )
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                // 情報ボックスの直下に固定する。Spacer で底に追いやるとウィンドウを
                // 伸ばしたぶんだけ空白が広がって見えるため。
                Button("はじめる", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
        }
    }

    private func welcomeRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Course selection

/// コース選択画面。3枚のカードから1つ選ぶ。微調整への導線もここに置く。
public struct OnboardingCourseView: View {
    @ObservedObject private var safety: SafetySettingsStore
    private let onNext: () -> Void
    private let onFineTune: () -> Void
    private let onBack: () -> Void
    /// ヘッダーのステップ表示(例「1/3」)。飛ばし・条件ステップを反映した値を呼び側から受ける。
    private let progressLabel: String

    @State private var selected: OnboardingCourse?

    public init(
        safety: SafetySettingsStore,
        onNext: @escaping () -> Void,
        onFineTune: @escaping () -> Void,
        onBack: @escaping () -> Void,
        progressLabel: String = "1/3"
    ) {
        self.safety = safety
        self.onNext = onNext
        self.onFineTune = onFineTune
        self.onBack = onBack
        self.progressLabel = progressLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Text("\(progressLabel) コース選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text("どの強さで見守ってもらう?")
                .font(.title2.bold())
                .padding(.horizontal, 20)
            Text("あとから設定画面で変えられます。迷ったら「おすすめ」か「おためし」から始めてください。「本気」には終了ロック(既定4時間)が含まれます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(OnboardingCourse.allCases) { course in
                        courseCard(for: course)
                    }
                    Button("7つの機能を1つずつ選ぶ(微調整)…") {
                        applySelection()
                        onFineTune()
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            Divider()
            HStack {
                Text(selected == nil ? "コースを選んでください" : footerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("次へ") {
                    applySelection()
                    onNext()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onAppear {
            // 保存値がプリセットと一致すればそれを選択状態にする。一致しなければ未選択。
            selected = OnboardingCourse.matching(safety.settings.enabled)
            // 初期値が全 OFF なら「おためし」を選択済みにする。
            if safety.settings.enabled.isEmpty { selected = .trial }
        }
    }

    private func courseCard(for course: OnboardingCourse) -> some View {
        let isSelected = selected == course
        return Button {
            select(course)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: course.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(course.title).font(.headline)
                        if course == .recommended {
                            Text("おすすめ")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.28), in: Capsule())
                        }
                        if course == .full {
                            Text("終了ロックあり")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(course.headline).font(.callout)
                    Text(course.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(course.permissionNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.1)
                    : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var footerSummary: String {
        guard let selected else { return "" }
        if selected.features.isEmpty { return "おためし: 権限は不要です" }
        return "\(selected.title): \(selected.features.count)機能ON"
    }

    private func select(_ course: OnboardingCourse) {
        // 見た目だけ先に選ばせる。保存は「次へ」「微調整へ」で進むときに `applySelection()`
        // で行う。触っただけで保存すると、選び直し・戻るで戻せない(本気で quitLock まで
        // 入ったまま残る)ため。
        selected = course
    }

    /// 選んだコースのプリセットを設定に反映する。
    ///
    /// `select()` は表示だけ。進む前にここで初めて `safety.request` を実行して保存する。
    /// 依存がある full は enableAll、それ以外は disableAll → 個別 enable の順で整形を通す。
    private func applySelection() {
        guard let selected else { return }
        switch selected {
        case .trial:
            _ = safety.request(.disableAll, isWatching: false)
        case .full:
            _ = safety.request(.enableAll, isWatching: false)
        case .recommended:
            _ = safety.request(.disableAll, isWatching: false)
            for feature in selected.features {
                _ = safety.request(.enable(feature), isWatching: false)
            }
        }
    }
}

// MARK: - QuitLock confirmation

/// 終了ロックの最終確認。ON の場合のみ割り込む。
public struct OnboardingQuitLockConfirmView: View {
    private let onBack: () -> Void
    private let onConfirm: () -> Void
    /// ヘッダーのステップ表示。最後の段階なので「n/n」が入る。
    private let progressLabel: String

    @State private var acknowledged = false

    public init(
        onBack: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        progressLabel: String = "確認"
    ) {
        self.onBack = onBack
        self.onConfirm = onConfirm
        self.progressLabel = progressLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Text("\(progressLabel) 最終確認")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("「監視中は終了させない」が ON です", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.orange)
                    Text("開始した瞬間から既定4時間、アプリを終了できなくなります。本当にこのまま始めますか?")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        confirmRow("LaunchAgent・ログイン項目に登録され、終了シグナルも無視されます")
                        confirmRow("解除は時間が切れるまでできません(設定からOFFにもできません)")
                        confirmRow("正規の出口は「どうしても終了する…」(10分のカウントダウン+戻る時刻の宣言)です")
                        confirmRow("前回の利用から24時間は再利用できません(冷却)")
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                    Toggle("上記を理解して開始する", isOn: $acknowledged)
                        .toggleStyle(.checkbox)
                        .font(.body)
                }
                .padding(.horizontal, 20)
            }

            Divider()
            HStack {
                Button("選び直す", action: onBack)
                    .controlSize(.large)
                Spacer()
                Button("ロックを理解して進む", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!acknowledged)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func confirmRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Completion

/// 完了画面。「何が起きるか」と「次にすること」を渡してから開始する。
public struct OnboardingCompletionView: View {
    private let enabledNames: [String]
    private let showsDiscordNote: Bool
    private let onBack: () -> Void
    private let onStart: () -> Void
    /// 「Discord に晒す」を ON にした人が、すぐ設定できるようにする二次導線。
    private let onOpenDiscordSettings: (() -> Void)?
    /// ヘッダーのステップ表示。
    private let progressLabel: String

    public init(
        enabledNames: [String],
        showsDiscordNote: Bool,
        onBack: @escaping () -> Void,
        onStart: @escaping () -> Void,
        onOpenDiscordSettings: (() -> Void)? = nil,
        progressLabel: String = "3/3"
    ) {
        self.enabledNames = enabledNames
        self.showsDiscordNote = showsDiscordNote
        self.onBack = onBack
        self.onStart = onStart
        self.onOpenDiscordSettings = onOpenDiscordSettings
        self.progressLabel = progressLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button("戻る", systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Text("\(progressLabel) 開始")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("準備ができました", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                    if enabledNames.isEmpty {
                        Text("おためしモードで始めます。ペットがデスクトップに現れ、サボると声で注意します。")
                            .font(.body)
                    } else {
                        Text("次の機能をONにして始めます:")
                            .font(.body)
                        ForEach(enabledNames, id: \.self) { name in
                            Label(name, systemImage: "checkmark")
                                .font(.callout)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("始めたら").font(.headline)
                        Text("• ペットがデスクトップに現れます\n• 在席スタンプ(Touch ID)で「います」を示せます\n• 設定はいつでもペットの右クリック → 設定… から変えられます")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    if showsDiscordNote {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Discord の設定はこれから", systemImage: "info.circle.fill")
                                .font(.headline)
                            Text(
                                "「Discord に晒す」をONにしましたが、Bot トークンと投稿先はまだ未設定です。開始後に 設定… → Discord タブから設定してください。未設定の間は投稿されません(検知自体は動きます)。"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if let onOpenDiscordSettings {
                                Button("Discord を設定してから始める", action: onOpenDiscordSettings)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("声について", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                        Text("既定は同封音声なので、そのまま声が出ます。VOICEVOX連携(live)は任意です。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 20)
            }

            Divider()
            HStack {
                Spacer()
                Button(enabledNames.isEmpty ? "おためしで始める" : "見守りをはじめる", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
