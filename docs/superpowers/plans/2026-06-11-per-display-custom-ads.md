# Per-Display Custom Ads + Multi-Face — owner demo spec (2026-06-11)

## Context

Phase 1 core (T-D multi-display kiosk, T1 Redis cooldown + atomic claim, T2 burst queue,
T3 watchdog) is **done and merged**. Owner now wants the per-display milestone T-D left a
forward hook for, with **distinct custom Remotion ad compositions** per display:

- **Demo 1 (one person):** camera identifies the owner ("Jason") → the 4 kiosk displays each
  play a **different composer-generated custom-Remotion ad**, all personalized "Jason".
- **Demo 2 (two people):** a second person is enrolled (image + name); both stand in frame →
  2 displays play ads for Jason, 2 for the other person.
- **Tooling:** an easy CLI to enroll a new person (image + name → Qdrant + Postgres), and a
  CLI that composes a random base video × a random ready Remotion component.

**T0/TODO-5 (ffmpeg latency benchmark) is ON HOLD (owner, 2026-06-11):** the current
single-host software-encode architecture is not the production shape, so benchmarking it
proves nothing. **Production target (recorded for T4-era planning):** real-time PARALLEL
composition — ~4 people identified per area, each served a personalized ad in <4s (target
2s), 1–4 areas per location, ~1000 locations. That implies horizontally scalable render
capacity (GPU/edge), not a tuned single box.

## Hard blocker found in recon

`/Users/jn/code/mras-vision/src/detection/embedder.py` **raises `multiple_faces` on the live
path** when >1 face is in frame, and the camera loop skips the frame — with two people
visible, NOTHING triggers. Demo 2 is impossible until T-V lands. (The one-face rule is
correct for enrollment photos and stays there.)

## Long-term perception architecture (owner direction — build the seam, not the system)

Target capability (Phase 2+): per face, within a time budget, know identity, demographics,
apparel/colors, objects held, movement direction — e.g. "White male, ~21, green shirt,
holding a drink, walking left" — and select/compose the ad from that. Decisions:

- **Pattern: Strategy + registry, scatter-gather with deadline.** Each perceiver is an
  `Analyzer` (one small interface). An aggregator fans registered analyzers out
  concurrently with a budget (~800ms), merges whatever completed into `scene_context`,
  and DROPS laggards — identity alone gates personalization; the rest is enrichment.
  This is how the <4s budget holds at N analyzers.
- **The wire seam already exists:** D9 puts `scene_context` in every P1→P2 trigger payload
  (Phase 0 `{}`); P1-C5 is the reserved architecture box. No protocol change ever needed.
- **The genuinely hard future part is face TRACKING** ("30–60 frames to decide" = a track-id
  accumulating evidence across frames). The aggregator should take a *track* when that
  lands; today it is frame-shaped but isolated behind the one interface so the swap is
  contained in `src/perception/`.
- **Built NOW:** `src/perception/aggregator.py` with the `Analyzer` protocol +
  deadline-gather, registry EMPTY (returns `{}` — zero behavior change). No speculative
  analyzers (CLAUDE.md §2); the seam is what the owner ordered.

## Tickets (order: T-V → T-C → T-E → T-R, then the live demo test)

### T-V — multi-face live resolution + perception seam · repo: `mras-vision`
1. `embed_all(frame) -> list[embedding]` on the Embedder (live path; `embed()` + its
   one-face rejection stays for enrollment).
2. Camera pipeline resolves EVERY face; each resolution goes through the atomic cooldown
   claim + T2 queue independently (that infra is why this is now safe).
3. `resolver.resolve(embedding, faces_in_frame=N, scene_context=None)`; payload gains
   `faces_in_frame` (composer uses it for display splitting) and forwards scene_context
   (still `{}`).
4. `src/perception/aggregator.py` (protocol + deadline-gather, tested; empty registry
   wired in `main.py`).
**TDD:** red = embed_all multi-rep test (mock DeepFace), pipeline test (2 faces → 2
resolves with faces_in_frame=2), aggregator tests (merge, drop-slow, drop-failed,
empty-registry → {}).

### T-C — per-display distinct custom-ad variants · repo: `mras-composer`
1. `WSManager` tracks `screen_id` per client (parse `/ws?screen_id=...`; T-D hook),
   gains `send_to(screen_id, msg)` + `screen_ids()`; broadcast kept for back-compat.
2. Display assignment (`src/display_assignment.py`, pure + tested): split connected
   displays evenly by `faces_in_frame` (`per_person = max(1, n // faces)`), short-lived
   reservations (TTL ≈ clip length) so near-simultaneous triggers don't collide; alone →
   all displays.
3. `/trigger` identified path: select up to `len(assigned)` **distinct active custom ads**
   (`selector.select_variants` — distinct component ads; cycle if fewer ads than
   displays), render + assemble **in parallel** (`asyncio.gather`), then `send_to` each
   assigned display its own clip. The D8 ffmpeg semaphore becomes per-variant concurrency
   (`FFMPEG_CONCURRENCY`, default 4) per the owner's real-time-parallel direction.
4. Fallbacks: no screen_id-tagged clients → single variant + broadcast (old behavior);
   no/one active ad → same ad on all assigned displays; new visitor → unchanged.
**TDD:** red = ws targeting, assignment policy (alone→all, 2 faces→split, reservation
excludes busy), select_variants distinctness, trigger fan-out (N assembles, N targeted
sends, parallel not serial).

### T-E — enrollment CLI · repo: `mras-ops`
`./enroll.sh "Name" photo.jpg [more photos...]` → multipart POST to native vision
`POST :8001/enroll` (existing endpoint already does Qdrant + Postgres + multi-photo
averaging + duplicate-name merge); prints enrolled/updated/failed envelope. Web-form tab
in ops-frontend is an optional follow-up, not this ticket.

### T-R — random-compose CLI · repo: `mras-ops`
`./compose-random.sh [Name]` → GET composer `/playlist` (random base) + GET ops-api
`/components` (random `ready` component) → POST composer `/preview` with the name in the
personalized/text prop → prints the output mp4 URL. Pure HTTP against the running stack.

### Live demo test (after merges)
Seed 4 active ads (4 distinct components × pool bases) via ops-api; trigger Jason
(seeded embedding) → assert 4 displays receive 4 DIFFERENT media URLs, all "Jason";
enroll a 2nd person via T-E; fire both triggers with faces_in_frame=2 → assert 2/2 split.
Camera walk-up (the real two-person frame) is owner-run — agent launches can't get camera
permission.

## Process (unchanged)

Worktree per ticket off origin/main; ALL git via git-flow-manager (`CLAUDE_GIT_OK=1`);
TDD red committed before green; self-review + code review per PR; live E2E against the
real stack (don't ask); SESSION_LOG entry per landing; absolute paths everywhere.

## Critical files

- `/Users/jn/code/mras-vision/src/detection/embedder.py`, `src/camera/capture.py`,
  `main.py`, `src/identity/resolver.py`, new `src/perception/aggregator.py` — T-V.
- `/Users/jn/code/mras-composer/main.py` (WSManager, ws_endpoint, TriggerPayload,
  /trigger), `src/selector/selector.py`, new `src/display_assignment.py` — T-C.
- `/Users/jn/code/mras-ops/enroll.sh`, `compose-random.sh` (new) — T-E/T-R.
- Wire contract: `faces_in_frame` added to the trigger payload (pydantic default 1 —
  backward compatible); `scene_context` unchanged per D9.
