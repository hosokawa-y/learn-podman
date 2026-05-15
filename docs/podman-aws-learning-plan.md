# Podman + AWS 学習計画

## 全体ゴール

Podman を使ったコンテナ化アプリのローカル開発から AWS 上での実運用までを一通り体験する。Docker への依存を抜き、systemd + Quadlet による Linux サーバー上のサービス運用感覚を身につけることを目標とする。

**想定期間**: 約2週間(平日夜1〜2時間想定で。土日に集中するなら3〜4日でも可能)

**前提環境**:
- 手元: macOS(Apple Silicon)、Podman Desktop または `brew install podman`
- AWS: 検証用アカウント、`aws` CLI 設定済み
- 言語: Go 1.23+

---

## フェーズ全体図

```
Phase 0: Podman 基礎       (1日)
   ↓
Phase 1: ローカルで Go アプリをコンテナ化  (1日)
   ↓
Phase 2: EC2 + Quadlet で初回デプロイ      (2日)  ← ここで一旦完成形
   ↓
Phase 3: ECR 運用への切り替え              (1〜2日)
   ↓
Phase 4: Caddy 前段で TLS 化               (1〜2日)
   ↓
Phase 5: マルチコンテナ・Pod 化            (2日)
   ↓
Phase 6: 運用面の押さえ(任意)             (随時)
```

各フェーズで「動いた」を一度確認してから次へ進むこと。詰まったら無理に先に進まない。

---

## Phase 0: Podman 基礎(1日)

### 目的
Docker との挙動差を体感し、`podman` コマンドを Docker と同じ感覚で叩けるようになる。

### やること
- [ ] `brew install podman` または Podman Desktop をインストール
- [ ] `podman machine init && podman machine start`(macOS は内部で VM を立てる)
- [ ] `podman version` でクライアント/サーバーバージョンを確認
- [ ] `podman run --rm -it alpine sh` で対話起動
- [ ] `podman run -d --name nginx -p 8080:80 nginx` でデーモン起動
- [ ] `podman ps`、`podman logs nginx`、`podman exec -it nginx sh` を一通り
- [ ] `podman stop nginx && podman rm nginx`
- [ ] **Docker との違いを観察**: `podman info` の出力で `rootless: true` を確認

### 確認ポイント
- [ ] dockerd 相当の常駐プロセスがないことを `ps aux | grep -i podman` で確認
- [ ] `alias docker=podman` で Docker コマンドがそのまま動くことを確認(より統合したい場合は `podman-mac-helper` で docker socket 互換を設定する選択肢もある)

### 参考
- 公式 Getting Started: https://podman.io/docs
- Podman vs Docker チートシート(各種ブログ)

---

## Phase 1: ローカルで Go アプリをコンテナ化(1日)

### 目的
`main.go` をマルチステージビルドで distroless イメージにし、サイズ・起動速度・SIGTERM ハンドリングを確認する。

### やること
- [x] リポジトリ直下の `main.go` を読み、`/`・`/health` の2エンドポイントと SIGTERM ハンドリングを確認(手を入れる必要は無い)
- [x] `Containerfile` をマルチステージで書く(builder: `golang:1.23-alpine`、runtime: `gcr.io/distroless/static-debian12:nonroot`)
- [x] **静的リンク必須**: builder ステージで `CGO_ENABLED=0 GOOS=linux` を設定し、`go build -ldflags="-s -w" -o /out/app .` でビルド。distroless/static は libc が無いので CGO を切らないと起動時に動的リンクエラーで死ぬ
- [x] `podman build -t myapp:0.1.0 .` でビルド
- [x] `podman images` でサイズ確認(目標: 15MB 以下)
- [x] `podman run --rm -p 8080:8080 myapp:0.1.0` で起動
- [x] `curl http://localhost:8080/` でレスポンス確認
- [x] **SIGTERM 検証**: 別ターミナルから `podman stop <container>` を実行 → 1秒以内に止まれば SIGTERM ハンドリングが効いている(Ctrl+C は SIGINT になるので EC2 想定の検証としては `podman stop` の方が本番に近い)
- [x] **SIGTERM 検証**: 別ターミナルから `podman stop <container>` を実行 → 1秒以内に止まれば SIGTERM ハンドリングが効いている(Ctrl+C は SIGINT になるので EC2 想定の検証としては `podman stop` の方が本番に近い)
- [x] `podman build --platform=linux/amd64 -t myapp:0.1.0-amd64 .` で **EC2(amd64)向け**のイメージも作っておく(macOS arm64 ホストでクロスビルドできることの確認。Phase 2 で使う)

