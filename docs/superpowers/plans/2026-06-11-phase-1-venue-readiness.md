# Phase 1 — Multi-Camera Venue Readiness

## Context

Phase 0 + milestones M3/M4/M5 are **done and merged**: the system runs a single-camera demo
end-to-end (camera → identity → composer → personalized TTS + animated overlay → kiosk over
WebSocket). Phase 1 makes MRAS **survivable and scalable for a live, multi-camera venue event** —
the hardening the CEO plan review deferred. This plan **consolidates the four Phase-1 items** that
currently live as scattered bullets in `/Users/jn/code/minority_report_architecture/TODOS.md`
(TODO-1..4) into one sequenced, executable plan with per-ticket TDD breakdowns and success criteria,
so a fresh agent can execute it the same way M3/M4/M5 were built.

**The tickets (revised 2026-06-11 — owner added multi-display; T4 deferred):**
- **T-D — Multi-display kiosk + shuffled idle rotation** — NEW (owner requirement, 2026-06-11).
  Kiosk startup launches **4 displays at once** (1–10 supported), each shuffling the idle pool
  independently; on identification all displays play the composed clip (same clip for now,
  per-display clips later via a `screen_id` forward hook).
- **T1 — Shared cooldown store (Redis)** — TODO-1. Per-person ad-replay cooldown survives restarts
  and is shared across cameras/processes.
- **T2 — P1→P2 burst handling (backpressure)** — TODO-3. A crowd firing simultaneous triggers can't
  flood the composer with stale work.
- **T3 — Kiosk watchdog / auto-restart** — TODO-4. The always-on screen recovers from a crash without
  a human.
- **T4 — AWS GPU rental profile** — TODO-2. **DEFERRED (owner decision 2026-06-11)** — kept below for
  when it's picked back up; not part of the current execution sequence.

Optional **T0 (Phase-0 carryover, validate first):** TODO-5 — empirically confirm software-ffmpeg
end-to-end latency holds <3s under Docker on the M3. Phase-1 multi-camera load amplifies any latency
miss, so verify the budget before adding concurrency.

## Repo reality (read before starting)

This planning doc lives in the **architecture/docs hub** (`minority_report_architecture`). The code
changes land in **sibling repos**, each its own git repo with the same CLAUDE.md guardrails:
- `mras-vision` (Python, **native macOS** — webcam) — `/Users/jn/code/mras-vision` → **T1, T2**
- `mras-display` (Electron kiosk) — `/Users/jn/code/mras-display` → **T3**
- `mras-ops` (Docker compose + infra) — `/Users/jn/code/mras-ops` → **Redis service (T1), kiosk
  restart policy (T3), `infra/aws/` (T4)**

Component taxonomy (P1=vision, P2=composer, P3=ops/display) is defined in
`/Users/jn/code/minority_report_architecture/adface_architecture.md` — read it for the C-numbers
referenced below (P1-C4 = Identity Resolution Service, P2-C1 = composer `/trigger`, P3-C4 = System
Health Monitor).

**Process rules (mandatory — same as M3/M4/M5; see CLAUDE.md §5/§6 + memory):**
- **One git worktree per ticket**, branch off `origin/main` as `{feat,chore}/{n}-{slug}`. **Delegate
  ALL git/gh to the `git-flow-manager` subagent** (raw git is blocked by `.claude/hooks/guard-git.sh`;
  the subagent opts in with `CLAUDE_GIT_OK=1`). Never push to `main`; land via `gh pr merge`.
- **TDD red→green with the failing test committed *separately*** from the implementation (so red→green
  shows in history).
