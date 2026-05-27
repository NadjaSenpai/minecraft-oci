#!/usr/bin/env bash
#
# setup.sh — Minecraft (PaperMC) + GeyserMC/Floodgate クロスプレイサーバー構築
#
# 対象: OCI Always Free ARM64 / Ubuntu 22.04 LTS・24.04 LTS。VM 上で root (sudo) 実行。
# 冪等: 再実行可。world と既存の設定ファイルは上書きしない。
#
# 対話実行: 端末から `sudo ./setup.sh` すると、未設定の項目を対話で尋ねます。
# 環境変数で渡した項目は対話をスキップ (自動化・再実行・パイプ実行向け。例:
#   sudo ADMIN_PLAYER=YourName ./setup.sh):
#
#   MC_VERSION    Minecraft バージョン            (既定: 26.1.2)
#   ADMIN_PLAYER  whitelist + op する Java 名      (既定: 空 = 登録しない)
#   BEDROCK_PLAYER whitelist + op する Bedrock 名   (既定: 空 = 登録しない)
#                 Bedrock(統合版)のゲーマータグ。XUID から Floodgate UUID を計算して登録。
#   MEMORY        ヒープサイズ(GB整数)            (既定: 総RAMの約75%)
#   ACCEPT_EULA   Minecraft EULA への同意          (既定: true)
#   MC_USER       実行ユーザー                     (既定: minecraft)
#   MC_DIR        サーバーディレクトリ             (既定: /opt/minecraft)
#   JAVA_PORT     Java版ポート                     (既定: 25565)
#   BEDROCK_PORT  Bedrock版(Geyser)ポート          (既定: 19132)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env で値が渡されたかを記録 (デフォルト適用前に。ハイブリッド対話の判定に使う)
_MC_VERSION_SET="${MC_VERSION+x}"
_ADMIN_SET="${ADMIN_PLAYER+x}"
_BEDROCK_SET="${BEDROCK_PLAYER+x}"
_MEMORY_SET="${MEMORY+x}"

# ゲームプレイ9項目: env で渡されたかを _SET フラグに記録 (デフォルト適用前に)。
# これらは「未設定なら server.properties に書かない」方針 (Minecraft 既定に任せる)。
# 既定値は適用しない (= 空のまま)。管理キー (white-list/online-mode/server-port) は別途強制。
_LEVEL_SEED_SET="${LEVEL_SEED+x}"
_MOTD_SET="${MOTD+x}"
_DIFFICULTY_SET="${DIFFICULTY+x}"
_GAMEMODE_SET="${GAMEMODE+x}"
_MAX_PLAYERS_SET="${MAX_PLAYERS+x}"
_PVP_SET="${PVP+x}"
_VIEW_DISTANCE_SET="${VIEW_DISTANCE+x}"
_SIMULATION_DISTANCE_SET="${SIMULATION_DISTANCE+x}"
_HARDCORE_SET="${HARDCORE+x}"

MC_VERSION="${MC_VERSION:-26.1.2}"
ADMIN_PLAYER="${ADMIN_PLAYER:-}"
BEDROCK_PLAYER="${BEDROCK_PLAYER:-}"
ACCEPT_EULA="${ACCEPT_EULA:-true}"
MC_USER="${MC_USER:-minecraft}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
JAVA_PORT="${JAVA_PORT:-25565}"
BEDROCK_PORT="${BEDROCK_PORT:-19132}"

# ゲームプレイ9項目: 既定は空 (= 未設定なら書かない)。Minecraft 既定値は適用しない。
LEVEL_SEED="${LEVEL_SEED:-}"
MOTD="${MOTD:-}"
DIFFICULTY="${DIFFICULTY:-}"
GAMEMODE="${GAMEMODE:-}"
MAX_PLAYERS="${MAX_PLAYERS:-}"
PVP="${PVP:-}"
VIEW_DISTANCE="${VIEW_DISTANCE:-}"
SIMULATION_DISTANCE="${SIMULATION_DISTANCE:-}"
HARDCORE="${HARDCORE:-}"
TMUX_SOCKET="minecraft"
TMUX_SESSION="minecraft"
SERVICE_NAME="minecraft"
ENV_FILE="/etc/default/minecraft"
PAPER_UA="minecraft-oci (+https://github.com/NadjaSenpai/minecraft-oci)"

