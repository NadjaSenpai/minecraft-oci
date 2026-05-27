#!/usr/bin/env bash
#
# update.sh — PaperMC とプラグイン (Geyser/Floodgate) を最新化する。
#
# world と設定ファイルは保護されます (jar の差し替えのみ)。
# サービスを停止 → jar 更新 → 再起動 の順で実行します。
#
# MC_VERSION を上書きすればマイナーバージョン更新も可能 (例):
#   MC_VERSION=1.21.12 sudo -E ./update.sh
#
#   MC_VERSION  Minecraft バージョン (既定: /etc/default/minecraft の値)

set -euo pipefail

ENV_FILE="/etc/default/minecraft"
SERVICE_NAME="minecraft"

STEP=0
TOTAL_STEPS=4
SCRIPT_START="$(date +%s)"

_ts()      { date '+%H:%M:%S'; }
_elapsed() { printf '%ds' "$(( $(date +%s) - SCRIPT_START ))"; }
step() { STEP=$((STEP+1)); printf '\n\033[1;36m━━━ [%d/%d] %s\033[0m \033[2m(%s / 経過 %s)\033[0m\n' "$STEP" "$TOTAL_STEPS" "$*" "$(_ts)" "$(_elapsed)"; }
log()  { printf '  \033[1;32m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m✗ ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./update.sh)"
[ -r "$ENV_FILE" ] || die "$ENV_FILE が見つかりません。先に setup.sh を実行してください。"
. "$ENV_FILE"

MC_VERSION="${MC_VERSION:-}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
MC_USER="${MC_USER:-minecraft}"
[ -n "$MC_VERSION" ] || die "MC_VERSION が未設定です。"

run_as_mc() { sudo -u "$MC_USER" bash -c "$1"; }

# minecraft ユーザーでダウンロード (進捗バーを表示)
fetch_mc() {  # fetch_mc <url> <dest> <label>
  log "ダウンロード: $3"
  run_as_mc "curl -fL --progress-bar '$1' -o '$2'"
}

# 起動ログを監視し、ワールド生成の進捗と経過秒をライブ表示する。
wait_progress() {  # wait_progress <log> <完了マーカー正規表現>
  local logf="$1" donm="${2:-}" start el prog hit=1
  start="$(date +%s)"
  while :; do
    el=$(( $(date +%s) - start ))
    prog="$(grep -oE 'Preparing spawn area: [0-9]+%' "$logf" 2>/dev/null | tail -1)"
    printf '\r\033[K  \033[2m%s\033[0m  経過 %ds' "${prog:-起動処理中...}" "$el"
    if [ -n "$donm" ] && grep -q "$donm" "$logf" 2>/dev/null; then hit=0; break; fi
    [ "$el" -ge 240 ] && { hit=1; break; }
    sleep 2
  done
  printf '\r\033[K'
  return $hit
}

# ---------------------------------------------------------------------------
# 1. サービス停止
# ---------------------------------------------------------------------------
step "サービスの停止"
log "現在のワールドを保存して停止します..."
systemctl stop "$SERVICE_NAME" || true
ok "停止完了"

# ---------------------------------------------------------------------------
# 2. PaperMC の更新
# ---------------------------------------------------------------------------
step "PaperMC の更新"
log "PaperMC $MC_VERSION の最新ビルドを PaperMC API で解決..."
BUILDS_JSON="$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds")" \
  || die "PaperMC API へのアクセスに失敗 (MC_VERSION=$MC_VERSION)。"
PAPER_BUILD="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].build')"
PAPER_JAR="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].downloads.application.name')"
[ -n "$PAPER_BUILD" ] && [ "$PAPER_BUILD" != "null" ] || die "ビルド解決に失敗 (MC_VERSION=$MC_VERSION)。"
ok "解決: build #$PAPER_BUILD ($PAPER_JAR)"
fetch_mc "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${PAPER_BUILD}/downloads/${PAPER_JAR}" "$MC_DIR/paper.jar.new" "Paper $MC_VERSION build #$PAPER_BUILD"
mv "$MC_DIR/paper.jar.new" "$MC_DIR/paper.jar"
chown "$MC_USER":"$MC_USER" "$MC_DIR/paper.jar"
ok "paper.jar を差し替え"

# ---------------------------------------------------------------------------
# 3. プラグインの更新
# ---------------------------------------------------------------------------
step "プラグイン (Geyser / Floodgate) の更新"
fetch_mc "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot" "$MC_DIR/plugins/Geyser-Spigot.jar" "GeyserMC (Spigot, latest)"
ok "Geyser-Spigot.jar を更新"
fetch_mc "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot" "$MC_DIR/plugins/floodgate-spigot.jar" "Floodgate (Spigot, latest)"
ok "floodgate-spigot.jar を更新"

# /etc/default/minecraft の MC_VERSION を更新 (オーバーライドされた場合に追従)
sed -i "s|^MC_VERSION=.*|MC_VERSION=${MC_VERSION}|" "$ENV_FILE"
ok "環境ファイルの MC_VERSION を ${MC_VERSION} に更新"

# ---------------------------------------------------------------------------
# 4. サービス再起動 & 起動確認
# ---------------------------------------------------------------------------
step "サービス再起動 & 起動確認"
systemctl start "$SERVICE_NAME"
log "起動完了 (Done) を待っています..."
if wait_progress "$MC_DIR/logs/latest.log" 'Done ('; then
  ok "サーバー起動完了"
else
  warn "起動完了を確認できませんでした。ログを確認してください: $MC_DIR/logs/latest.log"
fi

printf '\n\033[1;32m✓ 更新完了\033[0m  (所要時間 %s)\n  Paper %s build #%s / Geyser・Floodgate latest\n  ログ: %s\n\n' \
  "$(_elapsed)" "$MC_VERSION" "$PAPER_BUILD" "$MC_DIR/logs/latest.log"
