# Plan: 自作 Web ダッシュボード(Crafty を使わない)

> 全体方針は grill-me セッションで合意済み(Q1–Q6 + 公開は CF Tunnel/Access 流用)。
> Crafty 移行はセットアップが煩雑になったため取りやめ、**legacy の systemd+tmux+mc-* 制御プレーンに戻し、その上に薄い Go ダッシュボードを載せる**。

## なぜ自作が妥当か(前回 steelman との整合)

前回検証では「自作 = Crafty より工数大」と結論したが、それは**バックエンドをゼロから作る前提**だった。本案は **制御プレーンを作り直さない**(systemctl・tmux・mc-config・mc-whitelist は `legacy/` に動作実績つきで存在)。自作の実体は「それらを叩く薄い Go の Web 層 + ログ tail + backup」に縮むため、Crafty 固有のセットアップ(インポート・Java Path・起動コマンド config・API トークン)が消え、総じて単純になる。

## 合意済み設計サマリ(grill-me)

| # | 論点 | 決定 |
|---|---|---|
| 1 | 範囲 | **中**: 起動/停止 + ライブコンソール + whitelist + 設定編集(8項目) + ログ閲覧 + バックアップ |
| 2 | スタック | **Go 単一バイナリ**(UI を `embed`、ランタイム/npm 不要)。箱の上の常駐 HTTP デーモン(systemd) |
| 3 | 権限 | **`minecraft` ユーザーで実行** + `systemctl {start,stop,restart} minecraft` だけ narrow sudoers |
| 4 | コンソール/ログ | **SSE で `latest.log` を tail**(出力)+ **POST→`tmux send-keys`**(入力)。兼用 |
| 5 | バックアップ | **world のみ**、`save-off`+`save-all flush`→tar.gz→`save-on`、ローカル N 世代、DL 可(`mc-backup`) |
| 6 | リポ | **前進リストラ**: legacy→root 復帰、Crafty→`crafty-attempt/`、`dashboard/` 追加 |
| 公開 | (前回流用) | **Cloudflare Tunnel + Access**。daemon は `127.0.0.1:<port>` のみ bind、UI ポートは開けない |

## アーキテクチャ

```
ブラウザ ──Cloudflare Access──▶ cloudflared(エッジ) ──Tunnel──▶ 127.0.0.1:<PORT>
                                                                  minecraft-dashboard (Go, User=minecraft)
                                                                  ├─ sudo systemctl {start,stop,restart} minecraft  (sudoers: 3つだけ)
                                                                  ├─ tmux -L minecraft send-keys / latest.log tail   (直接=所有者)
                                                                  ├─ server.properties / whitelist.json 編集          (直接)
                                                                  └─ mc-backup (world tar, save flush)                (直接)
   サーバー本体: systemd(minecraft.service) → tmux → run.sh → java   ← legacy スタックそのまま
```

固定で守る不変条件(クロスプレイ保護): `online-mode=true` / Geyser `auth-type: floodgate` / `white-list=true`。

## リポ構成(リストラ後)

```
minecraft-oci/
  setup.sh update.sh mc-console mc-config mc-whitelist   ← legacy から root へ復帰(systemd+tmux 制御プレーン)
  mc-backup                         ← 新規(world バックアップ: save flush + 世代保持)
  dashboard/
    go.mod                          ← stdlib のみ(外部依存なし → クロスコンパイル容易)
    main.go                         ← Go daemon(HTTP/SSE、tmux/systemctl/ファイルを直接操作)
    web/index.html  web/app.js      ← embed する静的 UI(ビルド不要のバニラ)
    minecraft-dashboard.service     ← systemd unit(User=minecraft)
    minecraft-dashboard.sudoers     ← /etc/sudoers.d 用(systemctl 3コマンドの NOPASSWD)
    install.sh                      ← デプロイ(バイナリ配置+unit+sudoers+cloudflared 案内)
  crafty-attempt/                   ← 今回の Crafty 一式を退避保全
  docs/plans/web-dashboard.md       ← 本プラン(crafty-migration.md は記録として残す)
  README.md                         ← systemd スタック + ダッシュボードに改稿
```

## HTTP API(最小面)

認証は **Cloudflare Access がエッジで担保**(daemon は `127.0.0.1` bind を信頼)。任意で `Cf-Access-Jwt-Assertion` ヘッダ検証を後付け可。

