import Foundation
import Testing

@testable import MihariCore

/// セーフティー画面(モード選択 / 設定)の表示ロジック。
///
/// SwiftUI の View にはテストハーネスが無いので、`SafetyModeViewModel` に切り出した
/// 純粋関数の変換・文言・判定をここで検証する。
@Suite("セーフティー画面の表示ロジック")
struct SafetyModeViewModelTests {

    @Test("Toggle の操作が ON/OFF の方向で SafetyChange に変換される")
    func toggleChangeFollowsDirection() {
        #expect(SafetyModeViewModel.toggleChange(for: .macCamera, turningOn: true) == .enable(.macCamera))
        #expect(SafetyModeViewModel.toggleChange(for: .macCamera, turningOn: false) == .disable(.macCamera))

        // 従属(iphoneScreenshot)も同じ規則で方向だけ変わる。
        #expect(SafetyModeViewModel.toggleChange(for: .iphoneScreenshot, turningOn: true) == .enable(.iphoneScreenshot))
    }

    @Test("拒否の理由が、次にどうすればよいかまで書いた状態行の文言に変換される")
    func rejectionReasonsBecomeStatusMessages() {
        #expect(
            SafetyModeViewModel.statusMessage(for: .reject(.dependencyMissing(.iphonePresence)))
                == "「iPhone を見張る」を先に ON にしてください"
        )
    }

    @Test("quitLock を OFF にできない理由には、渡せるならロック解除の時刻を添える")
    func quitLockRejectionCarriesTheUnlockTime() throws {
        let unlockAt = try makeDate()

        #expect(
            SafetyModeViewModel.statusMessage(
                for: .reject(.quitLockWhileWatching),
                lockedUntil: unlockAt
            )
                == "ロック解除(14:30)まで OFF にできません。どうしても終了したい場合は右クリック →「どうしても終了する」"
        )
        // 解除時刻が取れないときは時刻抜きで同じことを言う。
        #expect(
            SafetyModeViewModel.statusMessage(for: .reject(.quitLockWhileWatching))
                == "ロック解除まで OFF にできません。どうしても終了したい場合は右クリック →「どうしても終了する」"
        )
    }

    @Test("#5 を OFF にできない理由は、解除時刻が取れるならそれを出す")
    func quitLockRestrictionNotePrefersTheUnlockTime() throws {
        let unlockAt = try makeDate()

        // ロック中なら、監視の有無にかかわらず解除時刻を出す。
        #expect(
            SafetyModeViewModel.quitLockRestrictionNote(isWatching: true, lockedUntil: unlockAt)
                == "ロック中(14:30 まで): OFF にできません"
        )
        #expect(
            SafetyModeViewModel.quitLockRestrictionNote(isWatching: false, lockedUntil: unlockAt)
                == "ロック中(14:30 まで): OFF にできません"
        )

        // 解除時刻が取れない(ロックは切れたが監視は続いている)ときだけ「監視中」と書く。
        #expect(
            SafetyModeViewModel.quitLockRestrictionNote(isWatching: true, lockedUntil: nil)
                == "監視中: OFF にできません"
        )

        // どちらでもなければ何も出さない。
        #expect(
            SafetyModeViewModel.quitLockRestrictionNote(isWatching: false, lockedUntil: nil) == nil
        )
    }

    @Test("権限行は、トグルが OFF なら静的な案内、ON なら許可状態を出す")
    func permissionRowShowsTheGrantOnlyWhileEnabled() {
        // OFF のあいだは「何が要るか」だけ。まだ要求もしていない権限を未許可とは書かない。
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .macCamera,
                isEnabled: false,
                kind: .camera,
                grant: .denied,
                tunneld: nil
            ) == .staticNote(SafetyFeature.macCamera.permissionNote)
        )

        #expect(
            SafetyModeViewModel.permissionRow(
                for: .macCamera,
                isEnabled: true,
                kind: .camera,
                grant: .granted,
                tunneld: nil
            ) == .satisfied("カメラ: 許可済み")
        )

        // 拒否も未決定も、その機能が動かないことに変わりはないので同じ出し方にする。
        // カメラは唯一の必須権限なので、進めないと伝える文言にする。
        for grant in [PermissionGrant.denied, .undetermined] {
            #expect(
                SafetyModeViewModel.permissionRow(
                    for: .macCamera,
                    isEnabled: true,
                    kind: .camera,
                    grant: grant,
                    tunneld: nil
                )
                    == .missing(
                        text: "カメラ: 未許可 — この機能の開始に必要です。OFF にすれば先へ進めます",
                        actionTitle: "システム設定を開く",
                        action: .openSystemSettings
                    )
            )
        }

        // 権限が要る機能を持っているか / 拒否による影響を、必須と任意で書き分ける。
        // オートメーションは任意(説教中の音楽停止だけが欠ける)。
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .sermonTakeover,
                isEnabled: true,
                kind: .automation,
                grant: .denied,
                tunneld: nil
            )
                == .missing(
                    text: "オートメーション: 未許可 — Music / Spotify を止められません(オーバーレイは出ます)(任意なので OFF のままでも進めます)",
                    actionTitle: "システム設定を開く",
                    action: .openSystemSettings
                )
        )

        // 権限の要らない機能は ON でも静的な案内のまま。
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .photobomb,
                isEnabled: true,
                kind: nil,
                grant: nil,
                tunneld: nil
            ) == .staticNote(SafetyFeature.photobomb.permissionNote)
        )
    }

    @Test("iPhone の画面を撮るの権限行は tunneld の常駐状態を出す")
    func permissionRowFollowsTunneldForIPhoneScreenshot() {
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .iphoneScreenshot,
                isEnabled: true,
                kind: nil,
                grant: nil,
                tunneld: .ready
            ) == .satisfied("tunneld: 登録済み")
        )
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .iphoneScreenshot,
                isEnabled: true,
                kind: nil,
                grant: nil,
                tunneld: .missing
            )
                == .missing(
                    text: "tunneld: 未登録 — 登録されるまで iPhone の画面は撮れません",
                    actionTitle: "登録する…",
                    action: .installTunneld
                )
        )
        #expect(
            SafetyModeViewModel.permissionRow(
                for: .iphoneScreenshot,
                isEnabled: true,
                kind: nil,
                grant: nil,
                tunneld: .working
            ) == .working("tunneld: 確認中…")
        )
    }

    @MainActor
    @Test("tunneld の状態は権限行の 3 段階に均される")
    func tunneldStatusIsFlattenedIntoThreeSteps() {
        #expect(SafetyModeViewModel.readiness(of: .running) == .ready)
        #expect(SafetyModeViewModel.readiness(of: .notRunning) == .missing)
        // まだ確かめていない・確認中・登録中は、どちらとも言えないので同じ扱い。
        #expect(SafetyModeViewModel.readiness(of: .unknown) == .working)
        #expect(SafetyModeViewModel.readiness(of: .checking) == .working)
        #expect(SafetyModeViewModel.readiness(of: .installing) == .working)
    }

    @Test("apply はスキップされた機能があるときだけ状態行に文言を出す")
    func applySpeaksOnlyWhenSomethingWasSkipped() {
        let settings = SafetySettings()
        #expect(
            SafetyModeViewModel.statusMessage(for: .apply(settings, skipped: [.quitLock]))
                == "監視中なので「監視中は終了させない」は残しました"
        )
        #expect(SafetyModeViewModel.statusMessage(for: .apply(settings, skipped: [])) == nil)
    }

    @Test("schedule は予約帯で示すので状態行には何も出さない")
    func scheduleProducesNoStatusMessage() {
        let settings = SafetySettings()
        #expect(SafetyModeViewModel.statusMessage(for: .schedule(settings, skipped: [])) == nil)
    }

    @Test("予約の発効時刻は M/d HH:mm の形で表示する")
    func pendingTimeTextUsesMonthDayAnd24HourClock() throws {
        // 9/2 14:30 が、作ったときと同じタイムゾーンで整形されることを確かめる。
        let date = try makeDate()

        #expect(SafetyModeViewModel.pendingTimeText(effectiveAt: date) == "9/2 14:30")
        #expect(SafetyModeViewModel.pendingFeatureText(effectiveAt: date) == "9/2 14:30 に ON")
    }

    @Test("予約帯は中身に応じて ON になる機能 / 変更可否の復帰を出し分ける")
    func pendingStatusTextDependsOnTheReservationContents() throws {
        let date = try makeDate()

        // 機能だけの予約。名前はトグルの並び順で並べる。
        let features = SafetyPendingChange(
            enabling: [.discordExposure, .macCamera],
            restoresChangeability: false,
            effectiveAt: date
        )
        #expect(
            SafetyModeViewModel.pendingStatusText(for: features)
                == "9/2 14:30 に ON になります(Mac のカメラで撮る, Discord に晒す)"
        )

        // 変更可否を戻すだけの予約。
        let changeability = SafetyPendingChange(
            enabling: [],
            restoresChangeability: true,
            effectiveAt: date
        )
        #expect(
            SafetyModeViewModel.pendingStatusText(for: changeability)
                == "9/2 14:30 に「あとで設定を変えられるようにする」が ON に戻ります"
        )

        // 両方が同じ予約に乗ったときは 1 文にまとめる。
        let both = SafetyPendingChange(
            enabling: [.macCamera],
            restoresChangeability: true,
            effectiveAt: date
        )
        #expect(
            SafetyModeViewModel.pendingStatusText(for: both)
                == "9/2 14:30 に ON になります(Mac のカメラで撮る、「あとで設定を変えられるようにする」)"
        )
    }

    @Test("オンボーディングのステップ 2 は全 OFF なら飛ばす")
    func permissionsStepIsSkippedWhenNothingToShow() {
        // 全 OFF でもモーション(トグルと紐づかない任意の権限)は一覧に残る。実際に
        // 渡ってくるのはこの配列なので、手で空配列を作らずここから取る。
        let allOff = PermissionKind.relevant(for: .default)
        #expect(allOff == [.motion])
        #expect(
            SafetyModeViewModel.shouldSkipPermissionsStep(
                relevantKinds: allOff,
                isIPhoneScreenshotEnabled: false
            )
        )

        // トグルが要求する権限が 1 本でもあれば、飛ばさず権限画面を見せる。
        var camera = SafetySettings.default
        camera.enabled = [.macCamera]
        #expect(
            !SafetyModeViewModel.shouldSkipPermissionsStep(
                relevantKinds: PermissionKind.relevant(for: camera),
                isIPhoneScreenshotEnabled: false
            )
        )
        // tunneld が要る(iphoneScreenshot が ON の)ときも、登録画面を見せる。
        #expect(
            !SafetyModeViewModel.shouldSkipPermissionsStep(
                relevantKinds: allOff,
                isIPhoneScreenshotEnabled: true
            )
        )
    }

    @Test("従属のカードの 1 行は、前提が ON / 予約中 / OFF で変わる")
    func dependencyNoteFollowsTheRequiredToggle() {
        // 前提が ON なら、従属は普通のカードなので何も添えない。
        #expect(
            SafetyModeViewModel.dependencyNote(isRequiredEnabled: true, isRequiredPending: false) == nil
        )

        // 前提が予約中なら、従属も同じ予約に積める。選べない理由ではなく、一緒に ON に
        // なることを伝える。
        #expect(
            SafetyModeViewModel.dependencyNote(isRequiredEnabled: false, isRequiredPending: true)
                == "「iPhone を見張る」の予約と一緒に ON になります"
        )

        // どちらでもなければ選べない。
        #expect(
            SafetyModeViewModel.dependencyNote(isRequiredEnabled: false, isRequiredPending: false)
                == "「iPhone を見張る」を ON にすると選べます"
        )
    }

    /// 実行環境のローカルタイムゾーンのグレゴリオ暦で 2025/9/2 14:30 を作る。
    private func makeDate() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.year = 2025
        components.month = 9
        components.day = 2
        components.hour = 14
        components.minute = 30
        return try #require(calendar.date(from: components))
    }
}
