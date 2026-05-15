# Podman / Docker コマンド対応表

学習計画 `podman-aws-learning-plan.md` の Phase 0 補足。基本的に **Podman は Docker CLI と互換性がある**(`alias docker=podman` で大半が動く)が、思想の違いから挙動が異なるところもある。

---

## 基本コマンド(ほぼ1対1で対応)

| 操作 | Docker | Podman | 備考 |
|------|--------|--------|------|
| イメージビルド | `docker build -t myapp .` | `podman build -t myapp .` | 同じ |
| イメージ一覧 | `docker images` | `podman images` | 同じ |
| コンテナ起動(対話) | `docker run -it alpine sh` | `podman run -it alpine sh` | 同じ |
| コンテナ起動(バックグラウンド) | `docker run -d --name web nginx` | `podman run -d --name web nginx` | 同じ |
| 動いているコンテナ一覧 | `docker ps` | `podman ps` | 同じ |
| 全コンテナ一覧 | `docker ps -a` | `podman ps -a` | 同じ |
| ログ確認 | `docker logs web` | `podman logs web` | 同じ |
| コンテナに入る | `docker exec -it web sh` | `podman exec -it web sh` | 同じ |
| コンテナ停止 | `docker stop web` | `podman stop web` | 同じ(SIGTERM 送信) |
| コンテナ強制終了 | `docker kill web` | `podman kill web` | 同じ(SIGKILL 送信) |
| コンテナ削除 | `docker rm web` | `podman rm web` | 同じ |
| イメージ削除 | `docker rmi nginx` | `podman rmi nginx` | 同じ |
| イメージ pull | `docker pull nginx` | `podman pull nginx` | 同じ |
| イメージ push | `docker push myapp` | `podman push myapp` | 同じ |
| レジストリ login | `docker login` | `podman login` | 同じ |
| リソース使用状況 | `docker stats` | `podman stats` | 同じ |
| 情報表示 | `docker info` | `podman info` | Podman 側は `rootless: true` 等の項目あり |
| バージョン確認 | `docker version` | `podman version` | 同じ |
| 不要リソース掃除 | `docker system prune` | `podman system prune` | 同じ |

---

## ボリューム・ネットワーク

| 操作 | Docker | Podman | 備考 |
|------|--------|--------|------|
| ボリューム作成 | `docker volume create v1` | `podman volume create v1` | 同じ |
| ボリューム一覧 | `docker volume ls` | `podman volume ls` | 同じ |
| ネットワーク作成 | `docker network create n1` | `podman network create n1` | 同じ |
| ネットワーク一覧 | `docker network ls` | `podman network ls` | 同じ |

---

## イメージの保存・読み込み(EC2 への素朴な転送に使う)

| 操作 | Docker | Podman |
|------|--------|--------|
| イメージを tar に保存 | `docker save myapp -o myapp.tar` | `podman save myapp -o myapp.tar` |
| tar からイメージ読み込み | `docker load -i myapp.tar` | `podman load -i myapp.tar` |
| パイプ転送(SSH 越し) | `docker save myapp \| ssh host 'docker load'` | `podman save myapp \| ssh host 'podman load'` |

Phase 2 で使うやつ。

---

## Compose 系(ここから差が出る)

| 操作 | Docker | Podman |
|------|--------|--------|
| Compose 起動 | `docker compose up -d` | `podman-compose up -d`(別パッケージ) |
| Compose 停止 | `docker compose down` | `podman-compose down` |

**Podman 流儀のおすすめ**: Compose ではなく `.container` / `.pod` / `.network` の **Quadlet ファイルを書いて systemd で管理する**。これが Phase 2 以降のメインテーマ。

---

## Podman にしか無いコマンド(Docker 側に対応なし)

