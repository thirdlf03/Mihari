import SwiftUI

/// 執行猶予脱出の宣言ダイアログ。
///
/// 戻るまでの時間を選び、「終了を始める」で 10 分のカウントダウンに入る。
/// 選べる時間は `EscapePolicy.returnDelayChoices` が決める(15 分刻み、ロック解除まで)。
///
/// 見出しはウィンドウ題(「どうしても終了する」)が持つので、ここには置かない。
public struct EscapeDialogView: View {
    /// 戻るまでの時間の選択肢。
    private let choices: [TimeInterval]
    /// 選択肢に実時刻を添えるための基準時刻。`choices` を作ったときと同じ時刻を渡す。
    private let now: Date
    /// 「Discord に晒す」が ON か。ON のときだけ、逃げたことが投稿されると警告する。
    private let postsToDiscord: Bool
    /// 「終了を始める」を押したときの処理。選ばれた戻るまでの時間を渡す。
    private let onStart: (TimeInterval) -> Void
    /// 「やめる」を押したときの処理。
    private let onCancel: () -> Void

    @State private var selected: TimeInterval

    /// - Parameters:
    ///   - now: 選択肢に添える実時刻の基準。`choices` と同じ時刻で揃える。
    ///   - postsToDiscord: 「Discord に晒す」が ON か。
    public init(
        choices: [TimeInterval],
        now: Date,
        postsToDiscord: Bool,
        onStart: @escaping (TimeInterval) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.choices = choices
        self.now = now
        self.postsToDiscord = postsToDiscord
        self.onStart = onStart
        self.onCancel = onCancel
        _selected = State(initialValue: choices.first ?? EscapePolicy.minReturnDelay)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "「終了を始める」を押すと 10 分後に終了します。選んだ時刻に自動で戻り、監視を再開します。脱出は 24 時間に 1 回だけです(次は 24 時間後から使えます)。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if postsToDiscord {
                Label(
                    "Discord に「逃げた」と戻る予定時刻が投稿されます",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if choices.isEmpty {
                // 選べるものが無い理由を書かないと、空の Picker と押せないボタンだけが残る。
                Text("ロック解除まで 15 分を切っているので、そのまま待ってください")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("戻ってくる時刻", selection: $selected) {
                    ForEach(choices, id: \.self) { delay in
                        Text(EscapePolicy.returnChoiceDescription(delay, from: now)).tag(delay)
                    }
                }
            }

            HStack {
                Button("やめる") { onCancel() }
                Spacer()
                Button("終了を始める") { onStart(selected) }
                    .buttonStyle(.borderedProminent)
                    // 選択肢が 1 つも無い(ロックの残りが 15 分未満)ときは押せない。
                    .disabled(choices.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