- **Run a live E2E (don't ask)** — unit-green has repeatedly hidden integration/stale-container breakage
  on this project. Rebuild the affected container and exercise the real path (httpx and/or Playwright).
- **Self-review + `/code-review`** each PR; **check the PR base branch before merging**; rebuild the
  affected service container after merge; **prepend a dated SESSION_LOG entry** citing `repo@sha`.

## Decisions (locked / recommended)

- **Sequencing: T-D → T1 → T2 → T3**, each an independent worktree + PR. T-D goes first because it
  and T3 touch the same files (`/Users/jn/code/mras-display/electron/main.js`, `src/App.tsx`) —
  building the watchdog before multi-window would mean building it twice. **T4 deferred** (owner,
  2026-06-11). Rationale below in *Dependencies*.
- **Multi-display (T-D, owner decisions 2026-06-11):** `DISPLAY_COUNT` env, **default 4**, range
  1–10. One fullscreen window per attached monitor when enough monitors exist; otherwise a tiled
  grid on one screen (dev/demo on a single Mac is the accepted stand-in). **Shuffle = shuffled
  cycle** (Fisher-Yates; every video plays once before any repeats, no immediate repeat across
  reshuffles), independent per display. On identification, **all displays play the same composed
  clip for now** — the composer's WS manager already broadcasts `play` to every connected client
  (`/Users/jn/code/mras-composer/main.py`), so this is free. Each window connects with a
  `screen_id` (e.g. `display-1`) as the **forward hook** for per-display composed clips later
  (composer-side selector change, no kiosk rework).
- **Redis (T1):** add a `redis` service to `mras-ops/docker-compose.yml`; resolver reads `REDIS_URL`
  and **falls back to the in-memory dict when Redis is absent** so native single-process dev/demo keeps
  working with zero new infra.
- **Backpressure (T2):** start with an in-process `asyncio.Queue(maxsize=N)` + drop-on-full policy
  (a person still in frame re-triggers next cycle). A Redis-backed queue is **out of scope** here —
  only needed if/when P1 goes multi-process (note it as a follow-up).
- **Watchdog (T3):** OS-level supervision (macOS `launchd KeepAlive`; Docker `restart: unless-stopped`)
  is the core deliverable and is **independent**. The `/health` IPC endpoint + alert wiring to P3-C4 is
  a thin add; **if P3-C4 System Health Monitor doesn't exist yet, ship the auto-restart and file the
  alert-wiring as a GitHub issue** rather than blocking.
- **AWS (T4):** scripts + compose override only — **no live cloud run in this plan** (needs an AWS
  account with g4dn.xlarge quota). Deliver `infra/aws/{launch.sh,docker-compose.aws.yml,teardown.sh}` +
  a cost/transfer README; validate with `--dry-run`/`shellcheck`, not a real paid launch.

## Dependencies & sequencing

```
T0 (validate latency)  ─ optional, do first, ~30 min, no code
T-D multi-display      ─ display repo; FIRST — T3's watchdog must supervise the multi-window app
T1 Redis cooldown      ─ adds redis to compose; foundational shared state
   └─ T2 burst queue   ─ asyncio.Queue is independent of T1; only a *Redis* queue would depend on it
T3 kiosk watchdog      ─ builds on T-D (per-window crash recovery); alert-wiring depends on P3-C4
T4 AWS profile         ─ DEFERRED (owner, 2026-06-11)
```

Recommended order **T-D → T1 → T2 → T3**: land the multi-window kiosk first (T3 supervises its final
shape), then the shared-state foundation, then producer-side backpressure, then display resilience.
T-D and T1/T2 are different repos so they *can* parallelize, but sequential keeps the live-demo stack
stable and review simple.

---

## T-D — Multi-display kiosk + shuffled idle rotation  ·  repo: `mras-display`

**Goal:** kiosk startup launches `DISPLAY_COUNT` displays (default **4**, 1–10) instead of one. Each
display shuffles the idle pool independently (shuffled cycle, not loop). On identification, every
display plays the composed clip (same clip for now; per-display clips are a later composer change).

**Current state (read):**
- `/Users/jn/code/mras-display/electron/main.js` — single `createWindow()`, one `BrowserWindow`.
- `/Users/jn/code/mras-display/src/App.tsx` — sequential idle rotation (`idleIndex` +
  `advanceIdle()` modulo the `/playlist` list); one WS client; two-element crossfade.
- Composer broadcast already reaches all connected WS clients — no composer change needed for
  same-clip-everywhere.

**Where to start:**
1. `electron/main.js`: read `DISPLAY_COUNT` (default 4, clamp 1–10). Create N windows; if
   `screen.getAllDisplays().length >= N`, one fullscreen window per monitor, else tile a grid on
   the primary display. Pass each window its identity via URL query (`?screen_id=display-<n>`).
2. `src/App.tsx`: replace the sequential `advanceIdle` with a **shuffled cycle** — Fisher-Yates
   the playlist, walk it, reshuffle on exhaustion with a no-immediate-repeat guard (new shuffle's
   first item ≠ last played). Keep the drop-in `refreshPlaylist()` semantics (new videos join the
   next cycle). Read `screen_id` from the query string; append it to the WS URL so the composer
   can target displays later (it ignores it today).
3. Extract the shuffle and the window-layout math into small pure modules so both are unit-testable
   (`src/shuffle.ts`; layout helper for main.js).

**TDD breakdown (red→green, one PR):**
1. *(red)* `src/__tests__/shuffle.test.ts`: full coverage before repeat (a cycle of N plays each of
   N videos exactly once); reshuffle never starts with the previous cycle's last item (seeded/mocked
   RNG); 1-item and 2-item pools don't hang. App-level test: rotation follows the shuffled order,
   not list order; `screen_id` from the query lands in the WS URL. Layout test: N=4 with 1 monitor →
   2×2 grid bounds; N=2 with ≥2 monitors → fullscreen bounds per monitor; DISPLAY_COUNT clamped to
   1–10.
