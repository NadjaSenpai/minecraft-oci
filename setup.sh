#!/usr/bin/env bash
#
# setup.sh — Minecraft (PaperMC) + GeyserMC/Floodgate クロスプレイサーバー構築
#
# 対象: OCI Always Free ARM64 / Ubuntu 22.04 LTS・24.04 LTS。VM 上で root (sudo) 実行。
# 冪等: 再実行可。world と既存の設定ファイルは上書きしない。
#
# 設定は環境変数で上書き可能 (例):
#   ADMIN_PLAYER=YourName sudo -E ./setup.sh
#
#   MC_VERSION    Minecraft バージョン            (既定: 1.21.11)
#   ADMIN_PLAYER  whitelist 追加 + op する Java 名 (既定: 空 = 登録しない)
#   MEMORY        ヒープサイズ(GB整数)            (既定: 総RAMの約75%)
#   ACCEPT_EULA   Minecraft EULA への同意          (既定: true)
#   MC_USER       実行ユーザー                     (既定: minecraft)
#   MC_DIR        サーバーディレクトリ             (既定: /opt/minecraft)
#   JAVA_PORT     Java版ポート                     (既定: 25565)
#   BEDROCK_PORT  Bedrock版(Geyser)ポート          (既定: 19132)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MC_VERSION="${MC_VERSION:-1.21.11}"
ADMIN_PLAYER="${ADMIN_PLAYER:-}"
ACCEPT_EULA="${ACCEPT_EULA:-true}"
MC_USER="${MC_USER:-minecraft}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
JAVA_PORT="${JAVA_PORT:-25565}"
BEDROCK_PORT="${BEDROCK_PORT:-19132}"
TMUX_SOCKET="minecraft"
TMUX_SESSION="minecraft"
SERVICE_NAME="minecraft"
ENV_FILE="/etc/default/minecraft"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

run_as_mc() { sudo -u "$MC_USER" bash -c "$1"; }

# ---------------------------------------------------------------------------
# 0. プリフライト
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./setup.sh)"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || warn "Ubuntu 以外を検出 (${ID:-unknown})。Ubuntu 22.04 / 24.04 向けスクリプトです。"
fi

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || warn "ARM64 (aarch64) 以外を検出 ($ARCH)。OCI ARM 向けに作られています。"

if [ "$ACCEPT_EULA" != "true" ]; then
  die "Minecraft EULA 未同意です。ACCEPT_EULA=true を指定すると同意したものとして続行します (https://aka.ms/MinecraftEULA)。"
fi
log "Minecraft EULA に同意したものとして eula.txt を作成します (https://aka.ms/MinecraftEULA)。"

# ---------------------------------------------------------------------------
# 1. 依存パッケージ
# ---------------------------------------------------------------------------
log "依存パッケージを導入します..."
export DEBIAN_FRONTEND=noninteractive
# iptables-persistent のインストール時プロンプトを抑止
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get update -qq
apt-get install -y -qq curl wget jq tmux ca-certificates gnupg iptables iptables-persistent netfilter-persistent

# ---------------------------------------------------------------------------
# 2. Eclipse Temurin 21 (Adoptium apt)
# ---------------------------------------------------------------------------
if java -version 2>&1 | grep -q 'version "21'; then
  log "Java 21 は導入済み。スキップします。"
else
  log "Eclipse Temurin 21 を Adoptium apt から導入します..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  chmod a+r /etc/apt/keyrings/adoptium.gpg
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  apt-get install -y -qq temurin-21-jdk
fi

# ---------------------------------------------------------------------------
# 3. 専用ユーザーとディレクトリ
# ---------------------------------------------------------------------------
if ! id "$MC_USER" >/dev/null 2>&1; then
  log "システムユーザー $MC_USER を作成します..."
  useradd --system --create-home --home-dir "$MC_DIR" --shell /usr/sbin/nologin "$MC_USER"
else
  log "ユーザー $MC_USER は既存。スキップします。"
fi
install -d -o "$MC_USER" -g "$MC_USER" -m 0755 "$MC_DIR" "$MC_DIR/plugins"

# ---------------------------------------------------------------------------
# 4. PaperMC (バージョン固定・ビルド自動解決)
# ---------------------------------------------------------------------------
if [ ! -f "$MC_DIR/paper.jar" ]; then
  log "PaperMC $MC_VERSION の最新ビルドを解決しています..."
  BUILDS_JSON="$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds")" \
    || die "PaperMC API へのアクセスに失敗。MC_VERSION=$MC_VERSION が存在するか確認してください。"
  PAPER_BUILD="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].build')"
  PAPER_JAR="$(echo "$BUILDS_JSON" | jq -r '.builds[-1].downloads.application.name')"
  [ -n "$PAPER_BUILD" ] && [ "$PAPER_BUILD" != "null" ] || die "PaperMC ビルドの解決に失敗 (MC_VERSION=$MC_VERSION)。"
  log "Paper $MC_VERSION build #$PAPER_BUILD をダウンロードします..."
  run_as_mc "curl -fsSL 'https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${PAPER_BUILD}/downloads/${PAPER_JAR}' -o '$MC_DIR/paper.jar'"
