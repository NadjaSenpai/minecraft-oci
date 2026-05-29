# minecraft-oci

OCI Always Free の ARM インスタンス上で、**Crafty Controller(Web ダッシュボード)** から
**PaperMC + GeyserMC/Floodgate** のクロスプレイ対応 Minecraft サーバーを運用するための構築スクリプト一式です。

サーバーの起動/停止・コンソール・ファイル編集・バックアップ・スケジュールは **Crafty** が担い、
公開は **Cloudflare Tunnel + Access** 経由(管理画面のポートはインターネットに晒しません)。
Crafty が持っていない「クロスプレイ維持(Bedrock whitelist・Geyser/Floodgate 更新・Java 昇格)」だけを
薄い CLI ヘルパで補います。

> **設計の経緯**(なぜ Crafty を入れ、なぜ自作 Web や serverless にしなかったか)は
> [`docs/plans/crafty-migration.md`](docs/plans/crafty-migration.md) に確証付きでまとめてあります。
> 旧 systemd ベースの構築一式は [`legacy/`](legacy/) に温存しています。

## 特徴

- **Web ダッシュボード** — Crafty Controller v4 が起動/停止・コンソール・ファイル管理・バックアップ・スケジュール・RBAC を提供。
- **クロスプレイ** — Geyser + Floodgate を仕込んだ Paper サーバーをそのまま運用(Java 版・統合版が同じワールドへ)。
- **ゼロ開放ポートで公開** — `cloudflared` で `localhost:8443` をトンネルし、`crafty.nadja.jp` を Cloudflare Access(SSO/メール認証)の背後に。UI ポートは開けません。
- **ホスト Java を使用** — Crafty のサーバー設定「Java Path」に、ホストの Eclipse Temurin の絶対パスを指定。
- **既存サーバーの移行** — 稼働中の `/opt/minecraft` を zip 化して Crafty にインポート(world・プラグイン・設定をそのまま)。
- **維持ヘルパ** — `mc-config` / `mc-whitelist` / `mc-maintain` が Crafty API 経由で動作。

## 動作対象

- OCI Always Free の **ARM64 (aarch64)** インスタンス
- **Ubuntu 22.04 / 24.04 LTS**(Crafty 公式 installer の対応版)
- root (sudo) で実行

## クイックスタート

OCI の VM に SSH して、次でホスト準備を実行します(冪等・再実行可)。

```bash
sudo apt-get update && sudo apt-get install -y git \
  && git clone https://github.com/NadjaSenpai/minecraft-oci.git \
  && cd minecraft-oci && sudo ./crafty-setup.sh
```

`crafty-setup.sh` が自動で行うこと:

1. 旧 `minecraft.service` を **停止 + 無効化**(Crafty がプロセスの持ち主になる)
2. 依存パッケージの導入
3. **Java (Temurin)** の確認/導入 — Crafty に貼る絶対パスを確定して表示
4. **Crafty Controller v4** をネイティブ導入(公式 installer)
5. `crafty.service` を有効化 + 起動
6. **cloudflared** を導入(`CLOUDFLARED_TOKEN=...` を渡せばトンネルも自動登録)
7. **MC ポート開放**(`25565/tcp` + `19132/udp` を iptables で永続化。UI `8443` は開けない)
8. 既存 `/opt/minecraft` を **インポート用 zip** に固める
9. 共有設定 `/etc/default/crafty-mc` の雛形 + ヘルパ配置

完了後、画面に表示される **一度きりの手動 runbook**(A/B/C)を実施します。

### [A] Cloudflare Zero Trust(ダッシュボード)

1. **Networks → Connectors → Cloudflare Tunnels → Create a tunnel**(Cloudflared)。表示される `cloudflared service install <TOKEN>` の TOKEN を控える(`sudo CLOUDFLARED_TOKEN=... ./crafty-setup.sh` で再実行すると自動登録)。
2. **Public Hostname** を追加: `crafty.nadja.jp` → Service **HTTPS** / URL `localhost:8443` → *Additional application settings → TLS → No TLS Verify を ON*(自己署名証明書のため)。
3. **Access controls → Applications → Self-hosted** に `crafty.nadja.jp` を登録 → ポリシー **Allow / Include / Emails =** あなたのメール。

### [B] OCI セキュリティリスト(OCI コンソール)

ネットワーキング → VCN → サブネット → セキュリティリスト で **Ingress** を追加:

- TCP `25565` — Java 版
- UDP `19132` — Bedrock 版 / Geyser

> UI ポート `8443` は **開けないこと**(Cloudflare Tunnel 経由のみ)。

### [C] Crafty UI(`https://crafty.nadja.jp`)

初回ログイン情報: `sudo cat /var/opt/minecraft/crafty/crafty-4/app/config/default-creds.txt`