STEP=0
TOTAL_STEPS=12
SCRIPT_START="$(date +%s)"

_ts()     { date '+%H:%M:%S'; }
_elapsed() { printf '%ds' "$(( $(date +%s) - SCRIPT_START ))"; }
step() { STEP=$((STEP+1)); printf '\n\033[1;36m━━━ [%d/%d] %s\033[0m \033[2m(%s / 経過 %s)\033[0m\n' "$STEP" "$TOTAL_STEPS" "$*" "$(_ts)" "$(_elapsed)"; }
log()  { printf '  \033[1;32m•\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m✗ ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 設定値バリデーション (env 由来の値はデフォルト適用直後に検証する) -------------
# Phase 0-B: server.properties は不正値を既定にリセットするため、書く前に検証必須。

valid_enum() {  # valid_enum <value> <allowed...(空白区切り)>  -> 一致すれば真
  local v=$1; shift
  local a
  for a in $*; do [ "$v" = "$a" ] && return 0; done
  return 1
}

valid_int_range() {  # valid_int_range <value> <min> <max>  -> 整数かつ範囲内なら真
  local v=$1 min=$2 max=$3
  case "$v" in ''|*[!0-9-]*) return 1;; esac   # 数字 (と先頭の符号) 以外を含む
  case "$v" in -*) ;; *[!0-9]*) return 1;; esac
  [ "$v" -ge "$min" ] && [ "$v" -le "$max" ]
}

valid_bool() {  # valid_bool <value>  -> true/false なら真
  case "$1" in true|false) return 0;; *) return 1;; esac
}

# motd を server.properties 用に正規化する。Phase 0-D: properties には生 § ではなく
# Java エスケープの § を書く。プラグイン慣習の & カラーコードは § へ変換する。
normalize_motd() {  # normalize_motd <value>  -> 変換後の文字列を stdout へ
  printf '%s' "${1//&/\\u00A7}"
}

# MC_VERSION がモダン (1.21.9 以上、または年次版でメジャー > 21) かを判定する。
# Phase 0-E: pvp は 1.21.9+/26.x ではゲームルール、≤1.21.8 では server.properties キー。
# Minecraft のバージョン体系は2系統: クラシック "1.21.9" (先頭=1) と年次版 "26.1.2" (先頭>21)。
is_modern_mc() {  # is_modern_mc  -> モダンなら真
  local ver="${MC_VERSION:-}" major minor patch rest
  major="${ver%%.*}"
  case "$major" in ''|*[!0-9]*) return 1;; esac
  # 先頭コンポーネント > 21 = 22/26 などの年次版 → モダン
  [ "$major" -gt 21 ] && return 0
  # 先頭 == 1 = クラシック系。minor.patch を 1.21.9 と比較
  if [ "$major" -eq 1 ]; then
    rest="${ver#*.}"               # "21.9" -> minor
    minor="${rest%%.*}"
    case "$minor" in ''|*[!0-9]*) minor=0;; esac
    [ "$minor" -gt 21 ] && return 0
    if [ "$minor" -eq 21 ]; then
      patch="${rest#*.}"           # "9" / "9.x" などの後続
      patch="${patch%%.*}"
      [ "$patch" = "$rest" ] && patch=0   # "1.21" のように patch 無し
      case "$patch" in ''|*[!0-9]*) patch=0;; esac
      [ "$patch" -ge 9 ] && return 0
    fi
  fi
  return 1
}

