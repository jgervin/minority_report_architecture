# The Librarian — Event-Sourcing Projector Worker: Build Spec

_Date: 2026-07-01. Incorporates CTO decisions D-A through D-E. Audience: the person building the projector._

---

## Goal

Build a single, durable background worker — "the Librarian" — that tails the append-only `events` journal
and folds each event into the mutable summary tables (`ad_runs`, `playbacks`, `viewer_exposures`,
`subject_observations`, `composition_runs`, `observation_tracks`, `personalization_decisions`,
`identity_matches`). The summary tables are the backing store for the God View's history and aggregate
panels. The projector is the **only writer** of those tables. Every write is an idempotent upsert keyed on
event-derived natural keys so that re-processing from any cursor value converges to the same state without
double-counting. Projector lag — the gap between the live journal and what the summaries reflect — must be
loud, not silent.

---

## Architecture

**Single sequential at-least-once worker.** The projector is a long-running Python asyncio loop. It reads a
batch of `events` rows ordered by `id`, folds each into one or more summary-table upserts, then commits the
batch (upserts + cursor advance) in a single transaction and repeats. "At-least-once" means a crash between
upsert and cursor commit causes the batch to be re-processed on restart; idempotent upserts absorb the
replay without double-counting.

**Bigserial cursor in `projector_state`.** A new table (migration 018, see §Deployment) holds:

```sql
CREATE TABLE projector_state (
    id              int PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- singleton row
    cursor          bigint NOT NULL DEFAULT 0,
    last_event_ts   timestamptz,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    projector_ver   text
);
```

The worker reads `SELECT cursor FROM projector_state FOR UPDATE` at the start of each cycle, fetches
`SELECT * FROM events WHERE id > $cursor ORDER BY id LIMIT $batch_size`, folds, then
`UPDATE projector_state SET cursor=$new, last_event_ts=$ts, updated_at=now()` — all in one transaction.

**Advisory-lock single-writer guarantee.** At startup, acquire
`pg_try_advisory_lock(<fixed constant, e.g. 20260701>)`. If not acquired, log and idle-retry until the
lock is free. This ensures exactly one active projector even if two containers start simultaneously (e.g.
rolling restart).

**Own compose service, shared image.** The projector runs as `mras-ops-projector` in
`/Users/jn/code/mras-ops/docker-compose.yml` — a separate service, not folded into `mras-ops-api`.
Folding it into a multi-worker FastAPI (uvicorn can fork) risks two loops racing the cursor. It shares
the api's image (`build: ./api`) with a different `command` (e.g. `python -m src.projector`), matching
the pattern the existing compose already uses for per-service `command`/`environment` overrides.

**Cursor advances in the batch transaction.** The cursor commit is inside the same `asyncpg` transaction
as the upserts. If any part of the batch txn fails, the cursor does not advance and the batch is retried.
Per-event exceptions (bad payload, unmappable event) are caught individually, written to the skip log
(§Failure Handling), and do not abort the surrounding transaction.

---

## Projection Map

The table below is the authoritative routing table for the projector. "Match key" is the `(service,
event_type, status)` triple that selects the row (D-B: keep the existing `(event_type, status)` pair
convention; the `service` column disambiguates when the same `event_type` is emitted by multiple services).
"Upsert key" is the constraint added by migration 018 (D-A) unless noted as pre-existing.

| service | event_type | status | target table | upsert key | notes |
|---|---|---|---|---|---|
| `mras-vision` | `detection` | `success` | `subject_observations` | `UNIQUE(event_id)` — pre-existing | One observation row per detection event. Scope: camera path. |
| `mras-vision` | `dispatch` | `success` | `observation_tracks` | `UNIQUE(camera_screen_id, camera_track_id)` — D-A, new column `camera_screen_id` | Keys on the RAW camera `screen_id` string, not the resolved uuid (D-A). `camera_screen_id` and `camera_track_id` are NOT NULL. |
| `mras-vision` | `perception` | `success` | supplements `subject_observations` | via `event_id` back-ref | Payload enriches an existing observation; upsert on the observation's `event_id`. |
| `mras-composer` | `composition` | `queued`/`selected`/`rendered` | `composition_runs` | `UNIQUE(trigger_id)` — D-A | One run per triggered composition. `trigger_id` NOT NULL. |
| `mras-composer` | `composition` | `selected` | `personalization_decisions` | `UNIQUE(event_id)` — D-A | One decision row per selection event. `event_id` NOT NULL. |
| `mras-composer` | `composition` | `selected` | `identity_matches` | `UNIQUE(subject_observation_id, rank)` — D-A | Candidate rows per ranked match. Both columns NOT NULL. |
| `mras-composer` | `playback` | `started` | `ad_runs` | `UNIQUE(trigger_id)` — pre-existing | Scope: display path. `trigger_id` NOT NULL. |
| `mras-composer` | `playback` | `started` | `playbacks` | `UNIQUE(trigger_id, display_id)` — pre-existing | `trigger_id`, `display_id` NOT NULL. |
| `mras-composer` | `playback` | `ended` | `viewer_exposures` | `UNIQUE(ad_run_id, subject_observation_id)` — D-A | Both columns NOT NULL. One exposure row per (ad run × subject observed). |
| `mras-display` | `playback` | `started`/`ended` | same as composer playback rows | same keys | Display events once Lane B is built; projector disambiguates by `service` column (D-E). |

