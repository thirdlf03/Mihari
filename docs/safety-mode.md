# セーフティーモード

Mihari の「どれだけ侵襲的に動くか」を機能単位のトグルで決める仕組み。README の「セーフティーモード」が概要で、こちらが詳細。

ソース: `desktop/Sources/MihariCore/Safety/`(設定・ポリシー・ゲート)、`desktop/Sources/MihariCore/Escape/`(執行猶予脱出)、`desktop/Sources/MihariCore/Permissions/`(権限の導出)、`bridge/src/device_bridge/daemon/safety.py`(bridge 側の二重防御)。

## 3 つのモード

ON にしたトグルの本数でモードを決める(`SafetyMode`)。固定ではなく、いつでも切り替えられる。

| モード | 状態 | 表示 |
| --- | --- | --- |
| セーフティー | 全トグル OFF(既定) | 「セーフティー」 |
| カスタム | 一部 ON | 「カスタム(n/7)」 |
| 無制限 | 全トグル ON | 「無制限」 |

**既定は全 OFF(= セーフティー)**。カメラでの撮影・iPhone の見張り・Discord への投稿・終了のブロックなどは、どれも**本人が ON にしたトグルだけ**が動く。

## 7 つの設定

「何をするか」「どこに送られるか」「必要な権限」は `SafetyFeature` の `summary` / `destination` / `permissionNote` の文言をそのまま使う。各カードの説明文・送り先・権限も、設定画面(`SafetyModeView`)には同じ文言が出る。

| 設定 | 何をするか | どこに送られるか | 必要な権限 |
| --- | --- | --- | --- |
| Mac のカメラで撮る | サボりが確定したときにカメラで 1 枚撮ります。写真はこの Mac の中で判定し、撮影後すぐ削除します | Discord(「Discord に晒す」が ON のとき) | カメラ |
| iPhone を見張る(触っているかだけ) | iPhone を触っているか(画面の点灯・操作中)と、開いているアプリの名前を見ます。画面の中身は見ません | このトグルだけならどこにも送りません(「iPhone の画面を撮る」が ON のときは開いているアプリ名も Google Gemini に送られ、「Discord に晒す」も ON なら読み取ったアプリ名が文面に載ります) | なし(USB 接続) |
| iPhone の画面を撮る | サボりが確定したときに iPhone の画面を撮ります | Google Gemini、Discord(「Discord に晒す」が ON のとき) | tunneld の登録(管理者パスワード) |
| Discord に晒す | サボりが確定したとき・逃げたとき・戻ってきたときに Discord へ投稿します。写真や画面を撮る設定が OFF なら文面だけです。Bot トークンを設定していると、OFF のあいだも Discord への接続だけは保ちます(投稿はしません) | Discord | なし |
| 説教中は画面を占領する | サボりが確定したとき、再生中の音楽を止めて全画面で説教します。既定 90 秒(最長 300 秒)で必ず解除されます | どこにも送りません | オートメーション(Music / Spotify) |
| 監視中は終了させない | アプリを起動した瞬間から、決めた時間(既定 4 時間)は終了できなくなります。終了させないために、常駐の見張り(LaunchAgent)とログイン項目を登録し、終了シグナル(SIGTERM/SIGINT)も無視して、20 秒ごとに登録を貼り直します。登録は OFF にしたとき、または時間が切れてから終了したときに解除します。Mac はスリープしませんが画面は消えます | どこにも送りません | なし |
| スクショに写り込む | あなたが撮ったスクリーンショットに、あとからペットを描き足して上書き保存します | どこにも送りません | デスクトップフォルダへのアクセス |

「iPhone の画面を撮る」と「監視中は終了させない」のカードには、要約に無いことだけを書いた注意帯が付く(`SafetyModeViewModel.notice`): 前者は「画面の中身が外部(Google Gemini)に送られます」、後者は「ON にした瞬間からロックされます(解除まで OFF にできません)」。

「監視中は終了させない」が ON のあいだは、終了を塞ぐために常駐の仕掛けを入れる(`AppCoordinator.applyQuitLockPolicy`): 監視プロセスの LaunchAgent(`KeepAlive`、`LaunchAgentWatchdogRegistrar`)とログイン項目(`SMAppServiceLoginItemRegistrar`)を登録し、終了シグナル SIGTERM / SIGINT を無視して `confirmQuit` に回し(`TerminationSignalGuard`)、スリープも止める。`launchctl bootout` で外から登録を剥がされても **20 秒ごとに貼り直す**(`reassertIfMissing`)。この登録を解くのは、トグルを OFF にしたとき(`releaseQuitLock`)か、ロックが解けたあとに終了したときの 2 つ。執行猶予脱出で終了するときは、宣言時刻に自動で戻るために**あえて解除しない**。