# env 由来のゲームプレイ設定値を検証 (空 = 未設定はスキップ)。不正なら die。
if [ -n "$DIFFICULTY" ]; then
  valid_enum "$DIFFICULTY" "peaceful easy normal hard" \
    || die "DIFFICULTY が不正です: '$DIFFICULTY' (有効値: peaceful easy normal hard)"
fi
if [ -n "$GAMEMODE" ]; then
  valid_enum "$GAMEMODE" "survival creative adventure spectator" \
    || die "GAMEMODE が不正です: '$GAMEMODE' (有効値: survival creative adventure spectator)"
fi
if [ -n "$MAX_PLAYERS" ]; then
  valid_int_range "$MAX_PLAYERS" 0 2147483647 \
    || die "MAX_PLAYERS が不正です: '$MAX_PLAYERS' (0 以上の整数)"
fi
if [ -n "$VIEW_DISTANCE" ]; then
  valid_int_range "$VIEW_DISTANCE" 3 32 \
    || die "VIEW_DISTANCE が不正です: '$VIEW_DISTANCE' (3〜32 の整数)"
fi
if [ -n "$SIMULATION_DISTANCE" ]; then
  valid_int_range "$SIMULATION_DISTANCE" 3 32 \
    || die "SIMULATION_DISTANCE が不正です: '$SIMULATION_DISTANCE' (3〜32 の整数)"
fi
if [ -n "$PVP" ]; then
  valid_bool "$PVP" || die "PVP が不正です: '$PVP' (true または false)"
fi
if [ -n "$HARDCORE" ]; then
  valid_bool "$HARDCORE" || die "HARDCORE が不正です: '$HARDCORE' (true または false)"
fi

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

# JSON 配列ファイルにエントリを upsert (同じ uuid があれば置換、無ければ追加)。
upsert_json() {  # upsert_json <file> <json-object>
  local file="$1" obj="$2" tmp; tmp="$(mktemp)"
  if [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
    jq --argjson e "$obj" 'map(select(.uuid != $e.uuid)) + [$e]' "$file" > "$tmp"
  else
    jq -n --argjson e "$obj" '[$e]' > "$tmp"
  fi
  mv "$tmp" "$file"
}

# 起動ログを監視し、ワールド生成の進捗と経過秒数をライブ表示する。
# wait_progress <監視対象ログ> <PID または 空> <完了マーカー正規表現>
#   PID 指定時はそのプロセスが終わるまで、完了マーカー指定時はマッチするまで監視する。
wait_progress() {
  local logf="$1" pid="${2:-}" donm="${3:-}" start el prog hit=1
  start="$(date +%s)"
  while :; do
    el=$(( $(date +%s) - start ))
    prog="$(grep -oE 'Preparing spawn area: [0-9]+%' "$logf" 2>/dev/null | tail -1)"
    printf '\r\033[K  \033[2m%s\033[0m  経過 %ds' "${prog:-起動処理中...}" "$el"
    if [ -n "$donm" ] && grep -q "$donm" "$logf" 2>/dev/null; then hit=0; break; fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then hit=0; break; fi
    [ "$el" -ge 240 ] && { hit=1; break; }
    sleep 2
  done
  printf '\r\033[K'
  return $hit
}

# ---------------------------------------------------------------------------
# 1. 事前チェック
# ---------------------------------------------------------------------------
step "事前チェック"
[ "$(id -u)" -eq 0 ] || die "root で実行してください (sudo ./setup.sh)"
ok "root 権限を確認"

# 対話プロンプト: env 未設定 かつ 対話端末のときだけ尋ねる (env 指定時・非対話時はスキップ)
if [ -t 0 ] && [ -e /dev/tty ]; then
  _ask() {  # _ask <質問> <既定値> -> 回答を stdout へ
    local a
    if [ -n "${2:-}" ]; then printf '%s [%s]: ' "$1" "$2" >/dev/tty; else printf '%s: ' "$1" >/dev/tty; fi
    IFS= read -r a </dev/tty || a=""
    if [ -n "$a" ]; then printf '%s' "$a"; else printf '%s' "${2:-}"; fi
  }
  printf '\n  \033[1m=== 対話設定 (そのまま Enter で既定値) ===\033[0m\n' >/dev/tty
  if [ -z "$_MC_VERSION_SET" ]; then MC_VERSION="$(_ask 'Minecraft バージョン' "$MC_VERSION")"; fi
  if [ -z "$_ADMIN_SET" ];      then ADMIN_PLAYER="$(_ask 'Java版 管理者名 (whitelist+op、空=なし)' "$ADMIN_PLAYER")"; fi
  if [ -z "$_BEDROCK_SET" ];    then BEDROCK_PLAYER="$(_ask 'Bedrock版 管理者ゲーマータグ (whitelist+op、空=なし)' "$BEDROCK_PLAYER")"; fi
  if [ -z "$_MEMORY_SET" ];     then MEMORY="$(_ask 'ヒープGB (空=総RAMの約75%を自動)' '')"; fi
  printf '\n' >/dev/tty
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ]; then
    ok "OS: ${PRETTY_NAME:-Ubuntu}"
  else
    warn "Ubuntu 以外を検出 (${ID:-unknown})。Ubuntu 22.04 / 24.04 向けスクリプトです。"
  fi
