import AppKit
import Foundation

/// `AppCoordinator` の extension。アンインストール(#55)の実装をここに集める。
extension AppCoordinator {

    // MARK: - アンインストール (#55)

    /// アンインストールできるか。quitLock が ON のロック中は、アンインストールの確認を
    /// 出せない(終了ブロックの抜け道にしないため)。設定画面のボタンの押下可否と
    /// `uninstall()` の二重ガードが同じ判定を見る。
    public var canUninstall: Bool {
        !(safety.isEnabled(.quitLock) && isQuitLocked)
    }

    /// アンインストールを始める。設定画面の「Mihari をアンインストール…」から呼ばれる。
    ///
    /// 確認ダイアログで OK が出たら、見張りとデーモンを止めて `Uninstaller` に消す作業を
    /// 任せる。失敗があれば手動の手順を示し、いずれにせよ終了する。
    /// `canUninstall == false`(quitLock が ON のロック中)なら何もしない。
    public func uninstall() {
        guard canUninstall else { return }

        let alert = NSAlert()
        alert.messageText = "Mihari をアンインストールします"
        // 消えるものを箇条書きで見せてから、破壊的な操作の確認を 1 枚だけ出す。
        let bullets = UninstallStep.allCases.map(\.title).joined(separator: "\n")
        alert.informativeText = "次のものを削除します。この操作は取り消せません:\n\(bullets)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "アンインストール")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isUninstalling = true
        // 消す作業と、そのあとの終了は分けておく。`confirmQuit` が待つのは前者だけで、
        // 自分自身の完了を待って固まらないようにする。
        let work = Task { [weak self] in
            guard let self else { return }
            // 消している最中に検知・写り込み・デーモンが動き続けないように止める。
            detection.stop()
            photobombWatcher.stop()
            daemon.stop()
            // watchdog を見直すループを止めないと、`Uninstaller` が消した直後に登録を
            // 引き戻して「消したのに残る」になる。
            watchdogReassertionTask?.cancel()
            watchdogReassertionTask = nil

            let report = await Uninstaller(
                watchdog: watchdogRegistrar,
                loginItem: loginItemRegistrar,
                tunneld: tunneld
            ).run()

            if !report.failed.isEmpty {
                showUninstallFailure(report)
            }
        }
        uninstallTask = work
        Task {
            await work.value
            NSApp.terminate(nil)
        }
    }

    /// アンインストールに失敗したステップを、手動の手順と一緒にダイアログで知らせる。
    func showUninstallFailure(_ report: UninstallReport) {
        let details = report.failed
            .map { "• \($0.step.title): \($0.reason)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "アンインストールが完了しませんでした"
        alert.informativeText =
            "次の項目を消せませんでした:\n\(details)\n\n"
            + "手動で削除するには、以下のコマンドを Terminal で実行してください:\n"
            + report.manualInstructions
        alert.alertStyle = .warning
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
    }
}
