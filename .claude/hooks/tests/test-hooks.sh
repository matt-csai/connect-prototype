#!/usr/bin/env bash
# Runs the guardrail hooks directly with sample PreToolUse inputs and checks
# their exit codes (0 = allow, 2 = block). Brief section 6, test 9.
# Usage: bash .claude/hooks/tests/test-hooks.sh
set -uo pipefail

hooks_dir=$(cd "$(dirname "$0")/.." && pwd)
# Stop if the temp repo can't be made: with an empty $repo, the git setup
# below would run against the real repository instead.
repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX") || { echo "cannot create temp dir; aborting" >&2; exit 1; }
[[ -d "$repo" && "$repo" != "$hooks_dir"* ]] || { echo "bad temp dir '$repo'; aborting" >&2; exit 1; }
trap 'rm -rf "$repo"' EXIT

# A throwaway repo with one committed migration (V1) and one staged-only one (V2).
# Any setup failure aborts the run rather than producing misleading results.
set -e
mig=src/main/resources/db/migration
git -C "$repo" init -q
mkdir -p "$repo/$mig" "$repo/src/main/java"
echo "create table t (id int);" > "$repo/$mig/V1__init.sql"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm init
echo "alter table t add column x int;" > "$repo/$mig/V2__staged.sql"
git -C "$repo" add -A
set +e

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
# Secrets on disk: .env files and the Stripe CLI config (holds the sandbox key).
expect 2 guard-bash.sh "$(bash_cmd 'cat .env')"                              "blocks cat .env"
expect 2 guard-bash.sh "$(bash_cmd 'cat ".env"')"                            "blocks a quoted .env path"
expect 2 guard-bash.sh "$(bash_cmd 'grep STRIPE ./.env.local')"              "blocks reading .env.local"
expect 2 guard-bash.sh "$(bash_cmd 'cat config/.env.local.bak')"             "blocks .env copies with extra suffixes"
expect 2 guard-bash.sh "$(bash_cmd 'source .env && mvn test')"               "blocks sourcing .env"
expect 2 guard-bash.sh "$(bash_cmd 'cat ~/.config/stripe/config.toml')"      "blocks reading the Stripe CLI config"
expect 2 guard-bash.sh "$(bash_cmd 'ls "$HOME/.config/stripe"')"             "blocks listing the Stripe CLI config dir"
expect 2 guard-bash.sh "$(bash_cmd 'stripe config --list --project-name connect-prototype')" \
  "blocks stripe config (prints stored keys)"
expect 2 guard-bash.sh "$(bash_cmd $'cat <<EOF\n$(cat .env)\nEOF')"          "blocks .env inside an unquoted heredoc"
expect 0 guard-bash.sh "$(bash_cmd 'cat .env.example')"                      "allows .env.example"
expect 0 guard-bash.sh "$(bash_cmd $'git commit -F - <<\'EOF\'\nDeny .env reads and ~/.config/stripe\nEOF')" \
  "allows .env mentioned in a quoted-heredoc commit message"
expect 0 guard-bash.sh "$(bash_cmd 'cat src/main/resources/application.yml')" "allows ordinary file reads"
# Round 2: heredocs only skip when the body is data (git commit -F -, cat > file).
expect 2 guard-bash.sh "$(bash_cmd $'bash <<\'EOF\'\ncat .env\nEOF')"         "checks a quoted heredoc fed to bash"
expect 2 guard-bash.sh "$(bash_cmd $'python3 - <<\'EOF\'\nprint(open(".env").read())\nEOF')" \
  "checks a quoted heredoc fed to python3"
expect 2 guard-bash.sh "$(bash_cmd $'cat <<\'EOF\' | bash\ncat .env\nEOF')"    "checks a quoted heredoc piped to bash"
expect 2 guard-bash.sh "$(bash_cmd $'grep a <<<\'EOF\'\ncat .env')"            "a here-string does not start a skip"
expect 0 guard-bash.sh "$(bash_cmd $'git commit -F - <<\'EOF\'\nstripe config prints keys; deny it\ngit push stays blocked | rm -rf too\nEOF')" \
  "commit message body lines are not checked as commands"
expect 0 guard-bash.sh "$(bash_cmd $'cd /tmp && cat >> NOTES.md <<\'EOF\'\nstripe listen prints the whsec\nEOF')" \
  "appending a quoted heredoc to a file is not checked as commands"
