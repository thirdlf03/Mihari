#!/usr/bin/env bash
#
# オンボーディングを最初から試すためのリセット。
#
# Mihari は「モード選択を済ませた」ことを UserDefaults の `safety.hasChosenMode`
# で覚えている。このキー(とセーフティー設定)を消すと、次回起動で初回オンボーディングが
# また出る。あわせて起動中のアプリと監視プロセスも止めて、初期状態に戻す。
#
# 使い方:
#   ./scripts/reset-onboarding.sh            基本リセット(設定を初期化)
#   ./scripts/reset-onboarding.sh --full     ~/.mihari(bridge 設定・認証情報)も退避
#   ./scripts/reset-onboarding.sh --tcc      権限(TCC)もリセットを試みる
#   ./scripts/reset-onboarding.sh --full --tcc   全部いっぺんに
#
# 実行後は `desktop/run.sh` か `open desktop/Mihari.app` で起動すると、
# 「Mihari へようこそ」から始まる。
#
# 注意: `--tcc` はシステム設定のプライバシー権限を戻す。ただしオートメーション(Music)や
# モーション(AirPods)は tccutil では戻せないことがあり、その場合は「システム設定 →
# プライバシーとセキュリティ」から Mihari を削除する必要がある。
#
set -euo pipefail

BUNDLE_ID="com.thirdlf03.mihari"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="${REPO_ROOT}/desktop"

echo "==> 1/3 起動中の Mihari と監視プロセスを停止"
if [ -x "${DESKTOP}/kill.sh" ]; then
  "${DESKTOP}/kill.sh"
else
  echo "    (kill.sh が無いため pkill で停止)" >&2
  pkill -9 -f '/Mihari.app/Contents/MacOS/Mihari$' 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/com.thirdlf03.mihari.watchdog" 2>/dev/null || true
  pkill -9 -f 'MihariWatchdog' 2>/dev/null || true
fi

echo ""
echo "==> 2/3 UserDefaults(${BUNDLE_ID}) を削除"
# hasChosenMode(モード選択済み)と safety.settings(7トグル)・quitLock の期限などが全部消え、
# 「全 OFF・未選択」の初期状態に戻る。次回起動でオンボーディングが出る。
if defaults delete "${BUNDLE_ID}" 2>/dev/null; then
  echo "    OK: ${BUNDLE_ID} を削除した"
else
  echo "    (削除する項目が無い、または既に初期状態)"
fi

# --full: bridge の設定ディレクトリ(~/.mihari の .env 等)も退避して完全初期化。
# 退避なので元に戻せる。消すのではなく mv で残す。
if [ "${1:-}" = "--full" ] || [ "${2:-}" = "--full" ]; then
  if [ -d "${HOME}/.mihari" ]; then
    backup="${HOME}/.mihari.bak.$(date +%s)"
    echo "    --full: ~/.mihari を退避 -> ${backup}"
    mv "${HOME}/.mihari" "${backup}"
  else
    echo "    --full: ~/.mihari は無い"
  fi
fi

# --tcc: このアプリへの TCC 権限(カメラ・画面収録)を未決定へ戻す。
# オートメーション/モーションは対象が特殊で戻せないことがある。
if [ "${1:-}" = "--tcc" ] || [ "${2:-}" = "--tcc" ]; then
  echo ""
  echo "==> 3/3 TCC 権限をリセット(ベストエフォート)"
  for service in Camera ScreenCapture; do
    if tccutil reset "${service}" "${BUNDLE_ID}" 2>/dev/null; then
      echo "    OK: ${service} を未決定へ"
    else
      echo "    (${service} は戻せなかった。システム設定から手動削除が必要かも)"
    fi
  done
  echo "    注意: オートメーション(Music)・モーション(AirPods)は tccutil では戻せない。"
  echo "          戻すなら システム設定 → プライバシーとセキュリティ → Mihari を削除。"
else
  echo ""
  echo "    (TCC 権限はリセットしていない。--tcc を付けると戻す。)"
fi

echo ""
echo "==> 完了。オンボーディングを試すには起動する:"
echo "    cd desktop && ./run.sh            # ビルドして起動"
echo "    または(ビルド済みなら) open desktop/Mihari.app"
echo ""
echo "注意: アプリを再ビルドすると ad-hoc 署名の cdhash が変わり、"
echo "      TCC 許可は再度必要になることがある(README の「署名について」参照)。"