### Containerfile スケルトン例
```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.su[m] ./
RUN go mod download
COPY . .
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

### 確認ポイント
- [x] イメージサイズが 15MB 以下
- [x] `podman stop` での停止が1秒以内
- [x] `podman build --platform=linux/amd64` も成功する(EC2 向け)

### よくあるつまずき
- `go.sum` がない場合の COPY エラー → `COPY go.su[m] ./` で glob 化
- distroless はシェルが無いので `podman exec -it ... sh` で入れない(これは正しい挙動)
- `CGO_ENABLED=0` を忘れて distroless/static で動かす → 起動と同時にクラッシュ。`base-debian12` に逃げる前にまず CGO を疑う

---

## Phase 2: EC2 + Quadlet で初回デプロイ(2日)

### 目的
EC2 上で rootless Podman + systemd --user + Quadlet という、Podman らしい構成を実際に動かす。**ここまでで一旦「動くもの」が完成**するので、ひと区切りとして自分なりにまとめる。

### Day 1: EC2 セットアップとイメージ転送
- [x] **CloudFormation で一括構築**: `infra/learn-podman-stack.yaml` を `aws cloudformation deploy --template-file infra/learn-podman-stack.yaml --stack-name learn-podman --capabilities CAPABILITY_IAM --parameter-overrides MyIp=<自宅IP>/32 --region ap-northeast-1` で適用すると VPC + パブリックサブネット + IGW + SG + IAMロール(SSM/ECR権限付き) + EC2(Ubuntu 24.04 LTS, t3.micro) が一気に作られる。キーペアは作成しない(`ec2:CreateKeyPair` が SCP で Deny される会社環境を前提とし、接続は SSM Session Manager で行う)
- [x] SG はテンプレートで管理: **TCP/8080 のみを `MyIp` パラメータの自宅 IP に限定して開放**。SSH(22番)は開放しない(キーペアを使わないため不要)
- [x] **SSM Session Manager で接続**: 手元の macOS に `brew install --cask session-manager-plugin` を入れてから、`aws cloudformation describe-stacks --stack-name learn-podman --query "Stacks[0].Outputs" --output table` で `InstanceId` を確認し、`aws ssm start-session --target <InstanceId> --region ap-northeast-1` で接続。入った直後は `ssm-user` なので `sudo su - ubuntu` でデフォルトユーザーに切り替える
- [x] `sudo apt update && sudo apt install -y podman awscli`(Ubuntu 24.04 LTS の podman は 4.9 系で Quadlet 対応 / awscli は universe の v1 系。EC2 上で ECR ログインするために必要)
- [x] `podman --version` が 4.4 以上(Quadlet 対応)
- [x] **`sudo loginctl enable-linger ubuntu`** ← 忘れない(これが無いと SSM セッション切断でサービスが死ぬ)
- [ ] **ECR 経由でイメージを EC2 に届ける**(SSH を開けていないので `save | ssh load` は使えない。Phase 3 で詳しくやる ECR push をここで先取りする):

  手元 (macOS) で ECR にリポジトリ作成 → ログイン → push:
  ```bash
  aws ecr create-repository --repository-name myapp --region ap-northeast-1

  aws ecr get-login-password --region ap-northeast-1 | \
    podman login --username AWS --password-stdin <account>.dkr.ecr.ap-northeast-1.amazonaws.com

  podman tag myapp:0.1.0-amd64 <account>.dkr.ecr.ap-northeast-1.amazonaws.com/myapp:0.1.0
  podman push <account>.dkr.ecr.ap-northeast-1.amazonaws.com/myapp:0.1.0
  ```

  EC2 (ubuntu ユーザー) で ECR にログインして pull:
  ```bash
  aws ecr get-login-password --region ap-northeast-1 | \
    podman login --username AWS --password-stdin <account>.dkr.ecr.ap-northeast-1.amazonaws.com

  podman pull <account>.dkr.ecr.ap-northeast-1.amazonaws.com/myapp:0.1.0
  ```
  ※ ECR ログイントークンは 12 時間で失効する。Phase 3 で `amazon-ecr-credential-helper` に置き換えて自動化する。EC2 側の IAM インスタンスプロファイル(CFn テンプレートで `AmazonEC2ContainerRegistryReadOnly` を付与済み)が AWS CLI の認証情報源として効くので、追加の認証情報設定は不要。
- [ ] EC2 上で `podman run --rm -p 8080:8080 <account>.dkr.ecr.ap-northeast-1.amazonaws.com/myapp:0.1.0` で単発起動できることを確認

### Day 2: Quadlet で systemd 化
- [ ] `~/.config/containers/systemd/myapp.container` を作成
- [ ] `systemctl --user daemon-reload`
- [ ] `systemctl --user start myapp.service`
- [ ] `systemctl --user status myapp.service` で active 確認
- [ ] `curl http://<public-ip>:8080/` で外部から疎通(SG で自宅IPに絞っている前提。`<public-ip>` は `aws cloudformation describe-stacks --stack-name learn-podman --query "Stacks[0].Outputs[?OutputKey=='PublicIp'].OutputValue" --output text` で取得)
- [ ] `podman kill` で殺してみる → 自動復活すれば Restart=always が効いている
- [ ] `sudo reboot` → 再ログイン後、自動起動していれば linger が効いている