fi

ARCH="$(uname -m)"
if [ "$ARCH" = "aarch64" ]; then ok "アーキテクチャ: $ARCH"; else warn "ARM64 (aarch64) 以外を検出 ($ARCH)。OCI ARM 向けに作られています。"; fi

if [ "$ACCEPT_EULA" != "true" ]; then
  die "Minecraft EULA 未同意です。ACCEPT_EULA=true を指定すると同意したものとして続行します (https://aka.ms/MinecraftEULA)。"
fi
ok "Minecraft EULA に同意 (https://aka.ms/MinecraftEULA)"
log "設定: MC=$MC_VERSION / Java=${ADMIN_PLAYER:-(なし)} / Bedrock=${BEDROCK_PLAYER:-(なし)} / MEM=${MEMORY:-自動} / DIR=$MC_DIR"

# ---------------------------------------------------------------------------
# 2. 依存パッケージ
# ---------------------------------------------------------------------------
step "依存パッケージの導入"
export DEBIAN_FRONTEND=noninteractive
# iptables-persistent のインストール時プロンプトを抑止
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
log "apt パッケージインデックスを更新..."
apt-get update -qq
log "導入: curl wget jq tmux ca-certificates gnupg iptables iptables-persistent netfilter-persistent"
apt-get install -y curl wget jq tmux ca-certificates gnupg iptables iptables-persistent netfilter-persistent
ok "依存パッケージ導入完了"

# ---------------------------------------------------------------------------
# 3. Java (Eclipse Temurin) — MC バージョンが要求する版を fill API から自動選択
# ---------------------------------------------------------------------------
step "Java (Eclipse Temurin)"
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
{ [ -n "$JAVA_BIN" ] && [ -x "$JAVA_BIN" ]; } || die "Temurin ${JAVA_MIN} の java が見つかりません (温存パス: /usr/lib/jvm/temurin-${JAVA_MIN}-jdk-*)。"
ok "Java: $("$JAVA_BIN" -version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 4. 専用ユーザーとディレクトリ
# ---------------------------------------------------------------------------
step "専用ユーザーとディレクトリ"
# tmux はペイン起動にユーザーのログインシェルを使うため、サービス用ユーザーにも
# 有効なシェルが必要。nologin だと new-session が即終了し起動に失敗する。
if ! id "$MC_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$MC_DIR" --shell /bin/bash "$MC_USER"
  ok "システムユーザー $MC_USER を作成 (shell: /bin/bash)"
