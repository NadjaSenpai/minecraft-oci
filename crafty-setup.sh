#!/usr/bin/env bash
#
# crafty-setup.sh — Crafty Controller (Web ダッシュボード) を導入し、既存の
#   PaperMC + Geyser/Floodgate クロスプレイサーバーを Crafty に引き継ぐためのホスト準備。
#
# 対象: OCI Always Free ARM64 / Ubuntu 22.04 LTS・24.04 LTS。VM 上で root (sudo) 実行。
# 冪等: 再実行可。既導入の Crafty / cloudflared / iptables ルールは上書きしない。
#
# このスクリプトが自動でやること (ホスト側):
#   1. 旧 minecraft.service を stop + disable  (Crafty がプロセスの持ち主になるため)
#   2. 依存パッケージの導入
#   3. Java (Temurin) の確認/導入 — Crafty の「Java Path」に貼る絶対パスを確定
#   4. Crafty Controller v4 をネイティブ導入 (公式 installer)
#   5. crafty.service を有効化 + 起動
#   6. cloudflared を導入 (トークンがあればトンネルをサービス登録)
#   7. MC ポート開放 (iptables, netfilter-persistent で永続化)。UI ポートは開けない。
#   8. 既存 /opt/minecraft を Crafty 取り込み用に zip 化
#   9. /etc/default/crafty-mc 雛形を生成 + ヘルパ (mc-config/mc-whitelist/mc-maintain) を配置
#
# このスクリプトでは「できない」一度きりの手動作業 (完了後に手順を表示):
#   - Cloudflare Zero Trust でのトンネル作成 / Access ポリシー
#   - Crafty UI でのサーバーインポート / Java Path 指定 / API トークン発行
#   - OCI セキュリティリストの Ingress 追加
#
# 環境変数で上書き可:
#   JAVA_PORT          Java版ポート(TCP)         (既定: 25565)
#   BEDROCK_PORT       Bedrock版ポート(UDP)      (既定: 19132)
#   MC_VERSION         Java 解決用の MC バージョン (既定: /etc/default/minecraft の値、無ければ 26.1.2)
#   CLOUDFLARED_TOKEN  cloudflared トンネルトークン (空なら導入のみ・登録はスキップ)
#   OLD_DIR            既存サーバーディレクトリ   (既定: /opt/minecraft)
#
# サブコマンド:
#   sudo ./crafty-setup.sh migrate [UUID]
#     先に Crafty UI で空サーバー(同じ Paper バージョン)を新規作成し、その UUID を渡すと、
#     既存 $OLD_DIR の world / plugins / 設定を /var/opt/minecraft/crafty/crafty-4/servers/<UUID>/ へ
#     コピーする(PC を経由しないサーバー内移行)。UUID 省略時は対話で尋ねる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JAVA_PORT="${JAVA_PORT:-25565}"
BEDROCK_PORT="${BEDROCK_PORT:-19132}"
CLOUDFLARED_TOKEN="${CLOUDFLARED_TOKEN:-}"
OLD_DIR="${OLD_DIR:-/opt/minecraft}"

OLD_SERVICE="minecraft"
CRAFTY_ROOT="/var/opt/minecraft/crafty"          # 公式 installer の install_dir
CRAFTY_APP="$CRAFTY_ROOT/crafty-4"
CRAFTY_USER="crafty"
CRAFTY_PORT="8443"
CRAFTY_MC_ENV="/etc/default/crafty-mc"
IMPORT_DIR="/var/opt/minecraft/import"
IMPORT_ZIP="$IMPORT_DIR/opt-minecraft.zip"
INSTALLER_DIR="/var/tmp/crafty-installer-4.0"
PAPER_UA="minecraft-oci (+https://github.com/NadjaSenpai/minecraft-oci)"

STEP=0
TOTAL_STEPS=9
SCRIPT_START="$(date +%s)"

