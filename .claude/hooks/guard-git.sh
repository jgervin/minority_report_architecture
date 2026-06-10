#!/usr/bin/env bash
# PreToolUse/Bash guard — keeps raw git/gh out of the main coding agent.
#
# Policy (see CLAUDE.md "Git & Branching Rules"):
#   - The main agent must NOT run git/gh directly. It delegates to the
#     git-flow-manager subagent, which opts in with the CLAUDE_GIT_OK=1 marker.
#   - Pushing to `main` is never allowed, even with the marker — merges go
#     through `gh pr merge` after review.
#
# Reads the PreToolUse hook JSON on stdin; emits a permissionDecision.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

deny() {
  # $1 = reason shown to the model
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Only police commands that actually invoke git or gh.
if ! printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|[[:space:]])(git|gh)([[:space:]]|$)'; then
  exit 0
fi

# The git-flow-manager subagent opts in by prefixing commands with this marker.
has_marker=0
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])CLAUDE_GIT_OK=1([[:space:]])'; then
  has_marker=1
fi

# Hard guard: never push to main — EXCEPT the git-flow-manager (marker) pushing nothing but the
# session journal (docs/SESSION_LOG.md) via the EXACT literal form `git push origin main` (or
# `HEAD:main`). Any other push-to-main invocation — a different/`refs/heads/` refspec, a non-HEAD
# source, --force, `git -C …`, or a compound command — is denied without consulting file contents,
# so a refspec can't smuggle code to main while the diff check only sees the journal. Push
# detection tolerates `git -C <dir>`; main detection also catches `refs/heads/main`.
if printf '%s' "$cmd" | grep -Eq 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push' \
   && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]:])(refs/heads/)?main([[:space:]]|:|$)'; then
  # Allow ONLY the exact, simple, marker-prefixed form (optionally HEAD: and -u/-q flags).
  if [ "$has_marker" = 1 ] \
     && printf '%s' "$cmd" | grep -Eq '^[[:space:]]*CLAUDE_GIT_OK=1[[:space:]]+git[[:space:]]+push([[:space:]]+(-u|--set-upstream|-q|--quiet))*[[:space:]]+origin[[:space:]]+(HEAD:)?main[[:space:]]*$'; then
    # Form is safe; confirm it actually delivers nothing but the journal.
    changed="$(git diff --name-only origin/main..HEAD 2>/dev/null || true)"
    if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -qv '^docs/SESSION_LOG\.md$'; then
      exit 0
    fi
  fi
  deny "Pushing to main is never allowed (except a docs/SESSION_LOG.md-only update via 'CLAUDE_GIT_OK=1 git push origin main'). Land changes via 'gh pr merge' after review (see CLAUDE.md Git & Branching Rules)."
fi

# Allowance: the marker opts the git-flow-manager subagent in for all other git/gh.
if [ "$has_marker" = 1 ]; then
  exit 0
fi

# Default: block raw git/gh for the main agent.
deny "Raw git/gh is disabled in this session. Delegate all Git work to the git-flow-manager subagent (.claude/agents/git-flow-manager.md) — it is the only sanctioned Git operator. Do not run git/gh yourself."