2. *(green)* Implement shuffle module, App wiring, multi-window main.js.

**Verification (live, don't ask):** stack up (composer serving `/playlist` + `/ws`) →
`DISPLAY_COUNT=4 npm run electron:dev` → 4 windows appear, each logging its own `screen_id` and a
*different* shuffle order; let one video end → window advances per its own order. Then fire a real
`POST /trigger` (httpx, enrolled person) → **all 4 windows** play the same composed clip, then each
resumes its own idle shuffle. Capture `[kiosk]` console logs per window as evidence.

---

## T1 — Shared cooldown store (Redis)  ·  repo: `mras-vision` (+ `mras-ops`)

**Goal:** per-person ad-replay cooldown survives a P1 restart and is shared across cameras/processes,
instead of a process-local dict that resets on restart (replaying ads for the same person).

**Current state (read):** `/Users/jn/code/mras-vision/src/identity/resolver.py`
- `self._cooldown: dict[str, dict]` (line ~34), keyed `f"{_SCREEN_ID}:{person_uuid}"`.
- `_is_on_cooldown()` (~81) checks `time.time() < entry["cooldown_until"]`.
- `_mark...()` (~89) sets `cooldown_until = time.time() + _COOLDOWN_SECS` after N hits.

**Where to start:**
1. Add a `redis` service to `/Users/jn/code/mras-ops/docker-compose.yml` (e.g. `redis:7-alpine`,
   port 6379, healthcheck). Add `REDIS_URL=redis://redis:6379/0` to the vision/compose env.
2. Introduce a tiny cooldown backend in `resolver.py`: if `REDIS_URL` is set and reachable, use
   `redis.Redis.set(key, "1", ex=_COOLDOWN_SECS)` / `exists(key)` (TTL replaces manual
   `cooldown_until` bookkeeping); **else fall back to the existing in-memory dict**. Keep the
   `screen_id:uuid` key format unchanged.
3. Keep the public resolver behavior identical (same cooldown semantics) — only the storage changes.

**Semantics note (multi-display, 2026-06-11):** the cooldown key's `screen_id` means the
**camera/screen-group**, NOT an individual display. One identification serves all `DISPLAY_COUNT`
displays and consumes **one** cooldown — exactly what the current single `_SCREEN_ID` does. Do not
"fix" this to be per-display.

**TDD breakdown (red→green, one PR):**
1. *(red)* Unit test with a **fake/in-memory Redis** (e.g. `fakeredis`, injected) asserting: first
   trigger allowed → key set with TTL; second within window → on cooldown; after TTL → allowed again;
   and **Redis-unavailable → falls back to the dict** (no crash). These fail until the backend exists.
2. *(green)* Implement the backend + fallback. Existing `tests/test_resolver.py` stays green.

**Verification (live):** `docker compose up -d redis` then run native vision; trigger the same enrolled
person twice quickly → second is suppressed; **restart the vision process** → cooldown still suppresses
(proves persistence). Confirm via Redis (`redis-cli keys '*'`) and the composer not receiving a 2nd
`/trigger`. Tests via `mras-vision/.venv/bin/python -m pytest`.

---

## T2 — P1→P2 burst handling / backpressure  ·  repo: `mras-vision`

**Goal:** simultaneous multi-camera triggers can't flood the composer with stale work; excess triggers
are dropped (the person re-triggers next detection cycle) rather than queued forever.

**Current state (read):** `resolver.py` fires a direct `await httpx.post(f"{_COMPOSER_URL}/trigger",
json=payload, timeout=5.0)` (~line 116) on every trigger — no queue, no drop policy.

**Where to start:** introduce an `asyncio.Queue(maxsize=N)` + a single worker task that drains it and
does the HTTP post. On enqueue, if the queue is full → **drop** (log a `TRIGGER_DROPPED` event). Wire
the producer (detection path) to `put_nowait` and handle `QueueFull`.

**TDD breakdown (red→green, one PR):**
1. *(red)* Unit: enqueue > maxsize triggers with a slow/blocked fake HTTP sink → assert exactly
   `maxsize` (or `maxsize`+in-flight) are dispatched and the rest are dropped with a logged event;
   assert FIFO drain order and that a failing post doesn't kill the worker.
2. *(green)* Implement the queue+worker+drop policy.

**Verification (live):** fire a burst of `/trigger`s (script N concurrent enrolled-person payloads) at a
deliberately slow composer → confirm the composer isn't swamped (bounded concurrency) and dropped
triggers are logged, while a person remaining in frame still eventually gets served.

**Follow-up (out of scope, file as issue):** Redis-backed queue if P1 becomes multi-process (depends on
T1's Redis).

---

## T3 — Kiosk watchdog / auto-restart  ·  repo: `mras-display` (+ `mras-ops`)

**Goal:** the always-on kiosk recovers from a crash (OOM, renderer hang, OS update) without a human;
crashes are detectable by the health monitor.

**Current state (read):** Electron main at `/Users/jn/code/mras-display/electron/main.js`; no supervisor,
no health endpoint.

**Where to start:**
- **Inner layer (new with T-D's multi-window app):** `webContents.on('render-process-gone')` per
  window in `/Users/jn/code/mras-display/electron/main.js` → recreate just that window, so one
  display crashing doesn't dark-screen the others or restart the whole app. `/health` reports
  per-window status.
- **macOS:** a `launchd` plist with `KeepAlive = true` targeting the Electron binary (ship the plist +
  load/unload instructions in the repo).
- **Docker/Linux:** `restart: unless-stopped` on the kiosk service (if/when containerized) in compose.
- **Health/alerting:** add a `/health` signal from the Electron main process (IPC to renderer) so
  **P3-C4 System Health Monitor** can detect kiosk death and alert. **If P3-C4 doesn't exist yet, ship
  the auto-restart and file the alert-wiring as a GitHub issue.**

**TDD breakdown (red→green, one PR):** Electron is harder to unit-test; favor a thin, testable health
module + a scripted crash-recovery check:
1. *(red)* Unit-test the health module (main-process status → IPC payload shape) and a plist/compose
   generator or validator (assert `KeepAlive`/`restart: unless-stopped` present and correct).
2. *(green)* Implement. **Live E2E:** start the kiosk under the supervisor, `kill -9` the process →
   assert it relaunches within a bound and reconnects the WebSocket; hit `/health`.

**Verification (live):** kill the kiosk process → it auto-restarts and the screen recovers; `/health`
returns OK; (if wired) the health monitor logs a recovery event.

---

## T4 — AWS GPU rental profile  ·  repo: `mras-ops` (new `infra/aws/`)

**Goal:** a reproducible, one-command cloud launch for a multi-camera event when the M3 saturates —
rent a `g4dn.xlarge` (NVIDIA T4, ~$0.526/hr) hourly, run the stack, tear down.

**Where to start:** create `/Users/jn/code/mras-ops/infra/aws/`:
- `launch.sh` — one-command launch (correct GPU AMI, security group, spot/on-demand toggle).
- `docker-compose.aws.yml` — cloud overrides (GPU device mounts, S3 paths for assets/enrolled data).
- `teardown.sh` — safe shutdown + cost check.
- `README.md` — estimated cost per 4-hour event, how to transfer enrolled identities (Qdrant + Postgres),
  and the native-vision caveat (cloud GPU box runs vision in-container with a real GPU, unlike the M3
  native-macOS path — call out the camera-input difference for a venue rig).

**TDD/verification:** infra scripts — validate with `bash -n` + `shellcheck`, a `--dry-run` that prints
the resolved AWS CLI invocation without launching, and `docker compose -f docker-compose.yml -f
docker-compose.aws.yml config` to confirm the override merges. **No live paid launch in this plan**
(gated on an AWS account + g4dn quota); a real smoke launch is a separate, owner-run step.

---

## Cross-cutting verification

- **Unit:** per-repo (`mras-vision/.venv/bin/python -m pytest`; display test runner). New tests fail
  first, then pass; pre-existing suites stay green.
- **Live E2E (don't ask):** each ticket has a real-path check above. For T1/T2 use Python `httpx`
  against the running stack (curl/wget are blocked); rebuild the affected container first (vision is
  native — restart the process; compose services need `docker compose up -d --build <svc>`).
- **Cross-repo:** cite `repo@sha` for every merged change in the SESSION_LOG entry.

## Risks & mitigations

- **Redis as a new hard dependency** → mitigated by the in-memory fallback (demo/native dev needs no
  Redis).
- **Drop policy hiding real load problems** → log every `TRIGGER_DROPPED`; surface counts so a venue
  operator sees saturation instead of silent loss.
- **Electron supervision is OS-specific** → ship both `launchd` (macOS) and compose `restart` (Linux);
  don't assume one venue OS.
- **AWS cost/secrets** → `teardown.sh` always runs a cost check; never commit credentials; the native-vs-
  containerized vision difference is documented so a venue rig isn't mis-provisioned.
- **P3-C4 may not exist** → T3 ships auto-restart standalone; alert-wiring filed as an issue, not blocked.

## Critical files

- `/Users/jn/code/mras-display/electron/main.js` — T-D multi-window startup + layout; T3 per-window
  crash recovery.
- `/Users/jn/code/mras-display/src/App.tsx` (+ new `src/shuffle.ts`, tests in `src/__tests__/`) —
  T-D shuffled idle cycle + `screen_id` wiring.
- `/Users/jn/code/mras-vision/src/identity/resolver.py` — T1 cooldown backend, T2 queue/worker/drop.
- `/Users/jn/code/mras-vision/tests/test_resolver.py` (+ new queue test) — T1/T2 TDD.
- `/Users/jn/code/mras-ops/docker-compose.yml` — `redis` service (T1), kiosk `restart:` (T3).
- `/Users/jn/code/mras-display/electron/main.js` + new health module / `launchd` plist — T3.
- `/Users/jn/code/mras-ops/infra/aws/{launch.sh,docker-compose.aws.yml,teardown.sh,README.md}` — T4 (new).
- This plan → `minority_report_architecture/docs/superpowers/plans/2026-06-11-phase-1-venue-readiness.md`.
- Read-first context: `/Users/jn/code/minority_report_architecture/adface_architecture.md` (component map),
  `/Users/jn/code/minority_report_architecture/TODOS.md` (source items),
  `/Users/jn/code/minority_report_architecture/docs/HANDOFF.md`, `docs/SESSION_LOG.md`.

## Closing checklist (per CLAUDE.md §5/§6)

- Worktree + branch per ticket off `origin/main`; all git via `git-flow-manager`; TDD red→green proven by
  running (failing test committed first); `/code-review` + self-review; **live E2E run, not skipped**.
- One PR per ticket → `main`; check the PR base before merge; rebuild the affected container; file any
  remaining/­deferred items (Redis queue, T3 alert-wiring, live AWS launch) as GitHub issues.
- Prepend a dated SESSION_LOG entry per ticket citing `repo@sha`, new env (`REDIS_URL`), new ops steps
  (`docker compose up -d redis`, the kiosk supervisor load command, the AWS launch/teardown), and gotchas.