**Unmapped events (Gap B from grounding doc):** `gaze`, `augment`, `tts_attempt`, `assembly`, `overlay`.
These are written to `events` today but have no target summary table. The projector skips them cleanly
(skip log, §Failure Handling). They remain available for future projection lanes.

**Tables with no source event yet (Gap A from grounding doc):** `model_runs`, `device_health_events`,
`system_health_events`. These require new event-emission work before the projector can populate them.
They are left empty until the event-emission lane (Lanes C/D) enriches payloads sufficiently.

---

## Scope Resolution (D-C + D-E)

**Problem:** services emit runtime `screen_id` strings (e.g. `screen_0`, `display-2`); every summary and
event scope column is a uuid. The registry bridge is `cameras.screen_id` and `displays.screen_id`
(both indexed: `cameras_screen_id_idx`, `displays_screen_id_idx`, migration 012).

**The projector owns resolution (D-C, Decision 10).** Services always include `screen_id` in their event
payload or in the `events` column where present. The projector resolves string→uuid at fold time — services
do not need to know the uuid keyspace. This is the single choke point for registry coupling.

**screen_id is overloaded (D-E — known contract).** Vision emits `screen_id` as a camera ID (`screen_0`
by default, `/Users/jn/code/mras-vision/src/identity/resolver.py:17`). Composer and display emit
`screen_id` as a display ID (`display-<n>`, `/Users/jn/code/mras-composer/main.py:418`). The projector
disambiguates by the emitting service:

- `service = 'mras-vision'` → resolve against `cameras` (`SELECT id, system_id, location_id,
  organization_id FROM cameras JOIN systems … WHERE cameras.screen_id = $1 AND status <> 'retired'`).
- `service = 'mras-composer'` or `service = 'mras-display'` on playback events → resolve against
  `displays` (same structure, `displays` table).

**Resolution cache.** The registry is small and changes only via the admin device-registration UI. Cache
the `screen_id → (uuids)` mapping in process memory; invalidate on TTL (default 60 s) or on a
`LISTEN registry_changed` NOTIFY from the device-registration write path.

**Unregistered `screen_id` (D-C).** If the string resolves to no row: do NOT drop the event, do NOT
crash. Insert the summary row with null scope uuids (God View "unfiltered" mode — null = unfiltered, not
an error). Write one `audit_logs` row per novel unknown string:

```
actor_type  = 'system'
action      = 'projector.unresolved_screen_id'
entity_type = 'camera' or 'display'   -- based on emitting service
entity_id   = <screen_id string>
```

Increment an `unresolved_screen_id` counter on `/projector/status` so the operator knows to register
the device. Once registered, a ranged rebuild re-resolves and back-fills the scope uuids — the natural-key
upserts absorb the re-processing safely.

---

## Idempotency and Full-Rebuild Semantics (D-A)

**Why the 018 UNIQUE constraints are necessary.** Three tables already had natural unique keys
pre-migration 018: `subject_observations UNIQUE(event_id)`, `ad_runs UNIQUE(trigger_id)`,
`playbacks UNIQUE(trigger_id, display_id)`. The remaining five — `observation_tracks`,
`identity_matches`, `personalization_decisions`, `composition_runs`, `viewer_exposures` — had only a
`uuid` PK. A blind INSERT on replay would double-count. Migration 018 adds the following constraints
(D-A, all discriminator columns made NOT NULL, per D-A rationale — a UNIQUE over a nullable column
does not enforce uniqueness because NULLs are distinct):

| table | constraint added by 018 | discriminators NOT NULL |
|---|---|---|
| `observation_tracks` | `UNIQUE(camera_screen_id, camera_track_id)` | both |
| `identity_matches` | `UNIQUE(subject_observation_id, rank)` | both |
| `personalization_decisions` | `UNIQUE(event_id)` | `event_id` |
| `composition_runs` | `UNIQUE(trigger_id)` | `trigger_id` |
| `viewer_exposures` | `UNIQUE(ad_run_id, subject_observation_id)` | both |

