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