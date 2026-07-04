# Handoff — Display Peel-Back Orchestration Spec (2026-07-03)

> **For the next (Fable) session.** The task: make the composer's display orchestration play a
> recognized person's ad on **all displays in their camera-area, then back off to half, then stop.**
> Companion: `/Users/jn/code/minority_report_architecture/docs/handoff-02-session-state.md`
> (what's committed, how to run the live E2E). This is a **composer-orchestrator** task, independent of
> the now-validated God View data pipeline.

## 1. Product behavior (from the owner, verbatim intent)

**Venue model (multi-tenant).** A venue is a mall + independent stores, each with its **own MRAS
system** (its own displays + cameras). Examples the owner gave:
- Mall: ~8 displays in the main walkways, scattered, plus 1 at each of 4 entrances.
- Gap: 4–8 displays through the store. Apple: 4. Victoria's Secret: 6.
- Each org runs 4–20 cameras for its MRAS system.

**Area = the displays tied to the camera(s) near where the person is standing** when we compose and play
their ad. When a person is recognized at a camera, the composed ad plays on **all available displays in
that camera's area.**

**Peel-back (the behavior to build):**
1. **Round 1 (opener):** play on **all N displays in the person's area** (all at once, same composed ad).
2. **Round 2:** back off to **half** the original count — `4→2`, `2→1`, `6→3` — and play the person's
   **named** ad (name mentioned + shown) on those.
3. **Then stop** (free those displays for other/new people; respect the existing cooldown).

**Explicitly deferred (do NOT build now, but design so it can be added):** *move-redistribution.* Later,
when a person we've composed for **moves** to a different area, the **already-composed** video should
follow them onto the new area's screens — **not** recomposed. Not this increment; likely next.

## 2. Current implementation (accurate map — read before changing)

**`/Users/jn/code/mras-composer/src/orchestrator/core.py`** (state machine; verified 2026-07-03 at
worktree `feat-composer-emission`). The `Orchestrator` is constructed with a **flat display list**
(`displays: list[str]`, e.g. `["display-1", "display-2", "display-3", "display-4"]`) and holds
per-subject `_Program` (with a `Round`) and per-display `_Screen` (owner, round, playing).

- `Round` enum + helpers live in `/Users/jn/code/mras-composer/src/orchestrator/model.py`:
  `Round.OPENER → Round.ROUND2 → Round.DONE`; `next_round(r)`; `even_split(subjects, displays) →
  {display: owner}`; `pair_slot(disp, sorted_owned) → 0|1`.
- `on_identify(uuid, screen_id)` (core.py:37) — (re)creates the subject's `_Program` at `OPENER`, stamps
  the **triggering camera `screen_id`**, marks present, calls `_reassign()`.
- `on_clip_ended(display)` (core.py:48) — marks the screen idle; **the first display of an owner to
  finish the current round advances that owner's round** (`OPENER → ROUND2 → DONE`); re-assigns.
- `_reassign()` (core.py:82) — the core: `even_split(active_newest_first, self._displays)` divides
  **ALL configured displays** among active subjects (newest-first). For each display:
  - **OPENER** → `slot 0`: one shared render on **every owned display**.
  - **ROUND2** → `pair_slot(...)`: splits the owner's displays into an **A/B pair** (slot 0 / slot 1) —
    **still across ALL the owner's displays**, just two variants.
  - Emits `Play(disp, owner, round, slot, camera_screen_id)`; on OPENER also queues one
    `RenderAhead(owner, ROUND2, …)` per owner.
- When a subject reaches `DONE`, `_active_newest_first()` (core.py:77) drops it → its displays go `Idle`
  or are reassigned to other present subjects. This is the existing **"make room for new people"**
  behavior (`even_split` favors newest subjects).

**Round advance is clip-driven and paced correctly.** The display (mras-display PR #13,
`feat-display-echo`, `src/App.tsx`) sends `{type:"clip_ended", screen_id, clip_id}` on the HTML5 video
`ended` event; Electron sets `screen_id=display-<n>` (`electron/main.js:59`). Composer `main.py:~408`
routes that to `on_clip_ended`. A watchdog (`main.py:~150`, `CLIP_SECONDS` default **30** + `WATCHDOG_GRACE_S`
default **5** = 35s) is only a fallback; clips are ~8s (`standard.mp4` = 8.09s), so the real `clip_ended`
drives the advance. **Timing is not the problem.**

## 3. The gap (what's wrong vs the desired behavior)

Observed in the 2026-07-03 live run (1 person, 4 displays):
- **Round 1** → all 4 displays, same opener clip. ✅ matches desired.
- **Round 2** → **still all 4 displays** (A/B pair split), NOT peeled to 2. ❌
- No explicit "stop to 2 then done" — round 2 fills all displays, then `DONE` frees them.

Two things are missing:
1. **Display-count-per-round doesn't reduce.** ROUND2 keeps all of the owner's displays (as an A/B pair)
   instead of dropping to `floor(N/2)` and idling the rest.
2. **No area scoping.** `_reassign` uses the flat `self._displays` (the whole `DISPLAY_COUNT`), with no
   notion of "the displays in the triggering camera's area." For a real venue with multiple
   areas/systems, the opener must target only the area where the person was seen (`_Program.screen_id`
   already carries the triggering camera — the join key you need).

## 4. What to build (this increment)

**A. Area model — camera → displays.** Introduce "which displays are in a camera's area." The God View
device registry already has `cameras` and `displays` under a `system` (unique `screen_id`), but **no
camera↔display area grouping.** Decide where the mapping lives (see open questions) and give the
orchestrator a way to resolve, for a triggering camera `screen_id`, the set of display `screen_id`s in
that area. Scope the opener to those displays, not the global list.

**B. Peel-back round logic.** Change the round sequence so:
- `OPENER` → all `N` area displays (unchanged in spirit).
- `ROUND2` → exactly `floor(N/2)` of those displays (`4→2`, `2→1`, `6→3`), playing the named ad; idle
  the other `N − floor(N/2)`.
- Then `DONE` → free all. (There is no round 3.)
This is a change to `_reassign()` and likely `model.py` (`even_split`/`pair_slot`/a new "half" helper).

**C. Keep it testable.** `Orchestrator` is a pure state machine with an injectable `clock` — unit-test
the peel-back with a fake clock and asserted `Play`/`Idle` command sequences (TDD red→green). Then prove
it live with the E2E harness (see the state-handoff doc). **Do a live Playwright/Electron E2E — do not
rely on unit green alone** (the God View work shows unit-green ≠ integration-green).

## 5. Open design questions (resolve with the owner before/while building)

1. **Where does the camera→display area mapping live?** Options: a `zone_id`/`area_id` column on both
   `cameras` and `displays` (area = same zone within a system); a `camera_displays` join table; or config
   passed to the composer at startup. The orchestrator currently gets a flat `displays` list from
   `DISPLAY_COUNT` — moving to area-scoped displays is the central change.
2. **Which half in round 2?** Owner said "half the original number." Which specific displays — the 2
   nearest the person (needs position/adjacency), the first 2 deterministically, or a defined subset?
   (Nearest-to-person overlaps with the deferred move-redistribution — a position model would serve both.)
3. **Odd N rounding.** `4→2, 2→1, 6→3` are all `floor(N/2)`. Confirm `floor` for odd N (e.g. `5→2`) or
   `ceil`/other.
4. **"Stop" semantics.** After round 2 ends: go idle/standard content on those displays; free them for
   other people (the existing `even_split` newest-first reassignment already does this on `DONE`);
   respect the Redis cooldown (`cooldown:<camera_screen_id>:<subject_id>`, TTL 120s) so the same person
   isn't immediately re-triggered.
5. **Multi-subject interaction.** `even_split` already divides displays among multiple concurrent
   subjects (newest-first). Define how peel-back composes with that: if a new person appears mid-sequence,
   how do the area's displays split between the existing peel-back and the newcomer's opener?
6. **Multi-area / multi-system at once.** The current `Orchestrator` is a single flat display list. A
   venue has many areas/systems. Decide: one orchestrator per area/system, or one orchestrator that is
   area-aware. This shapes A.
7. **Deferred move-redistribution.** Not now — but choose the area/position model (Q1/Q2) so a moving
   person's already-composed clip can later follow them to a new area's screens without recompose.

## 6. Files & entry points

- `/Users/jn/code/mras-composer/src/orchestrator/core.py` — the state machine (map above).
- `/Users/jn/code/mras-composer/src/orchestrator/model.py` — `Round`, `even_split`, `next_round`,
  `pair_slot` (read this next; the round-count math lives here).
- `/Users/jn/code/mras-composer/src/orchestrator/commands.py` — `Play`, `Idle`, `RenderAhead`.
- `/Users/jn/code/mras-composer/main.py` — `trigger_endpoint` (~276), WS handler + `on_clip_ended`
  routing (~408), watchdog `_fire_clip_ended` (~150), presence handling (~216/408).
- Device registry (for the area model): `mras-ops` `cameras` / `displays` / `systems` tables
  (migrations under `/Users/jn/code/mras-ops/db/migrations/`, latest applied 019–023).
- Display echo (clip_ended source): `/Users/jn/code/mras-display/src/App.tsx` (`handleEnded`),
  `electron/main.js:59` (per-window `screen_id`).

## 7. Constraints (project rules — non-negotiable)

- **No legal / no legal-review content.** Biometric-privacy machinery + the blocklist are **deferred
  until the production go-live announcement** — do not build them now.
- **Git only via the `git-flow-manager` subagent.** The main agent must not run raw `git`/`gh` (a hook
  blocks it in all 5 repos). Work on a dedicated worktree/branch, never on `main`. Open a PR per task.
- **TDD, red→green proven in git history** (commit the failing test separately, or prove RED before
  GREEN). A test that didn't fail first is not a real test.
- **Always reference files by absolute path** (chat, commits, PRs, docs).
- **Update `docs/SESSION_LOG.md`** before any likely reboot/`/clear` (prepend a dated entry, newest
  first; keep the Operational Reference current).
- **Run a live E2E** (Playwright MCP / live Electron) in red→green — unit tests miss integration and
  stale-container breakage. See the state-handoff doc for the worktree harness.

## 8. First moves for the new session

1. Read this doc + the state-handoff doc + `docs/SESSION_LOG.md` (2026-07-03) + `TODOS.md` +
   `adface_architecture.md`.
2. Read `src/orchestrator/model.py` and `core.py` together; confirm the OPENER→ROUND2→DONE map above.
3. Resolve the open design questions (§5) with the owner — especially Q1 (where the area mapping lives)
   and Q2 (which half), since they gate everything.
4. Write the plan (superpowers `writing-plans`), then execute TDD on a new worktree/branch off the
   composer's `feat/composer-emission` (or `main` if that stack has merged by then).
5. Prove it live with the E2E harness, then PR.
