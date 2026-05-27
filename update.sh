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

log()  { printf '\033[1;32m[update]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error ]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./update.sh)"
[ -r "$ENV_FILE" ] || die "$ENV_FILE が見つかりません。先に setup.sh を実行してください。"
. "$ENV_FILE"

MC_VERSION="${MC_VERSION:-}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
MC_USER="${MC_USER:-minecraft}"
[ -n "$MC_VERSION" ] || die "MC_VERSION が未設定です。"

run_as_mc() { sudo -u "$MC_USER" bash -c "$1"; }

log "サービスを停止します..."
systemctl stop "$SERVICE_NAME" || true

log "PaperMC $MC_VERSION の最新ビルドを解決しています..."
BUILDS_JSON="$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds")" \
  || die "PaperMC API へのアクセスに失敗 (MC_VERSION=$MC_VERSION)。"
PAPER_BUILD="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].build')"
PAPER_JAR="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].downloads.application.name')"
[ -n "$PAPER_BUILD" ] && [ "$PAPER_BUILD" != "null" ] || die "ビルド解決に失敗 (MC_VERSION=$MC_VERSION)。"

log "Paper $MC_VERSION build #$PAPER_BUILD をダウンロードします..."
run_as_mc "curl -fsSL 'https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${PAPER_BUILD}/downloads/${PAPER_JAR}' -o '$MC_DIR/paper.jar.new'"
mv "$MC_DIR/paper.jar.new" "$MC_DIR/paper.jar"
chown "$MC_USER":"$MC_USER" "$MC_DIR/paper.jar"

log "Geyser / Floodgate を最新化します..."
run_as_mc "curl -fsSL 'https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot' -o '$MC_DIR/plugins/Geyser-Spigot.jar'"
run_as_mc "curl -fsSL 'https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot' -o '$MC_DIR/plugins/floodgate-spigot.jar'"

# /etc/default/minecraft の MC_VERSION を更新 (オーバーライドされた場合に追従)
sed -i "s|^MC_VERSION=.*|MC_VERSION=${MC_VERSION}|" "$ENV_FILE"

log "サービスを起動します..."
systemctl start "$SERVICE_NAME"
log "完了。ログ: $MC_DIR/logs/latest.log"
