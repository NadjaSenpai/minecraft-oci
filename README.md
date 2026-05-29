# minecraft-oci

OCI Always Free の ARM インスタンス上に、**PaperMC + GeyserMC/Floodgate** のクロスプレイ対応
Minecraft サーバーを構築するスクリプト一式と、その上に乗せる**軽量 Web ダッシュボード**です。

サーバー本体は **systemd + tmux** で常駐運用(クラッシュ自動再起動・コンソール操作可)。
Web ダッシュボード(`dashboard/`)は、その制御プレーン(`systemctl`/tmux/`mc-*`)を叩くだけの
**Go 単一バイナリ**で、公開は **Cloudflare Tunnel + Access**(管理ポートは晒さない)。

> 設計の経緯は [`docs/plans/web-dashboard.md`](docs/plans/web-dashboard.md)。
> 一度試した Crafty Controller 移行は [`crafty-attempt/`](crafty-attempt/) に保全しています(セットアップが煩雑だったため取りやめ)。

## 特徴

- **Java 自動選択** — MC バージョンが要求する Eclipse Temurin を自動導入。
- **PaperMC** — バージョン固定・ビルドは API で自動解決。
- **クロスプレイ** — GeyserMC + Floodgate を導入し `auth-type: floodgate` まで自動設定。
- **常駐運用** — systemd + tmux(クラッシュ時自動再起動、`mc-console` でコンソール操作)。
- **Web ダッシュボード** — 起動/停止・ライブコンソール・設定編集・whitelist・バックアップをブラウザから。
- **ゼロ開放ポートで公開** — `cloudflared` で `localhost` をトンネルし、Cloudflare Access で認証。

## 動作対象

- OCI Always Free の **ARM64 (aarch64)** / **Ubuntu 22.04・24.04 LTS** / root (sudo) 実行。

## クイックスタート

```bash
# 1) サーバー構築(対話 or 環境変数)
sudo apt-get update && sudo apt-get install -y git \
  && git clone https://github.com/NadjaSenpai/minecraft-oci.git \
  && cd minecraft-oci && sudo ./setup.sh

# 2) Web ダッシュボード導入(任意)
#    推奨: 手元で linux/arm64 にクロスコンパイルして単一バイナリを scp(箱に Go 不要)
#      (cd dashboard && GOOS=linux GOARCH=arm64 go build -o minecraft-dashboard .)
#      scp dashboard/minecraft-dashboard <oci>:~/minecraft-oci/dashboard/
sudo ./dashboard/install.sh
```

`setup.sh` の環境変数(抜粋): `MC_VERSION`(既定 26.1.2)/ `ADMIN_PLAYER` / `BEDROCK_PLAYER` /
`MEMORY` / `JAVA_PORT`(25565)/ `BEDROCK_PORT`(19132)。ゲームプレイ設定(`MOTD`/`DIFFICULTY` 等)も
初回構築時に対話 or 環境変数で投入でき、後から `mc-config` で変更します。

## CLI ヘルパ(`/usr/local/bin` に自動配置)

```bash
sudo systemctl {status,restart,stop} minecraft   # サービス操作
sudo mc-console                                   # tmux コンソールにアタッチ (デタッチ: Ctrl-b → d)
sudo mc-config                                    # ゲームプレイ設定8項目を一覧/編集
sudo mc-whitelist <Java名>                        # whitelist 追加(Bedrock は -b <ゲーマータグ>)
sudo mc-backup                                    # world を整合スナップショットで tar.gz(世代保持)
sudo ./update.sh                                  # Paper / プラグイン / Java を最新化
```

`mc-config` の対象8項目: `motd` / `difficulty` / `gamemode` / `max-players` / `pvp` /
`view-distance` / `simulation-distance` / `hardcore`。`difficulty`/`gamemode`/`pvp`(1.21.9+/26.x の
ゲームルール)は稼働中なら即反映、その他は再起動で反映(`--restart` で即時)。

## Web ダッシュボード(`dashboard/`)

`minecraft` ユーザーで動く Go 単一バイナリ。`127.0.0.1` のみ bind し、`systemctl` 操作だけ narrow
sudoers(`/etc/sudoers.d/minecraft-dashboard`)で許可、それ以外は所有者として直接行います。

| 機能 | 仕組み |
|---|---|
| 起動/停止/再起動 | `sudo systemctl {start,stop,restart} minecraft`(許可された3コマンドのみ) |
| ライブコンソール | 出力=`latest.log` を **SSE で tail** / 入力=`tmux send-keys` |
| 設定編集(8項目) | `server.properties` を直接編集(+稼働中はコンソールへ即反映)。`online-mode`/`white-list`/`auth-type` は保護のため対象外 |
| whitelist | Java=Mojang UUID / Bedrock=XUID→Floodgate UUID を解決して追記 + `whitelist reload` |
| バックアップ | `mc-backup`(world のみ・`save-off`/`save-all flush` で整合・世代保持)、一覧/DL |

### 公開(Cloudflare Tunnel + Access)

UI ポートは**開けません**。`cloudflared` で `localhost:8765`(既定)をトンネルします。

1. Zero Trust でトンネル作成 → `cloudflared service install <TOKEN>`
2. Public Hostname: `<dash>.nadja.jp` → Service **HTTP** / `localhost:8765`
3. Access: Self-hosted app に `<dash>.nadja.jp` + ポリシー(Allow / Include / Emails)

> ビルドには Go **1.22 以上**が必要(`net/http` の method+path ルーティングと `embed` を使用)。
> 依存は標準ライブラリのみ。

## OCI 側のポート開放(別途必須)

VM 内 iptables とは別に、OCI の VCN セキュリティリスト(または NSG)で以下の Ingress を許可:

- TCP `25565` — Java 版
- UDP `19132` — Bedrock 版 / Geyser

(ダッシュボードの UI ポートは開けないこと。Cloudflare Tunnel 経由のみ。)

## ファイル構成

| パス | 役割 |
|---|---|
| `setup.sh` | サーバー構築(systemd + tmux + Geyser/Floodgate) |
| `update.sh` | Paper / プラグイン / Java の最新化 |
| `mc-console` | tmux コンソールにアタッチ |
| `mc-config` | ゲームプレイ設定8項目の編集 |
| `mc-whitelist` | Java/Bedrock の whitelist 追加 + reload |
| `mc-backup` | world の整合バックアップ + 世代保持 |
| `dashboard/` | Web ダッシュボード(Go daemon・埋め込み UI・systemd unit・sudoers・install.sh) |
| `docs/plans/` | 設計プラン(`web-dashboard.md` / 参考: `crafty-migration.md`) |
| `crafty-attempt/` | 取りやめた Crafty 移行一式の保全 |

## ライセンス

[MIT](LICENSE)
