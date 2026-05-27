# minecraft-oci

OCI Always Free の ARM インスタンス上に、**PaperMC + GeyserMC/Floodgate** の
クロスプレイ対応 Minecraft サーバーを構築するスクリプト一式です。

Java 版と統合版(Bedrock)の両方から、同じワールドに接続できます。

## 特徴

- **Java 自動選択** — MC バージョンが要求する Eclipse Temurin を自動で導入(例: 26.1.x → Java 25、1.21.x → Java 21)
- **PaperMC** — バージョンを固定し、ビルド番号は API で自動解決
- **クロスプレイ** — GeyserMC + Floodgate を導入し、`auth-type: floodgate` まで自動設定
- **常駐運用** — systemd + tmux で動作(クラッシュ時は自動再起動、コンソール操作も可能)
- **メモリ最適化** — 総 RAM の約 75% を自動でヒープに割り当て、Aikar's Flags を適用
- **whitelist 管理** — `white-list=true` と、初期管理者の登録(op 付き)を自動化
- **専用ユーザー** — `minecraft` ユーザー / `/opt/minecraft` で隔離して実行
- **ポート開放** — iptables を設定し `netfilter-persistent` で永続化
- **何度でも実行可能** — 再実行しても、ワールドや既存の設定は上書きしません

## 動作対象

- OCI Always Free の **ARM64 (aarch64)** インスタンス
- **Ubuntu 22.04 / 24.04 LTS**
- root (sudo) で実行

## クイックスタート

OCI の VM に SSH して、次のワンライナーで取得から起動まで一気に実行できます
(git が無ければ自動で導入します)。

```bash
sudo apt-get update && sudo apt-get install -y git && git clone https://github.com/NadjaSenpai/minecraft-oci.git && cd minecraft-oci && sudo ./setup.sh
```

端末から実行すると、**対話形式**で設定を尋ねられます(MC バージョン・管理者名・メモリ)。
そのまま Enter を押せば既定値が使われます。

2 回目以降は、次のように更新してから再実行できます。

```bash
cd ~/minecraft-oci && git pull && sudo ./setup.sh
```

完了すると、Java 版・Bedrock 版の接続先と、後述の **OCI セキュリティリスト** の設定手順が表示されます。

### 非対話で渡す(自動化・再実行向け)

環境変数で値を渡すと、その項目は対話をスキップします。

```bash
# Java + Bedrock 両方を whitelist + op して、非対話で構築
sudo ADMIN_PLAYER=あなたのJava版名 BEDROCK_PLAYER=あなたのBedrockゲーマータグ ./setup.sh
```

> **Bedrock プレイヤーの whitelist について**
>
> Bedrock プレイヤーは Mojang プロフィールを持たないため、`whitelist add <名前>` では登録できません。
>
> `BEDROCK_PLAYER`(対話では「Bedrock版 管理者ゲーマータグ」)を使うと、
> XUID から Floodgate UUID を計算して whitelist に追加します。

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
sudo MC_VERSION=26.1.2 MEMORY=16 ADMIN_PLAYER=foo ./setup.sh
```

### ゲームプレイ設定(初回構築時に投入)

以下の 9 項目も環境変数で渡せます。**未指定なら書き込まず、Minecraft の既定に従います**。
初回構築後の変更は後述の `mc-config` で行います(`LEVEL_SEED` を除く)。

| 変数 | 既定値 | 有効値 / 範囲 | 説明 |
|---|---|---|---|
| `LEVEL_SEED` | (空=ランダム) | 任意の文字列 | ワールドのシード値。**world 生成時のみ有効で、生成後は変更できません**(既存 world があると無視) |
| `MOTD` | `A Minecraft Server` | 任意の文字列 | サーバー一覧の説明文。`&` のカラーコードを使えます(`§` に変換して書き込み) |
| `DIFFICULTY` | `easy` | `peaceful` / `easy` / `normal` / `hard` | 難易度 |
| `GAMEMODE` | `survival` | `survival` / `creative` / `adventure` / `spectator` | 既定ゲームモード |
| `MAX_PLAYERS` | `20` | 0 以上の整数 | 最大同時接続人数 |
| `PVP` | `true` | `true` / `false` | プレイヤー間戦闘。**1.21.9 以上 / 26.x(既定の 26.1.2 を含む)ではゲームルール**、1.21.8 以下では `server.properties` キーとして扱います |
| `VIEW_DISTANCE` | `10` | 3〜32 | 描画距離(チャンク) |
| `SIMULATION_DISTANCE` | `10` | 3〜32 | シミュレーション距離(チャンク) |
| `HARDCORE` | `false` | `true` / `false` | ハードコアモード |

例:

```bash
sudo LEVEL_SEED=12345 DIFFICULTY=hard VIEW_DISTANCE=12 PVP=false ./setup.sh
```

### 初回構築時の対話

端末から `sudo ./setup.sh` を実行すると、world が未生成のときは **シード値** も尋ねられます
(`LEVEL_SEED` は後から変更できないため。空 Enter でランダム)。
続いて「**詳細設定をカスタマイズしますか? [y/N]**」と確認され、`y` を選んだときだけ
上記の `MOTD` / `DIFFICULTY` / `GAMEMODE` / `MAX_PLAYERS` / `PVP` / `VIEW_DISTANCE` /
`SIMULATION_DISTANCE` / `HARDCORE` を順に尋ねます(不正値は再入力)。
環境変数で渡した項目は、このゲート内でも対話をスキップします。

非対話(パイプ実行や TTY 無し)では従来どおりプロンプトは出ず、環境変数の値だけが反映されます。

## 運用

```bash
sudo systemctl status  minecraft     # 状態確認
sudo systemctl restart minecraft     # 再起動
sudo systemctl stop    minecraft     # 停止(コンソールに stop を送って正常終了)

