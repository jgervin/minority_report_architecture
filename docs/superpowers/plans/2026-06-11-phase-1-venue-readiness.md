# Phase 1 — Multi-Camera Venue Readiness

## Context

Phase 0 + milestones M3/M4/M5 are **done and merged**: the system runs a single-camera demo
end-to-end (camera → identity → composer → personalized TTS + animated overlay → kiosk over
WebSocket). Phase 1 makes MRAS **survivable and scalable for a live, multi-camera venue event** —
the hardening the CEO plan review deferred. This plan **consolidates the four Phase-1 items** that
currently live as scattered bullets in `/Users/jn/code/minority_report_architecture/TODOS.md`
(TODO-1..4) into one sequenced, executable plan with per-ticket TDD breakdowns and success criteria,
so a fresh agent can execute it the same way M3/M4/M5 were built.

**The four tickets (all priority P2 — "needed before the first live/paid venue, not for the demo"):**
- **T1 — Shared cooldown store (Redis)** — TODO-1. Per-person ad-replay cooldown survives restarts
  and is shared across cameras/processes.
- **T2 — P1→P2 burst handling (backpressure)** — TODO-3. A crowd firing simultaneous triggers can't
  flood the composer with stale work.
- **T3 — Kiosk watchdog / auto-restart** — TODO-4. The always-on screen recovers from a crash without
  a human.
- **T4 — AWS GPU rental profile** — TODO-2. A reproducible cloud launch for a multi-camera event when
  the M3 saturates.

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

- **Sequencing: T1 → T2 → T3 → T4**, each an independent worktree + PR. Rationale below in *Dependencies*.
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
T1 Redis cooldown      ─ adds redis to compose; foundational shared state
   └─ T2 burst queue   ─ asyncio.Queue is independent of T1; only a *Redis* queue would depend on it
T3 kiosk watchdog      ─ independent; alert-wiring depends on P3-C4 (may defer)
T4 AWS profile         ─ independent infra; best LAST (bundles the multi-cam code T1+T2 produce)
```

Recommended order **T1 → T2 → T3 → T4**: land the shared-state foundation, then the producer-side
backpressure that benefits from it, then display resilience, then the cloud packaging that ships all of
it. None hard-block each other, so they *can* parallelize across repos (vision vs display vs infra), but
sequential keeps the live-demo stack stable and review simple.

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