_ts()      { date '+%H:%M:%S'; }
_elapsed() { printf '%ds' "$(( $(date +%s) - SCRIPT_START ))"; }
step() { STEP=$((STEP+1)); printf '\n\033[1;36m━━━ [%d/%d] %s\033[0m \033[2m(%s / 経過 %s)\033[0m\n' "$STEP" "$TOTAL_STEPS" "$*" "$(_ts)" "$(_elapsed)"; }
log()  { printf '  \033[1;32m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m✗ ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# PaperMC fill API の JSON を取得する (CDN の gzip 不整合に対応; setup.sh と同じ)。
paper_meta() {  # paper_meta <url> -> JSON を stdout へ
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -A "$PAPER_UA" "$1" -o "$tmp"; then rm -f "$tmp"; return 1; fi
  if gzip -t "$tmp" 2>/dev/null; then gzip -dc "$tmp"; else cat "$tmp"; fi
  rm -f "$tmp"
}

# /etc/default/crafty-mc に key=val を upsert (既存値は置換、無ければ追記)。
env_upsert() {  # env_upsert <key> <value>
  local key=$1 val=$2
  if [ -f "$CRAFTY_MC_ENV" ] && grep -q "^${key}=" "$CRAFTY_MC_ENV"; then
    local esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
    sed -i "s|^${key}=.*|${key}=${esc}|" "$CRAFTY_MC_ENV"
  else
    echo "${key}=${val}" >> "$CRAFTY_MC_ENV"
  fi
}

# ---------------------------------------------------------------------------
# サブコマンド: migrate — 既存サーバーを Crafty 作成済みサーバーへサーバー内移行する。
#   使い方: sudo ./crafty-setup.sh migrate [UUID]
#   先に Crafty UI で空サーバー(同じ Paper バージョン)を作成し、その UUID を渡す。
#   /opt/minecraft の world / plugins / 設定を /var/opt/minecraft/crafty/crafty-4/servers/<UUID>/ へコピー。
# ---------------------------------------------------------------------------
migrate_server() {  # migrate_server [uuid]
  local uuid="${1:-}"
  if [ -z "$uuid" ] && [ -t 0 ]; then
    printf 'Crafty で作成したサーバーの UUID: '
    IFS= read -r uuid || uuid=""
  fi
  [ -n "$uuid" ] || die "UUID が指定されていません。Crafty UI で空サーバーを作成し、その UUID を渡してください。"

  local dst="/var/opt/minecraft/crafty/crafty-4/servers/$uuid"
  [ -d "$OLD_DIR" ] || die "移行元が見つかりません: $OLD_DIR"
  [ -d "$dst" ]     || die "サーバーディレクトリが見つかりません: $dst (UUID を確認。Crafty UI で作成済みですか?)"

  # 移行元の world 名を server.properties から解決 (既定 world)。
  local level="world" ln
  if [ -f "$OLD_DIR/server.properties" ]; then
    ln="$(sed -n 's|^level-name=||p' "$OLD_DIR/server.properties" | head -1)"
    [ -n "$ln" ] && level="$ln"
  fi

  # 旧サービスが残っていれば停止 (ファイル競合回避)。Crafty 側は UI で停止してもらう。
  systemctl stop "$OLD_SERVICE" 2>/dev/null || true
  warn "コピー先の Crafty サーバーは UI で『停止』しておいてください (稼働中だとファイル競合)。"
  if [ -t 0 ]; then
    printf '%s → %s へコピーします。続行しますか? [y/N]: ' "$OLD_DIR" "$dst"
    local a; IFS= read -r a || a=""
    case "$a" in y|Y|yes|Yes|YES) ;; *) die "中止しました。"; esac
  fi

  # world(全次元) / plugins / 設定 をコピー。-T で既存ディレクトリへネストせず統合する。
  log "コピー中: world / plugins / 設定 → $dst"
  local item
  for item in "$level" "${level}_nether" "${level}_the_end" \
              plugins server.properties whitelist.json ops.json \
              banned-players.json banned-ips.json \
              bukkit.yml spigot.yml paper.yml paper-global.yml paper-world-defaults.yml config; do
    if [ -e "$OLD_DIR/$item" ]; then
      cp -aT "$OLD_DIR/$item" "$dst/$item"
      ok "コピー: $item"
    fi
  done
  chown -R "$CRAFTY_USER":"$CRAFTY_USER" "$dst"
  ok "サーバー内移行 完了: $dst"

  cat <<EOF

 次の手順:
   1. Crafty UI: このサーバーの Config → Java Path を Temurin の絶対パスに、
      起動コマンドを Aikar's Flags に設定。
   2. /etc/default/crafty-mc に記入:
        SERVER_UUID  = $uuid
        MC_DIR       = $dst
        CRAFTY_TOKEN = (Crafty UI で発行した API トークン)
   3. Crafty UI でサーバーを起動し、Java版/Bedrock版の接続を確認。
