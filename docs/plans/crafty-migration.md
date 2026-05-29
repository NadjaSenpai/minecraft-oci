# Plan: minecraft-oci を Crafty Controller 化する

> 段階的・LLM フレンドリーな実装計画。各フェーズは新しいチャットコンテキストで自己完結して実行できるよう、参照すべき既存パターンの file:line を明記している。
> 全体方針は grill-me セッションで合意済み（Q1–Q8 + serverless 検証）。
> 外部事実（Crafty v4 のネイティブ導入手順 / ローカルインポート挙動 / API エンドポイント / cloudflared+Access 設定）は **Phase 0: Documentation Discovery** で一次情報により確証する。本計画では未確証箇所を **`【要確証】`** で明記し、(c) フェーズで埋める。

## 方針の一言まとめ

「Crafty Controller そのものを導入し、Crafty には触らず、Crafty が持たない “クロスプレイ維持” の薄い CLI 層だけを自作する」。Web ダッシュボードは Crafty が提供し、公開エッジは Cloudflare Tunnel + Access が担う。**serverless（Pages/Workers）は本案に登場しない**（理由は付録参照）。

---

## 合意済み設計サマリ（grill-me）

| # | 論点 | 決定 |
|---|---|---|
| 1 | 方針 | **Crafty を導入**（自作せず）。クロスプレイ部分だけ自前で維持 |
| 2 | 統合 | 既存 `/opt/minecraft` を **インポート** + Crafty を **ネイティブ導入**（ホストの Temurin 25 を使用）。`minecraft.service` は stop+disable、Crafty が supervisor に |
| 3 | 公開/認証 | **Cloudflare Tunnel + Access**（`crafty.nadja.jp`）。OCI は MC の `25565/tcp` + `19132/udp` のみ開放、UI ポートは非開放 |
| 4 | 自動化 | **ハイブリッド**: `crafty-setup.sh`（冪等）+ Crafty UI の一度きり手動 runbook |
| 5 | 残すヘルパ | `mc-whitelist` v2 / Geyser・Floodgate 更新 / Java 自動昇格 / `mc-config` v2 — 全て Crafty 前提に retarget |
| 6 | `mc-config` v2 | ホスト CLI が **Crafty API（Bearer token）** を叩く |
| 7 | リポ | **Crafty に軸足**（`crafty-setup.sh` 主役、旧 `setup.sh` は `legacy/` へ） |
| 8 | ステータス頁 | **不要**（Simplicity First。serverless 公開面は作らない） |
| 運用 | バックアップ/再起動/ユーザー | 毎晩ローカル7世代 / クラッシュ自動+定時再起動 / 単一管理者（いずれも Crafty 標準機能を UI 設定） |

---

## アーキテクチャの変化

```
【現在】 systemd(minecraft.service) → tmux(-L minecraft) → run.sh → java
         制御: mc-console / mc-config / mc-whitelist （tmux send-keys）
         公開: 25565/tcp + 19132/udp を OCI で開放

【移行後】 Crafty(native, crafty ユーザー) → 子プロセスで java（ホスト Temurin 25 + Aikar's Flags）
          Web制御: Crafty UI（start/stop/console/file/backup/schedule/players/RBAC）
          公開: cloudflared → crafty.nadja.jp（Access 認証, UI ポートは非開放）
                MC は 25565/tcp + 19132/udp のみ OCI で開放（従来どおり）
          補助CLI: mc-config v2 / mc-whitelist v2 / mc-maintain（全て Crafty API か Crafty サーバーdir経由）
```

固定で守る不変条件（クロスプレイ保護、従来どおり）: `online-mode=true` / Geyser `auth-type: floodgate` / `white-list=true`。

---

## リポジトリの新レイアウト（目標）

```
minecraft-oci/
  crafty-setup.sh      ★主役: minecraft.service 停止+無効化 / Crafty native導入 / cloudflared導入+トンネル / MCポート iptables / /etc/default/crafty-mc 雛形
  mc-config            v2: Craftyサーバーdirの server.properties 編集 + Crafty console API へ即時反映
  mc-whitelist         v2: XUID→Floodgate UUID を Craftyサーバーdir の whitelist.json へ + Crafty console で whitelist reload
  mc-maintain          新規（旧 update.sh の生き残り）: Java自動昇格 + Geyser/Floodgate latest 差し替え
  README.md            Crafty前提に全面改稿（手動 runbook 含む）
  docs/plans/crafty-migration.md   ← 本計画
  legacy/
    setup.sh           旧 systemd ベース一式（退避・温存。削除しない）
    update.sh
    mc-console
```

