#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit. After an edit to a Java file
# under src/, formats with Spotless and compiles main and test code.
# Hooks run OUTSIDE the sandbox, so this hook must never execute project
# code: no `mvn test`, no app startup. Only Maven's own plugins run here
# (formatter, compiler). Unit tests are run by Claude with `mvn test` inside
# the sandbox, where code can't read .env or the Stripe CLI config.
# The edit has already happened, so this can't block it. On failure, exit 2
# sends the tail of the Maven output to Claude so it can fix the problem.
# During TDD a test that doesn't compile yet (the "red" step) shows up here.
# Any internal error is reported with exit 2 as well, never a silent exit 1.
set -uo pipefail

log=""
trap 'rc=$?; [[ -n "$log" ]] && rm -f "$log"; if ((rc != 0 && rc != 2)); then echo "post-edit-check: internal error (exit $rc), so the edit was not verified." >&2; exit 2; fi' EXIT

input=$(cat)
path=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -n "$path" ]] || exit 0

project=$(cd "${CLAUDE_PROJECT_DIR:-.}" && pwd -P)
[[ "$path" == /* ]] || path="$project/$path"
if dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
  path="$dir/$(basename "$path")"
fi
rel=${path#"$project"/}

[[ "$rel" == src/*.java ]] || exit 0
[[ -f "$project/pom.xml" ]] || exit 0   # no Maven project yet
cd "$project"

# Show the end of the Maven output, with anything key-shaped masked.
report() {
  echo "post-edit-check: $1 after editing $rel. Last lines of Maven output:" >&2
  tail -n 40 <<<"$2" \
    | sed -E 's/(sk|rk|pk)_(test|live)_[A-Za-z0-9]+/\1_\2_[REDACTED]/g; s/whsec_[A-Za-z0-9]+/whsec_[REDACTED]/g' >&2
  exit 2
}

# Both Maven runs share one time budget, kept below the hook timeout in
# settings.json (300 s). If it runs out, report a timeout instead of letting
# Claude Code kill the hook silently. macOS has no `timeout`, hence the loop.
budget=${POST_EDIT_BUDGET_SECONDS:-240}
deadline=$((SECONDS + budget))
log=$(mktemp "${TMPDIR:-/tmp}/post-edit.XXXXXX") || exit 1   # exit trap turns this into exit 2

run_mvn() {
  local label=$1
  shift
  mvn "$@" >"$log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      pkill -P "$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
      report "$label timed out after ${budget}s, so the result is unknown (budget: POST_EDIT_BUDGET_SECONDS)" "$(cat "$log")"
    fi
    sleep 0.2
  done
  wait "$pid" || report "$label failed" "$(cat "$log")"
}

run_mvn "formatting (mvn spotless:apply)" -q spotless:apply
run_mvn "compiling (mvn test-compile)" -q test-compile

exit 0