### 確認ポイント
- [ ] `/usr/libexec/podman/quadlet -dryrun -user` で生成された unit を読んでみる
- [ ] `journalctl --user -u myapp.service` でログが追える
- [ ] SSM セッションを切断してもサービスが動き続ける(linger が効いている証拠)

### この時点での到達レベル
「Linux サーバー上でコンテナをサービスとして動かす」感覚が掴めている状態。**ここで小休止して、blog の下書きにしてもよい**。

---

## Phase 3: ECR 運用への切り替え(1〜2日)

### 目的
Phase 2 の「手元から `podman save | ssh load`」運用を ECR 経由のプル型に切り替える。`podman auto-update` で自動更新も体験する。

### やること
- [ ] ECR リポジトリ作成: `aws ecr create-repository --repository-name myapp`
- [ ] ローカルで ECR ログイン
  ```bash
  aws ecr get-login-password --region <region> | \
    podman login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
  ```
- [ ] イメージにタグ付け & push(amd64 イメージを push する)
  ```bash
  podman tag myapp:0.1.0-amd64 <ecr-url>/myapp:0.1.0
  podman push <ecr-url>/myapp:0.1.0
  ```
- [ ] EC2 に IAM ロールを付与(`AmazonEC2ContainerRegistryReadOnly`)

### EC2 側の ECR 認証(2案。最終的には A 案推奨)

**A案: `amazon-ecr-credential-helper` を使う(推奨)**
- AL2023 なら `sudo dnf install -y amazon-ecr-credential-helper` でインストール可能
- `~/.config/containers/auth.json` に下記を書くだけで、Podman が pull するたびに IAM ロール経由で自動的にトークンを取りに行く。**12時間問題が消える**。
  ```json
  {
    "credHelpers": {
      "<account>.dkr.ecr.<region>.amazonaws.com": "ecr-login"
    }
  }
  ```

**B案: cron で `aws ecr get-login-password` を定期再ログイン**
- 12時間に1回 `aws ecr get-login-password | podman login ...` を実行する systemd timer か cron を作る
- 仕組みが見えるので**学習目的としては一度通っておく価値あり**。最終的には A 案に寄せる前提でやるとよい

