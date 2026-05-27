# Plan: minecraft-oci ユーザーフレンドリー化 + 設定可能項目の拡張

> 段階的・LLM フレンドリーな実装計画。各フェーズは新しいチャットコンテキストで自己完結して実行できるよう、参照すべき既存パターンの file:line を明記している。
> 全体方針は grill-me セッションで合意済み（Q1–Q9）。外部事実は Phase 0 の Documentation Discovery で一次情報により確証済み。

## 合意済み設計サマリ（grill-me Q1–Q9）

- 対象9項目: `level-seed`(生成時固定) / `motd` / `difficulty` / `gamemode` / `max-players` / `pvp` / `view-distance` / `simulation-distance` / `hardcore`
- 固定で触らせない: `online-mode` / `auth-type=floodgate` / `white-list=true`（crossplay 保護）
- 「サーバー名」= `motd`（Q1）
- 可変設定は新設ヘルパー **`mc-config`** で後変更（Q2）。setup.sh は初回投入のみ。
- setup.sh 初回対話 = 最小 + 「詳細設定をカスタマイズ?[y/N]」ゲート。`level-seed` は後変更不可なので常に質問（空=ランダム）（Q4）。
- `mc-config` = 両対応（引数なし=一覧+対話 / `mc-config <key> <value>` 直接 / `get`）（Q5）。
- 再起動要の変更 = 編集 + 再起動確認（対話 y/N、コマンドは `--restart`）（Q6）。即時系はコンソール送出で即反映。
- 新9項目すべてに env 変数（Q7）。
- 厳格 + 親切バリデーション（Q8）。
- `mc-config` はゲームプレイ8項目のみ（インフラは setup/update 担当、seed は生成時固定で対象外）（Q9）。

---

## Phase 0: Documentation Discovery（確証済み事実 / Allowed APIs / Anti-patterns）

出典: minecraft.wiki/w/Server.properties, docs.papermc.io/paper/reference/server-properties, minecraft.wiki/w/Commands/difficulty, /defaultgamemode, /Game_rule, /Formatting_codes。

### 設定仕様テーブル（バニラ Java / Paper クロスチェック済み）

| キー | 型 | 有効値/範囲 | 既定 | 反映方法（target=26.x モダン） |
|---|---|---|---|---|
| `level-seed` | 文字列 | 任意（空=ランダム） | 空 | **生成時固定**: 初回 world 生成前に server.properties へ。既存 world では無視（警告） |
| `motd` | 文字列 | 任意（§は `§` で記述。2行は `\n`） | `A Minecraft Server` | 再起動要 |
| `difficulty` | 文字列/旧int | peaceful/easy/normal/hard（0–3） | `easy` | **ライブ**: `/difficulty <v>` + ファイル書込（再起動で戻るため両方） |
| `gamemode` | 文字列/旧int | survival/creative/adventure/spectator（0–3） | `survival` | **ライブ(新規参加者)**: `/defaultgamemode <v>` + ファイル書込 |
| `max-players` | 整数 | 0 〜 2^31−1（実用は小） | `20` | 再起動要 |
| `pvp` | 真偽 | true/false | `true` | **バージョン分岐**: 1.21.9+/26.x は **gamerule** `/gamerule pvp <bool>`（ライブ・world永続、server.properties キー無し）。≤1.21.8 は server.properties キー（再起動要） |
| `view-distance` | 整数 | 3 〜 32 | `10` | 再起動要（バニラ/Paper にライブコマンド無し） |
| `simulation-distance` | 整数 | 3 〜 32 | `10` | 再起動要 |
| `hardcore` | 真偽 | true/false | `false` | 再起動要 |

### 確証された load-bearing な事実

- **A. level-seed タイミング**: world 生成時のみ有効。生成後は world ファイルに焼き込まれ変更不可 → 先行書込は初回 boot 前のみ有効。
- **B. server.properties マージ**: 「既存値は保持、欠落キー or 不正値のみ既定にセット」。→ 初回 boot 前の先行書込は安全。ただし**不正値は既定にリセットされる**ためバリデーション必須。
- **C. ライブ可否**: ファイル編集は常に再起動要。ライブ変更はコマンドのみ。
  - ライブ: `difficulty`(`/difficulty`), `gamemode`既定(`/defaultgamemode`), `pvp`(26.x で `/gamerule pvp`)
  - 再起動要: `motd`, `max-players`, `view-distance`, `simulation-distance`, `hardcore`, `level-seed`(+ ≤1.21.8 の pvp)
  - difficulty/gamemode のライブ変更は再起動で server.properties 値に戻る → **永続化にはファイルも書く**。