else
  log "paper.jar は既存。更新は update.sh を使用してください。スキップします。"
fi

# ---------------------------------------------------------------------------
# 5. プラグイン (Geyser + Floodgate, latest)
# ---------------------------------------------------------------------------
if [ ! -f "$MC_DIR/plugins/Geyser-Spigot.jar" ]; then
  log "GeyserMC (Spigot) をダウンロードします..."
  run_as_mc "curl -fsSL 'https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot' -o '$MC_DIR/plugins/Geyser-Spigot.jar'"
else
  log "Geyser-Spigot.jar は既存。スキップします。"
fi
if [ ! -f "$MC_DIR/plugins/floodgate-spigot.jar" ]; then
  log "Floodgate (Spigot) をダウンロードします..."
  run_as_mc "curl -fsSL 'https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot' -o '$MC_DIR/plugins/floodgate-spigot.jar'"
else
  log "floodgate-spigot.jar は既存。スキップします。"
fi

# ---------------------------------------------------------------------------
# 6. EULA
# ---------------------------------------------------------------------------
run_as_mc "echo 'eula=true' > '$MC_DIR/eula.txt'"

# ---------------------------------------------------------------------------
# 7. メモリ算出と環境ファイル
# ---------------------------------------------------------------------------
TOTAL_GB="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
AUTO_GB="$(( TOTAL_GB * 3 / 4 ))"
[ "$AUTO_GB" -lt 1 ] && AUTO_GB=1
MEMORY_GB="${MEMORY:-$AUTO_GB}"
log "ヒープサイズ: ${MEMORY_GB}G (総RAM ${TOTAL_GB}G)"

cat > "$ENV_FILE" <<EOF
# Minecraft サーバー設定 (systemd EnvironmentFile)。update.sh からも参照されます。
MC_VERSION=${MC_VERSION}
MEMORY_GB=${MEMORY_GB}
MC_DIR=${MC_DIR}
MC_USER=${MC_USER}
EOF

# ---------------------------------------------------------------------------
# 8. 起動スクリプト (run.sh): Aikar's Flags をヒープ規模で切替
# ---------------------------------------------------------------------------
cat > "$MC_DIR/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -r /etc/default/minecraft ]; then . /etc/default/minecraft; fi
MEMORY_GB="${MEMORY_GB:-4}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
cd "$MC_DIR"

# Aikar's Flags (https://docs.papermc.io/paper/aikars-flags)。12G 以上で大ヒープ用に切替。
if [ "$MEMORY_GB" -ge 12 ]; then
  G1NewSizePercent=40; G1MaxNewSizePercent=50; G1HeapRegionSize=16M
  G1ReservePercent=15; InitiatingHeapOccupancyPercent=20
else
  G1NewSizePercent=30; G1MaxNewSizePercent=40; G1HeapRegionSize=8M
  G1ReservePercent=20; InitiatingHeapOccupancyPercent=15
fi

# exec により java がこのプロセスを引き継ぐ ($$ は不変) → PIDFile が java を指す
echo $$ > "${RUNTIME_DIRECTORY:-/run/minecraft}/server.pid"
exec java \
  -Xms"${MEMORY_GB}"G -Xmx"${MEMORY_GB}"G \
  -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
  -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
  -XX:G1NewSizePercent=${G1NewSizePercent} -XX:G1MaxNewSizePercent=${G1MaxNewSizePercent} \
  -XX:G1HeapRegionSize=${G1HeapRegionSize} -XX:G1ReservePercent=${G1ReservePercent} \
  -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
  -XX:InitiatingHeapOccupancyPercent=${InitiatingHeapOccupancyPercent} \
  -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 \
  -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
  -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true \
  -jar paper.jar --nogui
RUNEOF
chmod +x "$MC_DIR/run.sh"
chown "$MC_USER":"$MC_USER" "$MC_DIR/run.sh"

# ---------------------------------------------------------------------------
# 9. ブートストラップ起動 → 設定パッチ (初回のみ)
# ---------------------------------------------------------------------------
GEYSER_CFG="$MC_DIR/plugins/Geyser-Spigot/config.yml"
if [ ! -f "$GEYSER_CFG" ] || [ ! -f "$MC_DIR/server.properties" ]; then
  log "初回ブートストラップ起動 (設定ファイル生成)。数分かかります..."
  run_as_mc "cd '$MC_DIR' && printf 'stop\n' | timeout 600 java -Xms1G -Xmx2G -jar paper.jar --nogui >/dev/null 2>&1" || true

  [ -f "$MC_DIR/server.properties" ] || die "ブートストラップで server.properties が生成されませんでした。ログを確認してください: $MC_DIR/logs/latest.log"

  log "設定をパッチします (white-list, auth-type: floodgate)..."
  set_prop() {
    local file=$1 key=$2 val=$3
    if grep -q "^${key}=" "$file"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
      echo "${key}=${val}" >> "$file"
    fi
  }
  set_prop "$MC_DIR/server.properties" white-list true
  set_prop "$MC_DIR/server.properties" online-mode true
  set_prop "$MC_DIR/server.properties" server-port "$JAVA_PORT"

  if [ -f "$GEYSER_CFG" ]; then
    sed -i 's|^\( *auth-type:\).*|\1 floodgate|' "$GEYSER_CFG"
  else
    warn "Geyser config.yml が見つかりません。auth-type のパッチをスキップしました。"
  fi
  chown -R "$MC_USER":"$MC_USER" "$MC_DIR"