### Quadlet と AutoUpdate
- [ ] Quadlet の `Image=` を ECR の URL に書き換え
- [ ] `Image=` の下に `AutoUpdate=registry` を追加
- [ ] `systemctl --user enable --now podman-auto-update.timer`
- [ ] 新バージョン(`0.2.0` 相当)を作って **可変タグ(`:latest` か `:stable`)で push** し直す → 自動更新を観察
- [ ] **重要**: `AutoUpdate=registry` は「同じタグの参照先ダイジェストが変わったこと」を検知して pull する仕組み。`:0.2.0` のような不変タグを Quadlet で固定参照していると新バージョンを別タグで push しても**反応しない**。auto-update したいなら `:latest`/`:stable` のような可変タグを Quadlet に指定し、新版を同タグで push し直す運用にする

### 確認ポイント
- [ ] EC2 が ECR から pull できている(IAM ロール経由で)
- [ ] `podman auto-update` 手動実行で挙動確認
- [ ] バージョンタグの運用方針を自分で決める(`:latest` で auto-update する派か、固定タグで明示的に上げる派か)

---

## Phase 4: Caddy 前段で TLS 化(1〜2日)

### 目的
Caddy をもう一つの Quadlet として立て、Let's Encrypt の証明書を自動取得してアプリを HTTPS 公開する。**Quadlet を複数並べることの強み**を体感する。