- **D. motd**: server.properties には `§` ではなく **`§`** を書く（Java properties エスケープ）。`&`→`§` はプラグイン慣習でバニラ非対応。改行は `\n`、2行まで。
- **E. Anti-patterns（発明禁止コマンド）**: `/motd`・`/maxplayers`・`/pvp`(単体)・`/viewdistance`・`/simulationdistance`・`/hardcore` は**存在しない**。`/seed` は表示のみ（設定不可）。pvp は 26.x では `/gamerule pvp`。`/defaultgamemode` は hardcore を受け付けない。

### バージョン判定方針

`/etc/default/minecraft` の `MC_VERSION` を読む。pvp の扱いを「1.21.9 以上（26.x 含む年次版を含む）ならゲームルール、未満なら server.properties キー」で分岐。判定は単純化して「`1.21.9` 以上 or メジャー番号が 21 超（22+/26 等）ならモダン」とする（既定 26.1.2 はモダン）。

---

## Phase 1: setup.sh — 生成時設定の先行書込（seed 順序バグ修正）

**現状の問題**: 現行 setup.sh はステップ9（`setup.sh:307-344`）で「サーバーを一度起動して world 生成 → その後 server.properties をパッチ」の順。`level-seed` は world 生成前に書かれていないと無視される（Phase 0-A）。

### 何を実装するか（既存パターンを COPY）

1. env デフォルトと `_SET` フラグの追加: `setup.sh:27-45` の既存パターンに倣い、9項目の env（`LEVEL_SEED` `MOTD` `DIFFICULTY` `GAMEMODE` `MAX_PLAYERS` `PVP` `VIEW_DISTANCE` `SIMULATION_DISTANCE` `HARDCORE`）を「**未設定なら書かない**」方針で受ける（既定値は適用しない＝Paper 既定に任せる。例外: 既存の white-list/online-mode/server-port は従来どおり強制）。
2. バリデーション関数群（Phase 8-A の Q8）を先頭付近に追加: `valid_enum`/`valid_int_range`/`valid_bool`/`normalize_motd`（`&`→`§` 変換）。env 由来の不正値は `die()`（`setup.sh:57`）で明確に停止。
3. ステップ9を改修: 初回（world 未生成 = `$MC_DIR/world` 非存在）のとき、**bootstrap boot の前に** server.properties を先行作成し、設定された生成時キー（`level-seed` `level-type`将来 + `motd` `difficulty` `gamemode` `max-players` `view-distance` `simulation-distance` `hardcore`）と管理キー（`white-list=true` `online-mode=true` `server-port`）を書く。`set_prop`（`setup.sh:322-329`）を COPY して使う。
4. 既存 world 検出時: `level-seed` 指定があれば `warn()` で「既存 world のため seed は無視」と通知し、seed 行は書かない。
5. boot 後の Geyser `auth-type: floodgate` パッチ（`setup.sh:334-339`）は維持。
6. `pvp`: モダン版ではファイルに書かず、boot 完了後（`setup.sh:436-442` の Done 待ち後）に `PVP` 設定があれば tmux で `/gamerule pvp <bool>` を送る（送出パターンは `mc-whitelist:52-54` / `setup.sh:413` を COPY）。レガシー版のみ server.properties に `pvp=` を先行書込。

### 参照
- 先行書込の対象順序: `setup.sh:307-344`（このブロックを再構成）
- `set_prop`: `setup.sh:322-329`
- `die`/`warn`/`ok`/`log`: `setup.sh:57,56,55,54`
- tmux send-keys: `setup.sh:413`, `mc-whitelist:52-54`

### 検証チェックリスト
- `bash -n setup.sh` 構文 OK。`shellcheck setup.sh` で新規警告ゼロ。
- ロジック単体: `LEVEL_SEED=12345 DIFFICULTY=hard` 等を与え、bootstrap boot 直前に書かれる server.properties に該当行が含まれることを（boot をスタブ化した dry-run か、関数抽出テストで）確認。
- `grep -n 'level-seed' setup.sh` が boot 実行行より前にあること（順序の静的確認）。

