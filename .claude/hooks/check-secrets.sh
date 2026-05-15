#!/usr/bin/env bash
# PreToolUse hook: scans the staged git diff for likely secrets before `git commit`.
# Blocks the commit (permissionDecision: deny) when matches are found.

set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only act on git commit invocations. Defense-in-depth — also gated by the `if` filter in settings.json.
if ! printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# Skip dry-run / status-like invocations that don't actually create a commit.
if printf '%s' "$cmd" | grep -qE '[[:space:]](--dry-run|--status|-h|--help|--version)([[:space:]]|$)'; then
  exit 0
fi

diff=$(git diff --cached --no-color 2>/dev/null || true)
if [ -z "$diff" ]; then
  exit 0
fi

# Only inspect added lines (start with '+' but not '+++' diff header).
added=$(printf '%s\n' "$diff" | grep -E '^\+([^+]|$)' || true)
if [ -z "$added" ]; then
  exit 0
fi

hits=""

scan() {
  local flags="$1" pattern="$2" label="$3" m
  m=$(printf '%s\n' "$added" | grep -n $flags -- "$pattern" || true)
  if [ -n "$m" ]; then
    hits="${hits}[${label}]"$'\n'"${m}"$'\n'
  fi
}

# Case-sensitive patterns
scan '-E' 'AKIA[0-9A-Z]{16}'                                         'AWS Access Key ID'
scan '-E' 'ASIA[0-9A-Z]{16}'                                         'AWS Temporary Access Key'
scan '-E' '-----BEGIN[ A-Z]*PRIVATE KEY-----'                        'Private key block'
scan '-E' '(postgres|postgresql|mysql|mongodb|redis|amqp)://[^:/[:space:]]+:[^@/[:space:]]+@' 'Connection string with embedded password'
scan '-E' 'xox[abprs]-[A-Za-z0-9-]{10,}'                              'Slack token'
scan '-E' 'ghp_[A-Za-z0-9]{30,}'                                      'GitHub personal access token'
scan '-E' 'gh[osu]_[A-Za-z0-9]{30,}'                                  'GitHub token'

# Case-insensitive patterns
scan '-iE' 'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+=]{30,}' 'AWS secret access key assignment'
scan '-iE' '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[[:space:]]*[:=][[:space:]]*["'\''][^"'\''[:space:]]{16,}' 'Hardcoded credential assignment'
scan '-iE' '(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*["'\''][^"'\''[:space:]]{8,}' 'Hardcoded password'

# Look for staged .env files (other than .env.example / .env.sample)
env_files=$(git diff --cached --name-only 2>/dev/null | grep -E '(^|/)\.env($|\.[a-zA-Z0-9_-]+$)' | grep -vE '\.(example|sample|template|dist)$' || true)
if [ -n "$env_files" ]; then
  hits="${hits}[Staged .env file]"$'\n'"${env_files}"$'\n'
fi

if [ -n "$hits" ]; then
  reason=$'機密情報の可能性がある内容がステージされた差分に検出されました。コミットをブロックします。\n\n'"${hits}"$'\n誤検知の場合は、対象行を確認のうえ意図的にコミットしてください(--no-verify ではなく、フックの設定見直しを推奨)。'
  jq -nc --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi

exit 0
