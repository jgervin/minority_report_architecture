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

## TODO-5: Validate ffmpeg Software Latency Under 5s (Phase 0 — early)

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