### Anti-pattern ガード
- モダン版で `pvp=` を server.properties に書かない（Phase 0-E）。
- motd を `§` 生文字で書かない（`§` を使う）。
- 不正値をそのまま書かない（必ず validate→die/再入力）。

---

## Phase 2: setup.sh — 初回対話（seed 常時 + 詳細ゲート）+ env 連携

### 何を実装するか（COPY）
1. 対話ブロック（`setup.sh:113-127`）を拡張。既存の `_ask`（`setup.sh:115-120`）を再利用:
   - world 未生成かつ env 未指定なら `LEVEL_SEED` を常に質問（空=ランダム）。
   - 続いて `_ask` ベースのゲート「サーバー詳細設定をカスタマイズしますか? [y/N]」。y のときだけ motd/difficulty/gamemode/max-players/pvp/view-distance/simulation-distance/hardcore を順に質問。各プロンプトに既定値と一言説明を表示し、enum/整数/真偽を検証して不正なら再入力（対話ループ）。
   - `_SET` フラグ（`setup.sh:28-31` パターン）で env 指定済み項目はゲート内でもスキップ。
2. 先頭の env ドキュメントコメント（`setup.sh:8-21`）に9つの新 env を追記（既存の体裁に合わせる）。
3. 設定サマリ行（`setup.sh:145`）に主要項目を追加表示。

### 参照
- `_ask` と対話ブロック: `setup.sh:113-127`
- `_SET` フラグ: `setup.sh:28-31`
- env ドキュメント体裁: `setup.sh:8-21`

### 検証チェックリスト
- 非対話（`echo | sudo ...` 相当、TTY 無し）で従来どおりプロンプトをスキップし env のみ反映されること（`setup.sh:114` の `[ -t 0 ]` ガードを壊していない）。
- 対話で不正な difficulty を入れると再入力を促すこと（関数単体テスト）。
- `shellcheck` 警告ゼロ。

### Anti-pattern ガード
- ゲートを TTY 非依存にしない（自動化を壊す）。env は常に優先。

---

## Phase 3: 新規 `mc-config` ヘルパー

### 何を実装するか（COPY）
1. `mc-whitelist` / `mc-console` のヘッダ・スタイル・`set -euo pipefail`・`/etc/default/minecraft` の source（`mc-whitelist:14-19`, `mc-console:11-16`）を COPY して新規 `mc-config` を作成。
2. 設定レジストリ（8項目: seed 除く）を定義: 各キーに 型/バリデータ/有効値/反映方法（`file+restart` | `live:/difficulty` | `live:/defaultgamemode` | `pvp-versioned`）。
3. インターフェース（Q5 両対応）:
   - 引数なし: 現在値一覧（server.properties から読む。pvp はモダン版では「ゲームルール（ゲーム内で確認）」と表示）+ 対話編集メニュー。
   - `mc-config <key> <value>`: validate → 反映方法で分岐。
     - difficulty/gamemode: `set_prop` でファイル書込（永続）+ 稼働中なら tmux で `/difficulty` `/defaultgamemode` 送出（即反映）。
     - pvp: モダン版は稼働中なら `/gamerule pvp <bool>` 送出（world 永続、ファイル書込なし）/ 未起動なら「起動後に反映」案内。レガシー版は `set_prop` + 再起動確認。
     - motd/max-players/view-distance/simulation-distance/hardcore: `set_prop` 書込 + 稼働中なら再起動確認（対話 y/N、コマンドは `--restart` のとき `systemctl restart minecraft`）。
   - `mc-config get <key>`: 現在値表示。
4. `set_prop`（`setup.sh:322-329`）とバリデーション（Phase 1-2）を COPY（リポジトリ既存方針＝スクリプト自己完結。`paper_meta`/`run_as_mc` が setup/update に重複しているのと同じ流儀。共有 lib は作らない）。
5. setup.sh のヘルパー導入ループ（`setup.sh:389-394`）の対象に `mc-config` を追加し `/usr/local/bin` へ配置。