依存関係: **「iPhone の画面を撮る」は「iPhone を見張る」が ON のときだけ選べる**。親を OFF にすると従属も一緒に OFF になる(`SafetyFeature.requires` / `dependents`)。

設定画面のカードの「権限」行は、トグルが OFF のうちは必要な権限の案内、**ON のあいだはいまの許可状態**(「カメラ: 許可済み」/「カメラ: 未許可 — 許可されるまでこの機能は動きません」/「tunneld: 未登録 — 登録されるまで iPhone の画面は撮れません」)を出し、未許可・未登録なら「システム設定を開く」「登録する…」を添える。ON にした直後にプロンプトを断っても気づけるようにするため。

権限はトグルから導出する(`PermissionKind`)。全 OFF なら**TCC 権限を 1 つも要求しない**。カメラは「Mac のカメラで撮る」が ON のときだけ必須、オートメーション・モーションは任意。画面収録はトグルと紐づかず、デバッグの Mac スクショを撮るときだけ使う。

## 設定を変えるとき

変更は `SafetyPolicy` が判定する。

| 方向 | ルール |
| --- | --- |
| ON(緩める) | **いつでも即時**。監視中・ロック中でも変えられる。必要な権限はその場で要求し、**次の検知から効く** |
| OFF(締める) | **常に即時**。ただし「監視中は終了させない」は監視中(ロック中も含む)に OFF にできない |

当初は「ON は監視していないときだけ」だったが、ロック中に**厳しくできない**のは本末転倒なので撤廃した(2026-09-01)。`SafetyPolicy.decide` に渡す `isWatching`(ロック中も監視中として渡す)は、いまや「監視中は終了させない」を OFF にできるかの判定にしか効かない。

そのため設定画面で錠と「ロック中(HH:mm まで)」「監視中」を出すのは、**「監視中は終了させない」のトグル**(`SafetyModeViewModel.quitLockRestrictionNote`)と**「Mihari をアンインストール…」**の 2 か所だけ。ほかのカードは監視中でも押せる。

### クーリングオフ(24 時間)

「あとで設定を変えられるようにする」(既定 ON)を **OFF** にしている間は、**緩める方向の変更が即時ではなく 24 時間後の予約**になる。対象は 2 つ:

- 機能を **ON にすること**(1 本ずつでも「全部 ON」でも同じ)
- 「あとで設定を変えられるようにする」を **ON に戻すこと**

**OFF にすることは、クーリングオフ中でも常に即時**(安全側なので待たせない)。予約は設定画面のカードと最下部に表示され、**取り消せる**。OFF にすると、その機能の ON 予約も一緒に取り消される。

予約は 1 本にまとまる。**予約を重ねると発効時刻は「最後に頼んでから 24 時間後」に置き換わる**ので、先に入れた予約も一緒に延びる(緩める方向を遅らせる側なので安全側として許容している)。予約中の機能は前提(`requires`)を満たしたものとして扱うので、「iPhone を見張る」を予約したうえで「iPhone の画面を撮る」も同じ予約に積める。

**発効時は監視中かどうかを見ない**。ON 方向は監視中でも即時に通すので、予約の発効だけ監視中を理由に見送る筋合いがない。発効した結果は `normalized()` を通すので、前提を欠いた従属だけが立つことはない。

「全部 OFF」しても、監視中は「監視中は終了させない」だけが残る(それ以外の機能は即時で OFF になる)。

## どうしても終了したいとき(執行猶予脱出)