| Podman コマンド | 説明 |
|----------------|------|
| `podman pod create` | 複数コンテナをまとめる Pod を作る(Kubernetes と同じ概念) |
| `podman pod ps` | Pod 一覧 |
| `podman generate systemd` | コンテナを systemd unit ファイル化(古いやり方、現在は Quadlet 推奨) |
| `podman kube generate` | コンテナ/Pod を Kubernetes YAML に変換 |
| `podman kube play` | Kubernetes YAML から起動 |
| `podman auto-update` | レジストリのイメージ更新を検知して自動更新 |
| `podman machine ...` | macOS/Windows 上の VM 管理(Linux では不要) |
| `podman unshare` | rootless ユーザー名前空間の中でコマンド実行 |

---

## Docker にあって Podman にないもの

| Docker コマンド | Podman での扱い |
|----------------|----------------|
| `dockerd`(常駐デーモン) | **存在しない**。Podman はデーモンレス |
| `docker swarm` | 非対応。Kubernetes(`podman kube`)に寄せる思想 |

---

## 挙動が微妙に違うところ(ハマりどころ)

### 1. デフォルトが rootless
- Docker: root デーモン経由で動く(root 権限)
- Podman: **デフォルトで rootless**(一般ユーザー権限で動く)
- 影響: 1024番未満のポート bind ができない、ファイルパーミッションが UID マッピングされる、など

### 2. ホスト側ポートのバインド
- 同じ書式(`-p 8080:80`)で OK
- ただし rootless Podman で 80 番を直接 bind したい場合は `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80` が必要(Phase 4 で出てくる)

### 3. ボリュームマウントの SELinux ラベル
- Docker: 大体気にしなくて済む
- Podman(特に RHEL 系): `-v ./data:/data:Z` のように **`:Z` を付けないと SELinux で permission denied** になることがある
- Quadlet の `Volume=` でも同じく `:Z` が必要なケースあり(Phase 4 で Caddyfile マウント時)

### 4. デフォルトのレジストリ
- Docker: `docker pull nginx` → `docker.io/library/nginx` を引きに行く(暗黙)
- Podman: 設定ファイル(`/etc/containers/registries.conf`)で **複数レジストリを順番に探す** 挙動。`nginx` だけだと曖昧で警告が出ることがある
- 推奨: `podman pull docker.io/library/nginx` のように **完全修飾名**で書く癖をつける

### 5. ネットワークの命名
- Docker: コンテナを起動するとデフォルトの `bridge` ネットワークに繋がる
- Podman: ネットワーク機能の実装が CNI → Netavark に変わった(v4.0~)。挙動はほぼ同じだが、トラブル時に `podman info` で実装を確認しておくと吉

### 6. `--restart` ポリシーと systemd
- Docker: `docker run --restart=always` で再起動を任せる
- Podman: 同じ書式は使えるが、**EC2 で運用するなら Quadlet + systemd に任せる**のが Podman 流。`Restart=always` を unit ファイル側で書く

---

## macOS で使う際の注意

Podman は macOS には Linux カーネルが無いので、**内部で Linux VM を立てている**(`podman machine`)。

| 操作 | コマンド |
|------|---------|
| VM 初期化 | `podman machine init` |
| VM 起動 | `podman machine start` |
| VM 停止 | `podman machine stop` |
| VM 状態確認 | `podman machine list` |

`podman` コマンドは「ローカルから VM 内の Podman に話しかける」ことになる。これが Docker Desktop と同じような仕組み(Docker も macOS では裏で VM が動いている)。

---

## まとめ

- **基本コマンドはほぼ同じ**。`alias docker=podman` で 9 割そのまま動く
- **思想の違い**: Podman はデーモンレス + rootless + systemd 統合 が三本柱
- **本気で Podman を使うなら**: Compose ではなく Quadlet、`--restart` ではなく systemd unit、`docker.io/...` の完全修飾、`:Z` ラベル、この4つを押さえる
- 困ったら `podman info` と `man podman-<subcommand>` を見る。man page がとても丁寧
