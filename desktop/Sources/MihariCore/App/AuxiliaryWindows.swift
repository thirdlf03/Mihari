import AppKit
import SwiftUI

/// ふだんは出さない補助ウィンドウ(設定 / 権限 / 最初の設定 / デバッグ UI / 脱出)の置き場。
///
/// Mihari の本体はデスクトップのペットで、ウィンドウは必要になったときだけ出す。
/// そのため SwiftUI の `WindowGroup` は使わず、ここで `NSWindow` を直接組み立てて使い回す。
/// `isReleasedWhenClosed = false` にしてあるので、閉じても同じウィンドウを開き直せる。
@MainActor
final class AuxiliaryWindows {

    private var permissions: NSWindow?
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private var debug: NSWindow?
    private var escape: NSWindow?

    /// 起動時の「始める」フロー用の権限の確認画面を出す(すでに出ていれば中身を差し替えて前面へ)。
    ///
    /// 設定としての権限確認は設定ウィンドウの「権限」タブ側にある。こちらは初回導線専用で、
    /// 出す中身は「始める」ボタン付きの `OnboardingView` の 1 種類だけ。
    /// オンボーディングと同じ 600×520 に固定する(`PermissionRow` はボタンを説明の下に
    /// 右寄せで置く形なので、この幅でも収まる)。
    func showPermissions<Content: View>(@ViewBuilder content: () -> Content) {
        permissions = present(
            permissions,
            title: "権限の確認",
            size: NSSize(width: 600, height: 520),
            content: content()
        )
        permissions?.contentMinSize = NSSize(width: 600, height: 520)
        permissions?.contentMaxSize = NSSize(width: 600, height: 520)
        makeWizard(permissions)
    }

    /// 権限の確認画面を閉じる。出していなければ何もしない。
    func closePermissions() {
        permissions?.close()
    }

    /// セーフティーのオンボーディング(ようこそ → コース → 権限 → 完了)を出す。
    /// 既存の権限画面ウィンドウとは別枠。各ステップは ScrollView なので 600×520 に収める。
    /// ウィザードなのでサイズは固定する。縦に手で伸ばすと空白ばかり見えて「長すぎる」
    /// 見た目になるため、幅も高さも最初に決めた値に固定する。
    func showOnboarding<Content: View>(@ViewBuilder content: () -> Content) {
        onboarding = present(
            onboarding,
            title: "最初の設定",
            size: NSSize(width: 600, height: 520),
            content: content()
        )
        onboarding?.contentMinSize = NSSize(width: 600, height: 520)
        onboarding?.contentMaxSize = NSSize(width: 600, height: 520)
        makeWizard(onboarding)
    }

    /// セーフティーのオンボーディングを閉じる。出していなければ何もしない。
    func closeOnboarding() {
        onboarding?.close()
    }

    /// 設定画面(セーフティー / Discord / 権限のタブ)を出す。
    ///
    /// `PermissionRow` はボタンを説明の下に右寄せで置く形なので、横に幅を取らない。
    /// オンボーディングと同じ 600×520 に固定して、どのウィンドウも同じ大きさに揃える。
    /// 3 タブとも中身は自前の ScrollView を持つので、この高さで足りる。
    func showSettings<Content: View>(@ViewBuilder content: () -> Content) {
        settings = present(
            settings,
            title: "設定",
            size: NSSize(width: 600, height: 520),
            content: content()
        )
        settings?.contentMinSize = NSSize(width: 600, height: 520)
        settings?.contentMaxSize = NSSize(width: 600, height: 520)
    }

    /// 設定画面を閉じる。出していなければ何もしない。
    func closeSettings() {
        settings?.close()
    }

    /// 検証用の 10 タブ画面を出す。`MIHARI_DEBUG_UI=1` のときだけ使う。
    func showDebug<Content: View>(@ViewBuilder content: () -> Content) {
        debug = present(
            debug,
            title: "Mihari (検証用)",
            size: NSSize(width: 940, height: 720),
            content: content()
        )
    }

    /// 執行猶予脱出の宣言ダイアログを出す。
    func showEscape<Content: View>(@ViewBuilder content: () -> Content) {
        // 見出しはこのウィンドウ題 1 つだけにする。中身に同じ見出しをもう 1 行置くと、
        // 同じことを 2 回言うだけになる。
        escape = present(
            escape,
            title: "どうしても終了する",
            // 本文が 4 行あるので、200 では説明とピッカーが見切れる。
            size: NSSize(width: 420, height: 300),
            content: content()
        )
    }

    /// 実行猶予脱出の宣言ダイアログを閉じる。出していなければ何もしない。
    func closeEscape() {
        escape?.close()
    }

    /// 既にあるウィンドウなら中身を差し替えて前面に出し、無ければ作る。
    private func present<Content: View>(
        _ existing: NSWindow?,
        title: String,
        size: NSSize,
        content: Content
    ) -> NSWindow {
        let window = existing ?? makeWindow(title: title)
        // 既定のままでは NSHostingController がビューの fitting サイズでウィンドウを
        // 引き伸ばし、ここで決めた setContentSize や contentMin/MaxSize を無視して
        // 縦に伸びる(600×520 のはずが 600×818 になる)。ウィザード系はサイズ固定なので
        // 自動サイズ調整を無効化する。
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // 大きさと位置は最初に開いたときだけ決める。次からはユーザーが動かした場所を尊重する。
        if existing == nil {
            window.setContentSize(size)
            window.center()
        }
        // ペットはキーウィンドウにならないため、アプリ自体が前に出ていないことがある。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// ウィザード(オンボーディング / 初回権限)を途中で × で閉じられないようにする。
    ///
    /// `begin()` 前はペットも右クリックメニューも無く、ウィンドウを閉じた瞬間に
    /// そのセッションは何も操作できない状態になる(`AppCoordinator.handleReopen` も
    /// `hasBegun == false` では何も出さない)。退避は各ステップの「戻る」か、どうしても
    /// 抜けたいときの Cmd+Q(アプリ終了)に限定する。
    private func makeWizard(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.remove(.closable)
        window.standardWindowButton(.closeButton)?.isHidden = true
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // 閉じたあとも同じウィンドウを開き直すため、解放させない。
        window.isReleasedWhenClosed = false
        return window
    }
}