| メソッド | パス | 動作 |
|---|---|---|
| GET | `/` | 埋め込み UI |
| GET | `/api/status` | `systemctl is-active minecraft` の結果 |
| POST | `/api/power/{start\|stop\|restart}` | `sudo systemctl <action> minecraft` |
| GET | `/api/console/stream` | SSE: `latest.log` を tail |
| POST | `/api/console` | body=コマンド → `tmux -L minecraft send-keys` |
| GET | `/api/config` | server.properties 8項目を返す |
| POST | `/api/config` | `{key,value}` を検証して書込(+稼働中ならコンソール反映) |
| GET | `/api/whitelist` | whitelist.json 一覧 |
| POST | `/api/whitelist` | `{name, bedrock?}` → UUID 解決して追記 + reload |
| POST | `/api/backup` | `mc-backup` を実行 |
| GET | `/api/backups` | バックアップ一覧 |
| GET | `/api/backups/{file}` | tar.gz をダウンロード |

## 実装フェーズ

### Phase A: リストラ(b)
- `git mv` で root の Crafty 一式(`crafty-setup.sh`/`mc-maintain`/Crafty 版 `mc-config`/`mc-whitelist`)→ `crafty-attempt/`。
- `git mv` で `legacy/{setup.sh,update.sh,mc-console,mc-config,mc-whitelist}` → root。`legacy/` を削除。
- `crafty-migration.md` は `docs/plans/` に残置。

### Phase B: `mc-backup`(新規スクリプト)
- `/etc/default/minecraft` を source(MC_DIR/MC_USER/tmux ソケット)。
- 稼働中なら `save-off` + `save-all flush` を tmux 送信 → world(level-name を解決し全次元)を `tar czf backups/world-<ts>.tar.gz` → `save-on`。
- `backups/` に N 世代(既定7)保持、古いものを削除。root でも minecraft でも動くよう所有者判定。

### Phase C: ダッシュボード(Go daemon)
- `dashboard/main.go`: stdlib のみ。`net/http` + `embed`。
  - tmux/systemctl/ファイル操作は `os/exec` と直接 I/O(daemon=minecraft なので tmux/ファイルは sudo 不要、systemctl のみ `sudo`)。
  - SSE は `latest.log` を tail(**rotation 時の re-open に対応**)。
  - config 編集・whitelist の UUID 解決ロジックは Go に inline(リポ方針=自己完結・重複可。proven な CLI スクリプトは無改修で温存)。
- `dashboard/web/`: バニラ HTML+JS(ビルド不要)。
- `dashboard/minecraft-dashboard.service`: `User=minecraft`、`ExecStart=/usr/local/bin/minecraft-dashboard`、`Restart=always`、bind `127.0.0.1:<PORT>`。
- `dashboard/minecraft-dashboard.sudoers`: `minecraft ALL=(root) NOPASSWD: /usr/bin/systemctl start minecraft, /usr/bin/systemctl stop minecraft, /usr/bin/systemctl restart minecraft`。
- `dashboard/install.sh`: ビルド済みバイナリ(または箱で `go build`)を `/usr/local/bin` に、unit と sudoers を配置、`systemctl enable --now`。cloudflared 手順を表示。

### Phase D: 配布
- **Mac で `GOOS=linux GOARCH=arm64 go build` → 単一バイナリを scp**(箱に Go 不要 = セットアップ最小)。`install.sh` は配置のみ。

### Phase E: README 改稿 + 検証

## 実装上の注意 / 未知数

- **SSE の latest.log rotation**: inode 変化で再 open。
- **sudoers の systemctl 実体パス**は `/usr/bin/systemctl`(Ubuntu)。
- **config/whitelist は Go に inline**(daemon=minecraft が直接ファイル書込・tmux 送信。CLI 版 mc-config/mc-whitelist は root 前提のまま温存し共用しない=重複容認)。
- cloudflared 導入手順は crafty-attempt の調査が流用可。
- **クロスプレイ保護**: config 編集 API では `online-mode`/`white-list`/`auth-type` を編集対象外に固定。

## 成功基準

1. `dashboard/install.sh` 後、`<dash>.nadja.jp`(Access 越し)で UI 到達、UI ポートは外部閉。
2. UI から起動/停止/再起動でき `systemctl is-active` と一致。
3. コンソールが SSE でライブ表示、コマンド送信が反映。
4. 設定8項目の編集・whitelist 追加(Java/Bedrock)が即反映。
5. バックアップが整合スナップショットで作成・一覧・DL でき、N 世代保持。
6. daemon は root で動かない(`minecraft` + sudoers 3コマンドのみ)。
