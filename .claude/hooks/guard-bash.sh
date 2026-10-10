#!/usr/bin/env bash
# PreToolUse hook for Bash. Backs up the Bash deny rules in settings.json,
# which only match the literal command text (so `git -C . push` or `/bin/rm -rf`
# would slip past them). Blocks:
#   - live Stripe keys anywhere, and --live on stripe commands
#   - git push in any form (Matt pushes)
#   - rm with both recursive and force flags
#   - stripe CLI calls without the sandbox profile (--project-name connect-prototype)
# Exit 2 blocks the tool call; stderr is shown to Claude as the reason.
# This is a denylist on command text, not a sandbox.
set -euo pipefail

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

# Check each simple command separately. Quoted strings are dropped first so
# words inside a commit message (e.g. "push fix") don't trigger a block.
stripped=$(sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" <<<"$cmd")
segments=$(awk '{ gsub(/&&|\|\||[;&|]/, "\n"); print }' <<<"$stripped")

while IFS= read -r seg; do
  # Drop leading whitespace and VAR=value assignments.
  seg=$(sed -E 's/^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*//' <<<"$seg")
  [[ -n "$seg" ]] || continue
  prog=$(basename "${seg%% *}")

  case "$prog" in
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
      if [[ ! " $seg " =~ [[:space:]](--project-name[[:space:]=]|-p[[:space:]])connect-prototype[[:space:]] ]]; then
        block "Stripe CLI commands must use the sandbox profile. Add --project-name connect-prototype."
      fi
      ;;
  esac
done <<<"$segments"

exit 0