共有設定 `/etc/default/crafty-mc`（全ヘルパが source）:
```
CRAFTY_URL=https://127.0.0.1:8443
CRAFTY_TOKEN=<UIで発行した Bearer>
SERVER_UUID=<インポートしたサーバーの UUID>
MC_DIR=/var/opt/minecraft/server/<uuid>   # Crafty が展開したサーバーディレクトリ
```

---

## Phase 0: Documentation Discovery（確証済み事実 / 2026-05）

> (c) フェーズで Crafty 公式（docs.craftycontrol.com）・GitLab ソース（gitlab.com/crafty-controller/crafty-4 と crafty-installer-4.0）・`crafty-mcp` ソース・Cloudflare 公式を**一次情報で確証済み**。実装はこの値に依拠する。

### 1. Crafty v4 ネイティブ導入（ARM64 / Ubuntu 22.04・24.04）— ✅確証

- インストール: `git clone https://gitlab.com/crafty-controller/crafty-installer-4.0.git && cd crafty-installer-4.0 && sudo ./install_crafty.sh`（`install_crafty.py` を呼ぶ。対話で master/dev・サービス作成を尋ねる）。
- 実行ユーザー `crafty`（dep スクリプトが `useradd crafty -s /bin/bash`）。DB は **SQLite**。Python 3.10–3.12。
- インストールルート **`/var/opt/minecraft/crafty`**（app=`crafty-4/`、venv=`.venv/`、config/creds=`crafty-4/app/config/`）。
- systemd unit **`crafty.service`**（User=crafty, Restart=on-failure）。**自動有効化されない** → `systemctl enable crafty` が必要。
- UI **`https://<host>:8443`**（自己署名）。初回 creds: `/var/opt/minecraft/crafty/crafty-4/app/config/default-creds.txt`。
- **ARM64 対応**（dep スクリプトに `aarch64` 分岐で build-essential/libssl-dev/libffi-dev を導入）。
- **OS バージョン制約**: installer は `linux_versions.json` 掲載版のみ（22.04 / 24.04 等）。未掲載版は中断 → **22.04 / 24.04 LTS 必須**。

### 2. インポート挙動 — ✅確証（重要）

- **ZIP のみ**（ブラウザアップロード or ローカル zip）。**in-place 参照は不可**。`import_helper.py` が `unzip_file()` で **新ディレクトリへ展開（コピー）**。
- 取り込み後の実体: **`/var/opt/minecraft/server/<server_uuid>/`**、所有者 **`crafty:crafty`**。元の `/opt/minecraft` は無改変。
- world / `plugins/`（Geyser・floodgate）/ server.properties / Geyser config.yml / whitelist.json は**展開で保持**。「Select Root Dir」で server root を選ぶ。
- → **`MC_DIR` = `/var/opt/minecraft/server/<uuid>`**。ヘルパは**この新パスへ `crafty` 所有で**書く（旧 `/opt/minecraft` ではない）。

### 3. Java Path / 起動コマンド — ✅確証

- サーバー Config に **「Java Path」**（自由入力の絶対パス）+ **「Server Execution Command」**（`java …` で始まる自由入力）。
- ホストの Temurin 25 を**任意の絶対パスで指定可**。glob（`temurin-25-jdk-*`）は展開されない恐れ → **具体パスに解決して**渡す（`crafty-setup.sh` が解決して表示）。
- 1.21+/26.x は Java 21+ 必須（Temurin 25 で充足）。

### 4. Crafty v4 API（ソース確証）— ✅確証

- ベース **`https://<host>:8443/api/v2`**、自己署名 → `-k`。ヘッダ **`Authorization: Bearer <token>`**。
- **コンソール送信**: `POST /api/v2/servers/{uuid}/stdin` — **生ボディがコマンド（JSON 不可）**。`--data-binary 'whitelist reload'`。
- **電源操作**: `POST /api/v2/servers/{uuid}/action/{start_server|stop_server|restart_server|kill_server|backup_server}`。
- **状態**: `GET /api/v2/servers/{uuid}/stats` → `.data.running`（真偽）。
- **認証/トークン**: ログイン `POST /api/v2/auth/login`。長寿命キーは UI（ユーザー設定→API キー）で発行 → `GET /api/v2/users/{user_id}/key/{key_id}` がトークンを返す。
- 注意: `crafty-mcp` は stdin を JSON 化している疑いあり → **直接叩く本実装は生ボディ**で送る（実装済み）。

### 5. cloudflared + Cloudflare Access — ✅確証

