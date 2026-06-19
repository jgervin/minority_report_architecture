# Temporal Display Orchestration (Design)

**Date:** 2026-06-17
**Status:** Approved by owner (brainstorming session 2026-06-17)
**Repos affected:** `mras-composer` (new orchestrator — primary), `mras-vision` (presence
stream), `mras-display` (clip-ended event)
**Related:** builds on per-display custom ads (mras-composer PR #20) and Phase 2 perception
(tracks + `gaze`/`attending`, mras-vision). Adaptive enrollment is a **separate** spec
(`2026-06-17-adaptive-enrollment-design.md`, brainstormed next).

---

## Goal

Turn the current one-shot personalization (`recognize → one batch of clips → done`) into a
short, bounded **multi-round** sequence per identified person, fanned across the kiosk's
displays, with graceful handoff as new people are identified.

**Done means:** an identified person gets a 2-round program (opener → paired round 2) across the
displays they own; the newest identified people win displays via an even-split; a person who
finishes their program or leaves frees their displays; everything else falls back to the existing
idle shuffle. Verified by orchestrator unit tests (injected clock + fake event/render/play sinks)
plus a live walk-up trace observed in the `events` table.

## Owner decisions from the brainstorm

| Question | Decision |
|---|---|
| Continuation model | **Hybrid → bounded program.** Each identification = a guaranteed opener + one extension round, then idle. **Capped at 2 rounds — no round 3**, even if the person is still present. |
| Pacing | **Event-driven on clip-end** (kiosk emits `clip_ended` per display), **plus a duration watchdog** so a dropped WS / dead display still advances. |
| Per-round layout | **Shared opener → paired round 2.** Opener = 1 personalized render on all the owner's displays. Round 2 = 2 distinct random ads paired across displays (`A,A,B,B`), no immediate repeat. |
| Multi-person | **Even-split co-present people** (existing `DisplayAssigner` behavior preserved), **newest-wins only as the tiebreak** when active people outnumber displays. |
| Render-gap fallback | If a round's renders aren't ready at a boundary → **idle/standard**, resume personalized when ready. |
| Render strategy | **Render-ahead**: when the opener starts playing, render round 2's pair during its playback (~2×2.9s fits a ~10–15s opener). |
| Architecture | **Approach 1**: stateful `Orchestrator` in the composer; vision streams presence; kiosk emits clip-end. Composer stays the single owner of selection/assignment/render/WS state. |
| Budget-weighted split | **Deferred** — a future policy layer on top of even-split/newest-wins. |

## Core concept — the per-person program

On identification a person becomes **active** with a fixed program:

```
opener (round 0)  →  round 2 (round 1)  →  done
1 shared render      paired A,A,B,B          (drops out of the split)
on all owned         across owned
displays             displays
```

- **active(uuid)** ≝ `present(uuid)` (from the presence stream, TTL-refreshed) **AND**
  `program[uuid].round != done`.
- At each decision point, displays are **even-split among active people** (reuse/extend
  `DisplayAssigner`); when active people > displays, the **newest** people win
  (ordered by first-identification time).
- A display shows its owner's **current** round. Program advancement is **per-person**: a person's
  round advances when the **first** of their displays finishes the current round (its `clip_ended`
  or watchdog). Lagging displays catch up to the person's current round at their own next clip-end.
  Displays are thus a **projection** of the owner's current round; reassignment (split change)
  applies at clip-ends, never mid-clip.
- A **done** person never replays; their displays free and remaining active people re-split and
  reclaim. No active person left → **idle** (existing shuffle).

## Architecture

```
mras-vision (native)                 mras-composer                         mras-display (kiosk)
────────────────────                 ─────────────                         ───────────────────
identify face ──/trigger──▶  IdentityResolver ─▶ Orchestrator ──play(screen,clip)──▶ display-N
present ids  ──/presence──▶  PresenceTracker ──▶   │  state: programs, present(TTL),
 (~1–2s, per camera           (TTL active-set)      │         screens{owner,now_playing,
  screen_id)                                        │         clip_ends_at}
                                                    │  DisplayAssigner (even-split, newest-wins)
                                                    │  select()/select_variants() (opener / pair)
                                                    │  render-ahead queue (single-flight sidecar)
                                          clip_ended(screen) ◀──── WS ──── kiosk
                                          + duration watchdog fallback
```

**New components (composer):**
- **`Orchestrator`** — one instance per camera screen-group (e.g. `screen_0` → `display-1..4`).
  Holds `programs{uuid→{round, name, first_seen}}`, `present{uuid→last_seen}`,
  `screens{display→{owner_uuid, now_playing, clip_ends_at}}`. Drives the loop below.
- **`PresenceTracker`** — applies presence updates, expires entries past TTL, exposes the active
  set newest-first.
- **Extend `DisplayAssigner`** — even-split the active set across displays, re-evaluated per
  boundary; newest-wins tiebreak when active > displays.
- **Extend selector** — `select()` for the opener (1 ad); `select_variants(count=2)` for round 2's
  pair, avoiding immediate repeat of the opener ad.
- **Render-ahead queue** — on opener start, enqueue the round-2 pair renders (single-flight
  sidecar, reused).

## The loop (event-driven)

- **On `/trigger` (identification):** if `uuid` has no active program (cooldown already gates this
  to ≤1 per 30s per person), start `program[uuid] = {round: opener, first_seen: now}`; mark active.
- **On `/presence`:** refresh `present` set + `last_seen`; expire past TTL (≈ 2× cadence). A
  uuid dropping out = "left."
- **On `clip_ended(display)` (or watchdog timeout):**
  1. Re-evaluate the even-split over the current active set (newest-wins tiebreak).
  2. Resolve this display's owner. If none active → `play idle`.
  3. If the owner just advanced a round (their lead clip ended): bump `program.round`
     (`opener → round 2 → done`).
  4. Render the owner's current round if needed; if ready → `play(display, clip)`; else →
     `play idle`, mark resume. `done` → free display → re-split.
- **Render-ahead:** when an opener begins playing, enqueue that owner's round-2 pair.

## Wire contracts

**Vision → Composer: `POST /presence`** (new; HTTP, like `/trigger`, low rate ~1–2s):
```json
{ "screen_id": "screen_0", "ts": "<iso8601>",
  "present": [ { "uuid": "f487…", "first_seen": "<iso8601>" } ] }
```
Only **identified** tracks (bound to a uuid) are listed. `screen_id` is the camera group.

**Kiosk → Composer: `clip_ended`** (new; over the existing kiosk WS):
```json
{ "type": "clip_ended", "screen_id": "display-2", "clip_id": "<uuid>-1.mp4", "ts": "<iso8601>" }
```

**Composer → Kiosk: `play`** (existing WS push, reused) — personalized clip per `display-N`; plus
an explicit **`idle`/resume-shuffle** message so a display deterministically returns to the
existing standard shuffle.

**Watchdog:** when the composer pushes a clip it records `clip_ends_at = now + clip_duration +
grace`. Clip durations are known from the assembler/render (or `ffprobe` on assets). If
`clip_ended` doesn't arrive by then, the orchestrator advances that display as if it had.

## Error handling / edge cases

- **Dropped WS / dead display:** duration watchdog advances; no hang.
- **Round-2 render fails:** reuse existing variant-failure fallback — that display gets a standard
  ad or idle for the round; the program still completes.
- **Identity blocked / vanished:** `select()` already degrades to standard.
- **Person leaves mid-opener:** presence TTL drops them; at the next boundary their displays
  re-split/idle. The in-flight render is wasted (acceptable).
- **> 4 active people:** newest 4 served; others wait for a display to free (fast under the 2-round
  cap).
- **Cooldown:** unchanged. It gates `/trigger` to ≤1 program per person per 30s; the orchestrator
  self-drives the 2 rounds (no re-triggers needed). A genuinely new person isn't under cooldown, so
  they trigger and become newest.

## Testing strategy (TDD, red→green)

**Orchestrator unit tests** (injected clock; fake render + play sinks; simulated `/trigger`,
`/presence`, `clip_ended` events):
- Solo: opener on all displays → round 2 `A,A,B,B` → done → idle. **Asserts no round 3.**
- Two co-present: even-split 2/2; each runs their own program.
- Newest-wins tiebreak when active > displays.
- Reclaim: a person finishing round 2 (or leaving via presence TTL) frees displays; remaining
  active person reclaims at the next boundary, **not mid-clip**.
- Leave via presence TTL frees displays.
- Watchdog advances a display when `clip_ended` never arrives.
- Render-gap → idle then resume when renders land.

**Other:** `DisplayAssigner` re-split + newest ordering; selector opener-vs-pair + no-immediate-
repeat; kiosk `clip_ended` emission (component test); vision `/presence` emission (unit).
**Live E2E (camera):** walk-up trace (Jason solo → +Maria → Jason leaves → all gone) observed in
the `events` table.

## v1 scope boundary

**In:** composer `Orchestrator` (2-round program, even-split, newest-wins tiebreak, render-ahead,
idle fallback, watchdog); vision `/presence` stream; kiosk `clip_ended` + composer watchdog; opener
+ paired round 2.

**Deferred (YAGNI for v1):** budget/priority-weighted split (future layer on even-split/newest-
wins); per-dwell render caching; attention-based gating (intentionally dropped); >2 rounds;
multi-camera / multiple screen-groups (design is per-group; multiple groups is a natural extension,
not built now).