sudo mc-console                      # コンソールにアタッチ(停止中なら起動してから / デタッチ: Ctrl-b → d)
```

サーバーコマンドは `mc-console` で接続して入力します。

ログは `/opt/minecraft/logs/latest.log` にあります。

> サーバーを完全に止めたいときは `systemctl stop` を使ってください。
> コンソールで `stop` と打つと、`Restart=always` により自動で再起動します。

### 起動中に whitelist を追加

```bash
sudo mc-whitelist <JavaName>       # Java 版プレイヤー
sudo mc-whitelist -b <Gamertag>    # Bedrock 版プレイヤー (Floodgate)
```

`whitelist.json` に追記し、`whitelist reload` まで自動で行います(再起動は不要)。

Bedrock は `whitelist add <名前>` では追加できないため、このヘルパーを使ってください
(XUID から Floodgate UUID を計算します)。

op も付けたい場合は再起動が必要なので、setup.sh の `ADMIN_PLAYER` / `BEDROCK_PLAYER` を使います。

### ゲームプレイ設定を後から変更(`mc-config`)

構築後にゲームプレイ設定を変更するヘルパーです(`/usr/local/bin` に自動配置)。
対象は 8 項目 — `motd` / `difficulty` / `gamemode` / `max-players` / `pvp` /
`view-distance` / `simulation-distance` / `hardcore`。
(`level-seed` は world 生成時に焼き込まれ後から変更できないため対象外です。)

```bash
sudo mc-config                            # 現在値を一覧表示(端末なら編集メニュー)
sudo mc-config <key> <value>              # 1 項目を変更
sudo mc-config <key> <value> --restart    # 再起動が必要な変更を即時反映
sudo mc-config get <key>                  # 1 項目の現在値を表示
```

例:

```bash
sudo mc-config difficulty hard            # 即反映
sudo mc-config motd "&aWelcome"           # & カラーコードは § に変換して書き込み
sudo mc-config max-players 30 --restart   # 再起動して反映
sudo mc-config get view-distance
```

反映方法は項目ごとに異なります。

- **稼働中に即反映**: `difficulty` / `gamemode` / `pvp`(1.21.9 以上 / 26.x のゲームルール経路)
  — server.properties への書き込みに加え、起動中ならコンソールへ該当コマンドを送って反映します。
- **再起動が必要**: `motd` / `max-players` / `view-distance` / `simulation-distance` / `hardcore`
  (および 1.21.8 以下の `pvp`)— 端末では「今すぐ再起動しますか? [y/N]」と確認し、
  `--restart` を付けると確認なしで `systemctl restart minecraft` まで行います。

## 更新

PaperMC とプラグインを最新化します(ワールド・設定は保護されます)。

```bash
sudo ./update.sh                      # 同じバージョンの最新ビルドへ
sudo MC_VERSION=26.1.3 ./update.sh    # 別バージョンへ更新
```

## OCI 側のポート開放(別途必須)

このスクリプトが設定するのは **VM 内の iptables だけ**です。

それとは別に、**OCI の VCN セキュリティリスト(または NSG)**でも、以下の Ingress を許可してください。
これが無いと外部から接続できません。

- TCP `25565` — Java 版
- UDP `19132` — Bedrock 版 / Geyser

設定場所: OCI コンソール → ネットワーキング → VCN → サブネット → セキュリティリスト

## ファイル構成

| ファイル | 役割 |
|---|---|
| `setup.sh` | 構築本体 |
| `update.sh` | Paper / プラグインの最新化 |
| `mc-console` | コンソールにアタッチ(停止中なら起動)するヘルパー。`/usr/local/bin` に自動配置 |
| `mc-whitelist` | 起動中に Java/Bedrock を whitelist 追加して reload するヘルパー。`/usr/local/bin` に自動配置 |
| `mc-config` | 構築後にゲームプレイ設定(motd/難易度/PvP など 8 項目)を変更するヘルパー。`/usr/local/bin` に自動配置 |

## ライセンス

[MIT](LICENSE)
