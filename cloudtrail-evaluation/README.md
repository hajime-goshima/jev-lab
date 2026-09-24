# cloudtrail-evaluation — CloudTrail のリスク評価

AWS CloudTrail のイベントを100件取り出し、[TypeSafe AI](https://docs.typesafe.ai/) の **Jev** で1件ずつリスクを評価します。
イベントのJSONは加工せず、そのまま Jev に渡しています。ルールやパーサーを書かずに、生のログから判定が約0.2秒で返るところを見るためのデモです。

1件ごとに次の6問を1回のリクエストでまとめて聞いています。

| キー | 型 | 内容 |
|---|---|---|
| `risk` | Score (0〜3) | リスクの大きさ（0: 定型の読み取り 〜 3: 権限昇格・保護の無効化・外部公開・破壊） |
| `category` | Choice | read / change / iam / security_control / exposure / destructive / auth |
| `human` | Noul | 人が直接操作したか（自動処理ではないか） |
| `weakens` | Noul | セキュリティを弱める操作か |
| `escalation` | Noul | 権限昇格や居座りに使えるか |
| `investigate` | Noul | 今日セキュリティ担当が見るべきか |

## 実行方法

Ruby 3.4 で動きます。Jevの呼び出しは標準ライブラリだけ、CloudTrailの取得には `aws-sdk-cloudtrail` gem を使います。

```bash
cp .env.example .env    # TYPESAFE_API_KEY を設定

ruby fetch.rb           # CloudTrail から100件を取り出して data/events.jsonl へ（読み取りのみ）
ruby evaluate.rb        # 1件ずつ Jev で評価し、結果を流しながら表示
ruby evaluate.rb 10     # 先頭10件だけ
ruby evaluate.rb --mix  # 架空の危険操作を混ぜて評価（下記）
```

`fetch.rb` は AWS SDK の通常の認証情報（環境変数や `default` プロファイル）で `ap-northeast-1` を読みます。`AWS_PROFILE=... AWS_REGION=... ruby fetch.rb` で変えられます。

### 100件の選び方

CloudTrail の直近のイベントは、AWSサービス自身の `AssumeRole` や AWS Config の定期スキャン（`List*` / `Describe*`）がほとんどです。そのまま100件取ると同じ操作ばかりになるので、`fetch.rb` は直近2000件の中から「操作名＋実行者＋エラーコード」が重複しないものを新しい順に100件選びます。重複をまとめずに直近100件をそのまま取るには `ruby fetch.rb --raw` を使います。

## 出力例

```
  3 🟢 ░░░ 0.1  AssumeRole                         AWSService             auth              192ms  escalation
 10 🟢 ░░░ 0.0  GetCallerIdentity                  IAMUser:admin          auth              221ms  human
 11 🟢 ░░░ 0.1  CreateLogStream                    AssumedRole            security_control  194ms
 ...
100件を 24.2秒で評価（1件あたり 中央値 223ms / 最大 516ms）
```

左から、番号、リスク（🟢 0.5未満 / 🟡 1.5未満 / 🔴 それ以上）、スコア、操作名、実行者、種類、応答時間、0.5以上だったNoulの一覧です。最後にリスクの高い順の上位10件と、種類別の件数を表示します。

## 結果（jev-1.13.0, 2026-09-24）

- 100件を順番に1件ずつ評価して24.2秒。1件あたり中央値223ms、最大516ms
- イベント1件は1〜2KBほどのJSON
- 実アカウント（個人用）の約2時間半分は、読み取り91件・認証系8件・書き込み1件（`CreateLogStream`）でした。リスクの最大は0.42、`investigate` は0件で、Jevの判断は「見るべきものはない」

## 危険な操作を混ぜて試す（`--mix`）

実アカウントのログには危ない操作がほとんどないので、`samples/` に架空のイベントを用意しています。`--mix` を付けると、これらを実データ100件のランダムな位置に混ぜて評価します。

- `samples/risky.jsonl` ★ 危険な操作10件: MFAなしのrootログイン（海外IP）、rootのアクセスキー作成、CloudTrailの停止、GuardDutyの削除、AdministratorAccessの付与、他アカウントからのAssumeRoleの許可、S3バケットの全公開、EBSスナップショットの全公開、SSH/MySQLの全開放、KMSキーの削除予約
- `samples/decoys.jsonl` ☆ 見た目は似ているが安全な操作3件: MFAありのIAMユーザーのログイン、HTTPSを強制するバケットポリシー、社内CIDRからの443番ポートの許可

操作名だけで判断していないかを見るため、☆は★と同じ操作名にしてあります。架空であることはJSONには書かず（Jevへのヒントになるため）、Ruby側で覚えて表示のときに ★☆ を付けます。アカウントIDは実データのものに置き換えてから混ぜます。

### 結果

```
  7 ★ 🔴 ███ 3.0  PutBucketPolicy                IAMUser:ops-intern  exposure          185ms  human weakens escalation investigate
 10 ☆ 🔴 ██░ 1.7  AuthorizeSecurityGroupIngress  IAMUser:admin       exposure          208ms  human weakens
 ...
 77 ☆ 🔴 ██░ 1.6  PutBucketPolicy                IAMUser:admin       security_control  259ms  human
 91 ☆ 🟡 █░░ 0.7  ConsoleLogin                   IAMUser:admin       auth              204ms  human
 95 ★ 🔴 ███ 3.0  StopLogging                    IAMUser:ops-intern  security_control  212ms  human weakens escalation investigate

113件を 26.9秒で評価（1件あたり 中央値 221ms / 最大 387ms）
★ 架空の危険操作 10件 → 上位10件に入ったのは 10件（順位 1, 2, 3, 4, 5, 6, 7, 8, 9, 10）
☆ 似ているが安全な操作 3件 → 順位 11, 12, 13
```

- ★10件がすべて上位10件に入り（スコア2.25〜3.00）、`investigate` が立ったのもこの10件だけでした。混ぜる位置を変えて2回実行し、どちらも同じ結果です
- ☆3件はその直後の11〜13位（1.6、1.7、0.7）。実データ100件はすべて0.5未満のままでした
- ☆のうち2件は、スコアが1.5以上で表示上は 🔴 になります。危険ではないが「変更として確認はしておく」程度の扱いで、★との差はスコアと `investigate` に出ています。
  しきい値を2.0にすると★と☆をきれいに分けられますが、この13件に合わせて決めた値なので過信は禁物です

## ファイル構成

- `jev.rb` — Jev API を呼ぶ小さなクライアント
- `fetch.rb` — CloudTrail からイベントを取り出す
- `evaluate.rb` — 質問の定義と、1件ずつの評価・集計
- `samples/risky.jsonl` — 架空の危険操作10件
- `samples/decoys.jsonl` — 架空の、似ているが安全な操作3件
- `data/events.jsonl` — 取り出したイベント（実アカウントの情報を含むので `.gitignore` 済み）
- `results/results.jsonl` — 評価結果（同上）
