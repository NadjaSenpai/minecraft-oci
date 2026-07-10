#!/usr/bin/env bash
#
# uninstall.sh — setup.sh / dashboard/install.sh が導入したものを完全に撤去する。
#
# 対象: minecraft サービス一式 (systemd unit・/opt/minecraft・minecraft ユーザー・
#       iptables ルール・mc-* ヘルパー) と Web ダッシュボード (systemd unit・
#       バイナリ・sudoers)。apt でインストールした依存パッケージ (curl/jq/tmux/
#       Temurin JDK 等) は他用途で使われている可能性があるため対象外。
#
# world (セーブデータ) は /opt/minecraft ごと削除されます。実行前に確認を求めます。
# バックアップ (mc-backup が作る backups/*.tar.gz) は既定で /root へ退避してから
# 削除します (PURGE_BACKUPS=true で退避せず完全削除)。
#
# 環境変数:
#   MC_DIR         サーバーディレクトリ  (既定: /etc/default/minecraft の値、無ければ /opt/minecraft)
#   MC_USER        実行ユーザー          (既定: /etc/default/minecraft の値、無ければ minecraft)
#   JAVA_PORT      Java版ポート (iptables ルール削除用)   (既定: 25565)
#   BEDROCK_PORT   Bedrock版ポート (iptables ルール削除用) (既定: 19132)
#   PURGE_BACKUPS  true でバックアップも退避せず完全削除    (既定: false)
#   FORCE          true で確認プロンプトをスキップ (自動化向け)

set -euo pipefail

ENV_FILE="/etc/default/minecraft"
SERVICE_NAME="minecraft"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
log()  { printf '  \033[1;32m•\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m✗ ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./uninstall.sh)"

# 環境変数で渡された値を優先する (env ファイルの sourcing で上書きされないよう退避)
MC_DIR_OVERRIDE="${MC_DIR:-}"
MC_USER_OVERRIDE="${MC_USER:-}"
if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
MC_DIR="${MC_DIR_OVERRIDE:-${MC_DIR:-/opt/minecraft}}"
MC_USER="${MC_USER_OVERRIDE:-${MC_USER:-minecraft}}"
JAVA_PORT="${JAVA_PORT:-25565}"
BEDROCK_PORT="${BEDROCK_PORT:-19132}"
PURGE_BACKUPS="${PURGE_BACKUPS:-false}"
FORCE="${FORCE:-false}"

printf '\n\033[1;31m以下を完全に削除します:\033[0m\n'
printf '  - systemd: %s.service / %s-update.service / %s-update.timer / minecraft-dashboard.service\n' "$SERVICE_NAME" "$SERVICE_NAME" "$SERVICE_NAME"
printf '  - %s (world を含む。サーバーの全データ)\n' "$MC_DIR"
printf '  - %s ユーザー / %s\n' "$MC_USER" "$ENV_FILE"
printf '  - /usr/local/bin/{mc-console,mc-whitelist,mc-config,mc-backup,minecraft-dashboard}\n'
printf '  - /etc/sudoers.d/minecraft-dashboard\n'
printf '  - iptables ルール (tcp/%s, udp/%s)\n' "$JAVA_PORT" "$BEDROCK_PORT"
if [ "$PURGE_BACKUPS" = "true" ]; then
  printf '  - バックアップ (%s/backups) も退避せず完全削除\n' "$MC_DIR"
else
  printf '  - バックアップ (%s/backups) は /root/minecraft-backups-<日時> へ退避してから削除\n' "$MC_DIR"
fi
printf '\n'

if [ "$FORCE" != "true" ]; then
  if [ -t 0 ] && [ -e /dev/tty ]; then
    printf '本当に削除する場合は yes と入力してください: ' >/dev/tty
    IFS= read -r _confirm </dev/tty || _confirm=""
    [ "$_confirm" = "yes" ] || die "中断しました (確認と一致しませんでした)。"
  else
    die "非対話実行では FORCE=true を指定してください (例: sudo FORCE=true ./uninstall.sh)。"
  fi
fi

# ---------------------------------------------------------------------------
# 1. サービス停止・無効化
# ---------------------------------------------------------------------------
log "サービスを停止・無効化..."
for svc in minecraft-dashboard "${SERVICE_NAME}-update.timer" "${SERVICE_NAME}-update.service" "$SERVICE_NAME"; do
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
done
ok "サービス停止完了"

# ---------------------------------------------------------------------------
# 2. systemd unit ファイル削除
# ---------------------------------------------------------------------------
for unit in "${SERVICE_NAME}.service" "${SERVICE_NAME}-update.service" "${SERVICE_NAME}-update.timer" minecraft-dashboard.service; do
  rm -f "/etc/systemd/system/$unit"
done
systemctl daemon-reload
ok "systemd unit を削除"

# ---------------------------------------------------------------------------
# 3. sudoers / ヘルパーバイナリ削除
# ---------------------------------------------------------------------------
rm -f /etc/sudoers.d/minecraft-dashboard
ok "sudoers を削除"

for bin in mc-console mc-whitelist mc-config mc-backup minecraft-dashboard; do
  rm -f "/usr/local/bin/$bin"
done
ok "/usr/local/bin のヘルパーを削除"

# ---------------------------------------------------------------------------
# 4. iptables ルール削除
# ---------------------------------------------------------------------------
iptables -D INPUT -p tcp --dport "$JAVA_PORT" -j ACCEPT 2>/dev/null && ok "iptables tcp/$JAVA_PORT を削除" || log "iptables tcp/$JAVA_PORT は未検出 (スキップ)"
iptables -D INPUT -p udp --dport "$BEDROCK_PORT" -j ACCEPT 2>/dev/null && ok "iptables udp/$BEDROCK_PORT を削除" || log "iptables udp/$BEDROCK_PORT は未検出 (スキップ)"
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. バックアップ退避 & サーバーディレクトリ削除
# ---------------------------------------------------------------------------
if [ -d "$MC_DIR/backups" ] && [ "$PURGE_BACKUPS" != "true" ] && [ -n "$(ls -A "$MC_DIR/backups" 2>/dev/null)" ]; then
  OUT_DIR="/root/minecraft-backups-$(date +%Y%m%d%H%M%S)"
  mv "$MC_DIR/backups" "$OUT_DIR"
  ok "バックアップを退避: $OUT_DIR"
fi

if [ -d "$MC_DIR" ]; then
  rm -rf "$MC_DIR"
  ok "$MC_DIR を削除 (world を含む)"
fi

rm -f "$ENV_FILE"
ok "$ENV_FILE を削除"

# ---------------------------------------------------------------------------
# 6. ユーザー削除
# ---------------------------------------------------------------------------
if id "$MC_USER" >/dev/null 2>&1; then
  userdel "$MC_USER" 2>/dev/null || warn "$MC_USER ユーザーの削除に失敗しました (手動で userdel してください)。"
  ok "$MC_USER ユーザーを削除"
fi

printf '\n\033[1;32m✓ アンインストール完了\033[0m\n\n'
printf ' 【重要】OCI 側のポート開放は残ったままです。不要なら\n'
printf ' OCI コンソール → ネットワーキング → VCN → セキュリティリストで\n'
printf ' TCP %s / UDP %s の Ingress ルールを手動で削除してください。\n\n' "$JAVA_PORT" "$BEDROCK_PORT"
