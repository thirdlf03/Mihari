import Foundation

/// セーフティー画面(モード選択 / 設定)の表示ロジック。
///
/// SwiftUI の View はテストハーネスが無いので、判定と文言をここに純粋関数として
/// 切り出し、テストはこちらに対して書く(`SafetyModeViewModelTests`)。
/// View 側は文言を持たず、この関数の返り値をそのまま表示する。
public enum SafetyModeViewModel {

    /// Toggle の操作をポリシーへの依頼(`SafetyChange`)に変換する。
    public static func toggleChange(for feature: SafetyFeature, turningOn: Bool) -> SafetyChange {
        turningOn ? .enable(feature) : .disable(feature)
    }

    /// `SafetyDecision` から「状態行」に出す 1 行の文言を決める。
    ///
    /// 断るときは「できない」で終わらせず、次に何をすればできるようになるかまで書く。
    ///
    /// - Parameter lockedUntil: 終了ロックの解除時刻。ロック中でなければ `nil`。
    ///   `quitLockWhileWatching` の文言に「いつ OFF にできるようになるか」を添えるために使う。
    /// - Returns: 表示すべき文言。何も出さないときは `nil`。
    ///
    /// - Note: `.schedule` は予約帯を出して結果を示すため、状態行には何も書かない。
    ///   `.apply` は `skipped`(監視中の `disableAll` で残した `quitLock` など)が
    ///   あるときだけ、その旨を伝える。
    public static func statusMessage(
        for decision: SafetyDecision,
        lockedUntil: Date? = nil
    ) -> String? {
        switch decision {
        case .apply(_, let skipped):
            // 監視中に「全部 OFF」を頼むと quitLock だけ残る。残したことを明かさないと
            // 「全部 OFF にしたのに終了できない」と誤解させるため、ここで伝える。
            if !skipped.isEmpty {
                return "監視中なので「監視中は終了させない」は残しました"
            }
            return nil
        case .schedule:
            return nil
        case .reject(let reason):
            switch reason {
            case .quitLockWhileWatching:
                let unlock = lockedUntil.map { "ロック解除(\(clockText($0)))" } ?? "ロック解除"
                return "\(unlock)まで OFF にできません。どうしても終了したい場合は右クリック →「どうしても終了する」"
            case .dependencyMissing:
                return "「iPhone を見張る」を先に ON にしてください"
            }
        }
    }

    /// 時刻だけの表示文字列。`HH:mm` の形にする。ロック解除時刻に使う。
    public static func clockText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    /// #5(終了ブロック)の Toggle の左に出す「OFF にできない理由」。
    ///
    /// 変更できない旨を出すのはこの 1 本だけ。ほかのトグルは監視中でも ON も OFF も
    /// できるので、何も添えない。
    ///
    /// 解除時刻が分かるならそれを出す。監視を止めてもロックが残っている間は OFF に
    /// できないので、「監視中」ではなくロックが理由であることを書く(#52)。時刻が
    /// 取れないとき(ロックは切れたが監視は続いている)だけ「監視中」と書く。
    ///
    /// - Returns: 出す文言。制限がかかっていなければ nil。
    public static func quitLockRestrictionNote(isWatching: Bool, lockedUntil: Date?) -> String? {
        if let lockedUntil {
            return "ロック中(\(clockText(lockedUntil)) まで): OFF にできません"
        }
        return isWatching ? "監視中: OFF にできません" : nil
    }

