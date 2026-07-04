# AdFace / MRAS — Deferred TODOs

Items deferred from the CEO plan review. All Phase 1+ unless noted.

---

## TODO-1: Shared Cooldown Store (Phase 1)

**What:** Replace in-memory `_screen_cooldown` dict with a Redis-backed shared store.

**Why:** The Phase 0 in-memory dict is process-local and resets on service restart. A live
venue with multiple cameras or a restarted P1 service loses all cooldown state, potentially
replaying ads for the same person immediately after a restart.

**Current state:** `_screen_cooldown: dict[str, dict]` in P1-C4 Identity Resolution Service,
keyed `screen_id:uuid`. Works for Phase 0 single-process demo.

**Where to start:** Replace the dict with `redis.Redis.get/set` calls. Key format stays the
same. TTL on the Redis key handles expiry automatically (no need to track `cooldown_until`
manually). Use `REDIS_URL` env var; fall back to in-memory dict if Redis is unavailable so
Phase 0 local dev still works without Redis.

**Effort:** S (human) → S (CC+gstack)
**Priority:** P2 — needed before live venue; not needed for demo
**Depends on:** Redis in Docker Compose (add service)

---

## TODO-2: AWS GPU Rental Profile (Phase 1)

**What:** Define a reproducible AWS launch profile for Phase 1 multi-camera venue events
using a GPU instance (g4dn.xlarge, $0.526/hr).

**Why:** The M3 MPS backend handles single-camera Phase 0 demo well. Phase 1 multi-camera
events with concurrent identity resolution will saturate the M3 CPU/GPU. g4dn.xlarge
provides NVIDIA T4 GPU + 4 vCPUs + 16GB RAM. Rent hourly, terminate after event.

**Where to start:** Create an `infra/aws/` directory with:
- `launch.sh` — one-command launch with correct AMI, security group, spot/on-demand toggle
- `docker-compose.aws.yml` — overrides for cloud deployment (GPU device mounts, S3 paths)
- `teardown.sh` — safe shutdown + cost check
Document in a short README: estimated cost per 4-hour event, how to transfer enrolled data.

**Effort:** M (human) → S (CC+gstack)
**Priority:** P2 — needed before first paid venue event
**Depends on:** AWS account with g4dn.xlarge quota

---

## TODO-3: P1→P2 Burst Handling / asyncio Queue (Phase 1)

**What:** Add backpressure to the P1→P2 HTTP dispatch path for multi-camera concurrent
triggers.

**Why:** Phase 0 direct HTTP works for single-camera. Phase 1 multi-camera venues can fire
simultaneous triggers (crowd walks by). Without backpressure, P2 receives a burst of
concurrent HTTP calls it can't service, queuing up stale triggers for people who have
already walked away.

**Current state:** P1-C4 fires direct `httpx.post()` to P2-C1 on each trigger. No queue,
no drop policy.

**Where to start:** Add `asyncio.Queue(maxsize=N)` inside P1-C4. Worker task drains the
queue and fires HTTP. Drop policy: if queue is full, discard (person still in frame will
re-trigger on the next detection cycle anyway). Phase 1 may also evaluate a lightweight
Redis queue if multi-process P1 is needed.

**Effort:** S (human) → S (CC+gstack)
**Priority:** P2 — Phase 1 multi-camera; not needed for Phase 0 demo
**Depends on:** TODO-1 (Redis, if escalated to multi-process)

---

## TODO-4: Electron Kiosk Watchdog / Auto-Restart (Phase 1)

**What:** Add a process watchdog so the Electron kiosk auto-restarts if it crashes.

**Why:** The 3-tier always-on display model depends on the kiosk being continuously running.
A crash (OOM, renderer hang, OS update) leaves the screen dark until someone manually
restarts it. Unacceptable for a live venue.

**Where to start:**
- macOS: `launchd` plist with `KeepAlive = true` targeting the Electron binary
- Linux/Docker: `restart: unless-stopped` in Docker Compose for the kiosk container
- Add a `/health` endpoint to the Electron main process (via IPC to renderer) so P3-C4
  System Health Monitor can detect kiosk crashes and alert.

**Effort:** S (human) → S (CC+gstack)
**Priority:** P2 — needed before any live venue deployment
**Depends on:** P3-C4 System Health Monitor (for alert wiring)

---

## TODO-6: Qdrant Exception Handling in P1 Detection Loop (Phase 0 — required) — ✅ DONE (2026-06-07)

