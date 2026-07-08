# Multi-Camera: Roles, Failover & Device Management — Design Spec (TODO-8)

**Status:** SPEC APPROVED-PENDING-OWNER-REVIEW · plans in `docs/superpowers/plans/2026-07-08-multicam-plan-{a,b}.md`
**Scope:** mras-vision (runtime), mras-ops (registry/API/analytics surfacing). Composer area-targeting is
specified as Phase E interface but planned in a later lane.

---

## 1. Goal

Run **multiple cameras per venue** with distinct jobs, where:
1. A camera's **identity never changes** (`cameras.id`, `name`) — only its *function* does.
2. If the **ID (detection) camera dies, an eligible watcher camera automatically takes over
   the ID function** — without renaming, re-registering, or restarting anything by hand.
3. An **admin can permanently reassign roles** (promote a watcher to ID; demote the old ID
   camera to watcher or offline) and the fleet converges on the new assignment.
4. The design leaves clean seams for growth (more roles, more zones, cross-camera analytics)
   without rework — explicit interfaces, no spaghetti.

## 2. Terminology (fixes the identity-vs-function confusion)

| Term | What it is | Where it lives | Who changes it |
|---|---|---|---|
| **Identity** | `cameras.id` (uuid), `name`, `device_id` | Postgres registry | Nobody (create-once) |
| **Desired role** | What the admin wants this camera doing: `detection`, `audience_measurement`, `enrollment`, `security_context` (+ `standby`, added) | `cameras.camera_role` | Admin (ops-api endpoint) |
| **Lifecycle status** | `active / degraded / offline / retired` (`device_status` enum) | `cameras.status` | Admin + health automation |
| **Effective duty** | What the camera process is *actually doing right now* | Redis duty lease + journaled transitions | The runtime (failover), never the admin directly |

The owner's "main ID camera" = desired role `detection`. The owner's "slave / watching camera"
= desired role `audience_measurement` (existing enum value). We use **primary/watcher/standby**
terminology throughout; no new vocabulary is invented where the schema already has words.

**The core invariant: identity is permanent; desired role is admin truth; effective duty is
runtime truth. They are three different fields and never conflated.** A watcher covering for a
dead ID camera keeps `name` and `camera_role=audience_measurement` — only its *duty* changes,
and that change is journaled and visible.

## 3. Current reality (verified 2026-07-08)

- Vision is a single native macOS process: one `cv2.VideoCapture(cam_index)` loop, one global
  `SCREEN_ID`, pipeline stages already modular (`src/camera`, `src/detection`, `src/identity`,
  `src/perception`). It has a Postgres pool (journal events), Qdrant (global embeddings), and
  the TODO-1 Redis cooldown store (atomic claims, per-call in-memory fallback).
- Schema is ahead of the code: `cameras` has `camera_role`, `screen_group_id`, `status`,
  `calibration`; `screen_groups` (migration 025) groups cameras+displays into zones; God View
  drill-down already renders cameras per group.