### 参照
- ヘルパー雛形: `mc-whitelist:1-26`, `mc-console:1-39`
- tmux 送出 + has-session: `mc-whitelist:52-54`, `mc-console:18`
- `set_prop`: `setup.sh:322-329`
- 導入ループ: `setup.sh:389-394`
- 再起動: `systemctl restart minecraft`（`setup.sh:430`）

### 検証チェックリスト
- `shellcheck mc-config` 警告ゼロ、`bash -n` OK。
- ローカル dry-run（server 不要）: 一時 server.properties を用意し `MC_DIR=/tmp/x mc-config difficulty hard` 相当で該当行が書き換わること、不正値が拒否されることを確認。
- `mc-config`（引数なし）が現在値を正しく一覧すること。
- 導入ループに `mc-config` が含まれる（`grep -n mc-config setup.sh`）。

### Anti-pattern ガード
- 存在しないコマンドを送らない（`/motd` `/maxplayers` `/pvp` `/viewdistance` `/seed`set。Phase 0-E）。
- difficulty/gamemode で「ライブのみ」で済ませない（再起動で戻るのでファイルも書く。Phase 0-C）。
- 共有 lib を新設してインストール経路を増やさない（既存の自己完結スタイル維持）。

---

## Phase 4: README とドキュメント更新

### 何を実装するか
1. `README.md` の設定章に9項目・env 変数・詳細ゲート・`mc-config` の使い方（一覧/直接/`get`/`--restart`）を追記。env 表は `setup.sh:8-21` の体裁とミラーさせる。
2. pvp のバージョン分岐とライブ/再起動の別を一言注記。
3. `docs/agents/domain.md` 方針に沿い、必要なら `CONTEXT.md` に `mc-config` の用語を1行足す（任意・`/grill-with-docs` に委ねてもよい）。

### 検証チェックリスト
- README に `mc-config` と全 env 変数名が出現すること（`grep`）。

---

## Phase 5: 最終検証

1. 全スクリプト静的チェック: `shellcheck setup.sh update.sh mc-config mc-whitelist mc-console`（警告ゼロ）、`bash -n` 各ファイル。
2. Anti-pattern grep:
   - `grep -nE '/(motd|maxplayers|pvp|viewdistance|simulationdistance|hardcore)\b' mc-config setup.sh` → 想定外の発明コマンドが無いこと（`/gamerule pvp`・`/difficulty`・`/defaultgamemode` のみ許容）。
   - `grep -n '§' mc-config setup.sh` → server.properties 書込に生 `§` を使っていないこと（`§` を使う）。
   - モダン pvp パスで `pvp=` をファイルに書いていないこと。
3. バリデータの単体 dry-run（bash、server 不要）: 各 enum/範囲/真偽の正常系・異常系。
4. 冪等性確認（静的 + 可能なら VM）: setup.sh 再実行で world 既存時は world 生成をスキップし server.properties を破壊しない、`level-seed` 指定時は警告のみ。
5. **実機テスト指示（このマシンでは不可）**: OCI ARM Ubuntu VM で `sudo LEVEL_SEED=12345 DIFFICULTY=hard ./setup.sh` → world が seed 12345 で生成されること、`mc-config motd "&aTest"` → server.properties に `§aTest`、`mc-config difficulty peaceful` → 稼働中サーバーに即反映、を手動確認。

> 注: フル e2e（実 Minecraft サーバー起動）はローカル環境では実行不可。検証は静的解析・bash 関数 dry-run・冪等性チェックまでをローカルで行い、実機確認手順を別途明記する。

---

## 成果物
- 改修: `setup.sh`（Phase 1–2）
- 新規: `mc-config`（Phase 3、`/usr/local/bin` へ setup が配置）
- 更新: `README.md`（Phase 4）、任意で `CONTEXT.md`
- 変更なし: `update.sh`（jar 差し替えのみ、設定不干渉を維持）、`mc-console`

## 既知の制約 / 注意
- pvp はバージョン分岐（26.x=ゲームルール / ≤1.21.8=プロパティ）。既定 26.1.2 はゲームルール経路が主。
- difficulty/gamemode のライブ変更は再起動で server.properties 値に戻るため、必ずファイルにも書く。
- motd は `§` で書く（`&` 入力は変換）。
- リポジトリ既存方針に合わせ共有 lib は作らず、小さなヘルパーは各スクリプトに複製する。