# Round 2: .env end-of-name boundary.
expect 0 guard-bash.sh "$(bash_cmd 'cat .envrc')"                            "allows .envrc (not a .env file)"
expect 0 guard-bash.sh "$(bash_cmd 'ls src/.environment')"                   "allows .environment"
# Round 2: environment dumps.
expect 2 guard-bash.sh "$(bash_cmd 'env')"                                   "blocks env"
expect 2 guard-bash.sh "$(bash_cmd 'env | grep STRIPE')"                     "blocks env in a pipeline"
expect 2 guard-bash.sh "$(bash_cmd 'printenv STRIPE_SECRET_KEY')"            "blocks printenv"

echo "-- fail closed: an internal error must block (exit 2), never exit 1"
jq_only=$(mktemp -d "$repo/.jqonly.XXXX")
ln -s "$(command -v jq)" "$jq_only/jq"
for hook in guard-bash.sh protect-files.sh; do
  PATH=$jq_only /bin/bash "$hooks_dir/$hook" <<<"$(bash_cmd 'ls')" >/dev/null 2>&1
  got=$?
  if [[ $got == 2 ]]; then
    pass=$((pass + 1)); echo "PASS  $hook blocks when a helper tool is missing"
  else
    fail=$((fail + 1)); echo "FAIL  $hook blocks when a helper tool is missing (got $got)"
  fi
done
CLAUDE_PROJECT_DIR=/nonexistent bash "$hooks_dir/protect-files.sh" <<<"$(edit Edit "src/main/java/App.java")" >/dev/null 2>&1
got=$?
if [[ $got == 2 ]]; then
  pass=$((pass + 1)); echo "PASS  protect-files.sh blocks when the project dir is missing"
else
  fail=$((fail + 1)); echo "FAIL  protect-files.sh blocks when the project dir is missing (got $got)"
fi

echo "-- readonly-git.sh (payments-reviewer's Bash allowlist)"
expect 0 readonly-git.sh "$(bash_cmd 'git diff HEAD')"                       "allows git diff HEAD"
expect 0 readonly-git.sh "$(bash_cmd 'git diff HEAD --stat')"                "allows git diff --stat"
expect 0 readonly-git.sh "$(bash_cmd 'git diff --cached -U5 -- src/main/App.java')" "allows git diff --cached -U5 -- path"
expect 0 readonly-git.sh "$(bash_cmd 'git status --porcelain --untracked-files=all')" "allows git status listing new files"
expect 0 readonly-git.sh "$(bash_cmd 'git log --oneline -5')"                "allows git log"
expect 0 readonly-git.sh "$(bash_cmd 'git log --oneline -n 5')"              "allows git log -n 5"
expect 0 readonly-git.sh "$(bash_cmd 'git show HEAD:src/main/App.java')"     "allows git show"
expect 2 readonly-git.sh "$(bash_cmd 'git ls-files --others')"               "blocks git ls-files (use git status -uall)"
expect 2 readonly-git.sh "$(bash_cmd 'git diff --no-index /dev/null .env')"  "blocks --no-index on .env"
expect 2 readonly-git.sh "$(bash_cmd 'git diff --no-index README.md CLAUDE.md')" "blocks --no-index even inside the repo"
expect 2 readonly-git.sh "$(bash_cmd 'git diff --no-ind a b')"               "blocks abbreviated --no-index"
expect 2 readonly-git.sh "$(bash_cmd 'git diff --ext')"                      "blocks abbreviated --ext-diff"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- .env')"                    "blocks diffing .env"
expect 2 readonly-git.sh "$(bash_cmd 'git show HEAD:.env')"                  "blocks showing .env from a revision"
expect 2 readonly-git.sh "$(bash_cmd 'git diff /etc/hosts README.md')"       "blocks absolute paths (implied --no-index)"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- ~/.config/stripe/config.toml')" "blocks the Stripe CLI config"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- $HOME/.config/stripe/config.toml')" "blocks variable paths"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- ../other/file')"           "blocks paths outside the repo"
expect 2 readonly-git.sh "$(bash_cmd 'git commit -am x')"                    "blocks git commit"
# Round 2: shell syntax that hides flags or paths, and revision ranges.
expect 2 readonly-git.sh "$(bash_cmd "git diff '--output=x'")"              "blocks a quoted flag (was exit 1: fail open)"
expect 2 readonly-git.sh "$(bash_cmd 'git diff "--no-index" README.md CLAUDE.md')" "blocks a double-quoted --no-index"
expect 2 readonly-git.sh "$(bash_cmd 'git diff \--no-index README.md CLAUDE.md')"  "blocks a backslash-escaped --no-index"
expect 2 readonly-git.sh "$(bash_cmd 'git diff {--no-index,README.md,CLAUDE.md}')" "blocks brace expansion"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- .en[v]')"                  "blocks a bracket glob"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- .en?')"                    "blocks a ? glob"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- src/*')"                   "blocks a * glob"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- src/../../x')"             "blocks .. inside a path"
expect 2 readonly-git.sh "$(bash_cmd 'git diff -- ..')"                      "blocks a bare .."
expect 2 readonly-git.sh "$(bash_cmd 'git show HEAD:../secret')"             "blocks .. in rev:path"
expect 0 readonly-git.sh "$(bash_cmd 'git log --oneline main..HEAD')"        "allows a main..HEAD range"
expect 0 readonly-git.sh "$(bash_cmd 'git diff HEAD~2...HEAD --stat')"       "allows a three-dot range"
expect 2 readonly-git.sh "$(bash_cmd 'git checkout -- .')"                   "blocks git checkout"
expect 2 readonly-git.sh "$(bash_cmd 'git -c diff.external=sh diff')"        "blocks git -c config overrides"
expect 2 readonly-git.sh "$(bash_cmd 'git diff --output=out.txt')"           "blocks git diff --output"
expect 2 readonly-git.sh "$(bash_cmd 'git diff > out.txt')"                  "blocks redirects"
expect 2 readonly-git.sh "$(bash_cmd 'git diff && touch x')"                 "blocks compound commands"
expect 2 readonly-git.sh "$(bash_cmd 'git diff $(touch x)')"                 "blocks command substitution"
expect 2 readonly-git.sh "$(bash_cmd 'cat src/main/App.java')"               "blocks non-git commands"

