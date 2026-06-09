# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 0. Always Reference Files by Absolute Path

**Whenever you mention a file — in chat, plans, specs, PRs, commit messages, code comments, or
docs — use its full absolute path** (e.g. `/Users/jn/code/mras-overlays/examples/HelloName.tsx`),
never a bare name like `HelloName.tsx`. The reader should never have to search for where a file
lives. This applies to every session, skill, and agent.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## 5. Session Continuity — Maintain the Session Log

**This project spans 5 repos and is demoed live; sessions die to reboots and `/clear`. Persist context.**

`docs/SESSION_LOG.md` is the cross-repo engineering journal and source of truth for "what happened"
and "how to run it." **This is mandatory for every session, skill, and agent working on MRAS:**

- **At session start:** read `docs/SESSION_LOG.md` (top-to-bottom), `TODOS.md`, and
  `adface_architecture.md` before acting.
- **At session end, or before any likely reboot / `/clear`:** prepend a new dated entry following
  the template in that file (changes with `repo@sha`, learnings/gotchas, state). Newest first.
- **Keep the "Operational Reference" section current** whenever run steps, ports, topology, or
  gotchas change.
- Flag working-tree-only (uncommitted) changes as such; always cite `repo@sha` for committed work.

If you finish meaningful work without updating the log, you have not finished.

---

## 6. Development Workflow — Branch · TDD · Review · PR · Issues

**Standard software-development process. Applies to every MRAS repo and to every session, skill,
and agent. Use the Superpowers skills named below — invoke them, don't approximate them.**

**Per task:**
1. **Isolate the work.** Create a dedicated branch or git worktree — never implement on `main`.
   (`superpowers:using-git-worktrees`)
2. **TDD, red → green → refactor.** Write a failing test *first and watch it fail*, then make it
   pass, then refactor with tests green. (`superpowers:test-driven-development`)
3. **Request code review between tasks.** Get review before moving to the next task.
   (`superpowers:requesting-code-review`, `superpowers:receiving-code-review`)
4. **Finish the branch cleanly.** Run the close-out checklist before considering work shippable.
   (`superpowers:finishing-a-development-branch`)

**GitHub integration:**
- Push commits to the task branch on the remote.
- Open a **Pull Request per completed task batch**.
- After the PR's review is resolved and merged, file any **remaining unchecked plan items as
  GitHub issues** so nothing falls off the plan.

**Definition of Done — do NOT mark a task complete unless ALL of these hold:**
- A test **failed first, then passed** (red→green proven by running it, not assumed).
- The branch is **review-ready**: diff scoped to the task, no stray changes, review requested/resolved.

If the test didn't fail first, you don't have a real test, and the task is not done.

---

# Git & Branching Rules (for Claude)

## Absolutes
- **Never run raw Git operations as the "main" coding agent.** Delegate all Git work to the `git-flow-manager` subagent (`.claude/agents/git-flow-manager.md`) — the main agent must not invoke `git` directly. This prevents agents from stepping on each other's branches and accidentally touching `main`.
- **Use one Git worktree per ticket** so each session is isolated and Git state is deterministic. Claude Code has first-class worktree support — start the ticket session with the worktree flag (`--worktree` / `-w`); do not reuse a worktree across tickets.
  - Example: starting `claude -w feat/TKT-1234-delete-ads` creates a worktree at `.claude/worktrees/feat-TKT-1234-delete-ads/`.
- Never commit or merge directly to `main`.
- All work happens on ticket branches created from `main`.
- Branch naming: `{type}/{ticket}-{slug}`, where type ∈ {feat, fix, chore}.
  - Example: `feat/TKT-1234-delete-ads`.

## Ticket lifecycle (MUST follow in order)
1. When I say: `start ticket TKT-1234 delete ads`, do:
   - Create or use a worktree for this ticket from `main`.
   - Create a branch `feat/TKT-1234-delete-ads` in that worktree.
   - Ensure this session is **locked** to that worktree/branch.

2. While implementing:
   - Make **small, atomic commits** with Conventional Commit style messages.
   - Run tests before opening a PR using the repo's test command.

3. When I say: `open PR for this ticket`:
   - Push the branch.
   - Open a PR targeting `main`.
   - Use a structured PR description:
     - Summary
     - Motivation / context
     - Implementation details
     - Tests
     - Risks / rollout

4. Before you ask me to merge:
   - Perform a **self-review** on the PR.
   - List any concerns or potential regressions.

5. When I say: `finish ticket TKT-1234`:
   - If PR is approved and checks are green:
     - Merge the PR into `main`.
     - Delete the remote branch.
     - Delete the local worktree and branch.
     - Fetch and fast-forward local `main`.
   - If PR is not mergeable, tell me why and do not merge.

## Stacked PRs / Dependencies
- If a ticket depends on another ticket's branch:
  - Explicitly indicate the parent branch in PR description.
  - Do NOT merge parent PRs unless I explicitly say: `finish stack root for TKT-xxxx`.
- When I say "merge" without specifying PR:
  - Ask which PR number and show the base branch to avoid ambiguity.