EOF
}

if [ "${1:-}" = "migrate" ]; then
  [ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./crafty-setup.sh migrate [UUID])"
  migrate_server "${2:-}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. 事前チェック
# ---------------------------------------------------------------------------
step "事前チェック"
[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./crafty-setup.sh)"
ok "root 権限を確認"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ok "OS: ${PRETTY_NAME:-Ubuntu}" ;;
    ubuntu:*) warn "Ubuntu ${VERSION_ID:-?} を検出。Crafty の公式 installer は 22.04 / 24.04 LTS で確証されています (未対応版は installer が中断します)。" ;;
    *) warn "Ubuntu 以外を検出 (${ID:-unknown})。Ubuntu 22.04 / 24.04 LTS 向けです。" ;;
  esac
fi

ARCH="$(uname -m)"
if [ "$ARCH" = "aarch64" ]; then ok "アーキテクチャ: $ARCH"; else warn "ARM64 (aarch64) 以外を検出 ($ARCH)。OCI ARM 向けに作られています。"; fi

# Java 解決用の MC バージョン: env > /etc/default/minecraft > 既定。
if [ -z "${MC_VERSION:-}" ] && [ -r /etc/default/minecraft ]; then
  MC_VERSION="$(. /etc/default/minecraft 2>/dev/null; echo "${MC_VERSION:-}")"
fi
MC_VERSION="${MC_VERSION:-26.1.2}"
ok "MC バージョン (Java 解決用): $MC_VERSION"

# ---------------------------------------------------------------------------
# 2. 旧 minecraft サービスの停止 + 無効化
# ---------------------------------------------------------------------------
step "旧 minecraft サービスの停止 + 無効化"
if systemctl list-unit-files "${OLD_SERVICE}.service" >/dev/null 2>&1 \
   && systemctl cat "${OLD_SERVICE}.service" >/dev/null 2>&1; then
  systemctl stop "$OLD_SERVICE" 2>/dev/null || true
  systemctl disable "$OLD_SERVICE" 2>/dev/null || true
  ok "minecraft.service を停止 + 無効化 (Crafty がプロセスの持ち主になります)"
  warn "旧 unit ファイルは残置します。完全撤去は移行確認後に手動で削除してください。"
else
  ok "minecraft.service は未導入 (スキップ)"
fi

# ---------------------------------------------------------------------------
# 3. 依存パッケージ
# ---------------------------------------------------------------------------
step "依存パッケージの導入"
export DEBIAN_FRONTEND=noninteractive
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
log "apt パッケージインデックスを更新..."
apt-get update -qq
log "導入: git curl wget jq zip ca-certificates gnupg iptables iptables-persistent netfilter-persistent"
apt-get install -y git curl wget jq zip ca-certificates gnupg iptables iptables-persistent netfilter-persistent
ok "依存パッケージ導入完了 (Python 等は Crafty installer が導入します)"

