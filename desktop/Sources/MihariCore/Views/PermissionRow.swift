import SwiftUI

/// オンボーディングの 1 行。権限名・用途・現在の状態・操作ボタンを並べる。
struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityLabel(indicatorLabel)

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.body).bold()
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.grant != .granted {
                    Text("未許可だと: \(kind.consequenceIfDenied)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if let hint = kind.setupHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 照会に使った API と生の返り値は、切り分けのための開発者向けの情報。
                // ふだんは出さず、`MIHARI_DEBUG_UI=1` のときだけ見せる。
                if AppCoordinator.isDebugUIRequested {
                    Text(kind.api)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(kind.api)
                }
            }
            .frame(minWidth: 260, alignment: .leading)

            if AppCoordinator.isDebugUIRequested {
                Text(state.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            // ボタンは説明の右側に置く。説明の下に置くと 1 行あたり +23pt 高くなり、
            // 権限リストが縦に伸びて見える。
            // 実測の行幅は 501pt で、600 幅ウインドウのコンテンツ幅 560 に収まるので
            // ワンラインのままでよい。
            HStack(spacing: 8) {
                if let title = kind.requestButtonTitle, state.grant != .granted {
                    // この行の主たる行動(許可のプロンプト)を目立たせる。
                    Button(title, action: onRequest)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Button("システム設定を開く", action: onOpenSettings)
                    .controlSize(.small)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 権限の状態を示すインジケーター。
    private var indicatorColor: Color {
        switch state.grant {
        case .granted: return .green
        case .denied: return .red
        case .undetermined: return .gray
        }
    }

    private var indicatorLabel: String {
        switch state.grant {
        case .granted: return "許可済み"
        case .denied: return "拒否"
        case .undetermined: return "未決定"
        }
    }
}
