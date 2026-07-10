#!/usr/bin/env bash
#
# install.sh — minecraft-dashboard を導入する。
#
# 前提: setup.sh で systemd+tmux の Minecraft サーバーが構築済み (minecraft ユーザー存在)。
# 推奨デプロイ: 手元(Mac等)で `GOOS=linux GOARCH=arm64 go build -o minecraft-dashboard .`
#   して単一バイナリを scp し、本スクリプトを実行(箱に Go 不要)。
#   箱に Go があれば、バイナリが無ければ自動で go build する。
#
# やること:
#   - minecraft-dashboard を /usr/local/bin へ
#   - mc-backup を /usr/local/bin へ(リポ root から)
#   - sudoers (systemctl 3コマンドのみ) を /etc/sudoers.d へ (visudo 検証)
#   - systemd unit を配置し enable --now
#   - cloudflared の公開手順を表示

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$SCRIPT_DIR/minecraft-dashboard"
DASH_PORT="${DASHBOARD_PORT:-8765}"

ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
log() { printf '  \033[1;32m•\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./dashboard/install.sh)"
id minecraft >/dev/null 2>&1 || die "minecraft ユーザーがいません。先に setup.sh を実行してください。"

# 1) バイナリ: 既存を使う / 無ければ go build / それも無ければエラー
if [ ! -x "$BIN" ]; then
  if command -v go >/dev/null 2>&1; then
    log "バイナリが無いので go build します..."
    ( cd "$SCRIPT_DIR" && go build -o minecraft-dashboard . )
  else
    die "ビルド済みバイナリ ($BIN) も Go も見つかりません。手元で 'GOOS=linux GOARCH=arm64 go build -o minecraft-dashboard .' して scp してください。"
  fi
fi
install -m 0755 "$BIN" /usr/local/bin/minecraft-dashboard
ok "minecraft-dashboard を /usr/local/bin に配置"

# 2) mc-backup
if [ -f "$REPO_DIR/mc-backup" ]; then
  install -m 0755 "$REPO_DIR/mc-backup" /usr/local/bin/mc-backup
  ok "mc-backup を /usr/local/bin に配置"
else
  log "mc-backup が見つかりません (リポ root)。バックアップ機能はスキップされます。"
fi

# 3) sudoers (systemctl 3コマンドのみ)。visudo で検証してから配置。
TMP_SUDO="$(mktemp)"
cp "$SCRIPT_DIR/minecraft-dashboard.sudoers" "$TMP_SUDO"
if visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
  install -m 0440 "$TMP_SUDO" /etc/sudoers.d/minecraft-dashboard
  ok "sudoers を配置: /etc/sudoers.d/minecraft-dashboard (systemctl 3コマンドのみ)"
else
  rm -f "$TMP_SUDO"
  die "sudoers の検証に失敗しました。"
fi
rm -f "$TMP_SUDO"

# 4) systemd unit
sed "s|127.0.0.1:8765|127.0.0.1:${DASH_PORT}|" "$SCRIPT_DIR/minecraft-dashboard.service" \
  > /etc/systemd/system/minecraft-dashboard.service
ok "unit を配置: /etc/systemd/system/minecraft-dashboard.service (port ${DASH_PORT})"
systemctl daemon-reload
systemctl enable minecraft-dashboard >/dev/null 2>&1 || true
systemctl restart minecraft-dashboard
ok "minecraft-dashboard を起動 (127.0.0.1:${DASH_PORT})"

cat <<EOF

============================================================
 ダッシュボード導入 完了
============================================================
 ローカル確認: curl -s http://127.0.0.1:${DASH_PORT}/api/status

 公開 (Cloudflare Tunnel + Access、UI ポートは開けない):
   0. cloudflared 未導入なら (Ubuntu/ARM64):
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared \$(lsb_release -cs) main" \\
          | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo apt-get update && sudo apt-get install -y cloudflared
   1. Zero Trust でトンネル作成 →
        cloudflared service install <TOKEN>
   2. Public Hostname: dash.example.com → Service HTTP, URL http://localhost:${DASH_PORT}
   3. Access: Self-hosted app に dash.example.com + Allow/Include/Emails ポリシー

 状態確認: systemctl status minecraft-dashboard
 ログ:     journalctl -u minecraft-dashboard -f
EOF