- `camera_role` enum: `detection, enrollment, audience_measurement, security_context`.
  `cameras.status` is the `device_status` enum: `active, degraded, offline, retired`
  (NOT `lifecycle_status` — correction from Plan B's schema verification).
- `REMOTE_CONFIG_URL` appears in `.env.example` but **no endpoint or consumer exists** — the
  design must not lean on it.
- No camera heartbeat/health writer exists (`device_health_events` has no producer).
- Identity resolution is already multi-camera-correct for **known** people: every process
  resolves against the same Qdrant collection, and the Redis cooldown claim ("exactly one
  caller per window even when multiple cameras race") dedupes triggers.

## 4. Decisions (conservative; rationale one line each)

1. **One OS process per camera** (vision's own TODO-8 suggestion). Crash isolation per camera,
   no GIL contention, reuses the entire existing codebase; a launcher manages N processes.
2. **Each process is identified by `CAMERA_ID`** (uuid of its registry row) via env. `CAM_INDEX`
   stays the local capture device index. `SCREEN_ID` derives from the registry row (fallback to
   env for Phase-0 compat).
3. **Desired role is read from the Postgres registry** (vision polls its own `cameras` row every
   `ROLE_POLL_SECS`, default 10s, using the pool it already has). No new config service; the
   unimplemented `REMOTE_CONFIG_URL` stays unimplemented.
4. **Failover is a Redis duty lease**, reusing the proven TODO-1 claim idiom:
   `duty:detection:<scope>` with `SET NX EX` + periodic renewal (`DUTY_LEASE_TTL_SECS`, default
   15s; renew at TTL/3). Scope = `screen_group_id` when set, else `system_id`. Exactly one
   detection duty holder per scope, enforced atomically.
5. **Duty switching happens in-process, not by restart.** The capture loop is permanent; the
   frame consumer behind it is swappable. A small `RoleManager` selects which pipeline
   (`DetectionPipeline` | `AttentionPipeline` | `StandbyPipeline`) consumes frames, via one
   explicit interface (see §5.2). This is the "no spaghetti" seam: pipelines don't know about
   roles, leases, or each other.
6. **A camera runs ONE duty at a time.** A watcher acting as ID stops watching (attention
   metrics from that camera pause and the pause is journaled). Trade-off accepted: degraded
   attention analytics during failover beats double-load on one process and ambiguous metrics.
7. **No automatic failback (anti-flap).** When the failed primary returns, it finds the lease
   held and enters standby duty. Recovery paths: (a) admin restores desired roles, or (b) the
   acting camera's RoleManager sees its desired role is not `detection` and *gracefully
   releases* the lease whenever a camera whose desired role IS `detection` is alive — priority
   returns to the configured primary **only when it is provably healthy** (heartbeat present),
   never by stealing.
8. **Leases are released gracefully, never stolen.** Holders release on: shutdown (SIGTERM
   drain), desired-role change away from detection, or (b) above. Takeover happens only via
   lease *expiry* (crash) or *release* (cooperative).
9. **Failover eligibility is explicit**: new column `cameras.failover_eligible boolean NOT NULL
   DEFAULT false` (additive migration). An admin marks which watchers may act as ID. Default
   false = nothing changes for existing installs.
10. **Heartbeats live in Redis** (`heartbeat:camera:<camera_id>`, value = effective duty,
    **EX = DUTY_LEASE_TTL_SECS** — the heartbeat TTL is tied to the lease TTL, refreshed every
    tick, so a dead camera's liveness signal expires no later than its lease; a longer heartbeat
    TTL would block the watcher's claim guard and double the advertised failover latency
    [outside-review C1]. `<camera_id>` is ALWAYS the registry row's canonical `id::text` —
    never a raw env string — in heartbeat keys, lease holder values, and journal payloads
    [outside-review I1]) and duty *transitions* are journaled to the append-only `events` table
    (`event_type='camera_duty'`) so God View/audit can reconstruct history. Redis = liveness
    (fast, ephemeral, TTL'd — consistent with the owner rule that nothing accumulates in
    Redis); Postgres = history.
11. **Redis down ⇒ failover is disabled, not the cameras.** Each process falls back to
    desired-role-only operation (registry truth), logs a warning, keeps running. Consistent
    with the cooldown store's degrade posture. DB down ⇒ keep last-known role (cached).
12. **Admin API is small and audited**: `PATCH /cameras/{camera_id}` accepting `camera_role`,
    `status`, `failover_eligible` — journaled as `camera_admin` events (who/what/when). "Move
    the previous one to offline" = `status='offline'` (lifecycle), which also makes its process
    idle (StandbyPipeline) on next poll; role and name untouched.
13. **New enum value `standby`** added to `camera_role` (additive `ALTER TYPE ... ADD VALUE`)
    for cameras deliberately parked (admin's "slave with no job yet"). Distinct from lifecycle
    `offline` (don't run anything) and from `audience_measurement` (watching duty).
14. **Anonymous cross-camera correlation is deferred** (explicitly out of scope): known-person
    correlation already works via the shared Qdrant collection; transient-stranger track
    linking is a future lane. Exposure analytics already name the affected metric honestly
    (`anonymous_observations`).
15. **Compute guardrail**: per-role `FRAME_SAMPLE_RATE` overrides (attention cameras can run
    lighter); a documented two-camera ceiling on the M3 until TODO-2 (GPU rental) for venues.

## 5. Architecture

### 5.1 Processes & data flow

```
mras-ops Postgres (registry: cameras.camera_role/status/failover_eligible = ADMIN TRUTH)
        ▲  PATCH /cameras/{id} (ops-api, audited)          ▲ poll (10s)
        │                                                  │
   God View UI                                    vision proc per camera
                                                  ┌────────────────────────┐
Redis (RUNTIME TRUTH, all keys TTL'd)             │ capture loop (fixed)   │
  heartbeat:camera:<id> = duty, EX 30s   ◄────────│ RoleManager            │
  duty:detection:<scope>, EX 15s (lease) ◄──────► │  ├ DetectionPipeline   │
  cooldown:* (TODO-1, unchanged)                  │  ├ AttentionPipeline   │
                                                  │  └ StandbyPipeline     │
events journal (HISTORY): camera_duty /           └────────────────────────┘
  camera_admin transitions → God View
```

### 5.2 The pipeline seam (the "no spaghetti" contract)

```python
class FramePipeline(Protocol):
    """One camera duty. Stateless w.r.t. roles/leases — RoleManager owns those."""
    async def start(self) -> None: ...           # acquire duty-specific resources
    async def on_frame(self, frame, ts) -> None: # consume one sampled frame
    async def stop(self) -> None: ...            # release resources; MUST be idempotent
```

- `DetectionPipeline` wraps today's detect→identify→cooldown→trigger path (existing code moved
  behind the interface, not rewritten).
- `AttentionPipeline` wraps tracker+gaze (perception part 1), attributing gaze to the camera's
  `screen_group` displays.
- `StandbyPipeline` is a no-op consumer (process healthy, heartbeating, doing nothing).
- `RoleManager` is the ONLY component that reads the registry, holds/renews/releases the lease,
  chooses the active pipeline, and journals transitions. State machine in §6.
- Growth seam: a future *active* role = one new pipeline class + one enum value + two small
  registrations (a routing branch in the decision core, a consumers-dict entry) — four
  localized edits, all inside the roles package; no cross-pipeline leakage and no changes to
  existing pipelines [wording tightened per outside-review M5].

### 5.3 Failover state machine (per process)

States: `STANDBY`, `WATCHING` (attention), `PRIMARY_ID` (holds lease), `ACTING_ID`
(holds lease while desired role ≠ detection), `IDLE_OFFLINE` (lifecycle offline/retired).

Transitions (evaluated each poll tick + each lease-renew tick):
- desired `detection` + lease acquired → `PRIMARY_ID`; lease unavailable → `STANDBY` (retry claim each tick).
- desired `audience_measurement` → `WATCHING`; if `failover_eligible` AND lease is FREE
  (expired/released) AND no healthy desired-`detection` heartbeat exists → claim → `ACTING_ID`.
- `ACTING_ID`: each tick, if a healthy desired-`detection` camera heartbeat appears → release
  lease → return to `WATCHING` (decision 7b: cooperative handback, no steal).
- lifecycle `offline`/`retired` → stop pipeline → `IDLE_OFFLINE` (heartbeat continues
  so ops can see the process is alive but parked).
- Redis unreachable → pin to desired role (decision 11), retry with backoff.
- Every transition: journal `camera_duty` event `{camera_id, from, to, reason, lease_scope}`.

### 5.4 Admin flows (the two owner scenarios)

**Crash failover (automatic):** ID camera process dies → its lease expires (≤15s) + heartbeat
vanishes → eligible watcher claims lease → `ACTING_ID` (name/role unchanged) → journaled →
God View shows watcher's duty=`acting_id`, dead camera heartbeat-missing. Ads keep flowing with
at most one lease-TTL gap.

**Permanent reassignment (admin):** `PATCH /cameras/B {camera_role: detection}` +
`PATCH /cameras/A {camera_role: audience_measurement}` (or `{status: offline}`). Within one poll
tick: A's RoleManager releases the lease (desired role changed), B claims it → `PRIMARY_ID`.
Both PATCHes journaled as `camera_admin` events. Names never change.

**Recovery-handback timing (documented, accepted):** when a failed primary returns healthy, the
acting watcher releases the lease on its next tick and the primary claims on *its* next tick —
a ≤ one-tick (~5s default) no-holder gap. It is steal-safe: the returning primary's heartbeat
suppresses all other watcher claims throughout. This is the deliberate cost of decision 6
(one duty at a time) [outside-review M2]. Also note: a camera's lease *scope* is snapshotted at
process start — reassigning a camera's `screen_group_id` requires a process restart to move its
lease scope [outside-review M6].

### 5.5 mras-ops surface

- **Migration 027** (additive): `ALTER TYPE camera_role ADD VALUE 'standby'`;
  `ALTER TABLE cameras ADD COLUMN failover_eligible boolean NOT NULL DEFAULT false`.
- **`PATCH /cameras/{camera_id}`** (ops-api): validated updates to `camera_role`, `status`,
  `failover_eligible`; journals `camera_admin`; 404 on unknown id; no other fields writable.
- **God View (read)**: extend `GET /god-view/systems/{id}` cameras block additively with
  `camera_role`, `failover_eligible`, and `effective_duty` (from the latest `camera_duty`
  event; `unknown` when none) — the prototype's drill-down then shows duty vs role at a glance.

### 5.6 Phase E interface (composer — future lane, not planned here)

Triggers gain `camera_id` + `screen_group_id` (already derivable from the registry row); the
orchestrator resolves "displays near the person" as the trigger's screen_group displays,
falling back to today's global list when NULL. This also closes peel-back Q1. Specified so
Phase A–D don't paint it out; implemented in its own lane.

## 6. Rollout phases

- **A — Process-per-camera plumbing** (vision): CAMERA_ID env, registry-row read, launcher for
  N processes, per-camera log prefixes. No role logic yet; behavior identical for 1 camera.
- **B — RoleManager + pipelines behind the seam** (vision): wrap existing code paths as
  `DetectionPipeline`/`AttentionPipeline`/`StandbyPipeline`; static duty from desired role;
  heartbeats. Still no failover.
- **C — Duty lease + failover + admin PATCH** (vision + ops): the state machine, migration 027,
  admin endpoint, journaled transitions.
- **D — God View surfacing** (ops + prototype): effective duty in the systems drill-down.
- Each phase ships independently; a single-camera install is byte-identical through A–B and
  only gains behavior in C when a second camera + `failover_eligible` exist.

## 7. Failure modes & risks

| Failure | Behavior |
|---|---|
| Redis down | No failover; desired-role operation; warning logged; cooldown already degrades per TODO-1 |
| Postgres down | Last-known role cached; journaling buffered/dropped best-effort (existing journal posture) |
| Both ID cameras down | No detection duty; watchers keep watching; God View shows no detection heartbeat |
| Lease-holder wedged (alive but stuck) | Heartbeat/renewal stop → lease expires → takeover (same as crash) |
| Split brain | Impossible for duty: lease is a single atomic Redis key; worst case during Redis partition is decision 11's degrade (each camera follows desired role — brief double-detection risk is bounded by the cooldown claim, itself atomic) |
| M3 compute exhaustion | Per-role sample-rate overrides; documented 2-camera ceiling until TODO-2 |

Risks: DeepFace/YOLO double-load on the demo M3 (mitigated, measured in Phase A); macOS camera
permission is per-process from the owner's terminal (same as today, ×N); `ALTER TYPE ADD VALUE`
cannot run inside a transaction block on older PG (apply migration standalone — same manual-apply
posture as 025/026).

## 8. Out of scope (explicit)

Anonymous cross-camera track linking; camera auto-discovery; RTSP/network cameras
(`stream_url` column exists — future); composer area-targeting implementation (§5.6);
multi-venue federation; auth on the admin endpoint (single-operator dev posture, noted for
production hardening).