**`observation_tracks` keys on the raw `camera_screen_id` string (D-A).** A new `camera_screen_id text`
column is added to `observation_tracks` in migration 018. The idempotency key uses this raw string rather
than the resolved `camera_id` uuid, so idempotency does not depend on device-registry resolution having
completed. This means a track inserted before the camera is registered and a track inserted after
registration are the same row (same `camera_screen_id` + `camera_track_id`), and the subsequent rebuild
that resolves the uuid just updates the `camera_id` column on the existing row via upsert.

**All upserts are `INSERT … ON CONFLICT (upsert_key) DO UPDATE SET …`.** Every column except the
discriminators is overwritten on conflict so that a rebuild with richer data (e.g. newly resolved scope
uuids) always wins.

**Full-rebuild semantics.** Truncate the summary tables, reset `projector_state.cursor = 0`, restart.
The projector replays every event from id=1 and converges to the same state as a fresh projection.
Triggering mechanism: admin-only HTTP endpoint or CLI one-shot. The advisory lock ensures the live loop
pauses before a rebuild can start — rebuild acquires the same lock.

**Ranged rebuild.** To backfill only events in a window (e.g. after registering a previously unknown
device): set `cursor` to `id_start - 1`, let the projector run to `id_end`, then advance cursor back
to where it was. This is safe because upserts are idempotent and the ranged re-projection updates
existing rows rather than inserting duplicates.

---

## Projector-Lag Detection

The named silent failure mode: projector down → summary tables stale while `events` grows → God View looks
healthy but shows stale history. Make it loud.

**Two complementary metrics, both cheap:**

- **Backlog (id-space):** `lag_events = (SELECT max(id) FROM events) - projector_state.cursor`. Catches
  "projector is behind."
- **Wall-clock staleness:** `lag_seconds = now() - projector_state.last_event_ts`. Catches "projector
  is up but stalled" even when backlog is low.
- **Heartbeat:** `projector_state.updated_at` — if it isn't advancing, the loop is dead.

**Thresholds (configurable, defaults):**
- `warn`: `lag_seconds > PROJECTOR_LAG_WARN_S` (default 10) or `lag_events > 5000`.
- `critical`: `lag_seconds > PROJECTOR_LAG_CRIT_S` (default 60) or `updated_at` older than
  `3 × PROJECTOR_POLL_MS`.

**Three exposure surfaces:**

1. `GET /projector/status` — new endpoint in `/Users/jn/code/mras-ops/api/src/main.py`:
   ```json
   {
     "cursor": 12345,
     "max_event_id": 12350,
     "lag_events": 5,
     "lag_seconds": 2.1,
     "heartbeat_age_s": 1.8,
     "unresolved_screen_id_count": 0,
     "skip_count": 0,
     "state": "healthy"
   }
   ```
   `state` is `healthy | warn | critical`.

2. `GET /health` — currently returns static `{"status":"ok"}` at
   `/Users/jn/code/mras-ops/api/src/main.py:202`. Upgrade to return non-200 (or `"status":"degraded"`)
   when projector `state = critical`, so container/orchestrator health checks react.

3. God View health panel (T8) — "last event processed N s ago" indicator, amber at `warn`, red at
   `critical`. The api reads `projector_state` directly from the shared Postgres; no RPC needed.

---

## Failure Handling

**Poison / unmappable event:** never abort the batch or wedge the cursor. Catch per-event exceptions,
write a skip-log row (see below), advance past the event. Design bias: availability over completeness —
the journal is retained, so a skipped event can be re-folded after a code fix via ranged rebuild.

**Durable skip log — reuse `audit_logs` (no new table):**

```
actor_type  = 'system'
action      = 'projector.skip'
entity_type = 'event'
entity_id   = <events.id as text>
before      = { "event_type": "...", "status": "...", "service": "..." }
after       = { "error_class": "...", "error_message": "...", "projector_ver": "..." }
```

A `projector_skips` view over `audit_logs WHERE action = 'projector.skip'` gives the operator a
visible queue. Skip count is surfaced on `/projector/status`.

**Privacy scrub (D-C / Decision 7/9):** never copy raw `payload` into `audit_logs.after` — payloads
may hold names, subject uuids, or embeddings. Store only `error_class` + non-PII event shape.

**Partial batch:** the single-txn batch (upserts + cursor commit) ensures no partial commit. Either the
whole batch lands or nothing does. Per-event skips are the only intra-batch divergence and they are
explicit `audit_logs` rows, not silent drops.

**Repeated crash on same event:** the skip path prevents an infinite crash loop. A rising `skip_count`
on `/projector/status` is itself an alert signal for the operator to inspect the skip log.

---

## Settle-MS Note (D-D — bigserial commit-vs-allocation gap)