# ---------------------------------------------------------------------------
# 4. Java (Eclipse Temurin) — Crafty の「Java Path」に貼る絶対パスを確定
# ---------------------------------------------------------------------------
step "Java (Eclipse Temurin) の確認"
JAVA_MIN="$(paper_meta "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}" 2>/dev/null | jq -r '.version.java.version.minimum // empty')" || JAVA_MIN=""
[ -n "$JAVA_MIN" ] || JAVA_MIN=21
ok "Minecraft $MC_VERSION が要求する Java: ${JAVA_MIN}"
JAVA_BIN="$(ls -d /usr/lib/jvm/temurin-"${JAVA_MIN}"-jdk-*/bin/java 2>/dev/null | head -1 || true)"
if [ -n "$JAVA_BIN" ] && [ -x "$JAVA_BIN" ]; then
  ok "Temurin ${JAVA_MIN} は導入済み"
else
  log "Adoptium GPG キーを登録..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  chmod a+r /etc/apt/keyrings/adoptium.gpg
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"
  log "Adoptium リポジトリを追加 (codename: ${CODENAME})..."
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  log "temurin-${JAVA_MIN}-jdk を導入 (ダウンロードに少し時間がかかります)..."
  apt-get install -y "temurin-${JAVA_MIN}-jdk"
  JAVA_BIN="$(ls -d /usr/lib/jvm/temurin-"${JAVA_MIN}"-jdk-*/bin/java 2>/dev/null | head -1 || true)"
fi
{ [ -n "$JAVA_BIN" ] && [ -x "$JAVA_BIN" ]; } || die "Temurin ${JAVA_MIN} の java が見つかりません。"
ok "Java Path (Crafty に貼る絶対パス): $JAVA_BIN"

# ---------------------------------------------------------------------------
# 5. Crafty Controller v4 のネイティブ導入
# ---------------------------------------------------------------------------
step "Crafty Controller v4 の導入"
if [ -d "$CRAFTY_APP" ]; then
  ok "Crafty は既に導入済み ($CRAFTY_APP) — スキップ"
else
  log "公式 installer を取得: gitlab.com/crafty-controller/crafty-installer-4.0"
  rm -rf "$INSTALLER_DIR"
  git clone --depth 1 https://gitlab.com/crafty-controller/crafty-installer-4.0.git "$INSTALLER_DIR"
  warn "Crafty installer を実行します。対話プロンプト (master/dev・サービス作成) が出たら指示に従ってください。"
  ( cd "$INSTALLER_DIR" && ./install_crafty.sh )
  [ -d "$CRAFTY_APP" ] || die "Crafty の導入を確認できませんでした ($CRAFTY_APP)。installer の出力を確認してください。"
  ok "Crafty 導入完了: $CRAFTY_ROOT"
fi

# ---------------------------------------------------------------------------
# 6. crafty.service の有効化 + 起動
# ---------------------------------------------------------------------------
step "crafty.service の有効化 + 起動"
if [ -f /etc/systemd/system/crafty.service ]; then
  systemctl daemon-reload
  systemctl enable crafty >/dev/null 2>&1 || true
  systemctl start crafty || warn "crafty.service の起動に失敗。'systemctl status crafty' を確認してください。"
  ok "crafty.service を有効化 + 起動"
else
  warn "crafty.service が見つかりません。installer のサービス作成プロンプトで 'yes' を選んだか確認してください。"
  warn "手動起動: sudo su $CRAFTY_USER -c 'cd $CRAFTY_ROOT && ./run_crafty.sh'"
fi

# ---------------------------------------------------------------------------
# 7. cloudflared の導入 (+ トークンがあればトンネル登録)
# ---------------------------------------------------------------------------
step "cloudflared の導入"
if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared は導入済み ($(command -v cloudflared))"
else
  log "Cloudflare の apt リポジトリを登録 (arch は自動選択)..."
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y cloudflared
  ok "cloudflared 導入完了"
fi

