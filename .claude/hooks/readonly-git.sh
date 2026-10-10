#!/usr/bin/env bash
# PreToolUse hook for Bash, registered in the payments-reviewer subagent's
# frontmatter. Keeps the reviewer read-only and away from secrets.
# Strict allowlist: only git diff/status/log/show, only the flags listed
# below, and only plain arguments (no quotes, escapes, globs, braces or
# variables, so the shell can't turn an argument into something else)
# naming paths inside the repo that aren't .env files.
# Exit 2 blocks the tool call; stderr is shown to the reviewer as the reason.
# Any other failure is turned into exit 2 too: this hook never fails open.
set -euo pipefail

trap 'rc=$?; if ((rc != 0 && rc != 2)); then echo "BLOCKED by readonly-git.sh: internal error (exit $rc), blocking to be safe." >&2; exit 2; fi' EXIT

block() {
  echo "BLOCKED by readonly-git.sh: $1 The payments-reviewer may run only git diff/status/log/show with basic flags on plain paths inside the repo; use the Read/Grep/Glob tools for anything else." >&2
  exit 2
}

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) \
  || block "could not parse the hook input."

# Plain characters only. No quotes, backslashes, globs, braces, variables,
# operators or newlines: what the hook checks is exactly what git receives.
plain_re='^[A-Za-z0-9 ._/:@^~=-]+$'
[[ "$cmd" =~ $plain_re ]] || block "'$cmd' contains characters outside the plain set [A-Za-z0-9 ._/:@^~=-]."

read -ra args <<<"$cmd"
[[ "${args[0]:-}" == git ]] || block "'${args[0]:-}' is not git."

# `git <subcommand>` comes first, so options like -c or -C can't precede it.
sub=${args[1]:-}
case "$sub" in
  diff)   flags="--stat --shortstat --numstat --name-only --name-status --cached --staged --no-color" ;;
  status) flags="--porcelain --short -s --branch -b --untracked-files=all -uall --no-color" ;;
  log)    flags="--oneline --stat --name-only --name-status --patch -p --reverse --decorate --no-color -n" ;;
  show)   flags="--stat --name-only --name-status --no-patch --oneline --no-color" ;;
  *)      block "'git $sub' is not on the read-only list." ;;
esac

# A path must stay inside the repo and avoid secrets. Revision ranges such as
# main..HEAD are fine; `..` is refused only as a path segment.
check_path() {
  local p=$1
  [[ -n "$p" ]] || return 0
  if [[ "$p" == /* || "$p" == "~"* ]]; then
    block "'$1' points outside the repo."
  fi
  if [[ "$p" == .. || "$p" == ../* || "$p" == */.. || "$p" == */../* ]]; then
    block "'$1' points outside the repo."
  fi
  local name=${p##*/}
  if [[ "$name" == .env || ("$name" == .env.* && "$name" != .env.example) ]]; then
    block "'$1' is a secrets file."
  fi
}

after_dashdash=0
for arg in "${args[@]:2}"; do
  if ((!after_dashdash)) && [[ "$arg" == -- ]]; then
    after_dashdash=1
  elif ((!after_dashdash)) && [[ "$arg" == -* ]]; then
    [[ " $flags " == *" $arg "* || "$arg" =~ ^-U[0-9]+$ || "$arg" =~ ^-[0-9]+$ ]] \
      || block "flag '$arg' is not on the allowlist for git $sub."
  else
    check_path "$arg"
    # The path part of rev:path, e.g. HEAD:src/App.java.
    if [[ "$arg" == *:* ]]; then check_path "${arg#*:}"; fi
  fi
done

exit 0
