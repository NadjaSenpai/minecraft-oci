# minecraft-oci

OCI Always Free の ARM インスタンス上に、**PaperMC + GeyserMC/Floodgate** によるクロスプレイ対応 Minecraft サーバーを構築するセットアップスクリプト一式です。Java 版と統合版(Bedrock)の両方から同じワールドに接続できます。

## 特徴

- **Eclipse Temurin** を Adoptium apt リポジトリから導入(MC バージョンが要求する Java を fill API から解決して自動選択。例: 26.1.x → Java 25、1.21.x → Java 21)
- 専用システムユーザー `minecraft` / `/opt/minecraft` で隔離実行
- **PaperMC** はバージョンを固定しつつ、ビルド番号は PaperMC API (v3 fill) で自動解決
- **GeyserMC + Floodgate** でクロスプレイ(`auth-type: floodgate` を自動設定)
- **systemd + tmux** 常駐(クラッシュ時自動再起動、コンソール操作可)
- ヒープサイズは総 RAM の約 75% を自動算出、**Aikar's Flags** 適用
- `white-list=true` + 初期管理者の `whitelist add` / `op` を自動化
- **冪等**: 再実行してもワールドや既存設定を上書きしない
- iptables を冪等に設定(`netfilter-persistent` で永続化)

## 動作対象

- OCI Always Free **ARM64 (aarch64)** インスタンス
- **Ubuntu 22.04 LTS / 24.04 LTS**
- root (sudo) 実行

## クイックスタート

OCI の VM に SSH し、以下のワンライナーで取得〜起動まで一気に実行できます(git が無ければ導入):

```bash
sudo apt-get update && sudo apt-get install -y git && git clone https://github.com/NadjaSenpai/minecraft-oci.git && cd minecraft-oci && sudo ./setup.sh
```

端末から実行すると **対話形式**で設定(MC バージョン・管理者名・メモリ)を尋ねられます(そのまま Enter で既定値)。2 回目以降は `cd ~/minecraft-oci && git pull && sudo ./setup.sh`。

> private リポジトリのため、`git clone` には GitHub の認証(PAT 等)が必要です。公開する場合はリポジトリを public にしてください。

環境変数で渡すと、その項目は対話をスキップします(自動化・再実行・パイプ実行向け):

```bash
# Java + Bedrock 両方を whitelist + op して非対話で構築
sudo ADMIN_PLAYER=あなたのJava版名 BEDROCK_PLAYER=あなたのBedrockゲーマータグ ./setup.sh
```

完了すると Java 版・Bedrock 版の接続先と、後述の **OCI セキュリティリスト** 設定手順が表示されます。

> Bedrock プレイヤーは Mojang プロフィールを持たないため `whitelist add <名前>` では登録できません。`BEDROCK_PLAYER`(対話なら「Bedrock版 管理者ゲーマータグ」)を使うと XUID から Floodgate UUID を計算して whitelist に追加します。

## 設定(環境変数で上書き可)

| 変数 | 既定値 | 説明 |
|---|---|---|
| `MC_VERSION` | `26.1.2` | Minecraft バージョン(ビルドは自動解決) |
| `ADMIN_PLAYER` | (空) | whitelist + op する Java 版ユーザー名(Mojang UUID で登録) |
| `BEDROCK_PLAYER` | (空) | whitelist + op する Bedrock 版ゲーマータグ(XUID→Floodgate UUID で登録) |
| `MEMORY` | 総 RAM の約 75% | ヒープサイズ(GB 整数) |
| `ACCEPT_EULA` | `true` | Minecraft EULA への同意 |
| `MC_USER` | `minecraft` | 実行ユーザー |
| `MC_DIR` | `/opt/minecraft` | サーバーディレクトリ |
| `JAVA_PORT` | `25565` | Java 版ポート(TCP) |
| `BEDROCK_PORT` | `19132` | Bedrock 版 / Geyser ポート(UDP) |

例:
```bash
MC_VERSION=26.1.2 MEMORY=16 ADMIN_PLAYER=foo sudo -E ./setup.sh
```

## 運用

```bash
sudo systemctl status  minecraft     # 状態確認
sudo systemctl restart minecraft     # 再起動
sudo systemctl stop    minecraft     # 停止(正常終了: コンソールに stop を送り保存)

sudo mc-console                      # コンソールにアタッチ(停止中なら起動してから。デタッチ: Ctrl-b → d)
```

サーバーコマンドは `mc-console` で接続して入力します。ログは `/opt/minecraft/logs/latest.log`。

### 起動中に whitelist 追加

```bash
sudo mc-whitelist <JavaName>       # Java 版プレイヤー
sudo mc-whitelist -b <Gamertag>    # Bedrock 版プレイヤー (Floodgate)
```

whitelist.json に追記して `whitelist reload` まで自動で行います(再起動不要)。Bedrock は Mojang プロフィールが無く `whitelist add <名前>` では追加できないため、このヘルパー(XUID→Floodgate UUID 計算)を使ってください。op はサーバー再起動が必要なため、必要なら setup.sh の `ADMIN_PLAYER` / `BEDROCK_PLAYER` を使います。

> 完全に停止したいときは `systemctl stop` を使ってください。コンソールで `stop` を打つと `Restart=always` により自動再起動します。

## 更新

PaperMC とプラグインを最新化します(ワールド・設定は保護)。

```bash
sudo ./update.sh                       # 同一バージョンの最新ビルドへ
MC_VERSION=26.1.3 sudo -E ./update.sh # 別バージョンへ更新
```

## OCI 側のポート開放(別途必須)

スクリプトは VM 内の iptables のみ設定します。**OCI の VCN セキュリティリスト(または NSG)で以下の Ingress を別途追加**してください。これがないと外部から接続できません。

- TCP `25565`(Java 版)
- UDP `19132`(Bedrock 版 / Geyser)

OCI コンソール → ネットワーキング → VCN → サブネット → セキュリティリスト から設定します。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `setup.sh` | 構築本体 |
| `update.sh` | Paper / プラグインの最新化 |
| `mc-console` | コンソールアタッチ + 停止中なら起動するヘルパー(`/usr/local/bin` に自動配置) |
| `mc-whitelist` | 起動中に Java/Bedrock を whitelist 追加 + reload するヘルパー(`/usr/local/bin` に自動配置) |

## ライセンス

[MIT](LICENSE)
