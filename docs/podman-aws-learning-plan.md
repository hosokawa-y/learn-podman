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
- [ ] `alias docker=podman` で Docker コマンドがそのまま動くことを確認

### 参考
- 公式 Getting Started: https://podman.io/docs
- Podman vs Docker チートシート(各種ブログ)

---

## Phase 1: ローカルで Go アプリをコンテナ化(1日)

### 目的
最小の Go HTTP サーバーをマルチステージビルドで distroless イメージにし、サイズ・起動速度・SIGTERM ハンドリングを確認する。

### やること
- [ ] `myapp/` ディレクトリ作成、`go mod init example.com/myapp`
- [ ] `main.go` を書く(`/`, `/health` の2エンドポイント、SIGTERM でグレースフルシャットダウン)
- [ ] `Containerfile` をマルチステージで書く(builder: `golang:1.23-alpine`、runtime: `gcr.io/distroless/static-debian12:nonroot`)
- [ ] `podman build -t myapp:0.1.0 .` でビルド
- [ ] `podman images` でサイズ確認(目標: 15MB 以下)
- [ ] `podman run --rm -p 8080:8080 myapp:0.1.0` で起動
- [ ] `curl http://localhost:8080/` でレスポンス確認
- [ ] `podman stop` した際の挙動を `journalctl` 相当(podmanログ)で観察 → 即座に止まれば SIGTERM ハンドリング OK

### 確認ポイント
- [ ] イメージサイズが 15MB 以下
- [ ] `Ctrl+C` での停止が1秒以内
- [ ] `podman build --platform=linux/amd64` も成功する(EC2 向け)

### よくあるつまずき
- `go.sum` がない場合の COPY エラー → `COPY go.su[m] ./` で glob 化
- distroless はシェルが無いので `podman exec -it ... sh` で入れない(これは正しい挙動)

---

## Phase 2: EC2 + Quadlet で初回デプロイ(2日)

### 目的
EC2 上で rootless Podman + systemd --user + Quadlet という、Podman らしい構成を実際に動かす。**ここまでで一旦「動くもの」が完成**するので、ひと区切りとして自分なりにまとめる。

### Day 1: EC2 セットアップとビルド
- [ ] EC2 起動: Amazon Linux 2023、t3.micro、キーペア用意
- [ ] SG: SSH(自宅IP)、TCP/8080(0.0.0.0/0、検証用のみ)
- [ ] `ssh ec2-user@<ip>` でログイン
- [ ] `sudo dnf install -y podman`
- [ ] `podman --version` が 4.4 以上(Quadlet 対応)
- [ ] **`sudo loginctl enable-linger ec2-user`** ← 忘れない
- [ ] ローカルから `scp` でソース転送、EC2 上で `podman build`

### Day 2: Quadlet で systemd 化
- [ ] `~/.config/containers/systemd/myapp.container` を作成
- [ ] `systemctl --user daemon-reload`
- [ ] `systemctl --user start myapp.service`
- [ ] `systemctl --user status myapp.service` で active 確認
- [ ] `curl http://<public-ip>:8080/` で外部から疎通
- [ ] `podman kill` で殺してみる → 自動復活すれば Restart=always が効いている
- [ ] `sudo reboot` → 再ログイン後、自動起動していれば linger が効いている

### 確認ポイント
- [ ] `/usr/libexec/podman/quadlet -dryrun -user` で生成された unit を読んでみる
- [ ] `journalctl --user -u myapp.service` でログが追える
- [ ] SSH ログアウトしてもサービスが動き続ける

### この時点での到達レベル
「Linux サーバー上でコンテナをサービスとして動かす」感覚が掴めている状態。**ここで小休止して、blog の下書きにしてもよい**。

---

## Phase 3: ECR 運用への切り替え(1〜2日)

### 目的
ローカルでビルドしたイメージを ECR 経由で EC2 にデプロイする、より現実的な流れに切り替える。`podman auto-update` で自動更新も体験する。

### やること
- [ ] ECR リポジトリ作成: `aws ecr create-repository --repository-name myapp`
- [ ] ローカルで ECR ログイン
  ```bash
  aws ecr get-login-password --region <region> | \
    podman login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
  ```
- [ ] イメージにタグ付け & push
  ```bash
  podman tag myapp:0.1.0 <ecr-url>/myapp:0.1.0
  podman push <ecr-url>/myapp:0.1.0
  ```
- [ ] EC2 に IAM ロールを付与(`AmazonEC2ContainerRegistryReadOnly`)
- [ ] EC2 上の `~/.config/containers/auth.json` を `aws ecr get-login-password` で更新する仕組みを cron か systemd timer で作る(12時間に1回 程度)
- [ ] Quadlet の `Image=` を ECR の URL に書き換え
- [ ] `Image=` の下に `AutoUpdate=registry` を追加
- [ ] `systemctl --user enable --now podman-auto-update.timer`
- [ ] 新バージョン(`0.2.0`)を作って `:latest` タグで push → 自動更新を観察

### 確認ポイント
- [ ] EC2 が ECR から pull できている(IAM ロール経由で)
- [ ] `podman auto-update` 手動実行で挙動確認
- [ ] バージョンタグの運用方針を自分で決める(`:latest` で auto-update する派か、固定タグで明示的に上げる派か)

### 注意
ECR のログイントークンは **12時間で失効**する。AL2023 用には `ecr-credential-helper` を使う手もあるが、まずは cron で素朴に再ログインする方が仕組みが見えて学習向き。

---

## Phase 4: Caddy 前段で TLS 化(1〜2日)

### 目的
Caddy をもう一つの Quadlet として立て、Let's Encrypt の証明書を自動取得してアプリを HTTPS 公開する。**Quadlet を複数並べることの強み**を体感する。

### 前提
- ドメインを1つ用意(Route53 か他社、安いやつでOK)
- EC2 の Elastic IP を取得して固定化
- DNS A レコードを Elastic IP に向ける
- SG で 80, 443 を開ける(rootless ユーザーで <1024 を bind するため:
  `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80`、永続化は `/etc/sysctl.d/`)

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
- [ ] アプリ側コンテナは外部から直接到達不可になっている
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
- [ ] Caddy 側は引き続き `myapp.network` 経由でアプリへ(Pod の network mode に注意)

### 確認ポイント
- [ ] Pod 内のコンテナが同じネットワーク名前空間を共有
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
- [ ] **失敗集**: 自分が踏んだ罠リスト(linger 忘れ、distroless でヘルスチェック書いてしまった、ECR トークン12時間切れ、など)
- [ ] **構成図**: Phase 4 までの最終構成を図にしてみる

---

## 中断・再開時のチェックリスト

途中で長期間中断した場合、再開時にここを確認:

- [ ] Podman のメジャーバージョンが上がっていないか(Quadlet 周辺の挙動が変わることがある)
- [ ] EC2 が停止していないか、Elastic IP が外れていないか
- [ ] ECR ログイントークンの再ログインが必要
- [ ] 証明書の有効期限(Caddy は自動更新するが念のため確認)

---

## 進捗メモ欄

| Phase | 開始日 | 完了日 | メモ |
|------|--------|--------|------|
| 0    |        |        |      |
| 1    |        |        |      |
| 2    |        |        |      |
| 3    |        |        |      |
| 4    |        |        |      |
| 5    |        |        |      |
| 6    |        |        |      |