**Resolution:** The production fallback already existed in `src/identity/resolver.py` (try/except around
`query_points`, sets `uuid=None`/`is_new_visitor=True`/`confidence=0.0`, logs `QDRANT_UNAVAILABLE`
best-effort, pipeline continues). The real gap was the *test*: `test_resolver.py` mocked `qdrant.search`
while the code calls `query_points`, so the fallback test passed via an accidental `TypeError` rather than
a real exception, and the happy-path/cooldown tests silently failed. Fixed the mocks to drive `query_points`
and added `test_qdrant_down_logs_unavailable_event`. Verified live: 56 `QDRANT_UNAVAILABLE` events were
handled gracefully during a startup window with zero crashes, then the system auto-recovered (140 successful
detections, latest success post-dates all errors). Commit `31ad695` in mras-vision.

**What:** Add explicit `try/except QdrantException` in P1-C4's detection query path with fallback to `new_visitor=True`.

**Why:** Qdrant going down during live detection currently has no error handling and no test. P1 will either crash or spin in a retry loop, halting the entire detection pipeline. The fallback is simple: if Qdrant is unavailable, treat all detections as `new_visitor=True` (standard/demographic ad plays), log the error, and continue. Pipeline stays up; personalization degrades gracefully.

**Where to start:** In the Qdrant similarity search call in P1-C4, wrap the `qdrant_client.search()` call in `try/except QdrantException`. On exception: set `uuid=None`, `is_new_visitor=True`, `confidence=0.0`, log `QDRANT_UNAVAILABLE` to PostgreSQL (best-effort, also try/except'd). The reconciler (D10) handles enrollment writes separately — this is the read path.

**Effort:** XS (human: ~30min) → trivial
**Priority:** P0 — required before Phase 0 can be called production-ready
**Depends on:** None

---

## TODO-5: Validate ffmpeg Software Latency Under 5s (Phase 0 — early) — ✅ DONE (2026-06-19)

**Resolution:** Benchmarked software `libx264` (no VideoToolbox) in Docker (`jrottenberg/ffmpeg`) on the M3,
matching the production assembler's command shape (`/Users/jn/code/mras-composer/src/assembly/assembler.py`:
`-c:v libx264 -preset fast -c:a aac`, audio via `amix`). 4 runs/config, cold run discarded, median of 3.
Worst case — a synthetic 30s 720p base (top of the 15–30s range) at `-preset fast` — assembled in **~1.9s
median docker-wall** (~1.56s pure encode); a real 6.35s 720p MRAS ad ran in **~1.0s**. `-preset ultrafast`
roughly halves encode (30s: 1.56s→0.83s) as headroom. **All configs PASS the 3s target and 5s budget — no
mitigation needed; the "VideoToolbox required" modeling assumption does not hold.** Caveat: no real asset
>12s exists yet, so the 30s figure is a synthetic upper bound (conservative).

**What:** Run a timed ffmpeg benchmark on the M3 in Docker (no VideoToolbox) to confirm
the <5s end-to-end latency budget holds with software encoding.

**Why:** The latency budget was modeled assuming VideoToolbox hardware acceleration.
VideoToolbox is unavailable inside Docker containers on macOS. Software ffmpeg on M3 is
fast (~0.5-1.5s for a 15-30s clip), but this must be confirmed empirically before
committing to the 5s target.

**How to measure:**
```bash
time docker run --rm -v $(pwd)/assets:/assets jrottenberg/ffmpeg \
  -i /assets/base_ad.mp4 -i /assets/name_audio.mp3 \
  -filter_complex "amix=inputs=2:duration=first" \
  -c:v libx264 -preset fast -c:a aac \
  /assets/output_test.mp4
```
Target: under 3s for a 15-30s clip. If over 3s, evaluate: shorten base clip, use `-preset
ultrafast`, or run P2 natively outside Docker.

**Effort:** S (human: ~30min) → trivial
**Priority:** P1 — validate before building the rest of P2 assembly pipeline
**Depends on:** Base ad video clip asset (any placeholder works for the benchmark)

---

## TODO-7: Use Perception Signals in Ad Selection / Generation (Phase 2 — part 2)

**What:** Consume the Phase 2 perception signals (objects + colors, viewer mood, attention) as
context for ad selection, personalization, and GenAI ad generation. Examples: mention a detected
object ("nice red backpack"), pick creative matching mood, feed `scene_context` into the
Phase 2 GenAI video path (P2-C4), use `gaze`/`playback` join data to score which ads hold
attention.

