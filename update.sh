#!/usr/bin/env bash
#
# update.sh — PaperMC とプラグイン (Geyser/Floodgate) を最新化する。
#
# world と設定ファイルは保護されます (jar の差し替えのみ)。
# サービスを停止 → jar 更新 → 再起動 の順で実行します。
#
# MC_VERSION を上書きすればマイナーバージョン更新も可能 (例):
#   MC_VERSION=1.21.12 sudo -E ./update.sh
#   MC_VERSION=latest  sudo -E ./update.sh   # PaperMC の最新安定版を自動解決
#
#   MC_VERSION  Minecraft バージョン (既定: /etc/default/minecraft の値。"latest" で最新安定版を自動解決)

set -euo pipefail

ENV_FILE="/etc/default/minecraft"
SERVICE_NAME="minecraft"
PAPER_UA="minecraft-oci (+https://github.com/NadjaSenpai/minecraft-oci)"

STEP=0
TOTAL_STEPS=5
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
# 環境変数で渡された MC_VERSION を優先する (env ファイルの sourcing で上書きされないよう退避)
MC_VERSION_OVERRIDE="${MC_VERSION:-}"
. "$ENV_FILE"

MC_VERSION="${MC_VERSION_OVERRIDE:-${MC_VERSION:-}}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
MC_USER="${MC_USER:-minecraft}"
[ -n "$MC_VERSION" ] || die "MC_VERSION が未設定です。"

run_as_mc() { sudo -u "$MC_USER" bash -c "$1"; }

# minecraft ユーザーでダウンロード (進捗バーを表示)
fetch_mc() {  # fetch_mc <url> <dest> <label>
  log "ダウンロード: $3"
  run_as_mc "curl -fL --progress-bar '$1' -o '$2'"
}

# PaperMC fill API の JSON を取得する。CDN(Cloudflare)が Content-Encoding: gzip を
# 実体と不整合に返すことがあるため、curl に展開させず生で取得し、gzip なら自前で展開する。
paper_meta() {  # paper_meta <url> -> JSON を stdout へ
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -A "$PAPER_UA" "$1" -o "$tmp"; then rm -f "$tmp"; return 1; fi
  if gzip -t "$tmp" 2>/dev/null; then gzip -dc "$tmp"; else cat "$tmp"; fi
  rm -f "$tmp"
}

# 全 MC バージョンを新しい順に調べ、latest build の channel が STABLE な最初の
# バージョンを返す (rc/pre/alpha 等のプレリリース版名は事前に除外)。
resolve_latest_paper_version() {  # -> stdout: 最新安定版のバージョン文字列
  local versions_json v build_json channel
  versions_json="$(paper_meta "https://fill.papermc.io/v3/projects/paper")" || return 1
  while IFS= read -r v; do
    case "$v" in *-*) continue ;; esac
    build_json="$(paper_meta "https://fill.papermc.io/v3/projects/paper/versions/${v}/builds/latest" 2>/dev/null)" || continue
    channel="$(printf '%s' "$build_json" | jq -r '.channel // empty')"
    if [ "$channel" = "STABLE" ]; then
      printf '%s' "$v"
      return 0
    fi
  done < <(printf '%s' "$versions_json" | jq -r '.versions | to_entries[] | .value[]')
  return 1
}

