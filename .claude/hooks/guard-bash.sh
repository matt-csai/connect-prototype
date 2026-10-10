#!/usr/bin/env bash
# PreToolUse hook for Bash. Backs up the Bash deny rules in settings.json,
# which only match the literal command text (so `git -C . push` or `/bin/rm -rf`
# would slip past them). Blocks:
#   - live Stripe keys anywhere, and --live on stripe commands
#   - commands naming .env/.env.* (not .env.example) or ~/.config/stripe,
#     and `stripe config` (it can print stored keys)
#   - git push in any form (Matt pushes)
#   - rm with both recursive and force flags
#   - stripe CLI calls without the sandbox profile (--project-name connect-prototype)
#   - env / printenv (they dump the environment, keys included)
# Exit 2 blocks the tool call; stderr is shown to Claude as the reason.
# Any other failure is turned into exit 2 too: this hook never fails open.
# This is a denylist on command text, not a sandbox: globs, escapes and
# quoting can still hide a path (see Limits in CLAUDE.md).
set -euo pipefail

trap 'rc=$?; if ((rc != 0 && rc != 2)); then echo "BLOCKED by guard-bash.sh: internal error (exit $rc), blocking to be safe." >&2; exit 2; fi' EXIT

block() {
  echo "BLOCKED by guard-bash.sh: $1" >&2
  exit 2
}

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) \
  || block "could not parse the hook input, so the command is blocked to be safe."

if [[ "$cmd" == *sk_live_* ]]; then
  block "the command contains a live Stripe key prefix (sk_live_). This project is test mode only."
fi

# Drop heredoc bodies that are only data: a quoted heredoc (<<'EOF', so bash
# expands nothing) that ends its line and feeds `git commit` or `cat > file`.
# Commit messages and NOTES.md entries can then mention .env or `stripe
# config`. A heredoc fed to anything else (bash, python3, `| bash`) is still
# checked line by line, as is an unquoted heredoc, where $(...) would run.
checked=$(awk -v q="'" '
  skip { if ($0 ~ ("^[[:space:]]*" delim "[[:space:]]*$")) skip = 0; next }
  { print }
  match($0, "(^|[^<])<<-?[[:space:]]*[\"" q "][A-Za-z_][A-Za-z0-9_]*[\"" q "][[:space:]]*$") {
    marker = substr($0, RSTART, RLENGTH)
    pre = substr($0, 1, RSTART + RLENGTH - 1)
    sub("<<-?[[:space:]]*[\"" q "][A-Za-z_][A-Za-z0-9_]*[\"" q "][[:space:]]*$", "", pre)
    n = split(pre, parts, /&&|\|\||;|\|/)
    last = parts[n]; sub(/^[[:space:]]+/, "", last); sub(/[[:space:]]+$/, "", last)
    if (last ~ /^git commit([[:space:]]|$)/ || last ~ /^cat[[:space:]]*>>?[[:space:]]*[^[:space:]<>|;&]+$/) {
      delim = marker; sub(/^.*<</, "", delim); gsub("[-\"" q "[:space:]]", "", delim); skip = 1
    }
  }' <<<"$cmd")

# Secrets on disk: .env files (except .env.example) and the Stripe CLI config,
# which holds the sandbox key after `stripe login`. Quote characters are
# removed but their contents kept, so `cat ".env"` matches. A .env name must
# end at a word boundary, so .envrc and .environment are not matched.
secrets_text=$(tr -d "\"'" <<<"$checked")

if [[ "$secrets_text" == *.config/stripe* ]]; then
  block "the command touches ~/.config/stripe, where the Stripe CLI stores its keys."
fi
names=$(grep -oE '(^|[^[:alnum:]_.-])\.env(\.[[:alnum:]_.-]+)?([^[:alnum:]_-]|$)' <<<"$secrets_text" \
  | sed -E 's/^[^.]*//; s/[^[:alnum:]_.-]$//' || true)
while IFS= read -r name; do
  if [[ -n "$name" && "$name" != .env.example ]]; then
    block "the command touches $name, a secrets file. Keys live only in your local .env, which Claude never reads. Use .env.example for placeholders."
  fi
done <<<"$names"

# Check each simple command separately. Quoted strings are dropped first so
# words inside a commit message (e.g. "push fix") don't trigger a block.
stripped=$(sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" <<<"$checked")
segments=$(awk '{ gsub(/&&|\|\||[;&|]/, "\n"); print }' <<<"$stripped")

while IFS= read -r seg; do
  # Drop leading whitespace and VAR=value assignments.
  seg=$(sed -E 's/^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*//' <<<"$seg")
  [[ -n "$seg" ]] || continue
  first=${seg%% *}
  prog=${first##*/}

  case "$prog" in
    env | printenv)
      block "$prog is not allowed: it prints the environment, which holds the Stripe keys once the app runs."
      ;;
    git)
      if [[ " $seg " =~ [[:space:]]push[[:space:]] ]]; then
        block "git push is not allowed. Matt reviews and pushes."
      fi
      ;;
    rm)
      if [[ " $seg " =~ [[:space:]](-[[:alpha:]]*[rR][[:alpha:]]*|--recursive)[[:space:]] \
         && " $seg " =~ [[:space:]](-[[:alpha:]]*f[[:alpha:]]*|--force)[[:space:]] ]]; then
        block "recursive force delete (rm -rf) is not allowed. Remove specific files, or ask Matt."
      fi
      ;;
    stripe)
      if [[ " $seg " =~ [[:space:]]--live([[:space:]=]) ]]; then
        block "--live is not allowed. This project uses the Stripe sandbox in test mode only."
      fi
      if [[ " $seg " =~ [[:space:]]config[[:space:]] ]]; then
        block "stripe config is not allowed: it can print the stored API keys."
      fi
      if [[ ! " $seg " =~ [[:space:]](--project-name[[:space:]=]|-p[[:space:]])connect-prototype[[:space:]] ]]; then
        block "Stripe CLI commands must use the sandbox profile. Add --project-name connect-prototype."
      fi
      ;;
  esac
done <<<"$segments"

exit 0