Postgres allocates `bigserial` values at row-insert time but commits transactions independently.
Transaction B (lower id) can commit after Transaction A (higher id) is already visible. A simple
`WHERE id > cursor` can therefore miss A momentarily. At pre-alpha volume — effectively one row per
transaction — this gap is academic. **Accepted (D-D), documented here.**

Mitigation: `PROJECTOR_SETTLE_MS` (default 2000 ms) delays the upper bound of each poll:
the worker fetches `WHERE id > cursor AND id <= (SELECT max(id) FROM events)` but only processes
events whose `ts` is older than `now() - PROJECTOR_SETTLE_MS`. Set `PROJECTOR_SETTLE_MS=0` to disable
(useful in tests). Revisit before scale.

---

## Deployment

**Compose service.** Add to `/Users/jn/code/mras-ops/docker-compose.yml`:

```yaml
mras-ops-projector:
  build: ./api
  command: python -m src.projector
  environment:
    DATABASE_URL:          postgresql://mras:mras@postgres:5432/mras
    PROJECTOR_POLL_MS:     "1000"
    PROJECTOR_BATCH_SIZE:  "500"
    PROJECTOR_LAG_WARN_S:  "10"
    PROJECTOR_LAG_CRIT_S:  "60"
    PROJECTOR_SETTLE_MS:   "2000"
  depends_on:
    postgres:
      condition: service_healthy
  restart: unless-stopped
```

No inbound ports. The api reads `projector_state` from the shared Postgres directly. Uses the same
`asyncpg` pool pattern as `/Users/jn/code/mras-ops/api/src/main.py:23`.

**Migration 018 must land before the service starts.** Migrations run via the Postgres init-dir mount
already in compose. Migration 018 creates:
- `projector_state` (singleton cursor table).
- `observation_tracks.camera_screen_id text NOT NULL` (new column for the D-A idempotency key).
- `UNIQUE(camera_screen_id, camera_track_id)` on `observation_tracks`.
- `UNIQUE(subject_observation_id, rank)` on `identity_matches`.
- `UNIQUE(event_id)` on `personalization_decisions` (`event_id` column made NOT NULL).
- `UNIQUE(trigger_id)` on `composition_runs` (`trigger_id` column made NOT NULL).
- `UNIQUE(ad_run_id, subject_observation_id)` on `viewer_exposures` (both columns made NOT NULL).

**Start/stop story.** The projector starts with `docker compose up`. On SIGTERM it finishes the current
batch transaction (or rolls back), releases the advisory lock, and exits cleanly. Restart resumes from
`projector_state.cursor` — no data loss, no double-counting.

---

## Open Items for the Build

These are unresolved before code can be written. They are distinct from the CTO decisions (D-A through
D-E), which are settled.

1. **Event-emission lane must enrich payloads before most summary tables can be populated.** The
   projection map above shows many rows — `composition_runs`, `personalization_decisions`,
   `identity_matches` — that depend on `composition`-lifecycle events (`queued/selected/rendered`) that
   do not exist today. `mras-composer` currently emits only coarse `composition`/`orchestrated` status
   strings. Until Lane C adds the granular events, those summary tables stay empty even with the
   projector running. See the grounding document's Gap A list for the full set of tables affected.

2. **`viewer_exposures` cardinality.** D-A settled the constraint as `UNIQUE(ad_run_id,
   subject_observation_id)` — one row per (ad run × observed subject detection). If the business
   requirement is "one row per (ad run × identified subject profile)" across multiple observations,
   the key should instead be `UNIQUE(ad_run_id, subject_profile_id)`. This needs confirmation before
   migration 018 is written.

3. **Full-rebuild trigger and safety.** Is the rebuild endpoint admin-only HTTP, CLI one-shot, or a
   compose override (`REBUILD_FROM_SCRATCH=1`)? Does the live worker pause (advisory-lock handoff)
   during rebuild, or does the rebuild run as a second process holding the same lock? The answer affects
   the device-registration backfill story (§Idempotency) and the demo-day runbook.

4. **Back-stamping `events.*` scope columns.** Projector-only resolution (D-C) is accepted. Open
   question: does the projector also back-stamp the `events.camera_id`, `events.display_id`,
   `events.system_id` columns in the same batch transaction? If yes, the live-feed scope filters
   (`events_system_ts_idx`, `events_location_ts_idx`) work without the projector being ahead; if no,
   the live feed shows unscoped events until the projector catches up. Recommend yes (back-stamp),
   but confirm before implementing to avoid an unwanted second writer on `events`.

5. **Rebuild on device registration.** When a device is registered via the admin UI (T3), the operator
   must be prompted or the system must automatically trigger a ranged rebuild to back-fill scope uuids
   for events that were processed while the device was unregistered. The UX and automation level of
   this prompt are not yet decided.