if [ -n "$CLOUDFLARED_TOKEN" ]; then
  if systemctl list-unit-files cloudflared.service >/dev/null 2>&1 \
     && systemctl is-enabled cloudflared >/dev/null 2>&1; then
    ok "cloudflared サービスは既に登録済み (トークン登録をスキップ)"
  else
    log "トンネルをサービス登録 (cloudflared service install <TOKEN>)..."
    cloudflared service install "$CLOUDFLARED_TOKEN"
    ok "cloudflared.service を登録 (公開ホストの紐付けは Zero Trust ダッシュボードで)"
  fi
else
  warn "CLOUDFLARED_TOKEN 未指定。cloudflared はインストールのみ。トンネル登録は後述の手順で。"
fi

# ---------------------------------------------------------------------------
# 8. MC ポート開放 (iptables) — UI ポートは開けない
# ---------------------------------------------------------------------------
step "ファイアウォール (iptables)"
ensure_rule() {  # ensure_rule <proto> <port>
  local proto=$1 port=$2
  if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
    ok "既存ルール: ${proto}/${port}"
  else
    iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    ok "追加: ${proto}/${port}"
  fi
}
ensure_rule tcp "$JAVA_PORT"
ensure_rule udp "$BEDROCK_PORT"
log "ルールを永続化 (netfilter-persistent)..."
netfilter-persistent save
netfilter-persistent reload
ok "iptables 設定完了 (UI ポート ${CRAFTY_PORT} は開けません — Cloudflare Tunnel 経由のみ)"

# ---------------------------------------------------------------------------
# 9. インポート用 zip + 共有設定 + ヘルパ配置
# ---------------------------------------------------------------------------
step "インポート用 zip / 共有設定 / ヘルパ配置"

# 9a. 既存 /opt/minecraft を Crafty 取り込み用に zip 化 (サービスは停止済みなので一貫)。
if [ -d "$OLD_DIR" ] && [ -f "$OLD_DIR/paper.jar" ]; then
  install -d -o "$CRAFTY_USER" -g "$CRAFTY_USER" -m 0755 "$IMPORT_DIR"
  log "$OLD_DIR を zip 化中 (小規模時の代替インポート用)..."
  ( cd "$OLD_DIR" && rm -f "$IMPORT_ZIP" && zip -rq "$IMPORT_ZIP" . -x 'logs/*' 'bootstrap.log' )
  chown "$CRAFTY_USER":"$CRAFTY_USER" "$IMPORT_ZIP"
  ok "代替用 zip を作成: $IMPORT_ZIP (基本は 'migrate' サブコマンドで移行。これは scp+UI アップロード用)"
else
  warn "$OLD_DIR が見つからない/paper.jar 無し。インポート用 zip はスキップ (新規作成する場合は不要)。"
fi

# 9b. 共有設定 /etc/default/crafty-mc (既存値は壊さず upsert)。
if [ ! -f "$CRAFTY_MC_ENV" ]; then
  cat > "$CRAFTY_MC_ENV" <<EOF
# crafty-mc — mc-config / mc-whitelist / mc-maintain が参照する共有設定。
# Crafty UI でサーバーをインポートし API トークンを発行したら、下の TODO を埋めてください。
CRAFTY_URL=https://127.0.0.1:${CRAFTY_PORT}
CRAFTY_USER=${CRAFTY_USER}
MC_VERSION=${MC_VERSION}
JAVA_BIN=${JAVA_BIN}
# === 要記入 (Crafty UI 後) ===
CRAFTY_TOKEN=TODO_paste_api_token_here
SERVER_UUID=TODO_paste_server_uuid_here
MC_DIR=TODO_e.g_/var/opt/minecraft/crafty/crafty-4/servers/<uuid>
EOF
  chmod 600 "$CRAFTY_MC_ENV"
  ok "共有設定の雛形を生成: $CRAFTY_MC_ENV (CRAFTY_TOKEN / SERVER_UUID / MC_DIR は手動記入)"
