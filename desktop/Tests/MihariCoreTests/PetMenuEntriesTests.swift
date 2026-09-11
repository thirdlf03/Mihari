import Foundation
import Testing

@testable import MihariCore

/// ペットメニューの並びが、そのときの状態をチェックに映すかを検証する。
@Suite("ペットメニューの並び")
@MainActor
struct PetMenuEntriesTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.petMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    /// タイトルの一致する項目を探す。
    private func findItem(
        _ title: String,
        in entries: [PetMenuEntry]
    ) -> (isChecked: Bool, isEnabled: Bool, action: @MainActor () -> Void)? {
        for entry in entries {
            if case .item(let itemTitle, let isChecked, let isEnabled, let action) = entry,
                itemTitle == title
            {
                return (isChecked, isEnabled, action)
            }
        }
        return nil
    }

    /// タイトルの一致するサブメニューの中身を探す。
    private func findSubmenu(_ title: String, in entries: [PetMenuEntry]) -> [PetMenuEntry]? {
        for entry in entries {
            if case .submenu(let submenuTitle, let children) = entry, submenuTitle == title {
                return children
            }
        }
        return nil
    }

    @Test("先頭はモード行で、その直後に区切り線が来る")
    func firstEntriesAreTheModeLine() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        guard case .item(let title, _, _, _) = entries.first else {
            Issue.record("先頭が項目でない")
            return
        }
        #expect(title == actions.safetyStatusLine + "  ›")
        guard case .separator = entries[1] else {
            Issue.record("モード行の直後に区切り線が無い")
            return
        }
    }

    @Test("「スクショに写り込む」のチェックは写り込みの入り / 切りを映し、押すと切り替わる")
    func photobombEntryReflectsAndTogglesTheSetting() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let enabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(enabled.isChecked)

        enabled.action()
        #expect(actions.isPhotobombEnabled == false)

        let disabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(disabled.isChecked == false)
    }

    @Test("デバッグメニューは isDebugMenuVisible == false ならサブメニューごと出ない")
    func debugSubmenuDisappearsWhenHidden() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.isDebugMenuVisible = false

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)

        // 「デバッグ」サブメニューと、その直前の区切り線が一緒に消える。
        let hasDebugSubmenu = entries.contains { entry in
            if case .submenu(let title, _) = entry { return title == "デバッグ" }
            return false
        }
        #expect(!hasDebugSubmenu)
        let separatorCount = entries.reduce(into: 0) { count, entry in
            if case .separator = entry { count += 1 }
        }
        // (モード行)と(監視 / 在席 / 休憩)と(サイズ / 声 / 写り込み)の後ろの 3 本だけになる。
        #expect(separatorCount == 3)

        // 見える設定なら(既定どおり)デバッグサブメニューが最後に付く。
        let visible = StubPetMenuActions()
        let visibleEntries = PetMenuEntries.make(actions: visible, presenter: presenter)
        let last = try #require(visibleEntries.last)
        guard case .submenu("デバッグ", _) = last else {
            Issue.record("デバッグサブメニューが最後に付いていない")
            return
        }
    }

    @Test("執行猶予脱出の項目は状態どおりに出る(冷却中は灰色で押せない)")
    func escapeEntriesReflectTheState() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        // 使えるとき: 宣言ダイアログを開く。
        actions.escapeMenuState = .available
        let open = try #require(
            findItem("どうしても終了する…", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(open.isEnabled)
        open.action()
        #expect(actions.escapeDialogOpens == 1)

        // カウントダウン中: 取り消し項目に変わり、残り時間を出す。
        actions.escapeMenuState = .countingDown(remaining: 2 * 60)
        let cancel = try #require(
            findItem("終了を取り消す(あと2 分)", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(cancel.isEnabled)
        cancel.action()
        #expect(actions.escapeCancels == 1)
        #expect(findItem("どうしても終了する…", in: PetMenuEntries.make(actions: actions, presenter: presenter)) == nil)

        // 冷却中: 灰色にして押せなくし、理由をタイトルに載せる(Epic #58)。
        actions.escapeMenuState = .coolingDown(remaining: 23 * 3600)
        let cooling = try #require(
            findItem("どうしても終了する(あと23 時間 0 分で使えます)", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(cooling.isEnabled == false)
        cooling.action()
        #expect(actions.escapeDialogOpens == 1)
        #expect(actions.escapeCancels == 1)

        // ロック外など hidden のときはどちらも出ない。
        actions.escapeMenuState = .hidden
        let hidden = PetMenuEntries.make(actions: actions, presenter: presenter)
        #expect(findItem("どうしても終了する…", in: hidden) == nil)
        #expect(findItem("終了を取り消す", in: hidden) == nil)
    }

    @Test("じっくり決める設定は「設定…」1 つに寄り、個別の項目は通常メニューから消える")
    func settingsAreCollapsedIntoOneEntry() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)

        #expect(findItem("設定…", in: entries) != nil)
        #expect(findItem("セーフティー設定…", in: entries) == nil)
        #expect(findItem("Discord 設定…", in: entries) == nil)
        #expect(findItem("権限の確認…", in: entries) == nil)
        #expect(findItem("状態パネルを表示", in: entries) == nil)
    }

    @Test("モード行を押すとセーフティータブを指して設定画面が開く")
    func modeLineOpensTheSafetyTab() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let modeLine = try #require(
            findItem(actions.safetyStatusLine + "  ›", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        modeLine.action()

        #expect(actions.settingsOpens == 1)
        #expect(actions.lastSettingsTab == .safety)
    }

    @Test("「設定…」を押すとタブを指定せずに設定画面が開く")
    func settingsEntryKeepsTheLastTab() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let settings = try #require(
            findItem("設定…", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        settings.action()

        #expect(actions.settingsOpens == 1)
        #expect(actions.lastSettingsTab == nil)
    }

    @Test("「状態パネルを表示」はデバッグサブメニューの中にある")
    func statusPanelEntryLivesInTheDebugSubmenu() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()
        actions.isDebugMenuVisible = true

        let entries = PetMenuEntries.make(actions: actions, presenter: presenter)
        let debug = try #require(findSubmenu("デバッグ", in: entries))
        let statusPanel = try #require(findItem("状態パネルを表示", in: debug))

        #expect(statusPanel.isChecked == false)
        statusPanel.action()
        #expect(actions.statusPanelToggles == 1)
        #expect(actions.isStatusPanelVisible)
    }
}
