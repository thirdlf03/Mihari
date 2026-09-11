import AppKit
import Testing

@testable import MihariCore

@Suite("ペットの右クリックメニュー")
@MainActor
struct PetContextMenuTests {

    /// 項目が押された回数を覚えておく箱。
    private final class ActionCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("項目を押すとクロージャが呼ばれる")
    func itemRunsItsAction() {
        // performActionForItem は NSApp 経由で action を送るので、先にアプリを作っておく。
        _ = NSApplication.shared
        let counter = ActionCounter()
        let menu = PetContextMenu.makeMenu([
            .item(title: "しゃべる", action: { counter.record() })
        ])

        menu.performActionForItem(at: 0)

        #expect(counter.count == 1)
    }

    @Test("サブメニューの項目を押してもクロージャが呼ばれる")
    func submenuItemRunsItsAction() {
        _ = NSApplication.shared
        let counter = ActionCounter()
        let menu = PetContextMenu.makeMenu([
            .submenu(title: "サイズ", entries: [.item(title: "大", action: { counter.record() })])
        ])

        let submenu = menu.items[0].submenu
        submenu?.performActionForItem(at: 0)

        #expect(counter.count == 1)
    }

    @Test("チェックの有無がそのまま項目の状態になる")
    func checkedStateFollowsEntry() {
        let menu = PetContextMenu.makeMenu([
            .item(title: "声を出す", isChecked: true, action: {}),
            .item(title: "状態パネルを表示", isChecked: false, action: {}),
        ])

        #expect(menu.items[0].state == .on)
        #expect(menu.items[1].state == .off)
    }

    @Test("サブメニューは入れ子になり、区切りは区切り線になる")
    func submenuAndSeparatorAreBuilt() {
        let menu = PetContextMenu.makeMenu([
            .submenu(title: "サイズ", entries: [.item(title: "小", action: {}), .item(title: "大", action: {})]),
            .separator,
        ])

        #expect(menu.items[0].title == "サイズ")
        #expect(menu.items[0].submenu?.items.count == 2)
        #expect(menu.items[0].submenu?.items.map { $0.title } == ["小", "大"])
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test("「設定…」は「スクショに写り込む」の後の区切り線に続いて並ぶ")
    func settingsItemSitsAfterTheQuickToggles() throws {
        // 実機の表示設定をテスト同士で共有しないよう、実行のたびに空の UserDefaults を使う。
        let suiteName = "mihari.test.petContextMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let presenter = LivePetPresenter(controller: PetController(defaults: defaults))
        let actions = StubPetMenuActions()

        let menu = PetContextMenu.makeMenu(
            PetMenuEntries.make(actions: actions, presenter: presenter)
        )
        let titles = menu.items.map(\.title)
        let settingsIndex = try #require(titles.firstIndex(of: "設定…"))

        #expect(menu.items[settingsIndex - 1].isSeparatorItem)
        #expect(titles[settingsIndex - 2] == "スクショに写り込む")
        // 個別の設定項目は「設定…」のタブへ寄せたので、通常メニューには残っていない。
        #expect(!titles.contains("セーフティー設定…"))
        #expect(!titles.contains("Discord 設定…"))
        #expect(!titles.contains("権限の確認…"))
        #expect(!titles.contains("状態パネルを表示"))
    }

    @Test("自動での有効・無効判定に任せず、明示しなければ押せるままにする")
    func itemsStayEnabledUnlessSaidOtherwise() {
        // キーウィンドウにならないパネルから出すので、AppKit に任せると項目が灰色になる。
        let menu = PetContextMenu.makeMenu([
            .item(title: "しゃべる", action: {}),
            .submenu(title: "サイズ", entries: [.item(title: "小", action: {})]),
        ])

        #expect(menu.autoenablesItems == false)
        #expect(menu.items.allSatisfy { $0.isEnabled })
        #expect(menu.items[1].submenu?.autoenablesItems == false)
        #expect(menu.items[1].submenu?.items.allSatisfy { $0.isEnabled } == true)
    }

    @Test("isEnabled が false の項目は灰色になる")
    func disabledEntryBecomesAGreyedItem() {
        let menu = PetContextMenu.makeMenu([
            .item(title: "どうしても終了する(あと23 時間 0 分で使えます)", isEnabled: false, action: {}),
            .item(title: "在席スタンプを押す", action: {}),
        ])

        #expect(menu.items[0].isEnabled == false)
        #expect(menu.items[1].isEnabled)
    }

    @Test("脱出が冷却中なら、その項目だけが灰色で並ぶ")
    func coolingDownEscapeItemIsGreyedOut() throws {
        let suiteName = "mihari.test.petContextMenu.cooling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let presenter = LivePetPresenter(controller: PetController(defaults: defaults))
        let actions = StubPetMenuActions()
        actions.escapeMenuState = .coolingDown(remaining: 23 * 3600)

        let menu = PetContextMenu.makeMenu(
            PetMenuEntries.make(actions: actions, presenter: presenter)
        )
        let cooling = try #require(
            menu.items.first { $0.title.hasPrefix("どうしても終了する(") }
        )

        #expect(cooling.isEnabled == false)
        // 灰色にするのは冷却中の項目だけ。ほかは押せたままにする。
        #expect(menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }.count == 1)
    }

    @Test("右クリックメニューの先頭はモード行になる")
    func firstEntryIsTheModeLine() throws {
        _ = NSApplication.shared
        let actions = StubPetMenuActions()
        let suiteName = "mihari.test.contextMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let presenter = LivePetPresenter(controller: PetController(defaults: defaults))

        let menu = PetContextMenu.makeMenu(PetMenuEntries.make(actions: actions, presenter: presenter))

        #expect(menu.items.first?.title == actions.safetyStatusLine + "  ›")
        #expect(menu.items[1].isSeparatorItem)
    }
}