else
  env_upsert MC_VERSION "$MC_VERSION"
  env_upsert JAVA_BIN "$JAVA_BIN"
  ok "共有設定は既存。MC_VERSION / JAVA_BIN を更新 (トークン等は保持)"
fi

# 9c. ヘルパを /usr/local/bin に配置。
for helper in mc-config mc-whitelist mc-maintain; do
  if [ -f "$SCRIPT_DIR/$helper" ]; then
    install -m 0755 "$SCRIPT_DIR/$helper" "/usr/local/bin/$helper"
    ok "$helper を /usr/local/bin に配置"
  fi
done

# ---------------------------------------------------------------------------
# 完了メッセージ + 手動 runbook
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<サーバーのパブリックIP>')"
cat <<EOF

============================================================
 ホスト準備 完了  (所要時間 $(_elapsed))
============================================================

 ここから先は一度きりの手動作業です。

 [A] Cloudflare Zero Trust (ダッシュボード)
   1. Networks → Connectors → Cloudflare Tunnels → Create a tunnel (Cloudflared)
      → 表示される 'cloudflared service install <TOKEN>' の TOKEN を控える。
      （このスクリプトを CLOUDFLARED_TOKEN=... 付きで再実行すれば自動登録できます）
   2. Public Hostname を追加: crafty.nadja.jp → Service=HTTPS, URL=localhost:${CRAFTY_PORT}
      → Additional application settings → TLS → 'No TLS Verify' を ON (自己署名のため)
   3. Access controls → Applications → Self-hosted → crafty.nadja.jp を登録
      → ポリシー: Allow / Include / Emails = あなたのメール

 [B] OCI セキュリティリスト (OCI コンソール)
   ネットワーキング → VCN → サブネット → セキュリティリスト で Ingress を追加:
     - TCP  ${JAVA_PORT}   (Java版)
     - UDP  ${BEDROCK_PORT}  (Bedrock版 / Geyser)
   ※ UI ポート ${CRAFTY_PORT} は開けないこと (Tunnel 経由のみ)。

 [C] Crafty UI (https://crafty.nadja.jp、初回は default-creds.txt のパスワード)
   初回ログイン情報: sudo cat $CRAFTY_APP/app/config/default-creds.txt
   1. Create a server → 空サーバーを新規作成 (Paper・同じバージョン・RAM)。UUID を控える。
      → サーバー内で既存データを流し込む (PC 経由なし・推奨):
           sudo ./crafty-setup.sh migrate <UUID>
      (小規模なら代替: 上の $IMPORT_ZIP を scp で PC に落とし『Choose your Zip file』でアップロード)
   2. サーバーの Config → 'Java Path' に: $JAVA_BIN
      実行コマンドに Aikar's Flags を貼る (例):
        $JAVA_BIN -Xms<N>G -Xmx<N>G <Aikar flags...> -jar paper.jar --nogui
   3. ユーザー設定 → API キーを発行 (server 権限付き) → トークンを取得。
   4. $CRAFTY_MC_ENV の TODO を記入:
        CRAFTY_TOKEN = 発行したトークン
        SERVER_UUID  = インポートしたサーバーの UUID
        MC_DIR       = /var/opt/minecraft/crafty/crafty-4/servers/<UUID>
   5. バックアップ(毎晩7世代) / クラッシュ自動再起動 / 定時再起動 を UI で設定。

 記入後の動作確認:
   sudo mc-config                 # 現在のゲームプレイ設定を一覧
   sudo mc-whitelist <JavaName>   # whitelist 追加 + 即 reload
   sudo mc-maintain               # Java 昇格 + Geyser/Floodgate 最新化

 接続先 (OCI Ingress と Crafty 起動後):
   Java版    : ${PUBLIC_IP}:${JAVA_PORT}
   Bedrock版 : ${PUBLIC_IP}  ポート ${BEDROCK_PORT}

EOF
