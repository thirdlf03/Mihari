import Foundation

/// `AppCoordinator` の extension。終了ロック(quitLock)まわりの実装をここに集める。
///
/// `begin()` と `observeSafety()` の quitLock 購読から呼ばれるもの。
extension AppCoordinator {

    /// 終了ロック中か。quitLock トグルが ON でも、解除時刻が過ぎていればロック中ではない。
    ///
    /// `quitTimeLock` は `begin()` 以降にしかセットされない(初期値は無ロック)ので、
    /// `hasBegun` の検査は不要。[#52] の `isWatchingForSafety` は「監視外でもロック中は監視中として
    /// 扱う」文脈なので `hasBegun` を見ているが、こちらは quitLock トグルが ON であることを
    /// 外側の条件で確かめるため、ロックの本体だけで判定できる。
    var isQuitLocked: Bool {
        !quitTimeLock.isUnlocked()
    }

    /// quitLock トグルのいまの状態に、常駐の仕掛けを合わせる。
    ///
    /// `begin()` と、quitLock が OFF→ON に変わったとき(監視外でしか起きない)に呼ぶ。
    /// ON のときはスリープ防止・ログイン項目・watchdog(+見直しループ)を入れ、
    /// 保存されていた解除時刻(`quitLock.unlockAt`)が未来ならそれを引き継ぐ。引き継ぐ
    /// ものが無ければ既定時間で仮ロックして、この瞬間からロックを効かせる。
    /// OFF のときは以前 ON だったときの登録を掃除する。ON→OFF はロック中には起きない
    /// (SafetyPolicy が弾く)ので、掃除だけで足りる。
    func applyQuitLockPolicy() {
        if safety.isEnabled(.quitLock) {
            sleepPreventer.start()
            loginItemRegistrar.ensureRegistered()
            watchdogRegistrar.ensureRegistered()
            startWatchdogReassertion()
            resumePersistedQuitLockDeadline()
            beginProvisionalQuitLockIfNeeded()
        } else {
            releaseQuitLock()
        }
    }

    /// 引き継ぐ解除時刻が無ければ、既定の 4 時間で仮ロックして保存する。
    ///
    /// 解除時刻はデーモンに繋がってからでないと確定しない(`establishFreshQuitLockDeadline`)。
    /// その数秒を `unlockAt == nil` のまま放っておくと `QuitTimeLock.isUnlocked()` が true を
    /// 返し、Cmd+Q / SIGTERM が素通りしてしまう。#5 は「起動した瞬間から効く」なので、
    /// 先に塞いでおく。仮ロックだと分かるようにしておき、確定したら引き直す。
    /// 再起動を跨いだときは保存値の引き継ぎ側が拾うので、そのまま本ロックとして扱われる。
    func beginProvisionalQuitLockIfNeeded() {
        guard quitTimeLock.unlockAt == nil else { return }
        quitTimeLock = QuitTimeLock.provisional(hours: Self.defaultLockHours, from: Date())
        defaults.set(quitTimeLock.unlockAt, forKey: Self.quitLockDeadlineKey)
    }

    /// 終了ブロックを OFF にしたときの後片付け。登録を解き、解除時刻と保存を取り消す。
    func releaseQuitLock() {
        watchdogRegistrar.unregister()
        loginItemRegistrar.unregister()
        watchdogReassertionTask?.cancel()
        watchdogReassertionTask = nil
        sleepPreventer.stop()
        quitTimeLock = QuitTimeLock()
        defaults.removeObject(forKey: Self.quitLockDeadlineKey)
    }

    /// 監視プロセスの登録を定期的に見直すループを始める。既に走っていれば何もしない。
    ///
    /// `launchctl bootout` で登録だけ外からむしり取られても、Touch ID を経ない解除を
    /// 長続きさせない。解除側(`releaseQuitLock`)で止めてから OFF→ON されたときは
    /// 最初からやり直せるよう、止めたら nil に戻してある。
    func startWatchdogReassertion() {
        guard watchdogReassertionTask == nil else { return }
        watchdogReassertionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogReassertionInterval)
                guard !Task.isCancelled else { return }
                self?.watchdogRegistrar.reassertIfMissing()
            }
        }
    }

    /// 保存されていた解除時刻(`quitLock.unlockAt`)が未来なら、そのまま引き継ぐ。
    /// 監視を再開した拍子に 4 時間へ延び直さないためのもの。同期で済ませて、デーモン
    /// に繋がる前でもロックが効いている状態にする。
    func resumePersistedQuitLockDeadline() {
        guard quitTimeLock.unlockAt == nil else { return }
        guard let persisted = defaults.object(forKey: Self.quitLockDeadlineKey) as? Date,
            persisted > Date()
        else { return }
        quitTimeLock = QuitTimeLock(unlockAt: persisted)
    }

    /// 終了ロックの解除時刻を確定する。デーモンに繋がったあとに呼ぶ。
    ///
    /// 保存値の引き継ぎ(`resumePersistedQuitLockDeadline`)で既に本ロック中なら何もしない。
    /// 仮ロック中(`beginProvisionalQuitLockIfNeeded`)なら Discord の `/watch lock` の値
    /// (取れなければ既定 4 時間)で引き直して保存する ―― 取れないからロックしない、は
    /// 「ロックできない状況を作れば終了できる」という抜け道になってしまう。
    func establishFreshQuitLockDeadline() async {
        guard quitTimeLock.acceptsFreshDeadline else { return }
        var hours: Double?
        if let client = daemon.connectedClient {
            hours = try? await client.lockHours()
        }
        // lockHours を待っているあいだに別経路で確定されたら、`establishing` が据え置く。
        let established = QuitTimeLock.establishing(
            from: quitTimeLock,
            persisted: defaults.object(forKey: Self.quitLockDeadlineKey) as? Date,
            now: Date(),
            hours: hours ?? Self.defaultLockHours
        )
        guard established != quitTimeLock else { return }
        quitTimeLock = established
        defaults.set(quitTimeLock.unlockAt, forKey: Self.quitLockDeadlineKey)
    }
}