1. **Create a server** → zip インポート(`crafty-setup.sh` が作成した `/var/opt/minecraft/import/opt-minecraft.zip`)。`Select Root Dir` で `paper.jar` のある階層を root に。
2. サーバーの **Config → Java Path** に、手順3で表示された Temurin の絶対パスを設定。実行コマンドに **Aikar's Flags** を貼る(例: `… -Xms<N>G -Xmx<N>G <Aikar flags> -jar paper.jar --nogui`)。
3. ユーザー設定で **API キー**(server 権限付き)を発行 → トークンを取得。
4. `/etc/default/crafty-mc` の TODO を記入:
   - `CRAFTY_TOKEN` = 発行したトークン
   - `SERVER_UUID` = インポートしたサーバーの UUID
   - `MC_DIR` = `/var/opt/minecraft/server/<UUID>`
5. **バックアップ(毎晩・7世代)/ クラッシュ自動再起動 / 定時再起動** を UI で設定。

## 共有設定 `/etc/default/crafty-mc`

ヘルパ 3 つが参照します。`crafty-setup.sh` が雛形を生成し、Crafty UI 後に手動で埋めます。

| キー | 説明 |
|---|---|
| `CRAFTY_URL` | Crafty API のベース(既定 `https://127.0.0.1:8443`) |
| `CRAFTY_TOKEN` | Crafty UI で発行した API トークン(Bearer) |
| `SERVER_UUID` | Crafty 上のサーバー UUID |
| `MC_DIR` | Crafty のサーバーディレクトリ(例 `/var/opt/minecraft/server/<uuid>`) |
| `CRAFTY_USER` | Crafty 実行ユーザー(既定 `crafty`) |
| `MC_VERSION` / `JAVA_BIN` | Java 解決の参照値(`crafty-setup.sh` / `mc-maintain` が更新) |

## ヘルパコマンド

すべて root 実行、Crafty API 経由で反映します(`/usr/local/bin` に自動配置)。

### `mc-config` — ゲームプレイ設定(8 項目)

`motd` / `difficulty` / `gamemode` / `max-players` / `pvp` / `view-distance` / `simulation-distance` / `hardcore`。
(`level-seed` は world 生成時に焼き込まれ後変更不可のため対象外。)

```bash
sudo mc-config                            # 現在値を一覧(端末なら編集メニュー)
sudo mc-config difficulty hard            # 稼働中なら即反映(Crafty コンソールへ送信)
sudo mc-config motd "&aWelcome"           # & カラーコードは § に変換
sudo mc-config max-players 30 --restart   # 再起動要の項目を Crafty 経由で即時反映
sudo mc-config get view-distance
```

- **稼働中に即反映**: `difficulty` / `gamemode` / `pvp`(1.21.9+/26.x のゲームルール経路)。
- **再起動が必要**: `motd` / `max-players` / `view-distance` / `simulation-distance` / `hardcore`(と 1.21.8 以下の `pvp`)。`--restart` で Crafty にサーバー再起動を指示。

### `mc-whitelist` — クロスプレイ whitelist

```bash
sudo mc-whitelist <JavaName>       # Java 版(Mojang UUID)
sudo mc-whitelist -b <Gamertag>    # Bedrock 版(XUID → Floodgate UUID)
```

`whitelist.json` に追記し、稼働中なら Crafty コンソールへ `whitelist reload` を送って即反映します。
Bedrock は Crafty の whitelist UI で扱えないため、このヘルパを使います。

### `mc-maintain` — Java 昇格 + プラグイン更新

```bash
sudo mc-maintain               # 必要 Java を導入 + Geyser/Floodgate を latest に
sudo mc-maintain --restart     # 上記後、Crafty にサーバー再起動を指示
```

Paper 本体の更新と起動/停止は **Crafty が担当**します(`mc-maintain` は行いません)。
Java を昇格したら、Crafty UI の「Java Path」を表示された新パスに更新してください。

## 運用(Crafty UI / API)

- 起動/停止/再起動・コンソール・ファイル編集・バックアップ・スケジュールは Crafty UI から。
- クラッシュ時の自動復帰は Crafty のサーバー設定で有効化。
- ログも Crafty UI のコンソール/ログタブで確認できます。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `crafty-setup.sh` | ホスト準備(旧サービス停止・Crafty 導入・cloudflared・ポート開放・zip 化・ヘルパ配置) |
| `mc-config` | ゲームプレイ設定 8 項目を編集し Crafty API で即時反映 |
| `mc-whitelist` | Java/Bedrock を whitelist 追加し Crafty コンソールで reload |
| `mc-maintain` | Java 昇格 + Geyser/Floodgate 更新(Crafty が見ない維持作業) |
| `docs/plans/crafty-migration.md` | 設計と確証(Phase 0)・実装フェーズ |
| `legacy/` | 旧 systemd ベースの構築一式(`setup.sh` / `update.sh` / `mc-console` / 旧 `mc-config` / 旧 `mc-whitelist`) |

## ライセンス

[MIT](LICENSE)
