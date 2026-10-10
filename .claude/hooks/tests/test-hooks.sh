#!/usr/bin/env bash
# Runs the guardrail hooks directly with sample PreToolUse inputs and checks
# their exit codes (0 = allow, 2 = block). Brief section 6, test 9.
# Usage: bash .claude/hooks/tests/test-hooks.sh
set -uo pipefail

hooks_dir=$(cd "$(dirname "$0")/.." && pwd)
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT

# A throwaway repo with one committed migration (V1) and one staged-only one (V2).
mig=src/main/resources/db/migration
git -C "$repo" init -q
mkdir -p "$repo/$mig" "$repo/src/main/java"
echo "create table t (id int);" > "$repo/$mig/V1__init.sql"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init
echo "alter table t add column x int;" > "$repo/$mig/V2__staged.sql"
git -C "$repo" add -A

pass=0
fail=0

# expect <want-exit> <hook> <json> <description>
expect() {
  local want=$1 hook=$2 json=$3 desc=$4 got
  CLAUDE_PROJECT_DIR=$repo bash "$hooks_dir/$hook" <<<"$json" >/dev/null 2>&1
  got=$?
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1)); echo "PASS  $desc"
  else
    fail=$((fail + 1)); echo "FAIL  $desc (want exit $want, got $got)"
  fi
}

edit() { jq -nc --arg t "$1" --arg p "$2" '{tool_name: $t, tool_input: {file_path: $p}}'; }
bash_cmd() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }

echo "-- protect-files.sh"
expect 2 protect-files.sh "$(edit Write "$repo/.env")"                  "blocks Write to .env"
expect 2 protect-files.sh "$(edit Edit "$repo/.env.local")"             "blocks Edit to .env.local"
expect 2 protect-files.sh "$(edit Write "$repo/config/.env")"           "blocks nested config/.env"
expect 2 protect-files.sh "$(edit Edit ".env.production")"              "blocks relative .env.production"
expect 0 protect-files.sh "$(edit Write "$repo/.env.example")"          "allows .env.example"
expect 2 protect-files.sh "$(edit Edit "$repo/$mig/V1__init.sql")"      "blocks Edit to committed V1 migration"
expect 2 protect-files.sh "$(edit Write "$repo/$mig/V1__init.sql")"     "blocks Write to committed V1 migration"
expect 2 protect-files.sh "$(edit Edit "$mig/V1__init.sql")"            "blocks committed V1 via relative path"
expect 0 protect-files.sh "$(edit Edit "$repo/$mig/V2__staged.sql")"    "allows staged, uncommitted V2 migration"
expect 0 protect-files.sh "$(edit Write "$repo/$mig/V3__new.sql")"      "allows a new V3 migration"
expect 0 protect-files.sh "$(edit Edit "$repo/src/main/java/App.java")" "allows ordinary source file"
expect 2 protect-files.sh "not json"                                    "fails closed on unparseable input"

echo "-- guard-bash.sh"
expect 2 guard-bash.sh "$(bash_cmd 'git push origin main')"                  "blocks git push"
expect 2 guard-bash.sh "$(bash_cmd 'git -C . push')"                         "blocks git -C . push"
expect 2 guard-bash.sh "$(bash_cmd 'git status && git push')"                "blocks push inside a compound command"
expect 0 guard-bash.sh "$(bash_cmd 'git commit -m "push fix"')"              "allows 'push' inside a commit message"
expect 0 guard-bash.sh "$(bash_cmd $'git commit -F - <<\'EOF\'\nDeny live keys and stripe --live\nEOF')" \
  "allows '--live' in a heredoc commit message"
expect 2 guard-bash.sh "$(bash_cmd 'rm -rf target')"                         "blocks rm -rf"
expect 2 guard-bash.sh "$(bash_cmd 'rm -fr target')"                         "blocks rm -fr"
expect 2 guard-bash.sh "$(bash_cmd 'rm -r -f target')"                       "blocks rm -r -f"
expect 2 guard-bash.sh "$(bash_cmd '/bin/rm -Rf target')"                    "blocks /bin/rm -Rf"
expect 0 guard-bash.sh "$(bash_cmd 'rm target/foo.txt')"                     "allows plain rm (permissions still ask)"
expect 2 guard-bash.sh "$(bash_cmd 'export STRIPE_SECRET_KEY=sk_live_abc')"  "blocks a live key prefix"
expect 2 guard-bash.sh "$(bash_cmd 'stripe listen --forward-to localhost:8080/webhooks/stripe')" \
  "blocks stripe without the project profile"
expect 2 guard-bash.sh "$(bash_cmd 'stripe trigger --project-name connect-prototype --live payment_intent.succeeded')" \
  "blocks stripe --live"
expect 0 guard-bash.sh "$(bash_cmd 'stripe listen --project-name connect-prototype --forward-to localhost:8080/webhooks/stripe')" \
  "allows stripe listen with the project profile"
expect 0 guard-bash.sh "$(bash_cmd 'mvn test')"                              "allows mvn test"
expect 2 guard-bash.sh "not json"                                            "fails closed on unparseable input"

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
