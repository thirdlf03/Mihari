import AppKit
import Foundation
import os

/// `AppCoordinator` の extension。執行猶予脱出(escape)まわりの実装をここに集める。
///
/// 宣言ダイアログ・カウントダウンの配線・「逃げた」「戻ってきた」の投稿までを扱う。
extension AppCoordinator {

    /// 執行猶予脱出のメニュー項目の状態(quitLock が ON でロック中のときだけ出す)。
    public var escapeMenuState: EscapeMenuState {
        guard hasBegun, safety.isEnabled(.quitLock), !quitTimeLock.isUnlocked() else {
            return .hidden
        }
        switch escape.phase {
        case .idle:
            // 冷却中なら理由を添えただけで押せない項目にし、使えるときだけダイアログへ。
            if let remaining = EscapePolicy.cooldownRemaining(
                lastEscapeAt: safety.settings.lastEscapeAt,
                now: Date()
            ) {
                return .coolingDown(remaining: remaining)
            }
            return .available
        case .countingDown(_, let endsAt):
            return .countingDown(remaining: max(0, endsAt.timeIntervalSinceNow))
        case .readyToTerminate:
            // もう終了が始まるだけなので、メニュー項目は出さない。
            return .hidden
        }
    }

    /// 執行猶予脱出の宣言ダイアログを開く。
    public func openEscapeDialog() {
        // 選択肢とそれに添える実時刻は同じ時刻から作る。
        let now = Date()
        let choices = EscapePolicy.returnDelayChoices(
            now: now,
            unlockAt: quitTimeLock.unlockAt
        )
        windows.showEscape {
            EscapeDialogView(
                choices: choices,
                now: now,
                postsToDiscord: safety.isEnabled(.discordExposure),
                onStart: { [weak self] delay in self?.startEscape(returnDelay: delay) },
                onCancel: { [weak self] in self?.windows.closeEscape() }
            )
        }
    }

    /// 執行猶予脱出のカウントダウンを取り消す。
    public func cancelEscape() {
        escape.cancel()
        pet.controller.say("…うん、行かないんだ。ここにいて。")
    }

    /// 執行猶予脱出を始める。宣言ダイアログを閉じ、10 分のカウントダウンに入る。
    func startEscape(returnDelay: TimeInterval) {
        windows.closeEscape()
        escape.start(returnDelay: returnDelay, now: Date())
        pet.controller.say("…行くの? 10 分だけ、待ってる。")
    }

    /// 執行猶予脱出のコールバックを配線する。
    func wireEscape() {
        escape.onNag = { [weak self] remaining in
            guard let self else { return }
            let minutes = EscapePolicy.durationDescription(remaining)
            guard let line = Self.escapeNagPool.randomElement() else { return }
            // 音声ファイルは用意しない。吹き出しだけ出す(読み上げない)。
            self.pet.controller.say(
                line.replacingOccurrences(of: "{minutes}", with: minutes),
                voiced: false
            )
        }
        escape.onCountdownFinished = { [weak self] record in
            guard let self else { return }
            self.finishEscape(record: record)
        }
    }

    /// カウントダウン中の引き止めセリフの候補。`{minutes}` に残り時間(「5 分」など)が入る。
    static let escapeNagPool = [
        "あと {minutes}。まだ、いてくれる?",
        "{minutes}待ったら、ちゃんと戻ってくるよね?",
        "あと {minutes}だけ。私のところにいて。",
    ]

    /// 執行猶予脱出のカウントダウンが終わった。記録を残して終了する。
    ///
    /// 1. 記録を保存(次回起動の復帰判定と、watchdog の「宣言時刻まで起こさない」に使う)。
    /// 2. 「逃げた」を Discord に投稿(晒しが ON のとき)。
    /// 3. 終了する。watchdog とログイン項目は**解除しない** —— 宣言時刻に自動で立ち上がって
    ///    監視を再開するために使う。
    func finishEscape(record: EscapeRecord) {
        let url = EscapeRecordStore.url()
        do {
            try EscapeRecordStore.save(record, to: url)
        } catch {
            Self.logger.error("escape の記録を保存できなかった: \(error.localizedDescription, privacy: .public)")
        }
        safety.markEscapeUsed(at: record.escapedAt)
        EscapeController.savePendingReport(record, defaults: defaults)
        // 投稿はデーモンを落とす(shutdown)前に済ませる。接続を切ってからでは届かない。
        // 待っているあいだに Cmd+Q / SIGTERM が来ても投稿が飛ばないよう、`confirmQuit`
        // からも同じ Task を待つ。
        let posting = postEscaped(record: record)
        escapePostTask = posting
        Task { [weak self] in
            await posting.value
            self?.shutdown()
            NSApp.terminate(nil)
        }
    }

    /// 「逃げた」を Discord に投稿する Task を作る。晒しが OFF なら何もしない Task を返す。
    ///
    /// 投稿が返ってこないせいで終了できなくなるのを避けるため、`escapePostTimeout` で
    /// 投稿を取り消す。取り消された投稿は `discord.post` の失敗として扱われ(原因は
    /// `DiscordController` がログに残す)、終了はそのまま進む。
    func postEscaped(record: EscapeRecord) -> Task<Void, Never> {
        guard safety.isEnabled(.discordExposure) else { return Task {} }
        let text = DiscordMessageComposer.escaped(returnAt: record.returnAt)
        let post = Task<Void, Never> { [discord, daemon] in
            await discord.post(text: text, image: nil, mention: true, using: daemon.connectedClient)
        }
        return Task {
            let deadline = Task {
                try? await Task.sleep(for: Self.escapePostTimeout)
                post.cancel()
            }
            await post.value
            deadline.cancel()
        }
    }

    /// 前回の執行猶予脱出からの復帰を処理する。
    ///
    /// `pendingReport` があれば、宣言どおり再起動されてきたということ。watchdog が宣言
    /// 時刻に記録を消して起こしているので、残っていればここで消す。Mac を触っている
    /// (= 無操作 60 秒以内)なら「戻ってきた」、触っていなければ「戻っていなかった」を、
    /// デーモンに繋がってから投稿する。
    func handleEscapeReturnIfNeeded() {
        guard EscapeController.consumePendingReport(defaults: defaults) != nil else { return }
        // watchdog が宣言時刻に消しているはずだが、残っていれば(手動で立ち上げた等)消す。
        EscapeRecordStore.remove(at: EscapeRecordStore.url())
        let returned = EscapePolicy.didReturn(idleSeconds: MacIdleMonitor().idleSeconds())
        pendingEscapeReturn = returned
    }

    /// 執行猶予脱出からの復帰の投稿を、デーモンに繋がったいま送る。
    func postEscapeReturnIfPending() {
        guard let returned = pendingEscapeReturn else { return }
        pendingEscapeReturn = nil
        guard safety.isEnabled(.discordExposure) else { return }
        Task { [discord, daemon] in
            await discord.post(
                text: returned ? DiscordMessageComposer.returned() : DiscordMessageComposer.didNotReturn(),
                image: nil,
                // 戻っていなかったときだけ呼びつける(戻ってきたなら呼ぶ必要がない)。
                mention: !returned,
                using: daemon.connectedClient
            )
        }
    }
}