echo "-- post-edit-check.sh (stub mvn; exit code from STUB_MVN_EXIT)"
stub_bin=$(mktemp -d "$repo/.stub.XXXX")
cat > "$stub_bin/mvn" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_MVN_SLEEP:-}" ]] && sleep "$STUB_MVN_SLEEP"
echo "[ERROR] Tests run: 3, Failures: 1 -- OrderServiceTest.rejectsDisabledReseller"
echo "[ERROR] key in output: sk_test_abc123DEF whsec_xyz789"
exit "${STUB_MVN_EXIT:-0}"
STUB
chmod +x "$stub_bin/mvn"
java_file="$repo/src/main/java/App.java"
export PATH="$stub_bin:$PATH"

export STUB_MVN_EXIT=1
expect 0 post-edit-check.sh "$(edit Edit "$java_file")"            "skips when there is no pom.xml yet"
touch "$repo/pom.xml"
expect 0 post-edit-check.sh "$(edit Edit "$repo/README.md")"       "skips non-Java files"
expect 0 post-edit-check.sh "$(edit Edit "$repo/.claude/x.java")"  "skips Java files outside src/"
expect 2 post-edit-check.sh "$(edit Edit "$java_file")"            "reports failing unit tests back to Claude"

err=$(CLAUDE_PROJECT_DIR=$repo bash "$hooks_dir/post-edit-check.sh" <<<"$(edit Edit "$java_file")" 2>&1 >/dev/null)
if [[ "$err" == *rejectsDisabledReseller* && "$err" != *sk_test_abc* && "$err" != *whsec_xyz* ]]; then
  pass=$((pass + 1)); echo "PASS  failure output reaches Claude with keys redacted"
else
  fail=$((fail + 1)); echo "FAIL  failure output reaches Claude with keys redacted"
fi

export STUB_MVN_EXIT=0
expect 0 post-edit-check.sh "$(edit Edit "$java_file")"            "passes when format and tests succeed"

# A slow run must be reported as a timeout, not die silently when Claude Code kills the hook.
start=$SECONDS
err=$(STUB_MVN_SLEEP=10 POST_EDIT_BUDGET_SECONDS=1 CLAUDE_PROJECT_DIR=$repo \
  bash "$hooks_dir/post-edit-check.sh" <<<"$(edit Edit "$java_file")" 2>&1 >/dev/null)
code=$?
if [[ $code == 2 && "$err" == *"timed out"* && $((SECONDS - start)) -lt 5 ]]; then
  pass=$((pass + 1)); echo "PASS  reports a timeout (exit 2) when Maven exceeds the budget"
else
  fail=$((fail + 1)); echo "FAIL  reports a timeout (exit 2) when Maven exceeds the budget (exit $code, $((SECONDS - start))s)"
fi
unset STUB_MVN_EXIT

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
