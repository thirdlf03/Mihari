import Foundation
import Testing

@testable import MihariCore

/// セーフティートグルの変更可否ルール(Epic #58「トグルの変更ルール」)を検証する。
///
/// - OFF 方向(安全側)は常に即時。例外は quitLock の監視中 OFF だけ。
/// - ON 方向もいつでも即時(監視中・ロック中でも通る)。requires が OFF なら拒否。
/// - canChangeLater == false の間は、ON 方向が 24 時間後の予約(クーリングオフ)になる。
@Suite("セーフティーポリシー")
struct SafetyPolicyTests {

    /// 現在時刻。テストごとに固定して、発効時刻の計算を検証できるようにする。
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// 24 時間後の時刻。`now` と組で使う。
    private var due: Date {
        now.addingTimeInterval(SafetyPolicy.coolingOffInterval)
    }

    private func makeSettings(
        enabled: Set<SafetyFeature> = [],
        canChangeLater: Bool = true,
        pending: SafetyPendingChange? = nil
    ) -> SafetySettings {
        var settings = SafetySettings()
        settings.enabled = enabled
        settings.canChangeLater = canChangeLater
        settings.pendingChange = pending
        return settings
    }

    // MARK: - OFF 方向は常に即時

    @Test("OFF は即時に効く")
    func disablingAppliesImmediately() {
        let current = makeSettings(enabled: [.macCamera, .iphonePresence])

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.iphonePresence])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("OFF にすると従属(requires で繋がった先)も落ちる")
    func disablingPullsDependents() {
        // iphoneScreenshot は iphonePresence を requires に持つ。
        let current = makeSettings(enabled: [.iphonePresence, .iphoneScreenshot])

        let decision = SafetyPolicy.decide(
            .disable(.iphonePresence),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("quitLock は監視中に OFF にできない")
    func quitLockCannotBeDisabledWhileWatching() {
        let current = makeSettings(enabled: [.quitLock, .macCamera])

        let decision = SafetyPolicy.decide(
            .disable(.quitLock),
            current: current,
            isWatching: true,
            now: now
        )

        #expect(decision == .reject(.quitLockWhileWatching))
    }

    @Test("quitLock は監視していなければ OFF にできる")
    func quitLockCanBeDisabledWhenNotWatching() {
        let current = makeSettings(enabled: [.quitLock])

        let decision = SafetyPolicy.decide(
            .disable(.quitLock),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("canChangeLater == false でも OFF は即時に効く")
    func disablingAppliesImmediatelyEvenDuringCoolingOff() {
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        // 安全側なので待たせない。canChangeLater はそのまま。
        let expected = makeSettings(enabled: [], canChangeLater: false)
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("OFF は同じ機能の ON 予約を取り消す")
    func disablingRemovesTheFeatureFromThePendingChange() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera, .discordExposure],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [.discordExposure],
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("OFF で予約が空になれば予約ごと消える")
    func disablingClearsThePendingChangeWhenItBecomesEmpty() {
        let pending = SafetyPendingChange(
            enabling: [.iphonePresence, .iphoneScreenshot],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        // 従属も一緒に落ちるので、予約の中身が空になる。
        let decision = SafetyPolicy.decide(
            .disable(.iphonePresence),
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(makeSettings(canChangeLater: false), skipped: []))
    }

    @Test("OFF で予約が空になっても、変更可否を戻す予約は残す")
    func disablingKeepsThePendingChangeThatRestoresChangeability() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: true,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let decision = SafetyPolicy.decide(
            .disable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        #expect(decision == .apply(expected, skipped: []))
    }

    // MARK: - ON 方向

    @Test("ON は監視中でも即時に効く")
    func enablingAppliesImmediatelyWhileWatching() {
        let current = makeSettings()

        let decision = SafetyPolicy.decide(
            .enable(.macCamera),
            current: current,
            isWatching: true,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("監視中の ON も canChangeLater が false なら予約になる")
    func enablingWhileWatchingIsScheduledDuringCoolingOff() {
        let current = makeSettings(canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .enable(.macCamera),
            current: current,
            isWatching: true,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected, skipped: []))

        let all = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: true,
            now: now
        )
        var expectedAll = makeSettings(canChangeLater: false)
        expectedAll.pendingChange = SafetyPendingChange(
            enabling: Set(SafetyFeature.allCases),
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(all == .schedule(expectedAll, skipped: []))
    }

    @Test("ON は監視していなければ即時に効く")
    func enablingAppliesWhenNotWatching() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .enable(.discordExposure),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera, .discordExposure])
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("requires が OFF なら ON を拒否する")
    func enablingWithoutDependencyIsRejected() {
        let current = makeSettings()

        let decision = SafetyPolicy.decide(
            .enable(.iphoneScreenshot),
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .reject(.dependencyMissing(.iphonePresence)))
    }

    @Test("requires が ON なら iPhone の画面撮りも ON にできる")
    func enablingWithDependencyApplies() {
        let current = makeSettings(enabled: [.iphonePresence])

        let decision = SafetyPolicy.decide(
            .enable(.iphoneScreenshot),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.iphonePresence, .iphoneScreenshot])
        #expect(decision == .apply(expected, skipped: []))
    }

    // MARK: - クーリングオフ中の ON は予約になる

    @Test("canChangeLater == false の間は ON が 24 時間後の予約になる")
    func enablingSchedulesDuringCoolingOff() {
        let current = makeSettings(canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .enable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        // 予約は積むが、まだ ON にしない。
        #expect(decision == .schedule(expected, skipped: []))
    }

    @Test("canChangeLater == false の間は enableAll も予約になる")
    func enableAllSchedulesDuringCoolingOff() {
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: Set(SafetyFeature.allCases),
            restoresChangeability: false,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected, skipped: []))
    }

    @Test("予約中の機能を前提にした ON も予約できる")
    func enablingOnTopOfAPendingDependencyIsAllowed() {
        // iphonePresence が予約中なら、iphoneScreenshot も同じ予約に載せられる。
        let pending = SafetyPendingChange(
            enabling: [.iphonePresence],
            restoresChangeability: false,
            effectiveAt: now.addingTimeInterval(60 * 60)
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let decision = SafetyPolicy.decide(
            .enable(.iphoneScreenshot),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [.iphonePresence, .iphoneScreenshot],
            restoresChangeability: false,
            // 発効は既存予約の時刻に相乗りする(延びない)。
            effectiveAt: now.addingTimeInterval(60 * 60)
        )
        #expect(decision == .schedule(expected, skipped: []))
    }

    @Test("予約が既にあれば enabling は和集合になり、発効は早い方の時刻を引き継ぐ")
    func schedulingKeepsTheEarliestEffectiveAt() {
        let previous = SafetyPendingChange(
            enabling: [.quitLock],
            restoresChangeability: false,
            effectiveAt: now.addingTimeInterval(60 * 60)  // 1 時間前に入れた予約
        )
        let current = makeSettings(canChangeLater: false, pending: previous)

        let decision = SafetyPolicy.decide(
            .enable(.macCamera),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [.quitLock, .macCamera],
            restoresChangeability: false,
            // 新しく積んだ分は既存の発効時刻に相乗りする。今回の依頼から 24 時間後
            // (due)まで延びることはない。
            effectiveAt: now.addingTimeInterval(60 * 60)
        )
        #expect(decision == .schedule(expected, skipped: []))
    }

    // MARK: - 全部切り替え

    @Test("enableAll は監視中でも監視中でなくても全 ON")
    func enableAll() {
        let current = makeSettings(enabled: [.macCamera])
        let expected = makeSettings(enabled: Set(SafetyFeature.allCases))

        let whileWatching = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: true,
            now: now
        )
        #expect(whileWatching == .apply(expected, skipped: []))

        let notWatching = SafetyPolicy.decide(
            .enableAll,
            current: current,
            isWatching: false,
            now: now
        )
        #expect(notWatching == .apply(expected, skipped: []))
    }

    @Test("disableAll は監視中なら quitLock だけ残して残りを落とす")
    func disableAllSkipsQuitLockWhileWatching() {
        let current = makeSettings(enabled: Set(SafetyFeature.allCases))

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: true,
            now: now
        )

        let expected = makeSettings(enabled: [.quitLock])
        #expect(decision == .apply(expected, skipped: [.quitLock]))
    }

    @Test("disableAll は監視していなければ全部落とす")
    func disableAllTurnsEverythingOffWhenNotWatching() {
        let current = makeSettings(enabled: Set(SafetyFeature.allCases))

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(.default, skipped: []))
    }

    @Test("disableAll は canChangeLater == false でも即時で、ON の予約を消す")
    func disableAllAppliesImmediatelyAndClearsPendingDuringCoolingOff() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera, .quitLock],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(
            enabled: [.discordExposure],
            canChangeLater: false,
            pending: pending
        )

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(makeSettings(canChangeLater: false), skipped: []))
    }

    @Test("監視中の disableAll でも ON の予約は全部消える")
    func disableAllClearsPendingEvenWhenQuitLockIsSkipped() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: true,
            effectiveAt: due
        )
        let current = makeSettings(
            enabled: [.quitLock, .discordExposure],
            canChangeLater: false,
            pending: pending
        )

        let decision = SafetyPolicy.decide(
            .disableAll,
            current: current,
            isWatching: true,
            now: now
        )

        var expected = makeSettings(enabled: [.quitLock], canChangeLater: false)
        // 変更可否を戻す予約だけは残る(OFF 方向の依頼と関係がないため)。
        expected.pendingChange = SafetyPendingChange(
            enabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        #expect(decision == .apply(expected, skipped: [.quitLock]))
    }

    // MARK: - 変更可能性の切り替え

    @Test("setCanChangeLater(false) は即時に効く")
    func disablingChangeabilityAppliesImmediately() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(false),
            current: current,
            isWatching: false,
            now: now
        )

        let expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        #expect(decision == .apply(expected, skipped: []))
    }

    @Test("setCanChangeLater(true) はすでに true なら何もしない")
    func restoringChangeabilityWhenAlreadyEnabledDoesNothing() {
        let current = makeSettings(enabled: [.macCamera])

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(true),
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(current, skipped: []))
    }

    @Test("setCanChangeLater(true) は false からなら 24 時間後の予約になる")
    func restoringChangeabilityFromFalseSchedules() {
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false)

        let decision = SafetyPolicy.decide(
            .setCanChangeLater(true),
            current: current,
            isWatching: false,
            now: now
        )

        var expected = makeSettings(enabled: [.macCamera], canChangeLater: false)
        expected.pendingChange = SafetyPendingChange(
            enabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        #expect(decision == .schedule(expected, skipped: []))
    }

    @Test("cancelPendingChange は即時に予約を消す")
    func cancelPendingChangeClearsReservation() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let decision = SafetyPolicy.decide(
            .cancelPendingChange,
            current: current,
            isWatching: false,
            now: now
        )

        #expect(decision == .apply(makeSettings(canChangeLater: false), skipped: []))
    }

    // MARK: - 予約の発効

    @Test("発効時刻前なら予約は適用されない")
    func pendingChangeDoesNotApplyBeforeEffectiveAt() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: now)

        #expect(applied == current)
    }

    @Test("発効時刻が来たら予約どおり ON にして pendingChange を消す")
    func pendingChangeAppliesAtEffectiveAt() {
        let pending = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied == makeSettings(enabled: [.macCamera], canChangeLater: false))
    }

    @Test("発効は監視中かどうかを見ない")
    func pendingChangeAppliesRegardlessOfWatching() {
        // 監視は起動と同時に始まるので、ここで監視中を理由に見送ると予約が永久に
        // 発効しなくなる。24 時間の熟慮は済んでいるため、そのまま適用する。
        let pending = SafetyPendingChange(
            enabling: [.quitLock],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        // applyingDuePendingChange は isWatching を引数に取らない(見ないことの証明)。
        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.enabled == [.quitLock])
        #expect(applied.pendingChange == nil)
    }

    @Test("restoresChangeability が true なら発効時に変更可能性も戻す")
    func pendingChangeRestoresChangeability() {
        let pending = SafetyPendingChange(
            enabling: [],
            restoresChangeability: true,
            effectiveAt: due
        )
        let current = makeSettings(enabled: [.macCamera], canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.canChangeLater)
        #expect(applied.pendingChange == nil)
        // 戻しただけでは ON の機能は変わらない。
        #expect(applied.enabled == [.macCamera])
    }

    @Test("発効後も依存を満たさない ON は normalized が落とす")
    func pendingChangeResultIsNormalized() {
        // 予約に従属(iphoneScreenshot)だけが載っていて、前提の iphonePresence が
        // 予約に入っていなかった状況。従属だけが立つことはない。
        let pending = SafetyPendingChange(
            enabling: [.iphoneScreenshot],
            restoresChangeability: false,
            effectiveAt: due
        )
        let current = makeSettings(canChangeLater: false, pending: pending)

        let applied = SafetyPolicy.applyingDuePendingChange(current, now: due)

        #expect(applied.enabled.isEmpty)
        #expect(applied.pendingChange == nil)
    }
}