**「監視中は終了させない」でロックされているときの正規の出口**(#52)。`Escape/` が担う。

1. メニューから「どうしても終了する…」を選び、**戻る時刻を宣言**する
   - 戻るまでの時間は 15 分〜8 時間、**15 分刻み**で、ロック終了を超えない範囲(`EscapePolicy`)。選択肢には戻る実時刻を添える(「1 時間 30 分後(18:00)」)。
2. **10 分のカウントダウン**が始まる(途中で取り消せる)
3. カウントダウンが終わると終了する。**watchdog が宣言した時刻に自動で再起動**して監視を再開する
4. 「Discord に晒す」が ON なら「逃げた」「戻ってきた / 戻っていなかった」を投稿する(戻り判定は宣言時刻に Mac を触っているかどうか)

**前回使ってから 24 時間は使えない**(冷却)。使える状態かをメニュー項目が表示する。

## 初回起動の流れ

起動時、モード選択を済ませていなければ**オンボーディングを 1 回だけ**出す(`AppCoordinator.launch()`)。

1. **ようこそ**(`OnboardingWelcomeView`)。Mihari が何者か・所要時間(1〜2分)を示す
2. **コース選択**(`OnboardingCourseView`)。おためし(全 OFF)/おすすめ(カメラ+Discord+説教)/本気(全部 ON)のプリセットから選ぶ。7 トグルを 1 つずつ選びたい人だけ「微調整」(`SafetyModeView` の流用)へ進める
3. **必要な権限だけ確認**(`OnboardingView`)。プロンプトの自動発火はせず、ボタンを押したときだけ要求する。全 OFF など見せるものが無ければ**飛ばす**。必須権限を拒否しても詰ませず、「不足分の機能を OFF にして進む」の逃げ道を出す
4. **終了ロックの確認**(`OnboardingQuitLockConfirmView`)。`quitLock` が ON のときだけ割り込み、チェックを入れてから先へ進む
5. **完了**(`OnboardingCompletionView`)。ON にした機能・Discord Bot 設定がこれからである旨・声の扱いを示してから**見守りをはじめる**(即監視開始)。モード選択を済ませたことは記録される(`SafetySettingsStore.hasCompletedModeSelection`。保存先は UserDefaults キー `safety.hasChosenMode`)

既存インストールの**アップデート後も初回の 1 回だけ**出る。以降は、必須権限(ON にしたトグルから決まる)が欠けているときだけ「権限の確認」ウィンドウが出る。

## アンインストール

**アプリ内から:** ペットを右クリック → 設定…(または最上段のモード表示の行)→ 「セーフティー」タブ → 「Mihari をアンインストール…」。監視中(ロック中)は不可。

**手動で完全に消す場合**(アプリもしくは補助プロセスが止まっていないときはコマンドを打つ順に注意):

```sh
launchctl bootout gui/$(id -u)/com.thirdlf03.mihari.watchdog
sudo launchctl bootout system/com.thirdlf03.mihari.tunneld
rm -rf ~/.mihari
defaults delete com.thirdlf03.mihari
```

- 1 行目は監視プロセス(`MihariWatchdog`、LaunchAgent)の登録を外す。label は `WatchdogSetup.label`(`com.thirdlf03.mihari.watchdog`)。
- 2 行目は iPhone スクショ用の tunneld(LaunchDaemon)の登録を外す。label は `bridge/scripts/uninstall_tunneld_daemon.sh` の `com.thirdlf03.mihari.tunneld`。root 権限が必要なので `sudo` を付ける。
- 3・4 行目で、保存した設定(`~/.mihari`)と `UserDefaults` を消す。

最後に `desktop/Mihari.app` をゴミ箱へ入れる。

## 仕様上の限界

- **電源に繋いでいないときに蓋を閉じるとスリープすることがある**。蓋を閉じたままの監視は保証しない。
- **`kill -9` + `launchctl bootout` による強制停止は塞げない**。これは設計上、塞がない。開発用の `make kill` がそれに当たる。

## 担保と開発者向け

- **二重防御**: 機能の入口で **Swift(`SafetyGate`)が OFF を弾き**、さらに**bridge も 403 で拒否する**(`daemon/safety.py` の `require_feature`)。Swift にバグがあっても、OFF の機能はデーモンまで届かない。bridge の既定は全 OFF。
- デバッグメニュー・検証用の 10 タブ画面は、**`MIHARI_DEBUG_UI=1` のときだけ**出す(`AppCoordinator.isDebugUIRequested`)。権限画面の開発者向けの注記(TCC の挙動)と、各行の照会 API・生の返り値も同じ判定で出す。
- **`MIHARI_SAFETY_ENABLE`**: 開発用の起動時上書き(保存はしない)。値は `all`(全 ON)か、`SafetyFeature` の rawValue(`macCamera` など)をカンマ区切り。次の起動は保存値に戻る(`SafetySettingsStore.parseEnvironment`)。
- **`make kill`**: 開発用の完全停止。本体を SIGKILL → watchdog の LaunchAgent を bootout → 監視プロセスを SIGKILL → plist 削除、の順で実行する。**仕様上の限界の「強制停止」はこのために残してある**。
