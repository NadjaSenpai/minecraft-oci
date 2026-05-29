# Handoff: minecraft-oci — 自作 Web ダッシュボード

- 作成: 2026-05-29 22:00 JST
- リポジトリ: https://github.com/NadjaSenpai/minecraft-oci (public)
- 現在の HEAD: `ce1e7f8`（main、push 済み）
- 一行要約: PaperMC+Geyser のクロスプレイ MC サーバー(systemd+tmux)に、軽量 Go 製 Web ダッシュボードを実装。**コードは完成・コンパイル/ローカル検証済み・push 済み。残りは OCI 実機へのデプロイと実機検証のみ。**

## 自宅 PC で続行する手順

1. `git clone https://github.com/NadjaSenpai/minecraft-oci.git && cd minecraft-oci`
   - これで**全コードが揃う**(`dashboard/` の linux/arm64 ビルド済みバイナリも同梱)。
2. Claude Code をそのディレクトリで開き、この文書を貼って続行。
3. **注意**: `docs/plans/` は `.gitignore` 済みでリポジトリに**含まれない**(設計プランは作業機ローカルのみ)。本 handoff に要点を内包しているので、次セッションは基本これで足りる。完全な設計プランが要れば作業機の `docs/plans/web-dashboard.md` を別途持参。
4. `git`/GitHub への push 権限は自宅 PC の認証情報に依存(`gh auth` 済みか確認)。

## これまでの経緯(詳細はリポジトリ参照)

- `README.md`（リポ root）に最新の使い方・構成・公開手順を記載。
- 設計判断は grill-me セッションで合意(下表)。Crafty Controller 移行を一度試したが**セットアップが煩雑**で取りやめ → `crafty-attempt/` に保全。
- コミット履歴: `git log --oneline` 参照(直近: SLP プレイヤー一覧 `a6c4513` → docs gitignore `a77c5df` → README プレーン化 `ce1e7f8`)。

### 合意済み設計(load-bearing。`docs/plans/web-dashboard.md` の要約)

| 論点 | 決定 |
|---|---|
| 方針 | Crafty を使わず**自作 Web ダッシュボード**。サーバー本体は legacy の **systemd + tmux** に戻す |
| スタック | **Go 単一バイナリ**(stdlib のみ、`embed` で UI 同梱)。`dashboard/` |
| 権限 | daemon は **`minecraft` ユーザー**で実行。`systemctl {start,stop,restart} minecraft` だけ narrow sudoers。それ以外(tmux/ファイル/tar)は所有者として直接 |
| コンソール/ログ | 出力=`latest.log` を **SSE で tail** / 入力=`tmux send-keys` |
| 設定編集 | `server.properties` 8項目を直接編集(+稼働中はコンソール即反映)。`online-mode`/`white-list`/`auth-type` は保護=編集不可 |
| whitelist | Java=Mojang UUID / Bedrock=XUID→Floodgate UUID |
| バックアップ | `mc-backup`: world のみ `save-off`/`save-all flush` 整合 tar.gz + 世代保持 |
| プレイヤー一覧 | **SLP**(Server List Ping)を `127.0.0.1:server-port` に。`/api/players` |
| 公開 | **Cloudflare Tunnel + Access**。daemon は `127.0.0.1:8765` のみ bind、UI ポートは開けない |

## DONE(検証済み)

- 全コード実装・push。bash は `bash -n` 通過。
- Go: `go vet` + native + **linux/arm64 ビルド成功**。`dashboard/minecraft-dashboard`(arm64, 同梱)。
- ローカル実動: `/api/status`・`/api/config`・`/api/whitelist`・`/api/backups`・`/api/players`(停止時 available:false)・UI 配信を確認。
- **SLP プロトコルを実サーバーで検証**(Hypixel/CubeCraft でカウント・サンプル解析が正しい)。

## PENDING(次セッションの focus)= 実機デプロイ + 実機検証

唯一未検証なのは「実機ランタイム」。OCI ARM Ubuntu 上で:

```bash
cd ~/minecraft-oci && git pull
# Crafty 検証中に止めていれば MC サーバーを戻す
sudo systemctl enable --now minecraft
mc-console   # tmux コンソールが出れば OK（デタッチ Ctrl-b → d）
sudo ./dashboard/install.sh          # 同梱 arm64 バイナリ配置 + sudoers + unit + 起動
curl -s 127.0.0.1:8765/api/status    # {"running":true,...} 期待
```
その後 Cloudflare で公開(`dashboard/install.sh` 末尾の手順): Zero Trust トンネル作成 →
`cloudflared service install <TOKEN>` → Public Hostname `dash.nadja.jp` を **Service=HTTP /
`localhost:8765`** → Access(Self-hosted app + Allow/Include/Emails)。**No TLS Verify は不要**
(ダッシュボードは平文 HTTP をループバックで提供。OCI 側は何も開けない)。

### 実機で要確認の未知数(挙動がズレたらここ)

- `sudo systemctl` の実体パス(sudoers は `/usr/bin/systemctl` 前提)。
- daemon(minecraft)が tmux ソケット `/tmp/tmux-<uid>/minecraft` を共有できるか(両 unit とも PrivateTmp 無効である必要)。
- SSE の `latest.log` rotation(再生成)時の re-open 挙動。
- **SLP のプレイヤー名サンプル**: Paper 既定で出るはず。人数は常に正確だが、名前が出ない場合は Paper がサンプル抑制 → その時は `list` コマンド+ログ解析方式へ切替(設計合意の代替案)。
- OCI セキュリティリストの ingress は **25565/tcp + 19132/udp のみ**(UI ポートは開けない)。

## 環境 specifics

- OCI Always Free ARM64 / Ubuntu 22.04 or 24.04 / root(sudo)。
- MC: `minecraft` ユーザー / `/opt/minecraft` / systemd unit `minecraft` / tmux `-L minecraft`。
- ダッシュボード: `/usr/local/bin/minecraft-dashboard`、unit `minecraft-dashboard`、`/etc/sudoers.d/minecraft-dashboard`、port 既定 8765(`DASHBOARD_PORT=` で install 時に変更可)。
- ドメインは Cloudflare 管理の `nadja.jp`。

## ローカル(作業機)の後片付け

- デモ用ダッシュボードがローカルで起動したままの可能性: `pkill -f mcdash-native`。
- `/tmp/mcdemo`, `/tmp/slptest`, `/tmp/mcdash-*` は使い捨て。

## Suggested skills(次セッションで使う)

- **verify** — 実機でダッシュボードが実際に動くか(起動/停止・コンソール・設定・whitelist・バックアップ・プレイヤー一覧)をブラウザ越しに確認する。今回の主作業はこれ。
- **diagnose** — 実機で systemctl/tmux/SSE/SLP が想定外の挙動をした場合の切り分けに。
- **run** — アプリ(ダッシュボード)を起動して変更を目視確認したいとき。
- (Crafty に戻す気が再燃したら `crafty-attempt/` に一式あり。ただし当時の煩雑さは `docs/plans/crafty-migration.md`=ローカルに記録)

## 機密情報

- リポジトリ/本文書に API キー・トークン・パスワードは含めない。Cloudflare のトンネルトークンは Zero Trust ダッシュボードで取得し、`cloudflared service install <TOKEN>` で箱に入れるのみ(リポには置かない)。
