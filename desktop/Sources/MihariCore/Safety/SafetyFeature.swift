import Foundation

/// 機能単位のセーフティートグル。
///
/// 侵襲的な機能(カメラ撮影・iPhone 接続・Discord 投稿・画面占領・終了ブロック・
/// スクショ写り込み)は既定で全部 OFF(= セーフティーモード)にして、ユーザーが
/// 1 本ずつ明示的に ON にしたものだけ動くようにする。
///
/// `rawValue` は `UserDefaults` への保存(JSON)と環境変数 `MIHARI_SAFETY_ENABLE` に
/// そのまま使うので、変えてはいけない。
public enum SafetyFeature: String, CaseIterable, Codable, Sendable, Hashable {
    /// Mac のカメラで撮る。
    case macCamera
    /// iPhone を見張る(触っているかだけ)。
    case iphonePresence
    /// iPhone の画面を撮る。`iphonePresence` が前提。
    case iphoneScreenshot
    /// Discord に晒す。
    case discordExposure
    /// 説教中は画面を占領する。
    case sermonTakeover
    /// 監視中は終了させない。
    case quitLock
    /// スクショに写り込む。
    case photobomb

    /// 一覧に出す日本語名。
    ///
    /// 説明文の見出しになる名前で、番号(「#n」)は含めない。機能を足したらここも足す。
    public var title: String {
        switch self {
        case .macCamera: return "Mac のカメラで撮る"
        case .iphonePresence: return "iPhone を見張る(触っているかだけ)"
        case .iphoneScreenshot: return "iPhone の画面を撮る"
        case .discordExposure: return "Discord に晒す"
        case .sermonTakeover: return "説教中は画面を占領する"
        case .quitLock: return "監視中は終了させない"
        case .photobomb: return "スクショに写り込む"
        }
    }

    /// 何をするかの説明文。
    public var summary: String {
        switch self {
        case .macCamera:
            return "サボりが確定したときにカメラで 1 枚撮ります。写真はこの Mac の中で判定し、撮影後すぐ削除します"
        case .iphonePresence:
            return "iPhone を触っているか(画面の点灯・操作中)と、開いているアプリの名前を見ます。画面の中身は見ません"
        case .iphoneScreenshot:
            return "サボりが確定したときに iPhone の画面を撮ります"
        case .discordExposure:
            return
                "サボりが確定したとき・逃げたとき・戻ってきたときに Discord へ投稿します。写真や画面を撮る設定が OFF なら文面だけです。Bot トークンを設定していると、OFF のあいだも Discord への接続だけは保ちます(投稿はしません)"
        case .sermonTakeover:
            return "サボりが確定したとき、再生中の音楽を止めて全画面で説教します。既定 90 秒(最長 300 秒)で必ず解除されます"
        case .quitLock:
            return
                "アプリを起動した瞬間から、決めた時間(既定 4 時間)は終了できなくなります。終了させないために、常駐の見張り(LaunchAgent)とログイン項目を登録し、終了シグナル(SIGTERM/SIGINT)も無視して、20 秒ごとに登録を貼り直します。登録は OFF にしたとき、または時間が切れてから終了したときに解除します。Mac はスリープしませんが画面は消えます"
        case .photobomb:
            return "あなたが撮ったスクリーンショットに、あとからペットを描き足して上書き保存します"
        }
    }

    /// どこに送られるか。ON にする前に「何が外に出るか」を確かめられるようにする。
    public var destination: String {
        switch self {
        case .macCamera:
            return "Discord(「Discord に晒す」が ON のとき)"
        case .iphonePresence:
            return
                "このトグルだけならどこにも送りません(「iPhone の画面を撮る」が ON のときは開いているアプリ名も Google Gemini に送られ、「Discord に晒す」も ON なら読み取ったアプリ名が文面に載ります)"
        case .iphoneScreenshot:
            return "Google Gemini、Discord(「Discord に晒す」が ON のとき)"
        case .discordExposure:
            return "Discord"
        case .sermonTakeover, .quitLock, .photobomb:
            return "どこにも送りません"
        }
    }

    /// この機能に必要な権限。
    public var permissionNote: String {
        switch self {
        case .macCamera: return "カメラ"
        case .iphonePresence: return "なし(USB 接続)"
        case .iphoneScreenshot: return "tunneld の登録(管理者パスワード)"
        case .discordExposure: return "なし"
        case .sermonTakeover: return "オートメーション(Music / Spotify)"
        case .quitLock: return "なし"
        case .photobomb: return "デスクトップフォルダへのアクセス"
        }
    }

    /// この機能を ON にするために先に ON でなければならない機能。
    ///
    /// `iphoneScreenshot` は画面の中身を見るため、まず `iphonePresence` が
    /// ON でなければならない。他は独立。
    public var requires: SafetyFeature? {
        switch self {
        case .iphoneScreenshot: return .iphonePresence
        default: return nil
        }
    }

    /// 自分を `requires` に持つ機能(= 自分を OFF にしたら巻き添えで OFF になるもの)。
    public var dependents: [SafetyFeature] {
        SafetyFeature.allCases.filter { $0.requires == self }
    }

    /// bridge(デーモン)に伝える必要のある機能か。`SafetyDaemonPayload` が個別の ON/OFF
    /// を持つのはこの 3 本だけ。
    public var isForwardedToDaemon: Bool {
        switch self {
        case .iphonePresence, .iphoneScreenshot, .discordExposure: return true
        default: return false
        }
    }

    /// トグルの総数。モード表示(「カスタム(3/7)」)や無制限の判定に使う。
    public static let total = allCases.count
}