else
  log "設定ファイルは生成済み。ブートストラップとパッチをスキップします (既存設定を保護)。"
fi

# ---------------------------------------------------------------------------
# 10. systemd サービス
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/mc-console" ]; then
  install -m 0755 "$SCRIPT_DIR/mc-console" /usr/local/bin/mc-console
  log "mc-console を /usr/local/bin に配置しました。"
fi

log "systemd サービスを設定します..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Minecraft Server (PaperMC + Geyser/Floodgate)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${MC_USER}
Group=${MC_USER}
WorkingDirectory=${MC_DIR}
EnvironmentFile=${ENV_FILE}
RuntimeDirectory=minecraft
PIDFile=/run/minecraft/server.pid
# tmux でコンソールを保持しつつ起動 (socket: -L ${TMUX_SOCKET})
ExecStart=/usr/bin/tmux -L ${TMUX_SOCKET} new-session -d -s ${TMUX_SESSION} ${MC_DIR}/run.sh
# 正常終了: コンソールに stop を送り、java の終了を待つ
ExecStop=/bin/sh -c '/usr/bin/tmux -L ${TMUX_SOCKET} send-keys -t ${TMUX_SESSION} "stop" Enter; while kill -0 \$MAINPID 2>/dev/null; do sleep 1; done'
# tmux 経由のため java は systemd の孫プロセス。終了コードを取得できないことがあるので
# クラッシュ時の自動再起動には on-failure ではなく always を使う。
# (systemctl stop / ExecStop による正常停止後は再起動しない)
Restart=always
RestartSec=10
TimeoutStopSec=120
# 注意: PrivateTmp は tmux ソケット共有を壊すため有効化しないこと

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
log "サーバーを起動します..."
systemctl restart "$SERVICE_NAME"

# ---------------------------------------------------------------------------
# 11. 起動待ち & whitelist/op
# ---------------------------------------------------------------------------
log "サーバーの起動完了を待っています..."
DONE=0
for _ in $(seq 1 120); do
  if grep -q 'Done (' "$MC_DIR/logs/latest.log" 2>/dev/null; then DONE=1; break; fi
  sleep 2
done

if [ "$DONE" -eq 1 ]; then
  log "サーバー起動完了。"
  if [ -n "$ADMIN_PLAYER" ]; then
    log "$ADMIN_PLAYER を whitelist 追加 + op します..."
    run_as_mc "tmux -L ${TMUX_SOCKET} send-keys -t ${TMUX_SESSION} 'whitelist add ${ADMIN_PLAYER}' Enter"
    run_as_mc "tmux -L ${TMUX_SOCKET} send-keys -t ${TMUX_SESSION} 'op ${ADMIN_PLAYER}' Enter"
  else
    warn "ADMIN_PLAYER 未指定。white-list=true のため、誰も参加できません。"
    warn "  mc-console で接続し 'whitelist add <名前>' を実行してください。"
  fi
else
  warn "起動完了を確認できませんでした。ログを確認してください: $MC_DIR/logs/latest.log"
fi

# ---------------------------------------------------------------------------
# 12. ファイアウォール (iptables)
# ---------------------------------------------------------------------------
log "iptables を設定します (Java ${JAVA_PORT}/tcp, Bedrock ${BEDROCK_PORT}/udp)..."
ensure_rule() {
  local proto=$1 port=$2
  if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
    log "  既存ルール: ${proto}/${port}"
  else
    iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    log "  追加: ${proto}/${port}"
  fi
}
ensure_rule tcp "$JAVA_PORT"
ensure_rule udp "$BEDROCK_PORT"
netfilter-persistent save
netfilter-persistent reload

# ---------------------------------------------------------------------------
# 完了メッセージ
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<サーバーのパブリックIP>')"
cat <<EOF

============================================================
 セットアップ完了
============================================================

 Java版接続    : ${PUBLIC_IP}:${JAVA_PORT}
 Bedrock版接続 : ${PUBLIC_IP}  ポート ${BEDROCK_PORT}

 サービス操作:
   sudo systemctl status  ${SERVICE_NAME}
   sudo systemctl restart ${SERVICE_NAME}
   sudo systemctl stop    ${SERVICE_NAME}

 コンソール接続 (デタッチは Ctrl-b → d):
   sudo mc-console

 ログ: ${MC_DIR}/logs/latest.log

 【重要】OCI 側のポート開放が別途必要です
 OCI コンソール → ネットワーキング → VCN → サブネット → セキュリティリスト
 で以下の Ingress ルールを追加してください (これは本スクリプトでは設定できません):
   - TCP  ${JAVA_PORT}   (Java版)
   - UDP  ${BEDROCK_PORT}  (Bedrock版 / Geyser)

EOF