    /// 予約の発効時刻の表示文字列。`Date.FormatStyle` で `M/d HH:mm` の形にする。
    public static func pendingTimeText(effectiveAt: Date) -> String {
        effectiveAt.formatted(
            Date.FormatStyle()
                .month(.defaultDigits)
                .day(.defaultDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    /// カードの中に出す予約バッジの文言。「9/2 14:30 に ON」の形。
    ///
    /// 設定画面の最下部と違って、そのカード 1 枚のことだけを言う。
    public static func pendingFeatureText(effectiveAt: Date) -> String {
        "\(pendingTimeText(effectiveAt: effectiveAt)) に ON"
    }

    /// 設定画面の最下部に出す予約帯の文言。予約の中身で出し分ける。
    ///
    /// 予約に載るのは緩める方向(機能の ON・「あとで設定を変えられるようにする」の復帰)
    /// だけなので、どちらが載っているかで文を変える。両方なら 1 文にまとめる。
    public static func pendingStatusText(for pending: SafetyPendingChange) -> String {
        let time = pendingTimeText(effectiveAt: pending.effectiveAt)
        // 表示順はトグルの並び順に合わせる(Set のままだと順序が安定しない)。
        let names = SafetyFeature.allCases
            .filter { pending.enabling.contains($0) }
            .map(\.title)
        let changeability = "「あとで設定を変えられるようにする」"
        switch (names.isEmpty, pending.restoresChangeability) {
        case (false, false):
            return "\(time) に ON になります(\(names.joined(separator: ", ")))"
        case (false, true):
            return "\(time) に ON になります(\(names.joined(separator: ", "))、\(changeability))"
        case (true, true):
            return "\(time) に\(changeability)が ON に戻ります"
        case (true, false):
            // 中身が空の予約は積まれない(`SafetyPolicy.removing` が消す)ので、保険。
            return "\(time) に発効します"
        }
    }

    /// オンボーディングのステップ 2(権限画面)を飛ばしてよいか。
    ///
    /// トグルが要求している権限が 1 つも無く、かつ tunneld も不要(iphoneScreenshot が
    /// OFF)なら、ステップ 2 に見せるものが無いので直ちに `onStart` する。
    ///
    /// モーションのようにトグルと紐づかない権限(`feature == nil`)は全 OFF でも一覧に
    /// 出るが、任意なので「見せるものがある」とは数えない。
    public static func shouldSkipPermissionsStep(
        relevantKinds: [PermissionKind],
        isIPhoneScreenshotEnabled: Bool
    ) -> Bool {
        relevantKinds.allSatisfy { $0.feature == nil } && !isIPhoneScreenshotEnabled
    }

    // MARK: - 見た目の文言(design-54.md)

    /// モードの一言。
    public static func modeSubtitle(for mode: SafetyMode) -> String {
        switch mode {
        case .safety:
            return "撮らない・晒さない・縛らない。サボると吹き出しと声で注意するだけ。"
        case .custom(let enabledCount):
            return "ON の機能が \(enabledCount) 個あります。"
        case .unlimited:
            return "Mihari が本気になります。終了もロック時間(既定 4 時間)はできません。"
        }
    }

    /// モードのアイコン。
    public static func modeIcon(for mode: SafetyMode) -> String {
        switch mode {
        case .safety:
            return "checkmark.shield.fill"
        case .custom:
            return "slider.horizontal.3"
        case .unlimited:
            return "flame.fill"
        }
    }

    /// ヘッダーの 7 インジケータに並べる短い名前。トグルの並び順どおり。
    public static func shortFeatureName(for feature: SafetyFeature) -> String {
        switch feature {
        case .macCamera: return "Mac"
        case .iphonePresence: return "iPhone"
        case .iphoneScreenshot: return "画面"
        case .discordExposure: return "Discord"
        case .sermonTakeover: return "占領"
        case .quitLock: return "終了"
        case .photobomb: return "写込"
        }
    }

    /// 従属(`requires` を持つ機能)のカードに添える 1 行の文言。
    ///
    /// 前提が OFF なら選べないので、その理由を出す。前提が予約中(発効待ちの ON に
    /// 載っている)なら従属も同じ予約に積めるので、選べないのではなく「一緒に ON に
    /// なる」ことを伝える。
    ///
    /// - Returns: 出す文言。前提が ON で添える必要が無いときは nil。
    public static func dependencyNote(
        isRequiredEnabled: Bool,
        isRequiredPending: Bool
    ) -> String? {
        if isRequiredEnabled {
            return nil
        }
        if isRequiredPending {
            return "「iPhone を見張る」の予約と一緒に ON になります"
        }
        return "「iPhone を見張る」を ON にすると選べます"
    }

    /// カードの注意帯の文言。対象は iphoneScreenshot と quitLock の 2 本だけ。
    ///
    /// 要約(`SafetyFeature.summary`)と同じことを繰り返さず、要約に書いていない
    /// 「外に出る」「戻せなくなる」だけをここに書く。
    public static func notice(for feature: SafetyFeature) -> String? {
        switch feature {
        case .iphoneScreenshot:
            return "画面の中身が外部(Google Gemini)に送られます"
        case .quitLock:
            return "ON にした瞬間からロックされます(解除まで OFF にできません)"
        default:
            return nil
        }
    }

    // MARK: - カードの権限行

    /// カードの「権限」行に出すもの。
    ///
    /// トグルが OFF のうちは「何が要るか」の静的な案内でよいが、ON にしたあとは
    /// 「いま許可が下りているか」を出さないと、拒否・キャンセルされたことに気づけない。
    public enum PermissionRowState: Equatable, Sendable {
        /// 静的な案内(トグル OFF、または権限が要らない機能)。
        case staticNote(String)
        /// 許可済み / 登録済み。
        case satisfied(String)
        /// 未許可 / 未登録。押せば先に進めるボタンを添える。
        case missing(text: String, actionTitle: String, action: PermissionRowAction)
        /// 確認中・登録中で、まだどちらとも言えない。
        case working(String)
    }

    /// 権限行のボタンが何をするか。
    public enum PermissionRowAction: Equatable, Sendable {
        /// システム設定の該当ペインを開く(TCC は一度断られるとアプリから再要求できない)。
        case openSystemSettings
        /// tunneld の LaunchDaemon を登録する(管理者パスワード)。
        case installTunneld
    }

    /// tunneld の状態を権限行の 3 段階に均したもの。
    public enum TunneldReadiness: Equatable, Sendable {
        case ready
        case missing
        case working
    }

    /// `TunneldModel.Status` を権限行の 3 段階に均す。
    public static func readiness(of status: TunneldModel.Status) -> TunneldReadiness {
        switch status {
        case .running: return .ready
        case .notRunning: return .missing
        case .unknown, .checking, .installing: return .working
        }
    }

    /// カードの「権限」行を決める。
    ///
    /// - Parameters:
    ///   - isEnabled: そのトグルが ON か。OFF なら静的な案内に留める。
    ///   - kind: この機能が要求する TCC 権限。要らない機能では `nil`。
    ///   - grant: `kind` の現在の状態。`kind` が `nil` のときは無視する。
    ///   - tunneld: tunneld の状態。tunneld が要らない機能では `nil`。
    public static func permissionRow(
        for feature: SafetyFeature,
        isEnabled: Bool,
        kind: PermissionKind?,
        grant: PermissionGrant?,
        tunneld: TunneldReadiness?
    ) -> PermissionRowState {
        guard isEnabled else { return .staticNote(feature.permissionNote) }

        if let tunneld {
            switch tunneld {
            case .ready:
                return .satisfied("tunneld: 登録済み")
            case .missing:
                return .missing(
                    text: "tunneld: 未登録 — 登録されるまで iPhone の画面は撮れません",
                    actionTitle: "登録する…",
                    action: .installTunneld
                )
            case .working:
                return .working("tunneld: 確認中…")
            }
        }

        guard let kind, let grant else { return .staticNote(feature.permissionNote) }
        if grant == .granted {
            return .satisfied("\(kind.title): 許可済み")
        }
        // 残る権限は、必須(カメラ)と任意(オートメーション・モーション)に分かれる。
        // 必須は「進めない」、任意は「一部だけ動かない」と書き分けて、断ったときの
        // 影響を過大にも過小にも見せない。カメラだけが唯一の必須権限
        // (`PermissionKind.required(for:)`)。
        let isRequired = kind == .camera
        return .missing(
            text: isRequired
                ? "\(kind.title): 未許可 — この機能の開始に必要です。OFF にすれば先へ進めます"
                : "\(kind.title): 未許可 — \(kind.consequenceIfDenied)(任意なので OFF のままでも進めます)",
            actionTitle: "システム設定を開く",
            action: .openSystemSettings
        )
    }
}
