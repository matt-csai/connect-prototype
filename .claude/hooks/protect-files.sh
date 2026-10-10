#!/usr/bin/env bash
# PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
# Blocks edits to secrets files (.env, .env.*; .env.example is fine) and to
# Flyway migrations that are already committed (applied migrations are immutable).
# Exit 2 blocks the tool call; stderr is shown to Claude as the reason.
# Any other failure is turned into exit 2 too: this hook never fails open.
set -euo pipefail

trap 'rc=$?; if ((rc != 0 && rc != 2)); then echo "BLOCKED by protect-files.sh: internal error (exit $rc), blocking to be safe." >&2; exit 2; fi' EXIT

block() {
  echo "BLOCKED by protect-files.sh: $1" >&2
  exit 2
}

input=$(cat)
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null) \
  || block "could not parse the hook input, so the edit is blocked to be safe."
[[ -n "$path" ]] || block "no file path in the hook input, so the edit is blocked to be safe."

# 1. Secrets files.
name=${path##*/}
if [[ "$name" == ".env" || ("$name" == .env.* && "$name" != ".env.example") ]]; then
  block "$path is a secrets file. Keys live only in your local .env, which Claude never reads or writes. Put placeholder values in .env.example instead."
fi

# 2. Committed Flyway migrations.
project=$(cd "${CLAUDE_PROJECT_DIR:-.}" && pwd -P)
[[ "$path" == /* ]] || path="$project/$path"
# Resolve the parent directory so /tmp vs /private/tmp style symlinks still match.
if dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
  path="$dir/$(basename "$path")"
fi
rel=${path#"$project"/}

migration_re='^src/main/resources/db/migration/V[^/]*\.sql$'
if [[ "$rel" =~ $migration_re ]] && git -C "$project" cat-file -e "HEAD:$rel" 2>/dev/null; then
  latest=$(git -C "$project" ls-files "src/main/resources/db/migration/" \
    | sed -nE 's#.*/V([0-9]+)__.*#\1#p' | sort -n | tail -1)
  block "$rel is a committed Flyway migration and may already be applied to a database. Applied migrations are immutable. Create a new migration instead, e.g. src/main/resources/db/migration/V$((${latest:-0} + 1))__<description>.sql."
fi

exit 0
