#!/usr/bin/env bash
# Tests for guard-git.sh — the PreToolUse git guard.
# Run: bash .claude/hooks/guard-git.test.sh   (exits non-zero if any case fails)
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard-git.sh"
pass=0; fail=0

# Feed a command to the guard and echo "allow" or "deny".
decide() {  # decide <cmd>
  local out
  out="$(jq -cn --arg c "$1" '{tool_input:{command:$c}}' | bash "$HOOK")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then echo deny; else echo allow; fi
}

# Same, but run inside a given directory (for cases that inspect git state).
decide_in() {  # decide_in <dir> <cmd>
  local out
  out="$(cd "$1" && jq -cn --arg c "$2" '{tool_input:{command:$c}}' | bash "$HOOK")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then echo deny; else echo allow; fi
}

# Build a temp repo where origin/main == base, then HEAD is one commit ahead
# touching the given files. With no args, HEAD == origin/main (nothing ahead).
make_repo_ahead() {  # make_repo_ahead [files...]
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email t@t.t; git config user.name t
    mkdir -p docs; echo base > docs/SESSION_LOG.md; echo base > app.py
    git add -A; git commit -qm base
    git update-ref refs/remotes/origin/main HEAD
    local f
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo change >> "$f"; done
    [ "$#" -gt 0 ] && { git add -A; git commit -qm ahead; }
  ) >/dev/null 2>&1
  echo "$d"
}

check() {  # check <expected> <actual> <label>
  if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   - $3";
  else fail=$((fail+1)); echo "FAIL - $3 (expected $1, got $2)"; fi
}

# --- stateless cases (independent of cwd git state) ---
check deny  "$(decide 'git status')"                                "raw git denied without marker"
check allow "$(decide 'CLAUDE_GIT_OK=1 git status')"                "marker allows ordinary git"
check allow "$(decide 'CLAUDE_GIT_OK=1 git push -u origin feature-x')" "push to a non-main branch allowed"

# --- the SESSION_LOG push exception (needs real git state) ---
r_journal="$(make_repo_ahead docs/SESSION_LOG.md)"
r_code="$(make_repo_ahead app.py)"
r_mixed="$(make_repo_ahead docs/SESSION_LOG.md app.py)"

check allow "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push origin main')" "journal-only push to main allowed (with marker)"
check deny  "$(decide_in "$r_journal" 'git push origin main')"                 "journal-only push to main denied without marker"
check deny  "$(decide_in "$r_code"    'CLAUDE_GIT_OK=1 git push origin main')" "code-file push to main denied"
check deny  "$(decide_in "$r_mixed"   'CLAUDE_GIT_OK=1 git push origin main')" "journal+code push to main denied"

# --- security hardening: the exception applies ONLY to the literal `git push origin main`/`HEAD:main`
#     form, so a different refspec/flag can't smuggle code to main while the diff check sees the journal ---
check allow "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push origin HEAD:main')"          "journal-only push via HEAD:main allowed"
check deny  "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push origin topic:main')"          "non-HEAD source refspec to main denied"
check deny  "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push origin refs/heads/main')"     "refs/heads/main form denied"
check deny  "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push --force origin main')"        "force push to main denied"
check deny  "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git -C . push origin main')"           "git -C push to main denied"
check deny  "$(decide_in "$r_journal" 'CLAUDE_GIT_OK=1 git push origin main && echo pwned')"  "compound command with journal push denied"

rm -rf "$r_journal" "$r_code" "$r_mixed"

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
