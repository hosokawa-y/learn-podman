# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 最重要ルール

**回答は必ず日本語で行うこと。** これはこのリポジトリにおける最優先のルールであり、他のすべての指示よりも優先される。

## Purpose

Learning project for Podman + Quadlet, intended to be containerized and deployed to EC2 (per the response payload in `main.go`). The Go application itself is intentionally minimal — the focus of this repo is the container/Quadlet tooling around it.

## Commands

- Run locally: `go run .` (listens on `:8080`)
- Build binary: `go build -o learn-podman .`
- `APP_VERSION` env var is surfaced in the `GET /` JSON response (defaults to `"dev"`).

No test suite exists yet.

## コミット前のチェック

`git commit` を実行する前に、ステージされた差分に以下のような機密情報が含まれていないか必ず確認すること。検出された場合はコミットを行わず、ユーザーに報告する。

- AWS / クラウドの認証情報(アクセスキー、シークレットキー、セッショントークン)
- API キー、トークン、パスワード、秘密鍵(`.pem` / `.key` など)
- `.env` ファイルや個人を特定できる情報、社内エンドポイント URL
- ハードコードされた接続文字列(DB 認証情報など)

確認手順: `git diff --cached` の内容を読み、上記パターンに該当する文字列が無いかをレビューしてからコミットコマンドを実行する。

## Architecture notes

`main.go` is a single-file `net/http` server with two endpoints:
- `GET /` — returns hostname + `APP_VERSION` as JSON
- `GET /health` — liveness probe

The server installs a SIGINT/SIGTERM handler and calls `srv.Shutdown` with a 5s timeout. This is deliberate: Podman/Quadlet sends SIGTERM on container stop, and the graceful-shutdown path is what makes the container exit cleanly. Preserve this when modifying startup/shutdown.