- 導入（apt、arch 自動）: `mkdir -p --mode=0755 /usr/share/keyrings` → `curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg` → repo 行 `… https://pkg.cloudflare.com/cloudflared any main` → `apt-get install cloudflared`。
- トークン方式: Zero Trust でトンネル作成 → `cloudflared service install <TOKEN>`（systemd `cloudflared.service`）。
- 公開ホスト `crafty.nadja.jp` → Service **HTTPS** / `localhost:8443` + **No TLS Verify ON**（自己署名受理）。
- Access self-hosted app + Allow/Include/**Emails** ポリシー。**インバウンドポート開放は不要**（outbound only）。

### 出典（主要）

- docs.craftycontrol.com（installation/linux, server-config, api-reference/v2, faq）
- gitlab.com/crafty-controller/crafty-installer-4.0（`install_crafty.sh` / `app/ubuntu_24_04.sh` / `config.json`）
- gitlab.com/crafty-controller/crafty-4（`api_handlers.py` / `stdin.py` / `action.py` / `stats.py` / `import_helper.py` / `base_handler.py`）
- github.com/HadiCherkaoui/crafty-mcp（API 利用例）
- developers.cloudflare.com/cloudflare-one（tunnel get-started / origin-parameters / access policies）, pkg.cloudflare.com

---

## Phase 1: `crafty-setup.sh`（冪等ホストインストーラ）

> 既存 `setup.sh` の構造（preflight → step ログ → 冪等チェック → iptables 永続化）を踏襲。`set -euo pipefail`。

- **1a. 前提チェック**: root / Ubuntu / aarch64。`setup.sh` の preflight・`die`/`ok`/`step` ヘルパを流用（`setup.sh:1`〜冒頭ヘルパ群）。
- **1b. 旧サービス停止**: `minecraft.service` が存在すれば `systemctl stop` + `disable`（冪等）。`SERVICE_NAME`/`TMUX_*` 定義は現行 `mc-config`/`mc-console` と同じ。`/opt/minecraft` は触らない（インポート元として温存）。
- **1c. Crafty ネイティブ導入**: Phase 0-1 の確証手順を冪等に。再実行で既導入ならスキップ。
- **1d. cloudflared 導入 + トンネル**: Phase 0-5 の確証手順。token は対話 or 環境変数 `CLOUDFLARED_TOKEN` で受ける（`setup.sh` のハイブリッド対話方式に倣う、`setup.sh:251` 付近の `_ask` パターン）。
- **1e. MC ポート開放**: 既存 iptables ロジックをそのまま流用（`setup.sh:671`〜`686`: `iptables -C` で冪等確認 → `-I` → `netfilter-persistent save/reload`）。`25565/tcp` + `19132/udp`。UI ポートは開けない。
- **1f. 共有設定雛形**: `/etc/default/crafty-mc` を生成（既存なら上書きしない upsert。`setup.sh` の env 書込・`upsert_json` 系を参考）。
- **verify**: `bash -n crafty-setup.sh`、再実行で差分が出ない（冪等）、`crafty`/`cloudflared` サービスが active。

## Phase 2: retargeted ヘルパ群

> ロジックは現行スクリプトから最大限流用し、**変えるのは「送信経路 / ファイルパス / 稼働判定」の3点だけ**（surgical change）。

- **2a. `mc-config` v2**: 現行 `mc-config` の `validate_value`/`set_prop`/`get_prop`/`normalize_motd`/`is_modern_mc`/`apply_key` をそのまま使う。差し替えるのは:
  - `console_send()`（現 tmux send-keys）→ `crafty_console()`（`/etc/default/crafty-mc` の URL+token で Crafty console API に POST）。
  - `server_running()`（現 tmux has-session）→ Crafty status API。
  - `PROP="$MC_DIR/server.properties"` の `MC_DIR` を Crafty サーバーdir に。書込後 `chown crafty`。
  - 反映方針テーブルは不変（difficulty/gamemode=ファイル+コンソール、modern pvp=gamerule、再起動要キーは Crafty restart API を `--restart` 時のみ）。
- **2b. `mc-whitelist` v2**: 現行の XUID/UUID 導出（`mc-whitelist` の Mojang / Geyser API ロジック）をそのまま流用。差し替えるのは whitelist.json のパス（Crafty サーバーdir、所有者 `crafty`）と reload 経路（tmux → Crafty console API で `whitelist reload`）。
  - **load-bearing**: whitelist は「ファイル書込だけでは不反映、ライブに `whitelist reload` 必須」（serverless 検証で再確認済み）。
- **2c. `mc-maintain`（新規）**: 旧 `update.sh` の生き残り部分のみ。
  - Java 自動昇格: `update.sh:84`〜`103`（fill API で `java.version.minimum` 解決 → `temurin-N-jdk` 導入）を流用。Crafty のサーバー起動コマンドが参照する java パスの更新案内も出す。
  - Geyser/Floodgate 差し替え: `update.sh:125`〜`129`（geysermc.org latest を plugins/ に上書き）を Crafty サーバーdir 向けに。
  - **除去**: Paper jar 更新（Crafty 担当）/ `systemctl stop|start`（Crafty 担当）。
- 共有: 全ヘルパ冒頭で `/etc/default/crafty-mc` を source。`curl` の自己署名対応（`--cacert` or localhost 限定 `-k`）は Phase 0-1 の証明書方式に合わせて確定。

## Phase 3: リポ再編 + README + runbook

- **3a.** 旧 `setup.sh` / `update.sh` / `mc-console` を `legacy/` へ `git mv`（削除しない）。
- **3b. README 全面改稿**: Crafty 前提のクイックスタート + **手動 runbook**:
  1. `crafty-setup.sh` 実行。
  2. Cloudflare Zero Trust: トンネル ingress（`crafty.nadja.jp → localhost:8443`）+ Access ポリシー（メール許可）。
  3. OCI セキュリティリスト: `25565/tcp` + `19132/udp` の ingress（既存 README の手順を流用）。
  4. Crafty UI: `/opt/minecraft` をローカルインポート → 実行 Java を Temurin 25 のフルパス、起動コマンドを Aikar's Flags に。
  5. Crafty UI: API トークン発行 → `SERVER_UUID` と共に `/etc/default/crafty-mc` へ記入。
  6. Crafty UI: 毎晩バックアップ7世代 / クラッシュ自動再起動 / 定時再起動。
- **3c.** `.gitignore` 等の追従（必要なら）。

## Phase 4: 検証（成功基準）

1. `crafty-setup.sh` 後、`crafty.nadja.jp`（Access 認証越し）で UI 到達でき、UI ポートは外部から閉（外部から `8443` が閉と確認）。
2. インポートしたサーバーが Crafty 経由で起動し、**Java版(25565)・Bedrock版(19132)両方から同一ワールドに接続**できる（クロスプレイ維持）。
3. `sudo mc-config difficulty hard` が Crafty サーバーの server.properties を書換え、**稼働中サーバーに即時反映**（Crafty API 経由）。
4. `sudo mc-whitelist -b <Gamertag>` が Floodgate UUID を whitelist に追加し、Crafty コンソールで `whitelist reload` が走る。
5. `sudo mc-maintain` が必要 Java を昇格し Geyser/Floodgate を latest に差し替える（Paper 更新・再起動は Crafty に委譲）。
6. 毎晩バックアップとクラッシュ自動再起動が動作。

---

## 付録: serverless（Cloudflare Pages/Workers）を採らない理由（検証済み・2026-05）

公式ドキュメントで確証した、設計を縛る事実:

- **制御プレーンを serverless に置くのは原理的に不可**（quota ではなく構造）。Workers/Pages Functions は V8 isolate でステートレス・ファイルシステムなし・子プロセス不可・シェル/`systemctl` 不可・特定マシンに紐づかない。常駐 supervisor を持てない（CPU: Free 10ms / Paid 既定30s・最大5分、Cron は離散起動）。
  出典: developers.cloudflare.com/workers/reference/security-model, /workers/platform/limits, /workers/reference/how-workers-works
- **Steelman の壁**: SPA・認証ゲートウェイ・Cron・コンソール fan-out までは serverless が担えるが、プロセス監視・コンソール stdin/stdout・ファイル・バックアップは **箱の上の常駐エージェント必須**。結果、serverless 自作は「箱のエージェント + Crafty が無料で持つパネル全部」の二重実装となり、Crafty+Tunnel より厳密に工数大。
- **穴が無い裏付け**: `cloudflared` は WebSocket を localhost へ透過プロキシ（2022 以降デフォルト）→ Crafty のブラウザ内ライブコンソールが Tunnel 越しにそのまま動く。
  出典: developers.cloudflare.com/network/websockets, github.com/cloudflare/workerd/issues/4864（DO の outbound WS は hibernation 不可）
- **whitelist の罠（設計に反映済み）**: whitelist.json を書くだけでは不反映、ライブに `whitelist reload` を送る必要がある → `mc-whitelist`/`mc-config` v2 が Crafty API で reload まで送る設計の根拠。
- 唯一 serverless が綺麗に当てはまるのは「Java ポート(TCP 25565)へ SLP を投げる公開ステータス頁」だが、**Q8 で不要と決定**（Bedrock の UDP 19132 は Workers から不可という制約もある）。
