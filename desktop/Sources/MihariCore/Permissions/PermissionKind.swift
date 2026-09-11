import Foundation

/// Mihari が使う TCC 権限。オンボーディング画面にはこの順で並ぶ。
///
/// マイクと入力監視は使用コードが無いため扱わない(#51)。見せるか・必須かは
/// セーフティートグルから導出する(`relevant(for:)` / `required(for:)`)。
public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case camera
    case screenRecording
    case automation
    case motion

    public var id: String { rawValue }

    /// この権限を必要とするトグル。nil は「トグルと無関係(常に任意)」。
    ///
    /// 画面収録はデバッグタブの Mac スクショ専用、モーションは AirPods 首振りで、
    /// どちらもセーフティートグルとは紐づかない。
    public var feature: SafetyFeature? {
        switch self {
        case .camera: return .macCamera
        case .automation: return .sermonTakeover
        case .screenRecording: return nil
        case .motion: return nil
        }
    }

    /// 設定で意味を持つ(画面に出す)権限。screenRecording は含めない。
    ///
    /// トグルに紐づく権限は対応するトグルが ON のときだけ出し、トグルと
    /// 無関係の権限(モーション)は常に出す。screenRecording はオンボーディングには
    /// 出さず、デバッグタブで撮る直前に要求する。
    public static func relevant(for settings: SafetySettings) -> [PermissionKind] {
        allCases.filter { kind in
            guard let feature = kind.feature else { return kind != .screenRecording }
            return settings.isEnabled(feature)
        }
    }

    /// 揃わないと始められない権限。macCamera ON のときの camera のみ。
    ///
    /// automation は sermonTakeover ON でも「任意」に留める: 実際に Music / Spotify へ
    /// 命令を送る瞬間までプロンプトが出せず、必須にすると始められなくなるため。
    public static func required(for settings: SafetySettings) -> [PermissionKind] {
        guard settings.isEnabled(.macCamera) else { return [] }
        return [.camera]
    }

    /// 起動時・「まとめて許可を求める」でプロンプトできるもの。
    ///
    /// `relevant(for:)` のうち `requestButtonTitle != nil` かつモーション以外。
    /// モーションは AirPods が接続されていないとプロンプトが出ないため、まとめ要求からは外す。
    public static func requestableOnLaunch(for settings: SafetySettings) -> [PermissionKind] {
        relevant(for: settings).filter { $0.requestButtonTitle != nil && $0 != .motion }
    }

    public var title: String {
        switch self {
        case .camera: return "カメラ"
        case .screenRecording: return "画面収録"
        case .automation: return "オートメーション"
        case .motion: return "モーション(AirPods)"
        }
    }

    /// この権限が何に使われるか。ユーザーに見せる説明で、Info.plist の用途文字列と揃える。
    public var purpose: String {
        switch self {
        case .camera: return "サボりが確定したときに証拠写真を 1 枚撮ります"
        case .screenRecording: return "デバッグ画面から Mac のスクリーンショットを撮るときだけ使います"
        case .automation: return "説教中に Music や Spotify の再生を止めます(どちらか一方の許可で足ります)"
        case .motion: return "AirPods の首振りを はい/いいえ として受け取ります"
        }
    }

    /// 状態の照会に使っている API。想定と違う状態のときに、どこを見ればよいか分かるように出す。
    public var api: String {
        switch self {
        case .camera: return "AVCaptureDevice.authorizationStatus(for: .video)"
        case .screenRecording: return "CGPreflightScreenCaptureAccess()"
        case .automation: return "AEDeterminePermissionToAutomateTarget(com.apple.Music / com.spotify.client)"
        case .motion: return "CMHeadphoneMotionManager.authorizationStatus()"
        }
    }

    public var pane: PrivacyPane {
        switch self {
        case .camera: return .camera
        case .screenRecording: return .screenCapture
        case .automation: return .automation
        case .motion: return .motion
        }
    }

    /// アプリから権限要求 API を叩ける権限だけボタンのラベルを返す。
    /// オートメーションは対象アプリへ実際にイベントを送った瞬間しかプロンプトが出ないため、ここでは要求できない。
    public var requestButtonTitle: String? {
        switch self {
        case .camera, .screenRecording, .motion: return "許可を求める"
        case .automation: return nil
        }
    }

    /// 権限が下りていないときに、その権限に依存する機能がどう壊れるか。
    public var consequenceIfDenied: String {
        switch self {
        case .camera: return "サボりの証拠写真が撮れません"
        case .screenRecording: return "Mac の画面を晒せません"
        case .automation: return "Music / Spotify を止められません(オーバーレイは出ます)"
        case .motion: return "首振りで答えられません"
        }
    }

    /// 未許可のときに行へ添える操作のヒント。ハマりやすい権限だけ持つ。
    public var setupHint: String? {
        switch self {
        case .screenRecording:
            return "許可後はアプリの再起動が必要"
        case .automation:
            return
                "システム設定の Mihari の下で、Music か Spotify を ON にしてください。判定するにはそのアプリを起動した状態で再チェックが必要で、起動していないと許可済みでも灰色のままです。許可ダイアログはこの画面からは出せず、実際に止めようとした瞬間に出ます。"
        case .camera, .motion:
            return nil
        }
    }
}