**Why:** Part 1 (signal identification — see
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-12-phase2-perception-part1-design.md`)
deliberately produces signals nothing consumes yet. The value lands when the composer uses them.

**Current state (after part 1):** `scene_context` arrives at the composer populated
(`objects[]`, `viewer{mood, attending}`) on every personalized trigger; `gaze` events accumulate
in Postgres. Composer ignores all of it.

**Where to start:** In mras-composer's `/trigger` path, read `scene_context` and thread it into
ad selection (the `ads` table) and/or overlay/template props. Treat every perception key as
optional enrichment — `{}` must keep working. Attention-outcome scoring is a SQL join of
`gaze` × `playback` events.

**Effort:** M (human) → M (CC+gstack)
**Priority:** P2 — after part 1 lands and signal quality is verified live
**Depends on:** Phase 2 perception part 1 (tracker, analyzers, gaze events)

---

## TODO-8: Multi-Camera Feed / Device Management (Phase 2+)

**What:** Support multiple camera feeds per location — enrollment/detection cameras plus a
dedicated display-adjacent camera per screen that is the authority for attention ("is the ID'd
person watching this ad") and mood. Includes device discovery/assignment, per-camera
`SCREEN_ID`/role config, and cross-camera track correlation.

**Why (owner decision, 2026-06-12):** Production venues will have more than one feed. The
codebase today is strictly single-camera: one capture loop (`CAM_INDEX=0`), one `SCREEN_ID`
per vision process. Phase 2 perception part 1 assumes the default camera IS the display camera
(see
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-12-phase2-perception-part1-design.md`).

**Where to start:** Likely one vision process per camera with a camera-role config
(detection vs display-attention), shared identity stores, and per-screen gaze attribution.
Cross-camera person correlation reuses ArcFace embeddings.

**Effort:** L (human) → M (CC+gstack)
**Priority:** P2 — explicitly sequenced AFTER a production-level test of perception part 1
**Depends on:** Phase 2 perception part 1; production parallel composition (scale plan)

---

## TODO-9: Double-Name — suppress always-on overlay when the component renders the name (Phase 0.5)

**What:** When an ad is bound to a name-rendering custom Remotion component (e.g. `helloname`,
`hellonamepw`), do NOT also composite the always-on animated name overlay — pick one source.

**Why:** `mras-composer/main.py:_render_overlay_inserts` adds the bound custom component AND, then,
the always-on name overlay "custom-Remotion component or not". Ads whose component already renders
the name (`nike-hello`, `pw-hello-jordan`) show the viewer's name TWICE on screen; ads with
non-name components (`lightleak`, `fallingsnow`) show it once. Owner-reported live (2026-06-20).
Pre-existing collision of the "name ALWAYS written" owner rule (2026-06-12) with name-rendering
components — not caused by temporal orchestration.

**Where to start:** In `_render_overlay_inserts`, skip the always-on name overlay branch when the
selection personalizes via its component — i.e. `selection.composition_id` is set AND the ad has a
`personalized_field` (the `ads` table column that signals the component renders the name). Treat the
overlay as the fallback for base-video-only ads. TDD: a personalized-via-component selection yields
exactly one name source; a base-video-only personalized selection still gets the overlay.

**Effort:** S (human) → S (CC+gstack)
**Priority:** P2 — content/visual polish; owner deferred on 2026-06-20 ("leave it for now")
**Depends on:** None

## TODO-10: Display Peel-Back Orchestration (Phase 2)

**What:** Change the round sequence so round 2 plays the named ad on **half** the screens the
opener used — `floor(N/2)` of however many displays are in the person's area (`4→2`, `6→3`,
`2→1`) — then stop and free them. Includes the prerequisite **area model**: a camera→displays
mapping so the opener targets "all displays near the person," not the global display list.

**Why:** Owner-specified product behavior (opener everywhere in the area → named ad on half →
release). Today `ROUND2` keeps ALL the owner's displays as an A/B `pair_slot` split and the
orchestrator only knows one flat `displays` list — no venue/area awareness.

**Current state:** Fully specified, not built. Spec with the orchestrator state-machine map,
the camera→display "area" gap, and 7 open design questions:
`/Users/jn/code/minority_report_architecture/docs/handoff-03-peelback-orchestration-spec.md`.
Blocked on two owner decisions: **Q1** where the area mapping lives (`zone_id` columns on
`cameras`/`displays`, a `camera_displays` join table, or composer config) and **Q2** which half
round 2 keeps (nearest-to-person vs deterministic subset; nearest also serves the deferred
move-redistribution feature).

**Where to start:** `/Users/jn/code/mras-composer/src/orchestrator/core.py` (`_reassign`) and
`model.py` (`even_split`/`pair_slot` — add a "half" helper); area resolution from the mras-ops
device registry (`cameras`/`displays`/`systems`). Pure state machine with injectable clock —
TDD with fake clock + asserted Play/Idle sequences, then live E2E.

**Effort:** M (human) → M (CC+gstack)
**Priority:** P1 — next feature lane after God View; demo-visible behavior
**Depends on:** owner decisions Q1/Q2; deferred follow-on: move-redistribution (composed clip
follows a moving person to a new area without recompose)