### 前提
- ドメインを1つ用意(Route53 か他社、安いやつでOK)
- EC2 の Elastic IP を取得して固定化
- DNS A レコードを Elastic IP に向ける
- SG で 80, 443 を 0.0.0.0/0 で開ける(Let's Encrypt の HTTP-01 challenge と公開アクセスのため)
- rootless ユーザーで <1024 を bind するため:
  `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80`、永続化は `/etc/sysctl.d/` 配下に設定ファイルを置く

### やること
- [ ] `~/.config/containers/systemd/myapp.network` を作成(共有ネットワーク)
- [ ] `myapp.container` を編集: `PublishPort=8080:8080` を削除、`Network=myapp.network` を追加
- [ ] `Caddyfile` を準備
  ```
  yourdomain.example.com {
      reverse_proxy myapp:8080
  }
  ```
- [ ] `~/.config/containers/systemd/caddy.container` を作成
  - `Image=docker.io/caddy:latest`
  - `Network=myapp.network`
  - `PublishPort=80:80`、`PublishPort=443:443`
  - `Volume=...Caddyfile:/etc/caddy/Caddyfile:Z`
  - `Volume=caddy_data:/data`(証明書保存用)
- [ ] `systemctl --user daemon-reload && systemctl --user start caddy.service`
- [ ] ブラウザで `https://yourdomain.example.com/` にアクセス → 証明書取得 & アプリ応答

### 確認ポイント
- [ ] Caddy のログで証明書取得が成功
- [ ] アプリ側コンテナは外部から直接到達不可になっている(SG の 8080 公開を閉じる)
- [ ] `myapp.network` 内で `myapp` というホスト名で名前解決できている

### この時点での構成
```
Internet ─→ :443 Caddy(TLS終端) ─→ myapp:8080
              └── myapp.network (Quadlet)
```

実運用で見るような構成にかなり近づく。

---

## Phase 5: マルチコンテナ・Pod 化(2日)

### 目的
`.pod` Quadlet を使って Kubernetes 風の Pod 概念を体験する。アプリに Redis を足して、Pod 内通信を確認する。

### やること
- [ ] アプリに Redis 接続を実装(`/counter` でカウンタ +1 して返すとか)
- [ ] `~/.config/containers/systemd/myapp.pod` を作成
- [ ] `myapp.container` と `redis.container` を作成、両方に `Pod=myapp.pod` を指定
- [ ] Pod 内では `localhost:6379` で Redis にアクセス可能なことを確認
- [ ] `podman pod ps` で Pod 構造を確認

### Pod とネットワークの繋ぎ方(ここがハマりどころ)
- Pod は **Pod 内コンテナ全体で network namespace を共有**する。なので Pod に対して `Network=myapp.network` を指定すると、**Pod 全体がそのネットワークに参加**する形になり、Pod 内コンテナ個別の `Network=` 指定は無効(衝突する)。
- Caddy(別 Quadlet)からの reverse_proxy 先は、**Pod の Quadlet 名から導出されるホスト名(`myapp` 等)を Pod レベルで解決する**。Pod 内のコンテナ単位ではない点に注意。
- 具体的には:
  - `myapp.pod` に `Network=myapp.network` を書く
  - `myapp.container` / `redis.container` には `Pod=myapp.pod` のみを書き、`Network=` は書かない
  - Caddyfile の `reverse_proxy myapp:8080` は Pod 名 `myapp` を経由してアプリコンテナの 8080 に到達

### 確認ポイント
- [ ] Pod 内のコンテナが同じネットワーク名前空間を共有(`podman exec myapp curl localhost:6379` などで確認)
- [ ] 片方を再起動しても Pod が維持される

### Kubernetes との関連
- [ ] `podman kube generate myapp` で Kubernetes YAML を出力してみる
- [ ] 「あ、これがそのまま Kubernetes 上で動くのか」と理解できればこのフェーズは完了

---

## Phase 6: 運用面の押さえ(任意・随時)

実運用で必要になる項目。仕事で実際に Podman を使うなら、ここまで来てようやくスタートライン。

### 候補トピック
- [ ] **ログ集約**: journald → CloudWatch Logs(`amazon-cloudwatch-agent` で `_SYSTEMD_USER_UNIT` をフィルタ)
- [ ] **メトリクス**: `podman stats` の定期取得、Prometheus node_exporter で host メトリクス
- [ ] **バックアップ**: 名前付き volume の中身を定期 snapshot or `restic` で S3 へ
- [ ] **CI/CD**: GitHub Actions でビルド → ECR push → EC2 上で `podman auto-update.timer` 任せ、もしくは Webhook 連動
- [ ] **イメージスキャン**: `trivy image` をローカル or CI で
- [ ] **secrets 管理**: `podman secret` または AWS Secrets Manager + 起動時取得スクリプト
- [ ] **Infrastructure as Code**: Terraform で EC2 + SG + ECR をコード化(GCP 経験を活かして)

---

## 学んだことを定着させるためのアウトプット案

学習中に書きためたメモを以下のいずれかでまとめると定着しやすい:

- [ ] **社内 Wiki / ブログ記事**: 「Podman + Quadlet で AWS EC2 にデプロイした」一本もの
- [ ] **比較記事**: 「同じアプリを Docker と Podman それぞれでデプロイしてみた」
- [ ] **失敗集**: 自分が踏んだ罠リスト(linger 忘れ、distroless で CGO 切り忘れ、ECR トークン12時間切れ、AutoUpdate=registry が固定タグで反応しない、など)
- [ ] **構成図**: Phase 4 までの最終構成を図にしてみる
- [ ] **設定ファイルの最終版を `docs/` に保存**: `Containerfile`, `myapp.container`, `caddy.container`, `Caddyfile`, `myapp.pod` などを `docs/artifacts/` のような場所に残しておくと、振り返り・再構築・他人への共有が一気に楽になる

---

## 中断・再開時のチェックリスト

途中で長期間中断した場合、再開時にここを確認:

- [ ] Podman のメジャーバージョンが上がっていないか(Quadlet 周辺の挙動が変わることがある)
- [ ] EC2 が停止していないか、Elastic IP が外れていないか
- [ ] ECR ログイントークンの再ログインが必要(credential-helper 運用なら不要)
- [ ] 証明書の有効期限(Caddy は自動更新するが念のため確認)

---

## 進捗メモ欄

| Phase | 開始日 | 完了日 | メモ |
|------|--------|--------|------|
| 0    |2026/05/15|2026/05/15|学習計画 121 行目「ECR 経由でイメージを EC2 に届ける」の手前まで完了|
| 1    |        |        |      |
| 2    |        |        |      |
| 3    |        |        |      |
| 4    |        |        |      |
| 5    |        |        |      |
| 6    |        |        |      |