else
  usermod --shell /bin/bash "$MC_USER"
  ok "ユーザー $MC_USER は既存 (shell を /bin/bash に補正)"
fi
install -d -o "$MC_USER" -g "$MC_USER" -m 0755 "$MC_DIR" "$MC_DIR/plugins"
ok "ディレクトリ: $MC_DIR (plugins/ 含む)"

# ---------------------------------------------------------------------------
# 5. PaperMC (バージョン固定・ビルド自動解決)
# ---------------------------------------------------------------------------
step "PaperMC のダウンロード"
if [ ! -f "$MC_DIR/paper.jar" ]; then
  log "PaperMC $MC_VERSION の最新ビルドを PaperMC API (v3 fill) で解決..."
  PAPER_META="$(paper_meta "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds/latest")" \
    || die "PaperMC API へのアクセスに失敗。MC_VERSION=$MC_VERSION が存在するか確認してください。"
  PAPER_BUILD="$(echo "$PAPER_META" | jq -r '.id')"
  PAPER_URL="$(echo "$PAPER_META" | jq -r '.downloads."server:default".url')"
  { [ -n "$PAPER_BUILD" ] && [ "$PAPER_BUILD" != "null" ] && [ -n "$PAPER_URL" ] && [ "$PAPER_URL" != "null" ]; } \
    || die "PaperMC ビルドの解決に失敗 (MC_VERSION=$MC_VERSION)。"
  ok "解決: build #$PAPER_BUILD"
  fetch_mc "$PAPER_URL" "$MC_DIR/paper.jar" "Paper $MC_VERSION build #$PAPER_BUILD"
  ok "paper.jar 取得完了"
else
  ok "paper.jar は既存。更新は update.sh を使用してください (スキップ)"
fi

# ---------------------------------------------------------------------------
# 6. プラグイン (Geyser + Floodgate, latest)
# ---------------------------------------------------------------------------
step "プラグイン (Geyser / Floodgate)"
if [ ! -f "$MC_DIR/plugins/Geyser-Spigot.jar" ]; then
  fetch_mc "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot" "$MC_DIR/plugins/Geyser-Spigot.jar" "GeyserMC (Spigot, latest)"
  ok "Geyser-Spigot.jar 取得完了"
else
  ok "Geyser-Spigot.jar は既存 (スキップ)"
fi
if [ ! -f "$MC_DIR/plugins/floodgate-spigot.jar" ]; then
  fetch_mc "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot" "$MC_DIR/plugins/floodgate-spigot.jar" "Floodgate (Spigot, latest)"
  ok "floodgate-spigot.jar 取得完了"
else
  ok "floodgate-spigot.jar は既存 (スキップ)"
fi

# ---------------------------------------------------------------------------
# 7. EULA 同意 & メモリ設定 (環境ファイル)
# ---------------------------------------------------------------------------
step "EULA 同意 & メモリ設定"
run_as_mc "echo 'eula=true' > '$MC_DIR/eula.txt'"
ok "eula.txt を作成 (eula=true)"

TOTAL_GB="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
AUTO_GB="$(( TOTAL_GB * 3 / 4 ))"
[ "$AUTO_GB" -lt 1 ] && AUTO_GB=1
MEMORY_GB="${MEMORY:-$AUTO_GB}"
ok "ヒープサイズ: ${MEMORY_GB}G (総RAM ${TOTAL_GB}G の約75%)"

cat > "$ENV_FILE" <<EOF
# Minecraft サーバー設定 (systemd EnvironmentFile)。update.sh からも参照されます。
MC_VERSION=${MC_VERSION}
MEMORY_GB=${MEMORY_GB}
MC_DIR=${MC_DIR}
MC_USER=${MC_USER}
JAVA_BIN=${JAVA_BIN}
EOF
ok "環境ファイルを書き込み: $ENV_FILE"