# 起動ログを監視し、ワールド生成の進捗と経過秒をライブ表示する。
wait_progress() {  # wait_progress <log> <完了マーカー正規表現>
  local logf="$1" donm="${2:-}" start el prog hit=1 last_hb=0
  start="$(date +%s)"
  while :; do
    el=$(( $(date +%s) - start ))
    prog="$(grep -oE 'Preparing spawn area: [0-9]+%' "$logf" 2>/dev/null | tail -1)"
    printf '\r\033[K  \033[2m%s\033[0m  経過 %ds' "${prog:-起動処理中...}" "$el"
    # \r 上書きが効かない環境 (ログへのリダイレクト等) でも進行が分かるよう、
    # 30秒毎に改行付きの heartbeat 行を残す。
    if [ $((el - last_hb)) -ge 30 ]; then
      printf '\n'
      log "${prog:-起動処理中...} (経過 ${el}s)"
      last_hb=$el
    fi
    if [ -n "$donm" ] && grep -q "$donm" "$logf" 2>/dev/null; then hit=0; break; fi
    [ "$el" -ge 590 ] && { hit=1; break; }
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

if [ "$MC_VERSION" = "latest" ]; then
  log "MC_VERSION=latest → PaperMC の最新安定版を解決..."
  MC_VERSION="$(resolve_latest_paper_version)" || die "最新バージョンの解決に失敗しました。MC_VERSION を明示してください。"
  ok "解決: MC_VERSION=$MC_VERSION"
fi

# ---------------------------------------------------------------------------
# 2. Java の確認 (MC が要求する版を fill API から解決し、足りなければ導入)
# ---------------------------------------------------------------------------
step "Java の確認"
JAVA_MIN="$(paper_meta "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}" 2>/dev/null | jq -r '.version.java.version.minimum // empty')" || JAVA_MIN=""
[ -n "$JAVA_MIN" ] || JAVA_MIN=21
JAVA_BIN="$(ls -d /usr/lib/jvm/temurin-"${JAVA_MIN}"-jdk-*/bin/java 2>/dev/null | head -1 || true)"
if [ -z "$JAVA_BIN" ] || [ ! -x "$JAVA_BIN" ]; then
  log "Minecraft $MC_VERSION は Java ${JAVA_MIN} が必要。temurin-${JAVA_MIN}-jdk を導入します..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "temurin-${JAVA_MIN}-jdk"
  JAVA_BIN="$(ls -d /usr/lib/jvm/temurin-"${JAVA_MIN}"-jdk-*/bin/java 2>/dev/null | head -1 || true)"
fi
{ [ -n "$JAVA_BIN" ] && [ -x "$JAVA_BIN" ]; } || die "Temurin ${JAVA_MIN} が見つかりません。setup.sh を実行してください。"
if grep -q '^JAVA_BIN=' "$ENV_FILE"; then
  sed -i "s|^JAVA_BIN=.*|JAVA_BIN=${JAVA_BIN}|" "$ENV_FILE"
else
  echo "JAVA_BIN=${JAVA_BIN}" >> "$ENV_FILE"
fi
ok "Java ${JAVA_MIN}: ${JAVA_BIN}"

# ---------------------------------------------------------------------------
# 3. PaperMC の更新
# ---------------------------------------------------------------------------
step "PaperMC の更新"
log "PaperMC $MC_VERSION の最新ビルドを PaperMC API (v3 fill) で解決..."
PAPER_META="$(paper_meta "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds/latest")" \
  || die "PaperMC API へのアクセスに失敗 (MC_VERSION=$MC_VERSION)。"
PAPER_BUILD="$(echo "$PAPER_META" | jq -r '.id')"
PAPER_URL="$(echo "$PAPER_META" | jq -r '.downloads."server:default".url')"
{ [ -n "$PAPER_BUILD" ] && [ "$PAPER_BUILD" != "null" ] && [ -n "$PAPER_URL" ] && [ "$PAPER_URL" != "null" ]; } \
  || die "ビルド解決に失敗 (MC_VERSION=$MC_VERSION)。"
ok "解決: build #$PAPER_BUILD"
fetch_mc "$PAPER_URL" "$MC_DIR/paper.jar.new" "Paper $MC_VERSION build #$PAPER_BUILD"
mv "$MC_DIR/paper.jar.new" "$MC_DIR/paper.jar"
chown "$MC_USER":"$MC_USER" "$MC_DIR/paper.jar"
ok "paper.jar を差し替え"

# ---------------------------------------------------------------------------
# 4. プラグインの更新
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
# 5. サービス再起動 & 起動確認
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