# ---------------------------------------------------------------------------
# 8. 起動スクリプト (run.sh): Aikar's Flags をヒープ規模で切替
# ---------------------------------------------------------------------------
step "起動スクリプト (run.sh) の生成"
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
exec "${JAVA_BIN:-java}" \
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
ok "run.sh を生成 (Xms=Xmx=${MEMORY_GB}G, Aikar's Flags)"

# ---------------------------------------------------------------------------
# 9. 設定の先行書込 → ブートストラップ起動 → Geyser パッチ (初回のみ)
# ---------------------------------------------------------------------------
step "初回ブートストラップ & 設定パッチ"
GEYSER_CFG="$MC_DIR/plugins/Geyser-Spigot/config.yml"

# server.properties に key=val を upsert する (既存値は置換、無ければ追記)。
# boot 前の先行書込と boot 後のパッチ双方で使うため、ループの外で定義する。
set_prop() {
  local file=$1 key=$2 val=$3
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

if [ ! -f "$GEYSER_CFG" ] || [ ! -f "$MC_DIR/server.properties" ]; then
  # Phase 0-A: level-seed は world 生成時のみ有効 (生成後は world に焼き込まれ変更不可)。
  # Phase 0-B: Minecraft は server.properties の既存値を保持し欠落キーのみ既定で埋める。
  # → 初回 boot の前に server.properties を先行作成しておけば seed や生成時設定が確実に効く。
  if [ ! -f "$MC_DIR/server.properties" ]; then
    log "初回 boot 前に server.properties を先行作成 (seed / 生成時設定を確実に反映)..."
    : > "$MC_DIR/server.properties"

    # 管理キー (常に強制): crossplay 保護のため固定。
    set_prop "$MC_DIR/server.properties" white-list true
    set_prop "$MC_DIR/server.properties" online-mode true
    set_prop "$MC_DIR/server.properties" server-port "$JAVA_PORT"

    # level-seed: world ディレクトリが無いときだけ書く。既存 world では無視 (警告)。
    if [ -n "$LEVEL_SEED" ]; then
      if [ -d "$MC_DIR/world" ]; then
        warn "既存の world があるため LEVEL_SEED='$LEVEL_SEED' は無視されます (seed は生成時のみ有効)。"
      else
        set_prop "$MC_DIR/server.properties" level-seed "$LEVEL_SEED"
      fi
    fi

    # ユーザー指定のファイル backed キー (空 = 未指定なら書かない = Minecraft 既定に任せる)。
    [ -n "$MOTD" ]                && set_prop "$MC_DIR/server.properties" motd "$(normalize_motd "$MOTD")"
    [ -n "$DIFFICULTY" ]          && set_prop "$MC_DIR/server.properties" difficulty "$DIFFICULTY"
    [ -n "$GAMEMODE" ]            && set_prop "$MC_DIR/server.properties" gamemode "$GAMEMODE"
    [ -n "$MAX_PLAYERS" ]         && set_prop "$MC_DIR/server.properties" max-players "$MAX_PLAYERS"
    [ -n "$VIEW_DISTANCE" ]       && set_prop "$MC_DIR/server.properties" view-distance "$VIEW_DISTANCE"
    [ -n "$SIMULATION_DISTANCE" ] && set_prop "$MC_DIR/server.properties" simulation-distance "$SIMULATION_DISTANCE"
    [ -n "$HARDCORE" ]            && set_prop "$MC_DIR/server.properties" hardcore "$HARDCORE"

    # pvp: Phase 0-E。モダン (1.21.9+/26.x) はゲームルールなので boot 後にコンソール送出する。
    # レガシー (≤1.21.8) のみ server.properties キーとして先行書込する。
    if [ -n "$PVP" ] && ! is_modern_mc; then
      set_prop "$MC_DIR/server.properties" pvp "$PVP"
    fi

    chown "$MC_USER":"$MC_USER" "$MC_DIR/server.properties"
    ok "server.properties を先行作成 (管理キー + 指定済み生成時設定)"
  fi

  log "サーバーを一度起動して設定ファイルを生成します (ワールド生成のため数分かかります)..."
  BOOT_LOG="$MC_DIR/bootstrap.log"
  run_as_mc "cd '$MC_DIR' && printf 'stop\n' | timeout 600 '$JAVA_BIN' -Xms1G -Xmx2G -jar paper.jar --nogui > '$BOOT_LOG' 2>&1" &
  BOOT_PID=$!
  wait_progress "$BOOT_LOG" "$BOOT_PID" "" || true
  wait "$BOOT_PID" 2>/dev/null || true
  rm -f "$BOOT_LOG"

  [ -f "$MC_DIR/server.properties" ] || die "ブートストラップで server.properties が生成されませんでした。ログを確認してください: $MC_DIR/logs/latest.log"
  ok "設定ファイル生成完了"

  # boot 後: 念のため管理キーを再確認 (先行書込が効いていれば no-op)。
  log "設定をパッチ: white-list=true / online-mode=true / auth-type=floodgate"
  set_prop "$MC_DIR/server.properties" white-list true
  set_prop "$MC_DIR/server.properties" online-mode true
  set_prop "$MC_DIR/server.properties" server-port "$JAVA_PORT"

  if [ -f "$GEYSER_CFG" ]; then
    sed -i 's|^\( *auth-type:\).*|\1 floodgate|' "$GEYSER_CFG"
    ok "Geyser auth-type を floodgate に設定"
  else
    warn "Geyser config.yml が見つかりません。auth-type のパッチをスキップしました。"
  fi
  chown -R "$MC_USER":"$MC_USER" "$MC_DIR"
  ok "設定パッチ完了"
else
  ok "設定ファイルは生成済み。ブートストラップとパッチをスキップ (既存設定を保護)"
fi

# 管理者を whitelist + op。コンソールへ送ると Done 直後は getLevel() が null で
# NPE になるため、Mojang UUID を解決して whitelist.json / ops.json に直接書く。
if [ -n "$ADMIN_PLAYER" ]; then
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true   # 起動中なら一旦止めてから書く
  log "$ADMIN_PLAYER の UUID を Mojang API で解決..."
  ADMIN_ID="$(curl -fsSL "https://api.mojang.com/users/profiles/minecraft/${ADMIN_PLAYER}" 2>/dev/null | jq -r '.id // empty')" || ADMIN_ID=""
  if [ "${#ADMIN_ID}" -eq 32 ]; then
    ADMIN_UUID="${ADMIN_ID:0:8}-${ADMIN_ID:8:4}-${ADMIN_ID:12:4}-${ADMIN_ID:16:4}-${ADMIN_ID:20:12}"
    upsert_json "$MC_DIR/whitelist.json" "{\"uuid\":\"$ADMIN_UUID\",\"name\":\"$ADMIN_PLAYER\"}"
    upsert_json "$MC_DIR/ops.json" "{\"uuid\":\"$ADMIN_UUID\",\"name\":\"$ADMIN_PLAYER\",\"level\":4,\"bypassesPlayerLimit\":false}"
    chown "$MC_USER":"$MC_USER" "$MC_DIR/whitelist.json" "$MC_DIR/ops.json"
    ok "$ADMIN_PLAYER を whitelist + op (UUID $ADMIN_UUID)"
  else
    warn "$ADMIN_PLAYER の UUID を解決できませんでした (名前を確認)。起動後に mc-console で 'whitelist add'/'op' してください。"
  fi
else
  warn "ADMIN_PLAYER 未指定。white-list=true のため誰も参加できません。mc-console で 'whitelist add <名前>' を実行してください。"
fi

# Bedrock (Floodgate) プレイヤーを whitelist + op。Bedrock は Mojang プロフィールを
# 持たないため、Geyser API で XUID を取得し Floodgate UUID (new UUID(0, xuid)) を
# 計算して直接書く。名前は Floodgate のプレフィックス (既定 ".") 付き。
if [ -n "$BEDROCK_PLAYER" ]; then
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  log "$BEDROCK_PLAYER (Bedrock) の XUID を Geyser API で解決..."
  BR_XUID="$(curl -fsSL "https://api.geysermc.org/v2/xbox/xuid/${BEDROCK_PLAYER}" 2>/dev/null | jq -r '.xuid // empty')" || BR_XUID=""
  if [ -n "$BR_XUID" ]; then
    BR_HEX="$(printf '%016x' "$BR_XUID")"
    BR_UUID="00000000-0000-0000-${BR_HEX:0:4}-${BR_HEX:4:12}"
    BR_NAME=".${BEDROCK_PLAYER}"
    upsert_json "$MC_DIR/whitelist.json" "{\"uuid\":\"$BR_UUID\",\"name\":\"$BR_NAME\"}"
    upsert_json "$MC_DIR/ops.json" "{\"uuid\":\"$BR_UUID\",\"name\":\"$BR_NAME\",\"level\":4,\"bypassesPlayerLimit\":false}"
    chown "$MC_USER":"$MC_USER" "$MC_DIR/whitelist.json" "$MC_DIR/ops.json"
    ok "$BR_NAME を whitelist + op (Floodgate UUID $BR_UUID)"
  else
    warn "$BEDROCK_PLAYER の XUID を解決できませんでした (ゲーマータグを確認)。"
  fi
fi

# ---------------------------------------------------------------------------
# 10. systemd サービス
# ---------------------------------------------------------------------------
step "systemd サービスの設定"
for helper in mc-console mc-whitelist; do
  if [ -f "$SCRIPT_DIR/$helper" ]; then
    install -m 0755 "$SCRIPT_DIR/$helper" "/usr/local/bin/$helper"
    ok "$helper を /usr/local/bin に配置"
  fi
done

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
ok "unit を書き込み: /etc/systemd/system/${SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
log "サーバーを起動 (systemctl restart ${SERVICE_NAME})..."
systemctl restart "$SERVICE_NAME"
ok "サービス起動を指示"

# ---------------------------------------------------------------------------
# 11. 起動待ち & whitelist/op
# ---------------------------------------------------------------------------
step "サーバー起動待ち"
log "起動完了 (Done) を待っています..."
if wait_progress "$MC_DIR/logs/latest.log" "" 'Done ('; then
  ok "サーバー起動完了"
else
  warn "起動完了を確認できませんでした。ログを確認してください: $MC_DIR/logs/latest.log"
fi

# pvp: Phase 0-E。モダン (1.21.9+/26.x) では pvp は server.properties キーではなく
# ゲームルールなので、起動完了後にコンソールへ /gamerule pvp を送って world に永続化する。
# (レガシー版は step 9 で server.properties に先行書込済みのため、ここでは何もしない)
if [ -n "$PVP" ] && is_modern_mc; then
  if sudo -u "$MC_USER" tmux -L "$TMUX_SOCKET" has-session -t "$TMUX_SESSION" 2>/dev/null; then
    sudo -u "$MC_USER" tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" "gamerule pvp $PVP" Enter
    ok "ゲームルール pvp=$PVP を送信 (モダン版・world 永続)"
  else
    warn "サーバーが未起動のため pvp=$PVP を設定できませんでした。起動後に mc-console で 'gamerule pvp $PVP' を実行してください。"
  fi
fi

# ---------------------------------------------------------------------------
# 12. ファイアウォール (iptables)
# ---------------------------------------------------------------------------
step "ファイアウォール (iptables)"
ensure_rule() {
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
ok "iptables 設定完了"

# ---------------------------------------------------------------------------
# 完了メッセージ
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<サーバーのパブリックIP>')"
cat <<EOF

============================================================
 セットアップ完了  (所要時間 $(_elapsed))
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
