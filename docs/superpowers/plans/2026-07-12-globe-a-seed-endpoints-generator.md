# God View Globe — Plan A: seed, map endpoints, demo-traffic generator (mras-ops)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Globe page its backend: a tagged, reversible demo fleet seeded into the dev Postgres, two read-only rollup endpoints (`GET /god-view/map`, `GET /god-view/map/locations/{id}`), and an opt-in demo-traffic generator that pushes well-formed event sequences through the real events→projector→summaries spine.

**Architecture:** Seeds are plain SQL applied manually to the dev DB (never via initdb migrations), scoped by a fixed demo-org UUID plus `demo_seed` tags. The endpoints are new read helpers in `/Users/jn/code/mras-ops/api/src/godview/map.py` wired into `/Users/jn/code/mras-ops/api/src/main.py`, computing rollups on the fly from base tables (no summary tables exist) — `/map` is ONE set-based GROUP BY query. The generator (`/Users/jn/code/mras-ops/scripts/demo_traffic.py`) only appends to `events` with payload shapes copied from the real composer emitters; the projector's single-writer fold is untouched.

**Tech Stack:** PostgreSQL 16 (dockerized, `mras-ops-postgres-1`), FastAPI + asyncpg (ops-api container `mras-ops-mras-ops-api-1` on :8080), pytest + pytest-asyncio (throwaway-DB fixtures), plain-SQL seeds, stdlib-argparse asyncpg script.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-11-globe-view-design.md` §3 (encodings), §4 (endpoints), §5 (seed/teardown), §6 (generator), §7 Plan A.

---

## Recon findings that bind this plan (read before implementing)

These were verified against the live repos/DB on 2026-07-12; where the spec's assumptions differ, the finding below wins (the spec itself says exact shapes are recon'd at plan time).

1. **Projector payload field names (ground truth from `/Users/jn/code/mras-ops/api/src/projector/handlers.py` and the composer emitters in `/Users/jn/code/mras-composer/main.py` + `/Users/jn/code/mras-composer/src/orchestrator/renderer.py`):**
   - Every event payload carries `screen_id` + `screen_kind` (`"camera"` or `"display"`); the fold resolves scope from these (typed events scope columns are ignored on read — `/Users/jn/code/mras-ops/api/src/projector/events.py`).
   - `service` must be `'mras-composer'` and `(event_type, status)` must be one of the registry keys in `/Users/jn/code/mras-ops/api/src/projector/routing.py`: `composition/{queued,rendering,rendered,failed}`, `ad_run/{planned,dispatched,playing,completed,failed}`, `playback/{dispatched,started,ended,interrupted}`. `env.status` itself becomes the enum value — payload needs no `status` field.
   - Real composer scope convention: **composition + ad_run/planned use camera scope** (`screen_kind:"camera"`, the trigger camera's `screen_id`); **playback/* and ad_run/{dispatched,playing,completed} use display scope**. The generator mirrors this.
   - Timestamps travel as ISO-8601 strings in payload (`started_at`, `ended_at`, `dispatched_at`) — handlers cast `$n::text::timestamptz`.
   - `playback/dispatched` payload includes `ad_run_trigger_id` (same value as the trigger) and `media_asset_ref` (nullable). `playback/ended` may carry `duration_ms`.
   - Nullable ad/subject FKs (`ad_id`, `campaign_id`, `target_subject_profile_id`, …) are simply **omitted** — a payload naming a non-existent `ad_id` FK-violates inside the per-event savepoint and the pulse is silently dropped to `projector.skip`.
2. **`metadata` jsonb does NOT exist on every table** (spec §5 assumed it does): `systems` has `config` jsonb (not metadata); `cameras`/`displays` have `calibration` jsonb only. Tagging plan: `organizations.metadata`, `locations.metadata`, `location_participants.metadata`, `screen_groups.metadata` get `{"demo_seed": true}`; `systems` get it in `config`; cameras/displays are identified by their `demo-` screen_id prefix + system join (org scope remains the primary key for teardown).
3. **FK cycle the spec's teardown order misses:** `events.ad_run_id → ad_runs` (016) while `personalization_decisions.event_id → events` and `ad_runs.personalization_decision_id → personalization_decisions`. The projector **back-stamps `ad_run_id` onto demo events** (`_backstamp` in `/Users/jn/code/mras-ops/api/src/projector/fold.py`), so deleting `ad_runs` before `events` FK-violates. Teardown must first `UPDATE events SET ad_run_id = NULL` for demo-scoped rows. Similarly `unresolved_devices.event_id → events` (020) needs a defensive NULL-out before deleting demo events.
4. **Idle playbacks:** the composer emits ad-run-less `playback/dispatched` rows for idle segments (`_emit_idle` in `/Users/jn/code/mras-ops/../mras-composer/src/orchestrator/runtime.py`) that never receive `ended`. The `/map` "playing" encoding must only count open playbacks whose trigger has an `ad_runs`/`composition_runs` row, else the real venue glows "playing" forever.
5. **Live IDs (queried from the dev DB 2026-07-12):** real demo org `55bf0abd-def0-47e1-847a-86ea9c7d7f0b` ("Demo Org"), real demo system `d8d2d05d-0a73-463b-b5d1-fec94255fe78` ("Demo System"), real demo location **`acc4e851-ab7a-4b59-989e-85cb8b597e14`** ("Demo Store", lat/lng currently NULL) — this is the target of the guarded lat/lng UPDATE. If the dev DB has been rebuilt since, re-run `docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT id,name FROM locations"` and fix the literal in the seed before applying.
6. **Test harness:** api-side DB tests live in `/Users/jn/code/mras-ops/api/tests/` and run with host python: `cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/ -q` (verified green 2026-07-12). They build a throwaway `mras_projector_test` DB on the live PG16 server via the module-scoped `projector_pool` fixture + function-scoped `godview_isolate` truncation fixture in `/Users/jn/code/mras-ops/api/tests/conftest.py` — the real `mras` DB is untouched, safe to run anytime. Repo-root script tests live in `/Users/jn/code/mras-ops/tests/` and run `cd /Users/jn/code/mras-ops && python3 -m pytest tests/<file> -q`. Both need the dockerized Postgres up: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`.
7. **ops-api code is baked into the image** (no bind mount): new endpoints require `cd /Users/jn/code/mras-ops && docker compose build mras-ops-api && docker compose up -d mras-ops-api`. The projector container needs **no** rebuild for this plan (no projector code changes; seeds add no enum values, so no asyncpg enum-codec staleness).
8. **Projector pacing:** `settle_ms=2000` + `poll_ms=1000` (`/Users/jn/code/mras-ops/api/src/projector/config.py`) ⇒ summary rows trail event inserts by ~2–3 s. Generator beats are spaced ≥3 s; live-drill assertions wait ≥5 s after emission.

## Global Constraints

- **No schema changes, no new migrations.** Seeds live in `/Users/jn/code/mras-ops/db/seed/` (create the directory), never in `/Users/jn/code/mras-ops/db/migrations/`.
- **All git via the `git-flow-manager` subagent** — the executor never runs raw `git`/`gh`. One branch for this plan, e.g. `feat/globe-a-seed-endpoints-generator`, created from `main`. **Red test commit separate from green impl commit** (TDD pairs; the red must be run and seen failing before the impl is written). Merge commits (not squash) at PR time.
- Reference every file by absolute path in commits/PR/docs.
- **Never touch `projector_state`** (the cursor) in seed or teardown; never "rebuild the projector" as cleanup.
- Endpoints are **read-only**; `/map` rollups come from ONE set-based query (CTEs are fine; per-venue subqueries are not).
- `curl`/`wget` are blocked in the authoring session and may be blocked for the executor — all HTTP live checks use `python3` + `urllib.request` one-liners.
- Dev-stack precondition for any live step: `cd /Users/jn/code/mras-ops && docker compose ps` must show `postgres`, `mras-ops-api`, `mras-ops-projector` up. Bring up with `docker compose up -d postgres mras-ops-api mras-ops-projector`.
- Fixed demo-org UUID used everywhere (seed, teardown, tests, generator): **`dea00000-0000-4000-8000-000000000001`**, org name **`Demo Retail Group`**.

---

## Task 1 — Demo fleet seed SQL (`seed_demo_fleet.sql`)

**Files**
- Create: `/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql`
- Test: `/Users/jn/code/mras-ops/api/tests/test_demo_seed.py`

**Interfaces**
- Consumes: schema tables `organizations`, `locations`, `location_participants`, `systems`, `screen_groups`, `cameras`, `displays` (migrations 011/012/025); enum values `host`, `mall`/`airport`/`store`, `onsite_mras`, `zone`, `detection`, `primary_ad`, device_status values (010/025).
- Produces: 1 org (`dea00000-0000-4000-8000-000000000001`), 13 venues (12–15 band per spec), 38 systems (2–5/venue), 1–2 cameras + 2–6 displays per system, 1 screen_group per system, 13 location_participants; deterministic ids via `md5('demo-fleet:…')::uuid`; deterministic screen_ids `demo-cam-<slug>-<sys>-<n>` / `demo-disp-<slug>-<sys>-<n>`; status spread (3 degraded + 1 offline display, 1 degraded + 1 offline camera); guarded single-row UPDATE giving the real "Demo Store" location lat/lng. Idempotent: every INSERT is `ON CONFLICT DO NOTHING`; UPDATEs are absolute assignments.

### Steps

- [ ] **1.1 Write the failing test** — create `/Users/jn/code/mras-ops/api/tests/test_demo_seed.py`:

```python
"""Demo fleet seed (Globe Plan A): shape, tags, idempotency.

Runs against the throwaway mras_projector_test DB (projector_pool fixture).
Requires the dockerized Postgres running:
    cd /Users/jn/code/mras-ops && docker compose up -d postgres
"""
import pathlib

import pytest

pytestmark = pytest.mark.usefixtures("godview_isolate")

SEED = pathlib.Path(__file__).resolve().parents[2] / "db" / "seed" / "seed_demo_fleet.sql"
DEMO_ORG = "dea00000-0000-4000-8000-000000000001"
REAL_DEMO_LOCATION = "acc4e851-ab7a-4b59-989e-85cb8b597e14"  # dev-DB "Demo Store"


async def _apply_seed(pool):
    async with pool.acquire() as conn:
        await conn.execute(SEED.read_text())


async def test_seed_creates_tagged_org_and_venues(projector_pool):
    await _apply_seed(projector_pool)
    org = await projector_pool.fetchrow(
        "SELECT name, organization_type::text AS t, metadata->>'demo_seed' AS tag "
        "FROM organizations WHERE id = $1", DEMO_ORG)
    assert org is not None
    assert org["name"] == "Demo Retail Group"
    assert org["t"] == "host"
    assert org["tag"] == "true"

    venues = await projector_pool.fetch(
        "SELECT id, location_type::text AS lt, lat, lng, city, country, timezone "
        "FROM locations WHERE metadata->>'demo_seed' = 'true'")
    assert 12 <= len(venues) <= 15
    # every seeded venue plots: real lat/lng + city/country/timezone present
    for v in venues:
        assert v["lat"] is not None and v["lng"] is not None
        assert v["city"] and v["country"] and v["timezone"]
    types = {v["lt"] for v in venues}
    assert "mall" in types and "airport" in types and "store" in types


async def test_seed_fleet_shape_per_venue_and_system(projector_pool):
    await _apply_seed(projector_pool)
    per_venue = await projector_pool.fetch(
        "SELECT location_id, count(*) AS n FROM systems "
        "WHERE organization_id = $1 GROUP BY location_id", DEMO_ORG)
    assert len(per_venue) >= 12
    assert all(2 <= r["n"] <= 5 for r in per_venue)

    shape = await projector_pool.fetch(
        """
        SELECT s.id,
               (SELECT count(*) FROM cameras c  WHERE c.system_id = s.id) AS cams,
               (SELECT count(*) FROM displays d WHERE d.system_id = s.id) AS disps,
               (SELECT count(*) FROM screen_groups g WHERE g.system_id = s.id) AS grps
        FROM systems s WHERE s.organization_id = $1
        """, DEMO_ORG)
    for r in shape:
        assert 1 <= r["cams"] <= 2
        assert 2 <= r["disps"] <= 6
        assert r["grps"] == 1  # one screen_group per system (multi-display grouping)
    # systems tagged via config (systems has config jsonb, not metadata)
    untagged = await projector_pool.fetchval(
        "SELECT count(*) FROM systems WHERE organization_id = $1 "
        "AND config->>'demo_seed' IS DISTINCT FROM 'true'", DEMO_ORG)
    assert untagged == 0
    # every device carries the demo- screen_id namespace and joins a demo system
    stray = await projector_pool.fetchval(
        "SELECT count(*) FROM cameras c JOIN systems s ON s.id = c.system_id "
        "WHERE s.organization_id = $1 AND c.screen_id NOT LIKE 'demo-cam-%'", DEMO_ORG)
    assert stray == 0


async def test_seed_status_spread(projector_pool):
    await _apply_seed(projector_pool)
    disp = await projector_pool.fetch(
        "SELECT status::text AS st, count(*) AS n FROM displays d "
        "JOIN systems s ON s.id = d.system_id WHERE s.organization_id = $1 "
        "GROUP BY status", DEMO_ORG)
    by = {r["st"]: r["n"] for r in disp}
    assert by.get("degraded", 0) >= 1
    assert by.get("offline", 0) >= 1
    assert by.get("active", 0) > by.get("degraded", 0) + by.get("offline", 0)  # mostly healthy
    cam_bad = await projector_pool.fetchval(
        "SELECT count(*) FROM cameras c JOIN systems s ON s.id = c.system_id "
        "WHERE s.organization_id = $1 AND c.status IN ('degraded','offline')", DEMO_ORG)
    assert cam_bad >= 1


async def test_seed_idempotent(projector_pool):
    await _apply_seed(projector_pool)
    counts1 = await projector_pool.fetchrow(
        "SELECT (SELECT count(*) FROM locations) AS l, (SELECT count(*) FROM systems) AS s, "
        "(SELECT count(*) FROM cameras) AS c, (SELECT count(*) FROM displays) AS d, "
        "(SELECT count(*) FROM screen_groups) AS g, (SELECT count(*) FROM location_participants) AS lp")
    await _apply_seed(projector_pool)  # re-run must be a clean no-op
    counts2 = await projector_pool.fetchrow(
        "SELECT (SELECT count(*) FROM locations) AS l, (SELECT count(*) FROM systems) AS s, "
        "(SELECT count(*) FROM cameras) AS c, (SELECT count(*) FROM displays) AS d, "
        "(SELECT count(*) FROM screen_groups) AS g, (SELECT count(*) FROM location_participants) AS lp")
    assert dict(counts1) == dict(counts2)


async def test_seed_guarded_update_is_scoped_to_real_demo_location(projector_pool):
    # In the throwaway DB the real demo location id does not exist: the guarded
    # UPDATE must update zero rows and never invent it or touch other locations.
    await projector_pool.execute(
        "INSERT INTO locations (id, name, location_type) VALUES "
        "('11111111-1111-4111-8111-111111111111', 'Innocent Bystander', 'store')")
    await _apply_seed(projector_pool)
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM locations WHERE id = $1", REAL_DEMO_LOCATION) == 0
    row = await projector_pool.fetchrow(
        "SELECT lat, lng FROM locations WHERE id = '11111111-1111-4111-8111-111111111111'")
    assert row["lat"] is None and row["lng"] is None
```

- [ ] **1.2 Run it and watch it fail** (dev postgres must be up: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_seed.py -q
```

Expected failure: `FileNotFoundError: .../db/seed/seed_demo_fleet.sql` in every test (the seed file does not exist yet).

- [ ] **1.3 Commit the red test** — message: `test: red — demo fleet seed shape/tags/idempotency (Globe Plan A T1)` (executor delegates the commit to the git-flow-manager subagent; same for every commit step below).

- [ ] **1.4 Write the seed** — create `/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql`:

```sql
-- /Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql
-- God View Globe Plan A (spec 2026-07-11 §5): "Demo Retail Group" fake fleet.
-- Seeds live OUTSIDE db/migrations/ on purpose — initdb applies migrations on
-- fresh volumes and fake data must never bake into every fresh DB.
-- Apply manually:
--   docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
-- Idempotent: fixed/derived uuids + ON CONFLICT DO NOTHING; re-running is a no-op.
-- Reverse with /Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql.
-- Scope tags: org id dea00000-0000-4000-8000-000000000001 is primary;
-- metadata.demo_seed=true on org/locations/location_participants/screen_groups;
-- systems carry it in config (systems has no metadata column); cameras/displays
-- have neither (calibration only) — they are identified by the demo- screen_id
-- namespace + their system join.

BEGIN;

INSERT INTO organizations (id, name, organization_type, status, metadata)
VALUES ('dea00000-0000-4000-8000-000000000001', 'Demo Retail Group', 'host',
        'active', '{"demo_seed": true}')
ON CONFLICT DO NOTHING;

-- Venue catalog: 13 venues, real coordinates, US/EU/APAC; malls + one airport
-- + one showroom (location_type 'store'). n_systems drives the 2-5 spread.
CREATE TEMP TABLE demo_venues (
    slug text, name text, ltype text, city text, country text, tz text,
    lat numeric, lng numeric, n_systems int
) ON COMMIT DROP;
INSERT INTO demo_venues VALUES
  ('moa',      'Mall of America',                'mall',    'Bloomington',     'US', 'America/Chicago',      44.8549,  -93.2422, 4),
  ('kop',      'King of Prussia Mall',           'mall',    'King of Prussia', 'US', 'America/New_York',     40.0885,  -75.3946, 3),
  ('century',  'Westfield Century City',         'mall',    'Los Angeles',     'US', 'America/Los_Angeles',  34.0584, -118.4173, 3),
  ('aventura', 'Aventura Mall',                  'mall',    'Aventura',        'US', 'America/New_York',     25.9565,  -80.1428, 2),
  ('yorkdale', 'Yorkdale Shopping Centre',       'mall',    'Toronto',         'CA', 'America/Toronto',      43.7255,  -79.4522, 2),
  ('wlondon',  'Westfield London',               'mall',    'London',          'GB', 'Europe/London',        51.5079,   -0.2216, 4),
  ('berlin',   'Mall of Berlin',                 'mall',    'Berlin',          'DE', 'Europe/Berlin',        52.5100,   13.3805, 2),
  ('partdieu', 'Westfield La Part-Dieu',         'mall',    'Lyon',            'FR', 'Europe/Paris',         45.7610,    4.8570, 2),
  ('dubai',    'The Dubai Mall',                 'mall',    'Dubai',           'AE', 'Asia/Dubai',           25.1972,   55.2796, 5),
  ('siam',     'Siam Paragon',                   'mall',    'Bangkok',         'TH', 'Asia/Bangkok',         13.7462,  100.5347, 2),
  ('chadstone','Chadstone Shopping Centre',      'mall',    'Melbourne',       'AU', 'Australia/Melbourne', -37.8859,  145.0838, 3),
  ('changi',   'Changi Airport Terminal 3',      'airport', 'Singapore',       'SG', 'Asia/Singapore',        1.3554,  103.9866, 4),
  ('fifthave', 'Fifth Avenue Flagship Showroom', 'store',   'New York',        'US', 'America/New_York',     40.7638,  -73.9730, 2);

INSERT INTO locations (id, name, location_type, city, country, lat, lng, timezone, status, metadata)
SELECT md5('demo-fleet:loc:' || slug)::uuid, name, ltype::location_type,
       city, country, lat, lng, tz, 'active', '{"demo_seed": true}'
FROM demo_venues
ON CONFLICT DO NOTHING;

INSERT INTO location_participants (id, location_id, organization_id, role, status, metadata)
SELECT md5('demo-fleet:lp:' || slug)::uuid, md5('demo-fleet:loc:' || slug)::uuid,
       'dea00000-0000-4000-8000-000000000001', 'host', 'active', '{"demo_seed": true}'
FROM demo_venues
ON CONFLICT DO NOTHING;

-- Systems: n_systems per venue, concept-doc style names, deterministic ids.
CREATE TEMP TABLE demo_systems ON COMMIT DROP AS
SELECT md5('demo-fleet:sys:' || v.slug || ':' || i)::uuid          AS id,
       md5('demo-fleet:loc:' || v.slug)::uuid                     AS location_id,
       v.slug                                                     AS slug,
       i                                                          AS sys_idx,
       (ARRAY['Entrance Wall A','Food Court Wall','Atrium Displays',
              'Concourse Screens','Promenade Wall'])[i]           AS name,
       (ARRAY['Level 1','Food Court','Atrium','Concourse B','Promenade'])[i] AS zone
FROM demo_venues v, generate_series(1, v.n_systems) AS i;

INSERT INTO systems (id, organization_id, location_id, name, system_type, zone, status, config)
SELECT id, 'dea00000-0000-4000-8000-000000000001', location_id, name,
       'onsite_mras', zone, 'active', '{"demo_seed": true}'
FROM demo_systems
ON CONFLICT DO NOTHING;

-- One screen_group per system (spec: screen_groups where multi-display; every
-- demo system has >=2 displays).
INSERT INTO screen_groups (id, system_id, location_id, name, group_type, status, metadata)
SELECT md5('demo-fleet:grp:' || slug || ':' || sys_idx)::uuid, id, location_id,
       name || ' Group', 'zone', 'active', '{"demo_seed": true}'
FROM demo_systems
ON CONFLICT DO NOTHING;

-- Cameras: 1-2 per system (1 + sys_idx % 2). screen_id is globally UNIQUE (020)
-- so the demo- namespace guarantees no collision with real devices
-- ('screen_0', 'display-2', ...).
INSERT INTO cameras (id, system_id, location_id, screen_group_id, name,
                     camera_role, screen_id, status, last_seen_at)
SELECT md5('demo-fleet:cam:' || s.slug || ':' || s.sys_idx || ':' || c)::uuid,
       s.id, s.location_id,
       md5('demo-fleet:grp:' || s.slug || ':' || s.sys_idx)::uuid,
       s.name || ' Cam ' || c, 'detection',
       'demo-cam-' || s.slug || '-' || s.sys_idx || '-' || c,
       'active', now()
FROM demo_systems s, generate_series(1, 1 + s.sys_idx % 2) AS c
ON CONFLICT DO NOTHING;

-- Displays: 2-6 per system (2 + (sys_idx*3) % 5).
INSERT INTO displays (id, system_id, location_id, screen_group_id, name,
                      screen_id, display_role, status, last_seen_at)
SELECT md5('demo-fleet:disp:' || s.slug || ':' || s.sys_idx || ':' || d)::uuid,
       s.id, s.location_id,
       md5('demo-fleet:grp:' || s.slug || ':' || s.sys_idx)::uuid,
       s.name || ' Display ' || d,
       'demo-disp-' || s.slug || '-' || s.sys_idx || '-' || d,
       'primary_ad', 'active', now()
FROM demo_systems s, generate_series(1, 2 + (s.sys_idx * 3) % 5) AS d
ON CONFLICT DO NOTHING;

-- Status spread so Health mode has something to show (mostly healthy, a couple
-- of warning/offline devices). Deterministic screen_ids; idempotent UPDATEs.
UPDATE displays SET status = 'degraded'
WHERE screen_id IN ('demo-disp-wlondon-2-1', 'demo-disp-moa-3-2', 'demo-disp-dubai-4-1');
UPDATE displays SET status = 'offline', last_seen_at = now() - interval '3 hours'
WHERE screen_id = 'demo-disp-changi-1-2';
UPDATE cameras SET status = 'degraded'
WHERE screen_id = 'demo-cam-century-2-1';
UPDATE cameras SET status = 'offline', last_seen_at = now() - interval '5 hours'
WHERE screen_id = 'demo-cam-kop-1-1';

-- Real demo box gets coordinates so it plots as the one live dot (spec §5).
-- GUARDED single-row UPDATE: locations.id acc4e851-ab7a-4b59-989e-85cb8b597e14
-- is the dev DB's "Demo Store" (verified live 2026-07-12). If the dev DB was
-- rebuilt since, re-check the id before applying. Coordinates are the demo rig's
-- site — placeholder San Francisco; adjust the literals if the rig moves.
-- "lat IS NULL" guard: never clobbers owner-set coordinates; re-runs are no-ops.
-- Teardown intentionally leaves this row untouched ("leave as-is" set).
UPDATE locations
SET lat = 37.7749, lng = -122.4194,
    city    = COALESCE(NULLIF(city, ''), 'San Francisco'),
    country = COALESCE(NULLIF(country, ''), 'US'),
    updated_at = now()
WHERE id = 'acc4e851-ab7a-4b59-989e-85cb8b597e14' AND lat IS NULL;

COMMIT;
```

- [ ] **1.5 Run the test to green:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_seed.py -q
```

Expected: `5 passed`.

- [ ] **1.6 Commit the green impl** — message: `feat: demo fleet seed SQL — Demo Retail Group, 13 venues, deterministic ids, guarded Demo Store lat/lng (Globe Plan A T1)`.

---

## Task 2 — Teardown SQL (`teardown_demo_fleet.sql`)

**Files**
- Create: `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql`
- Test: `/Users/jn/code/mras-ops/api/tests/test_demo_teardown.py`

**Interfaces**
- Consumes: the demo org id + tags from Task 1; the FK graph of migrations 012/013/015/016/020/025 (no ON DELETE CASCADE anywhere).
- Produces: dependency-ordered, org-scoped deletes leaving **zero** seeded/derived demo rows; two cycle-breaker UPDATEs (`events.ad_run_id`, `unresolved_devices.event_id` — recon finding 3); never touches `projector_state`, the real "Demo Org"/"Demo System"/"Demo Store" rows, or the Demo Store lat/lng set by the seed.

### Steps

- [ ] **2.1 Write the failing test** — create `/Users/jn/code/mras-ops/api/tests/test_demo_teardown.py`:

```python
"""Demo fleet teardown (Globe Plan A): dependency-ordered delete leaves zero
demo rows, survives projector-shaped activity (back-stamped events.ad_run_id),
preserves real rows and the projector cursor.

Requires the dockerized Postgres running:
    cd /Users/jn/code/mras-ops && docker compose up -d postgres
"""
import json
import pathlib
import uuid

import pytest

pytestmark = pytest.mark.usefixtures("godview_isolate")

BASE = pathlib.Path(__file__).resolve().parents[2] / "db" / "seed"
SEED = BASE / "seed_demo_fleet.sql"
TEARDOWN = BASE / "teardown_demo_fleet.sql"
DEMO_ORG = "dea00000-0000-4000-8000-000000000001"


async def _apply(pool, path):
    async with pool.acquire() as conn:
        await conn.execute(path.read_text())


async def _inject_demo_activity(pool):
    """Simulate what the generator + projector produce: composition_run, ad_run,
    playback, and an events row BACK-STAMPED with ad_run_id (the FK cycle the
    teardown must break), plus an unresolved_devices row pointing at a demo event."""
    row = await pool.fetchrow(
        "SELECT s.id AS system_id, s.location_id, d.screen_id "
        "FROM systems s JOIN displays d ON d.system_id = s.id "
        "WHERE s.organization_id = $1 LIMIT 1", DEMO_ORG)
    trig = uuid.uuid4()
    comp_id = await pool.fetchval(
        "INSERT INTO composition_runs (trigger_id, organization_id, location_id, system_id, status) "
        "VALUES ($1,$2,$3,$4,'rendered') RETURNING id",
        trig, uuid.UUID(DEMO_ORG), row["location_id"], row["system_id"])
    ad_run_id = await pool.fetchval(
        "INSERT INTO ad_runs (trigger_id, organization_id, location_id, system_id, "
        "composition_run_id, status) VALUES ($1,$2,$3,$4,$5,'completed') RETURNING id",
        trig, uuid.UUID(DEMO_ORG), row["location_id"], row["system_id"], comp_id)
    await pool.execute(
        "INSERT INTO playbacks (trigger_id, screen_id, ad_run_id, organization_id, "
        "location_id, system_id, status) VALUES ($1,$2,$3,$4,$5,$6,'ended')",
        trig, row["screen_id"], ad_run_id, uuid.UUID(DEMO_ORG),
        row["location_id"], row["system_id"])
    event_id = await pool.fetchval(
        "INSERT INTO events (trigger_id, service, event_type, status, payload, "
        "organization_id, location_id, system_id, ad_run_id) "
        "VALUES ($1,'mras-composer','ad_run','completed',$2::jsonb,$3,$4,$5,$6) RETURNING id",
        trig, json.dumps({"demo_seed": True, "screen_id": row["screen_id"],
                          "screen_kind": "display"}),
        uuid.UUID(DEMO_ORG), row["location_id"], row["system_id"], ad_run_id)
    await pool.execute(
        "INSERT INTO unresolved_devices (screen_id, kind, event_id) VALUES ($1,'display',$2)",
        "demo-disp-never-registered", event_id)
    return trig


async def test_teardown_leaves_zero_demo_rows(projector_pool):
    await _apply(projector_pool, SEED)
    await _inject_demo_activity(projector_pool)
    await _apply(projector_pool, TEARDOWN)

    checks = {
        "organizations": "SELECT count(*) FROM organizations WHERE id = $1",
        "locations": ("SELECT count(*) FROM locations WHERE metadata->>'demo_seed' = 'true'", None),
        "location_participants": "SELECT count(*) FROM location_participants WHERE organization_id = $1",
        "systems": "SELECT count(*) FROM systems WHERE organization_id = $1",
        "ad_runs": "SELECT count(*) FROM ad_runs WHERE organization_id = $1",
        "composition_runs": "SELECT count(*) FROM composition_runs WHERE organization_id = $1",
        "playbacks": "SELECT count(*) FROM playbacks WHERE organization_id = $1",
        "events": "SELECT count(*) FROM events WHERE organization_id = $1",
    }
    for name, q in checks.items():
        if isinstance(q, tuple):
            n = await projector_pool.fetchval(q[0])
        else:
            n = await projector_pool.fetchval(q, uuid.UUID(DEMO_ORG))
        assert n == 0, f"{name} still has demo rows"
    # devices/groups are gone (their parent systems are gone; count all —
    # godview_isolate started us from a clean slate)
    for table in ("cameras", "displays", "screen_groups"):
        assert await projector_pool.fetchval(f"SELECT count(*) FROM {table}") == 0, table
    # events with demo payload tag are gone too (belt-and-braces clause)
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM events WHERE payload->>'demo_seed' = 'true'") == 0


async def test_teardown_preserves_real_rows_and_cursor(projector_pool):
    # a "real" org/location/system + activity that must survive
    real_org, real_loc, real_sys = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Demo Org','host')", real_org)
    await projector_pool.execute(
        "INSERT INTO locations (id,name,location_type) VALUES ($1,'Demo Store','store')", real_loc)
    await projector_pool.execute(
        "INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,'Demo System')",
        real_sys, real_org, real_loc)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,organization_id,system_id,status) VALUES ($1,$2,$3,'completed')",
        uuid.uuid4(), real_org, real_sys)
    await projector_pool.execute("UPDATE projector_state SET cursor = 4242 WHERE id = 1")

    await _apply(projector_pool, SEED)
    await _apply(projector_pool, TEARDOWN)

    assert await projector_pool.fetchval(
        "SELECT count(*) FROM organizations WHERE id = $1", real_org) == 1
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM systems WHERE id = $1", real_sys) == 1
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM ad_runs WHERE organization_id = $1", real_org) == 1
    # NEVER touch the projector cursor (spec §5)
    assert await projector_pool.fetchval(
        "SELECT cursor FROM projector_state WHERE id = 1") == 4242


async def test_teardown_idempotent(projector_pool):
    await _apply(projector_pool, SEED)
    await _apply(projector_pool, TEARDOWN)
    await _apply(projector_pool, TEARDOWN)  # second run: clean no-op, no errors
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM organizations WHERE id = $1", uuid.UUID(DEMO_ORG)) == 0
```

- [ ] **2.2 Run it and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_teardown.py -q
```

Expected failure: `FileNotFoundError: .../db/seed/teardown_demo_fleet.sql` in all 3 tests.

- [ ] **2.3 Commit the red test** — message: `test: red — demo fleet teardown zero-rows/preservation/idempotency (Globe Plan A T2)`.

- [ ] **2.4 Write the teardown** — create `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql`:

```sql
-- /Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql
-- Reverses /Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql plus everything
-- the demo-traffic generator + projector derived from it (spec 2026-07-11 §5).
-- Apply manually (stop scripts/demo_traffic.py first):
--   docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/teardown_demo_fleet.sql
--
-- EXPLICIT DEPENDENCY ORDER (no ON DELETE CASCADE exists anywhere in the schema).
-- Two FK cycle-breakers the spec's enumeration needs (recon 2026-07-12):
--   * events.ad_run_id -> ad_runs is BACK-STAMPED by the projector fold, while
--     personalization_decisions.event_id -> events and
--     ad_runs.personalization_decision_id -> personalization_decisions close a
--     cycle — NULL events.ad_run_id for demo rows before deleting ad_runs.
--   * unresolved_devices.event_id -> events — NULL it for demo events.
-- NEVER reset projector_state / never "rebuild" the projector as cleanup.
-- LEAVE-AS-IS SET: the real "Demo Org" (55bf0abd-...), "Demo System"
-- (d8d2d05d-...), and "Demo Store" (acc4e851-...) rows — including the lat/lng
-- the seed gave Demo Store — are intentionally untouched.
-- Idempotent: every statement is scoped; re-running deletes nothing.

BEGIN;

-- 0. Cycle breakers
UPDATE events SET ad_run_id = NULL
WHERE ad_run_id IN (
    SELECT id FROM ad_runs
    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
       OR system_id IN (SELECT id FROM systems
                        WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'));
UPDATE unresolved_devices SET event_id = NULL
WHERE event_id IN (SELECT id FROM events
                   WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
                      OR payload->>'demo_seed' = 'true');

-- 1. Projector-derived activity leaves (children of everything else). Scoped by
-- org AND by demo systems (belt-and-braces: a row folded before back-stamping
-- would still carry the demo system scope).
DELETE FROM viewer_exposures
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM identity_matches
WHERE subject_observation_id IN (
    SELECT id FROM subject_observations
    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
       OR system_id IN (SELECT id FROM systems
                        WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'));
DELETE FROM playbacks
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');

-- 2. Runs (children before parents: ad_runs -> composition_runs -> decisions)
DELETE FROM ad_runs
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM composition_runs
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM personalization_decisions
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM subject_observations
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');

-- 3. Journal rows (children of ad_runs are gone / nulled; subject_observations
-- and personalization_decisions — the two tables that FK INTO events — are gone).
-- payload clause is belt-and-braces for any row that escaped org-stamping.
DELETE FROM events
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'
   OR payload->>'demo_seed' = 'true';

-- 4. Remaining derived rows keyed on demo devices/systems
DELETE FROM observation_tracks
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001')
   OR camera_screen_id LIKE 'demo-cam-%';
DELETE FROM device_health_events
WHERE device_id IN (SELECT id FROM devices
                    WHERE system_id IN (SELECT id FROM systems
                                        WHERE organization_id = 'dea00000-0000-4000-8000-000000000001'));
DELETE FROM system_health_events
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');

-- 5. Devices -> groups -> systems -> participants -> orphaned venues -> org
DELETE FROM cameras
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM displays
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM screen_groups
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM devices
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id = 'dea00000-0000-4000-8000-000000000001');
DELETE FROM systems
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001';
DELETE FROM location_participants
WHERE organization_id = 'dea00000-0000-4000-8000-000000000001';
-- Only ORPHANED seeded venues (never a tagged location some other system moved
-- into) — and never Demo Store (it is untagged).
DELETE FROM locations
WHERE metadata->>'demo_seed' = 'true'
  AND NOT EXISTS (SELECT 1 FROM systems s WHERE s.location_id = locations.id);
DELETE FROM organizations
WHERE id = 'dea00000-0000-4000-8000-000000000001';

COMMIT;
```

- [ ] **2.5 Run to green:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_teardown.py tests/test_demo_seed.py -q
```

Expected: `8 passed` (3 new + the 5 from Task 1 still green).

- [ ] **2.6 Commit the green impl** — message: `feat: demo fleet teardown SQL — dependency-ordered, org-scoped, events.ad_run_id/unresolved_devices cycle-breakers, cursor untouched (Globe Plan A T2)`.

---

## Task 3 — `GET /god-view/map` (venue rollups, ONE set-based query)

**Files**
- Create: `/Users/jn/code/mras-ops/api/src/godview/map.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (import + route)
- Test: `/Users/jn/code/mras-ops/api/tests/test_godview_map.py`

**Interfaces**
- Consumes: `locations`, `systems`, `cameras`, `displays`, `ad_runs`, `composition_runs`, `playbacks` base tables (the projector writes the run tables; there are no rollup tables).
- Produces: `async def get_map(conn) -> dict` returning
  `{"venues": [{"location_id", "name", "location_type", "city", "country", "lat", "lng", "rollup": {"systems", "cameras", "displays", "worst_status", "active_ad_runs", "composing_count", "playing_count", "runs_last_hour", "failures_last_hour", "last_activity_at"}}]}`.
  Spec §4 shape plus `composing_count`/`playing_count` (the §3 Live-mode encodings need the split; `active_ad_runs = composing_count + playing_count`; key names match Plan B's `apiTypes.ts` exactly — Plan B's selectors fall back to glow-only if these keys are absent, so a name drift here fails silently). One row per venue = location that has ≥1 system; venues without lat/lng are returned with `lat`/`lng` `null` (rail-only, not plotted).
- Encodings (spec §3, against what the projector actually produces):
  - `worst_status`: worst of all device (camera+display) statuses at the venue, precedence `offline > retired > degraded > active` (client colors offline/retired gray, degraded yellow, active green). Red is **not** a device status — it is `failures_last_hour > 0`.
  - `composing_count` ("composing-ish"): triggers with `ad_runs.status = 'planned'`, or an open `composition_runs` (`queued`/`rendering`) that has no ad_run row yet.
  - `playing_count`: triggers with `ad_runs.status IN ('dispatched','playing')`, or an open playback (`dispatched`/`started`) on a trigger that has an ad_run/composition row — the join shape deliberately excludes the composer's ad-run-less idle playbacks (recon finding 4).
  - `failures_last_hour`: ad_runs failed in the last hour + composition_runs failed in the last hour.

### Steps

- [ ] **3.1 Write the failing tests** — create `/Users/jn/code/mras-ops/api/tests/test_godview_map.py`:

```python
"""GET /god-view/map rollups: one set-based query, spec §3/§4 encodings.

Requires the dockerized Postgres running:
    cd /Users/jn/code/mras-ops && docker compose up -d postgres
"""
import uuid

import pytest

from src.godview.map import get_map

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def _org(pool):
    org = uuid.uuid4()
    await pool.execute(
        "INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','host')", org)
    return org


async def _venue(pool, name="Venue", lat=10.0, lng=20.0):
    loc = uuid.uuid4()
    await pool.execute(
        "INSERT INTO locations (id,name,location_type,city,country,lat,lng) "
        "VALUES ($1,$2,'mall','City','US',$3,$4)", loc, name, lat, lng)
    return loc


async def _system(pool, org, loc, name="Sys"):
    sid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,$4)",
        sid, org, loc, name)
    return sid


async def _camera(pool, sid, status="active"):
    await pool.execute(
        "INSERT INTO cameras (system_id,screen_id,status) VALUES ($1,$2,$3)",
        sid, f"cam-{uuid.uuid4()}", status)


async def _display(pool, sid, status="active"):
    await pool.execute(
        "INSERT INTO displays (system_id,screen_id,status) VALUES ($1,$2,$3)",
        sid, f"disp-{uuid.uuid4()}", status)


def _venue_by_name(result, name):
    return next(v for v in result["venues"] if v["name"] == name)


async def test_map_lists_only_locations_with_systems(projector_pool):
    org = await _org(projector_pool)
    loc_with = await _venue(projector_pool, "HasSystems")
    await _venue(projector_pool, "Empty")  # no systems -> not a venue
    await _system(projector_pool, org, loc_with)
    result = await get_map(projector_pool)
    names = [v["name"] for v in result["venues"]]
    assert names == ["HasSystems"]
    v = result["venues"][0]
    assert v["location_id"] == loc_with
    assert v["location_type"] == "mall"
    assert v["lat"] == 10.0 and v["lng"] == 20.0  # float8, not Decimal


async def test_map_device_counts_and_worst_status(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    s1 = await _system(projector_pool, org, loc, "S1")
    s2 = await _system(projector_pool, org, loc, "S2")
    await _camera(projector_pool, s1, "active")
    await _camera(projector_pool, s2, "degraded")
    await _display(projector_pool, s1, "active")
    await _display(projector_pool, s1, "offline")
    await _display(projector_pool, s2, "active")
    v = _venue_by_name(await get_map(projector_pool), "V")
    r = v["rollup"]
    assert r["systems"] == 2
    assert r["cameras"] == 2
    assert r["displays"] == 3
    assert r["worst_status"] == "offline"  # offline > retired > degraded > active


async def test_map_worst_status_degraded_and_all_active(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc)
    await _display(projector_pool, sid, "active")
    await _display(projector_pool, sid, "degraded")
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["worst_status"] == "degraded"


async def test_map_activity_encodings(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc)
    # composing-ish: planned ad_run
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status) VALUES ($1,$2,$3,'planned')",
        uuid.uuid4(), loc, sid)
    # composing-ish: open composition with no ad_run yet
    await projector_pool.execute(
        "INSERT INTO composition_runs (trigger_id,location_id,system_id,status) "
        "VALUES ($1,$2,$3,'rendering')", uuid.uuid4(), loc, sid)
    # playing: dispatched ad_run
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,started_at) "
        "VALUES ($1,$2,$3,'playing', now())", uuid.uuid4(), loc, sid)
    # neither: completed run (still counts toward runs_last_hour via created_at)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,ended_at) "
        "VALUES ($1,$2,$3,'completed', now())", uuid.uuid4(), loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    r = v["rollup"]
    assert r["composing_count"] == 2
    assert r["playing_count"] == 1
    assert r["active_ad_runs"] == 3
    assert r["runs_last_hour"] == 3  # the 3 ad_runs; the bare composition is not a run
    assert r["failures_last_hour"] == 0
    assert r["last_activity_at"] is not None


async def test_map_red_is_failures_last_hour_only(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc)
    # failed inside the window -> counts
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,ended_at) "
        "VALUES ($1,$2,$3,'failed', now() - interval '5 minutes')", uuid.uuid4(), loc, sid)
    # failed outside the window -> does not count (ended_at AND updated_at old)
    old_trig = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,ended_at,updated_at) "
        "VALUES ($1,$2,$3,'failed', now() - interval '2 hours', now() - interval '2 hours')",
        old_trig, loc, sid)
    # failed composition inside the window -> counts
    await projector_pool.execute(
        "INSERT INTO composition_runs (trigger_id,location_id,system_id,status,ended_at) "
        "VALUES ($1,$2,$3,'failed', now() - interval '1 minute')", uuid.uuid4(), loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["failures_last_hour"] == 2


async def test_map_idle_playback_never_glows(projector_pool):
    # Composer idle segments are ad-run-less playback/dispatched rows that never
    # end (recon finding 4) — they must NOT count as playing.
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc)
    await projector_pool.execute(
        "INSERT INTO playbacks (trigger_id,screen_id,location_id,system_id,status) "
        "VALUES ($1,'disp-idle',$2,$3,'dispatched')", uuid.uuid4(), loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["playing_count"] == 0
    # but an open playback WITH its ad_run does count
    trig = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status) "
        "VALUES ($1,$2,$3,'completed')", trig, loc, sid)
    await projector_pool.execute(
        "INSERT INTO playbacks (trigger_id,screen_id,location_id,system_id,status,started_at) "
        "VALUES ($1,'disp-live',$2,$3,'started', now())", trig, loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["playing_count"] == 1


async def test_map_null_latlng_venue_still_listed(projector_pool):
    org = await _org(projector_pool)
    loc = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO locations (id,name,location_type) VALUES ($1,'NoCoords','store')", loc)
    await _system(projector_pool, org, loc)
    v = _venue_by_name(await get_map(projector_pool), "NoCoords")
    assert v["lat"] is None and v["lng"] is None
    assert v["rollup"]["systems"] == 1
```

- [ ] **3.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected failure: `ModuleNotFoundError: No module named 'src.godview.map'` (collection error).

- [ ] **3.3 Commit the red test** — message: `test: red — /god-view/map rollups, worst_status precedence, composing/playing/failure encodings, idle-playback guard (Globe Plan A T3)`.

- [ ] **3.4 Implement** — create `/Users/jn/code/mras-ops/api/src/godview/map.py`:

```python
"""God View Globe map read: one set-based rollup query, one row per venue.

There are no rollup/summary tables — like the dashboard, this computes on the
fly from the base tables the projector writes (ad_runs / composition_runs /
playbacks) joined to the registry (locations / systems / cameras / displays).

Encodings (spec 2026-07-11 §3, defined against what the projector actually
produces — device_status has no 'failing'; red is reserved for activity
failures, not a device status):
  worst_status        worst device status at the venue; offline > retired >
                      degraded > active
  composing_count     triggers with ad_runs.status='planned' OR an open
                      composition (queued/rendering) that has no ad_run row yet
  playing_count       triggers with ad_runs.status in (dispatched, playing) OR
                      an open playback (dispatched/started). Open playbacks are
                      only visible through their ad_run/composition trigger —
                      the composer's ad-run-less idle playbacks (which never
                      receive 'ended') can therefore never glow.
  failures_last_hour  failed ad_runs + failed compositions in the last hour
"""

_MAP_SQL = """
WITH sys AS (
    SELECT location_id, count(*) AS systems
    FROM systems
    GROUP BY location_id
),
dev AS (
    SELECT s.location_id,
           count(*) FILTER (WHERE d.kind = 'camera')  AS cameras,
           count(*) FILTER (WHERE d.kind = 'display') AS displays,
           max(CASE d.status WHEN 'offline' THEN 4 WHEN 'retired' THEN 3
                             WHEN 'degraded' THEN 2 ELSE 1 END) AS worst_rank
    FROM (
        SELECT system_id, 'camera' AS kind, status::text AS status FROM cameras
        UNION ALL
        SELECT system_id, 'display' AS kind, status::text AS status FROM displays
    ) d
    JOIN systems s ON s.id = d.system_id
    GROUP BY s.location_id
),
pb AS (
    SELECT trigger_id,
           bool_or(status IN ('dispatched','started')) AS open_playback,
           max(GREATEST(COALESCE(started_at, created_at),
                        COALESCE(ended_at, created_at), created_at)) AS last_ts
    FROM playbacks
    GROUP BY trigger_id
),
tr AS (
    -- one row per trigger: ad_runs and composition_runs are both
    -- UNIQUE(trigger_id), so the FULL JOIN is 1:1; playbacks pre-aggregated.
    SELECT COALESCE(ar.location_id, cr.location_id) AS location_id,
           ar.status::text AS ar_status,
           cr.status::text AS cr_status,
           COALESCE(pb.open_playback, false) AS open_playback,
           ar.created_at AS ar_created_at,
           GREATEST(COALESCE(ar.updated_at, '-infinity'),
                    COALESCE(cr.ended_at, cr.started_at, cr.created_at, '-infinity'),
                    COALESCE(pb.last_ts, '-infinity')) AS last_ts,
           ((ar.status = 'failed'
             AND COALESCE(ar.ended_at, ar.updated_at) >= now() - interval '1 hour')
            OR (cr.status = 'failed'
                AND COALESCE(cr.ended_at, cr.created_at) >= now() - interval '1 hour')
           ) AS failed_last_hour
    FROM ad_runs ar
    FULL JOIN composition_runs cr ON cr.trigger_id = ar.trigger_id
    LEFT JOIN pb ON pb.trigger_id = COALESCE(ar.trigger_id, cr.trigger_id)
),
act AS (
    SELECT location_id,
           count(*) FILTER (WHERE ar_status = 'planned'
                               OR (ar_status IS NULL
                                   AND cr_status IN ('queued','rendering'))) AS composing,
           count(*) FILTER (WHERE ar_status IN ('dispatched','playing')
                               OR open_playback)                             AS playing,
           count(*) FILTER (WHERE ar_created_at >= now() - interval '1 hour') AS runs_last_hour,
           count(*) FILTER (WHERE failed_last_hour)                          AS failures_last_hour,
           NULLIF(max(last_ts), '-infinity')                                 AS last_activity_at
    FROM tr
    WHERE location_id IS NOT NULL
    GROUP BY location_id
)
SELECT l.id AS location_id, l.name, l.location_type::text AS location_type,
       l.city, l.country, l.lat::float8 AS lat, l.lng::float8 AS lng,
       sys.systems,
       COALESCE(dev.cameras, 0)  AS cameras,
       COALESCE(dev.displays, 0) AS displays,
       CASE COALESCE(dev.worst_rank, 1)
            WHEN 4 THEN 'offline' WHEN 3 THEN 'retired'
            WHEN 2 THEN 'degraded' ELSE 'active' END AS worst_status,
       COALESCE(act.composing, 0)          AS composing,
       COALESCE(act.playing, 0)            AS playing,
       COALESCE(act.runs_last_hour, 0)     AS runs_last_hour,
       COALESCE(act.failures_last_hour, 0) AS failures_last_hour,
       act.last_activity_at
FROM locations l
JOIN sys ON sys.location_id = l.id
LEFT JOIN dev ON dev.location_id = l.id
LEFT JOIN act ON act.location_id = l.id
ORDER BY l.name ASC, l.id ASC
"""


async def get_map(conn) -> dict:
    rows = await conn.fetch(_MAP_SQL)
    venues = []
    for r in rows:
        venues.append({
            "location_id": r["location_id"],
            "name": r["name"],
            "location_type": r["location_type"],
            "city": r["city"],
            "country": r["country"],
            "lat": r["lat"],
            "lng": r["lng"],
            "rollup": {
                "systems": r["systems"],
                "cameras": r["cameras"],
                "displays": r["displays"],
                "worst_status": r["worst_status"],
                "active_ad_runs": r["composing"] + r["playing"],
                "composing_count": r["composing"],
                "playing_count": r["playing"],
                "runs_last_hour": r["runs_last_hour"],
                "failures_last_hour": r["failures_last_hour"],
                "last_activity_at": r["last_activity_at"],
            },
        })
    return {"venues": venues}
```

- [ ] **3.5 Wire the route** — in `/Users/jn/code/mras-ops/api/src/main.py`, extend the godview import block (line ~16, next to the existing `from src.godview.dashboard import get_dashboard`):

```python
from src.godview.map import get_map
```

and add next to the existing `/god-view/dashboard` route:

```python
@app.get("/god-view/map")
async def god_view_map():
    async with _db.acquire() as conn:
        return await get_map(conn)
```

- [ ] **3.6 Run to green:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected: `7 passed`.

- [ ] **3.7 Commit the green impl** — message: `feat: GET /god-view/map — one set-based venue rollup query, §3 health/live encodings, idle-playback guard (Globe Plan A T3)`.

- [ ] **3.8 Live check** (needs the dev stack up; rebuild the api image since code is baked in — recon finding 7):

```bash
cd /Users/jn/code/mras-ops && docker compose build mras-ops-api && docker compose up -d mras-ops-api
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
print('venues:', len(d['venues']))
print(json.dumps(d['venues'][0], indent=2, default=str) if d['venues'] else 'EMPTY')
"
```

Expected: HTTP 200; pre-seed the dev DB has 1 venue (`Demo Store`) with `rollup.systems == 1`; after Task 6's seed it will show 14. Any 500 here is a bug — stop and fix before proceeding.

---

## Task 4 — `GET /god-view/map/locations/{id}` (venue panel payload)

**Files**
- Modify: `/Users/jn/code/mras-ops/api/src/godview/map.py` (add `get_map_location`)
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (route)
- Test: `/Users/jn/code/mras-ops/api/tests/test_godview_map.py` (append tests)

**Interfaces**
- Consumes: `locations`, `systems`, `cameras`, `displays`, `ad_runs` (+ system name join).
- Produces: `async def get_map_location(conn, location_id, *, limit=20) -> dict | None` returning
  `{"location": {id, name, location_type, city, country, lat, lng, timezone, status}, "systems": [{id, name, zone, status, system_type, cameras: [{id, name, status, screen_id, last_seen_at}], displays: [{id, name, status, screen_id, last_seen_at}]}], "ad_runs": [{id, status, system_id, system_name, started_at, ended_at, created_at}]}`.
  `None` when the location does not exist → route 404s. `ad_runs` are newest-first, `LIMIT` clamped 1–50 (default 20) — the "recent/active, keyset-limited" panel list. This is a per-venue drill-down (a handful of rows), so 4 bounded queries + Python grouping is the right shape — mirrors `get_system` in `/Users/jn/code/mras-ops/api/src/godview/systems.py`; the ONE-query rule applies to `/map` only.

### Steps

- [ ] **4.1 Write the failing tests** — append to `/Users/jn/code/mras-ops/api/tests/test_godview_map.py`:

```python
# --------------------------------------------------------------------------- #
# GET /god-view/map/locations/{id} — venue panel payload
# --------------------------------------------------------------------------- #
from src.godview.map import get_map_location  # noqa: E402  (module top in final file)


async def test_panel_nested_shape(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "Panel Venue")
    s1 = await _system(projector_pool, org, loc, "Alpha Wall")
    s2 = await _system(projector_pool, org, loc, "Beta Wall")
    await projector_pool.execute(
        "INSERT INTO cameras (system_id,screen_id,status,name,last_seen_at) "
        "VALUES ($1,'cam-a1','active','Cam A1', now())", s1)
    await projector_pool.execute(
        "INSERT INTO displays (system_id,screen_id,status,name) "
        "VALUES ($1,'disp-a1','degraded','Disp A1')", s1)
    await projector_pool.execute(
        "INSERT INTO displays (system_id,screen_id,status,name) "
        "VALUES ($1,'disp-b1','active','Disp B1')", s2)

    panel = await get_map_location(projector_pool, loc)
    assert panel["location"]["name"] == "Panel Venue"
    assert panel["location"]["lat"] == 10.0
    systems = {s["name"]: s for s in panel["systems"]}
    assert set(systems) == {"Alpha Wall", "Beta Wall"}
    alpha = systems["Alpha Wall"]
    assert [c["screen_id"] for c in alpha["cameras"]] == ["cam-a1"]
    assert alpha["cameras"][0]["last_seen_at"] is not None
    assert [d["screen_id"] for d in alpha["displays"]] == ["disp-a1"]
    assert alpha["displays"][0]["status"] == "degraded"
    assert systems["Beta Wall"]["cameras"] == []
    assert [d["screen_id"] for d in systems["Beta Wall"]["displays"]] == ["disp-b1"]


async def test_panel_ad_runs_limited_newest_first(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc, "S")
    for i in range(5):
        await projector_pool.execute(
            "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,created_at) "
            "VALUES ($1,$2,$3,'completed', now() - ($4 || ' minutes')::interval)",
            uuid.uuid4(), loc, sid, str(i))
    panel = await get_map_location(projector_pool, loc, limit=3)
    assert len(panel["ad_runs"]) == 3
    times = [r["created_at"] for r in panel["ad_runs"]]
    assert times == sorted(times, reverse=True)  # newest first
    assert panel["ad_runs"][0]["system_name"] == "S"


async def test_panel_unknown_location_returns_none(projector_pool):
    assert await get_map_location(projector_pool, uuid.uuid4()) is None
```

- [ ] **4.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected failure: `ImportError: cannot import name 'get_map_location' from 'src.godview.map'` (collection error; the 7 Task-3 tests were green before this append).

- [ ] **4.3 Commit the red test** — message: `test: red — /god-view/map/locations/{id} panel shape, ad_run limit/order, 404 (Globe Plan A T4)`.

- [ ] **4.4 Implement** — append to `/Users/jn/code/mras-ops/api/src/godview/map.py`:

```python
async def get_map_location(conn, location_id, *, limit: int = 20) -> dict | None:
    """Venue panel payload: location header, systems with nested cameras/displays,
    recent ad_runs (newest-first, bounded). Per-venue drill-down — a handful of
    rows — so bounded queries + Python grouping, like godview/systems.get_system."""
    loc = await conn.fetchrow(
        "SELECT id, name, location_type::text AS location_type, city, country, "
        "lat::float8 AS lat, lng::float8 AS lng, timezone, status::text AS status "
        "FROM locations WHERE id = $1", location_id)
    if loc is None:
        return None

    systems = [dict(r) for r in await conn.fetch(
        "SELECT id, name, zone, status::text AS status, system_type::text AS system_type "
        "FROM systems WHERE location_id = $1 ORDER BY name ASC, id ASC", location_id)]
    sys_ids = [s["id"] for s in systems]

    cams = await conn.fetch(
        "SELECT id, system_id, name, status::text AS status, screen_id, last_seen_at "
        "FROM cameras WHERE system_id = ANY($1::uuid[]) "
        "ORDER BY name ASC NULLS LAST, id ASC", sys_ids)
    disps = await conn.fetch(
        "SELECT id, system_id, name, status::text AS status, screen_id, last_seen_at "
        "FROM displays WHERE system_id = ANY($1::uuid[]) "
        "ORDER BY name ASC NULLS LAST, id ASC", sys_ids)
    by_sys_cams: dict = {}
    for c in cams:
        d = dict(c)
        by_sys_cams.setdefault(d.pop("system_id"), []).append(d)
    by_sys_disps: dict = {}
    for x in disps:
        d = dict(x)
        by_sys_disps.setdefault(d.pop("system_id"), []).append(d)
    for s in systems:
        s["cameras"] = by_sys_cams.get(s["id"], [])
        s["displays"] = by_sys_disps.get(s["id"], [])

    ad_runs = [dict(r) for r in await conn.fetch(
        "SELECT ar.id, ar.status::text AS status, ar.system_id, s.name AS system_name, "
        "ar.started_at, ar.ended_at, ar.created_at "
        "FROM ad_runs ar LEFT JOIN systems s ON s.id = ar.system_id "
        "WHERE ar.location_id = $1 "
        "ORDER BY ar.created_at DESC, ar.id DESC LIMIT $2", location_id, limit)]

    return {"location": dict(loc), "systems": systems, "ad_runs": ad_runs}
```

- [ ] **4.5 Wire the route** — in `/Users/jn/code/mras-ops/api/src/main.py`, extend the map import to `from src.godview.map import get_map, get_map_location` and add below the `/god-view/map` route (uses the existing `_uuid_or_400` helper defined higher in the file):

```python
@app.get("/god-view/map/locations/{location_id}")
async def god_view_map_location(location_id: str, limit: int = 20):
    async with _db.acquire() as conn:
        result = await get_map_location(conn, _uuid_or_400(location_id),
                                        limit=max(1, min(limit, 50)))
    if result is None:
        raise HTTPException(status_code=404, detail="location not found")
    return result
```

  Route-ordering note: FastAPI matches in registration order; `/god-view/map/locations/{location_id}` and `/god-view/map` don't collide with any existing `/god-view/*` route (nearest neighbor is `/god-view/ad-runs/{ad_run_id}`), so appending both after `/god-view/dashboard` is safe.

- [ ] **4.6 Run to green** (full map suite):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected: `10 passed`.

- [ ] **4.7 Commit the green impl** — message: `feat: GET /god-view/map/locations/{id} — venue panel payload, nested systems/devices, bounded ad_runs (Globe Plan A T4)`.

- [ ] **4.8 Live check** (rebuild api again to pick up the new route):

```bash
cd /Users/jn/code/mras-ops && docker compose build mras-ops-api && docker compose up -d mras-ops-api
python3 -c "
import json, urllib.request
m = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
loc = m['venues'][0]['location_id']
p = json.load(urllib.request.urlopen(f'http://localhost:8080/god-view/map/locations/{loc}'))
print('location:', p['location']['name'])
print('systems:', [(s['name'], len(s['cameras']), len(s['displays'])) for s in p['systems']])
print('ad_runs:', len(p['ad_runs']))
import urllib.error
try:
    urllib.request.urlopen('http://localhost:8080/god-view/map/locations/00000000-0000-4000-8000-000000000000')
except urllib.error.HTTPError as e:
    print('missing-id status:', e.code)
"
```

Expected: panel payload for the first venue and `missing-id status: 404`.

---

## Task 5 — Demo-traffic generator (`scripts/demo_traffic.py`)

**Files**
- Create: `/Users/jn/code/mras-ops/scripts/demo_traffic.py`
- Test: `/Users/jn/code/mras-ops/tests/test_demo_traffic.py` (repo-root tests dir, like `/Users/jn/code/mras-ops/tests/test_purge.py`, so `scripts.*` imports resolve; unit tests use AsyncMock — no DB needed)

**Interfaces**
- Consumes: the seeded demo fleet (org `dea00000-...001` by name+tag); the projector routing registry keys and handler payload fields (recon finding 1); `events` insert with first-class scope columns (016).
- Produces:
  - `build_sequence(trigger_id, target, fail=False) -> list[(delay_s, event_type, status, payload)]` — pure, testable; composition→ad_run→playback **in order**; camera scope for composition + ad_run/planned, display scope for the rest (mirrors the real composer); every payload has `demo_seed: True`; inter-status delays ≥ `SETTLE_GAP_S` (3.0 s > settle_ms 2000 + poll_ms 1000).
  - `emit_sequence(pool, org_id, target, trigger_id, beats, ...)` — stamps `started_at`/`ended_at`/`dispatched_at`/`duration_ms` at emission time; **INSERTs org/location/system directly onto the events row** (spec §6 amendment: events still inside the settle window at Ctrl-C must not escape the scoped teardown); prints each emission.
  - CLI `python -m scripts.demo_traffic [--rate RUNS_PER_MIN] [--failure-pct PCT] [--duration SECS]` — hard-exits if the demo org is absent (cannot run post-teardown), re-checks the org each cycle (exits mid-run if teardown lands), hard-scoped: targets come only from an `organization_id = demo` query. Takes no advisory lock, never projects — append-only.

### Steps

- [ ] **5.1 Write the failing tests** — create `/Users/jn/code/mras-ops/tests/test_demo_traffic.py`:

```python
"""Demo-traffic generator (Globe Plan A, spec §6): sequence shape, payload
contract vs the projector handlers, timestamp stamping, org hard-scope guard.
Pure unit tests (AsyncMock DB) — no live services needed."""
import json
from unittest.mock import AsyncMock

import pytest

from scripts.demo_traffic import (SETTLE_GAP_S, build_sequence, emit_sequence,
                                  load_demo_org)

TARGET = {
    "system_id": "33333333-3333-4333-8333-333333333333",
    "location_id": "22222222-2222-4222-8222-222222222222",
    "system_name": "Entrance Wall A",
    "venue": "Mall of America",
    "camera_screen_id": "demo-cam-moa-1-1",
    "display_screen_id": "demo-disp-moa-1-1",
}


def test_build_sequence_happy_path_order_and_scope():
    beats = build_sequence("trig-1", TARGET)
    keys = [(e, s) for _, e, s, _ in beats]
    # composition -> ad_run -> playback, in journal order (FK sibling lookups
    # by shared trigger_id require ascending-id existence)
    assert keys == [
        ("composition", "queued"), ("composition", "rendering"), ("ad_run", "planned"),
        ("composition", "rendered"),
        ("playback", "dispatched"), ("ad_run", "dispatched"),
        ("playback", "started"), ("ad_run", "playing"),
        ("playback", "ended"), ("ad_run", "completed"),
    ]
    for _, event_type, status, payload in beats:
        assert payload["demo_seed"] is True
        assert payload["trigger_id"] == "trig-1"
        assert payload["screen_kind"] in ("camera", "display")
    # composer scope convention: render lane = camera scope, playback lane = display
    by = {(e, s): p for _, e, s, p in beats}
    assert by[("composition", "queued")]["screen_kind"] == "camera"
    assert by[("composition", "queued")]["screen_id"] == "demo-cam-moa-1-1"
    assert by[("ad_run", "planned")]["screen_kind"] == "camera"
    assert by[("playback", "dispatched")]["screen_kind"] == "display"
    assert by[("playback", "dispatched")]["screen_id"] == "demo-disp-moa-1-1"
    assert by[("playback", "dispatched")]["ad_run_trigger_id"] == "trig-1"
    assert by[("ad_run", "completed")]["screen_kind"] == "display"
    # no phantom FK payloads: a non-existent ad_id would FK-violate in the
    # handler savepoint and silently drop the pulse
    for _, _, _, payload in beats:
        assert "ad_id" not in payload and "campaign_id" not in payload
        assert "target_subject_profile_id" not in payload


def test_build_sequence_respects_settle_window():
    beats = build_sequence("t", TARGET)
    # every status-advancing beat with a delay waits out the projector settle
    delays = [d for d, _, _, _ in beats if d > 0]
    assert delays, "sequence must pace itself"
    assert all(d >= SETTLE_GAP_S for d in delays)


def test_build_sequence_failure_path():
    beats = build_sequence("t", TARGET, fail=True)
    keys = [(e, s) for _, e, s, _ in beats]
    assert keys == [
        ("composition", "queued"), ("composition", "rendering"), ("ad_run", "planned"),
        ("composition", "failed"), ("ad_run", "failed"),
    ]
    by = {(e, s): p for _, e, s, p in beats}
    assert by[("composition", "failed")]["error_code"] == "DEMO_RENDER_FAIL"
    assert "playback" not in {e for e, _ in keys}


async def test_emit_sequence_stamps_scope_and_timestamps():
    pool = AsyncMock()
    sleep = AsyncMock()
    beats = build_sequence("trig-2", TARGET)
    await emit_sequence(pool, "dea00000-0000-4000-8000-000000000001", TARGET,
                        "trig-2", beats, sleep=sleep)
    assert pool.execute.await_count == len(beats)
    for call in pool.execute.await_args_list:
        args = call.args
        # (sql, trigger_id, service, event_type, status, payload_json, org, loc, sys)
        assert "INSERT INTO events" in args[0]
        assert args[2] == "mras-composer"  # projector routing registry service key
        assert args[6] == "dea00000-0000-4000-8000-000000000001"
        assert args[7] == TARGET["location_id"]
        assert args[8] == TARGET["system_id"]
        payload = json.loads(args[5])
        assert payload["demo_seed"] is True
    stamped = {(c.args[3], c.args[4]): json.loads(c.args[5])
               for c in pool.execute.await_args_list}
    assert "started_at" in stamped[("playback", "started")]
    assert "started_at" in stamped[("ad_run", "playing")]
    assert "ended_at" in stamped[("playback", "ended")]
    assert "duration_ms" in stamped[("playback", "ended")]
    assert "dispatched_at" in stamped[("playback", "dispatched")]
    assert "ended_at" in stamped[("ad_run", "completed")]
    # pacing went through the injected sleep, not real time
    assert sleep.await_count == sum(1 for d, *_ in beats if d > 0)


async def test_load_demo_org_hard_exits_when_absent():
    pool = AsyncMock()
    pool.fetchval = AsyncMock(return_value=None)
    with pytest.raises(SystemExit):
        await load_demo_org(pool)
```

- [ ] **5.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py -q
```

Expected failure: `ModuleNotFoundError: No module named 'scripts.demo_traffic'` (collection error).

- [ ] **5.3 Commit the red test** — message: `test: red — demo_traffic sequence order/scope/pacing, event stamping, org hard-exit (Globe Plan A T5)`.

- [ ] **5.4 Implement** — create `/Users/jn/code/mras-ops/scripts/demo_traffic.py`:

```python
"""Demo-traffic generator for the God View Globe (spec 2026-07-11 §6).

Appends minimal well-formed composition -> ad_run -> playback event sequences to
the append-only `events` journal for SEEDED venues only; the real projector
folds them into ad_runs/composition_runs/playbacks and the globe pulses. Never
projects, takes no advisory lock — the projector's single-writer discipline is
untouched.

Payload shapes are copied from the real emitters + the projector handlers
(/Users/jn/code/mras-composer/main.py, .../src/orchestrator/renderer.py,
/Users/jn/code/mras-ops/api/src/projector/handlers.py): every payload carries
screen_id + screen_kind (render lane = camera scope, playback lane = display
scope), timestamps are ISO strings, and nullable ad/subject FKs are OMITTED —
a payload naming a non-existent ad_id would FK-violate inside the projector's
per-event savepoint and silently drop the pulse.

Hard scope: targets come only from systems WHERE organization_id = the demo
org; hard-exits if the org is absent (cannot run post-teardown) and re-checks
each cycle. Every events row is stamped with organization_id + location_id +
system_id AT INSERT (plus payload.demo_seed=true) so rows still inside the
projector's settle window at Ctrl-C never escape the scoped teardown.

Usage:
    python -m scripts.demo_traffic [--rate RUNS_PER_MIN] [--failure-pct PCT]
                                   [--duration SECS]
Ctrl-C to stop. Doubles as projector load/soak tooling at high --rate.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone

DEMO_ORG_NAME = "Demo Retail Group"
SERVICE = "mras-composer"  # must match the projector routing registry keys
# projector settle_ms=2000 + poll_ms=1000 => summaries trail inserts by ~2-3s;
# status beats are scheduled no tighter than this (expected lag, not a bug).
SETTLE_GAP_S = 3.0

_INSERT = (
    "INSERT INTO events (trigger_id, ts, service, event_type, status, payload, "
    "organization_id, location_id, system_id) "
    "VALUES ($1, now(), $2, $3, $4, $5::jsonb, $6, $7, $8)"
)

# emission-time timestamp stamping per (event_type, status)
_STAMPS = {
    ("composition", "rendering"): ("started_at",),
    ("composition", "rendered"): ("ended_at",),
    ("composition", "failed"): ("ended_at",),
    ("ad_run", "playing"): ("started_at",),
    ("ad_run", "completed"): ("ended_at",),
    ("ad_run", "failed"): ("ended_at",),
    ("playback", "dispatched"): ("dispatched_at",),
    ("playback", "started"): ("started_at",),
    ("playback", "ended"): ("ended_at",),
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_sequence(trigger_id: str, target: dict, fail: bool = False) -> list:
    """Ordered (delay_s, event_type, status, payload) beats for one demo run.

    composition -> ad_run -> playback IN THAT ORDER: the projector's FK-link
    lookups by shared trigger_id expect the sibling row to already exist
    (events fold in ascending id order). Timestamps are added at emit time."""
    cam = {"screen_id": target["camera_screen_id"], "screen_kind": "camera",
           "trigger_id": trigger_id, "demo_seed": True}
    disp = {"screen_id": target["display_screen_id"], "screen_kind": "display",
            "trigger_id": trigger_id, "demo_seed": True}

    def gap() -> float:  # jittered, never tighter than the settle window
        return SETTLE_GAP_S + random.uniform(0.0, 1.5)

    beats = [
        (0.0, "composition", "queued", dict(cam)),
        (gap(), "composition", "rendering", dict(cam)),
        (0.0, "ad_run", "planned", dict(cam)),
    ]
    if fail:
        beats += [
            (gap(), "composition", "failed",
             {**cam, "error_code": "DEMO_RENDER_FAIL",
              "error_message": "demo-traffic injected failure"}),
            (0.0, "ad_run", "failed", dict(cam)),
        ]
        return beats
    beats += [
        (gap(), "composition", "rendered", dict(cam)),
        (0.0, "playback", "dispatched",
         {**disp, "ad_run_trigger_id": trigger_id, "media_asset_ref": None}),
        (0.0, "ad_run", "dispatched", dict(disp)),
        (gap(), "playback", "started", dict(disp)),
        (0.0, "ad_run", "playing", dict(disp)),
        (SETTLE_GAP_S + random.uniform(2.0, 10.0), "playback", "ended", dict(disp)),
        (0.0, "ad_run", "completed", dict(disp)),
    ]
    return beats


async def emit_sequence(pool, org_id, target, trigger_id, beats,
                        sleep=asyncio.sleep, clock=time.monotonic) -> None:
    """Emit one sequence, pacing with `sleep`, stamping timestamps at emission."""
    started = None
    for delay_s, event_type, status, payload in beats:
        if delay_s > 0:
            await sleep(delay_s)
        payload = dict(payload)
        for field in _STAMPS.get((event_type, status), ()):
            payload[field] = now_iso()
        if (event_type, status) == ("playback", "started"):
            started = clock()
        if (event_type, status) == ("playback", "ended"):
            payload["duration_ms"] = int(((clock() - started) if started else 0) * 1000)
        await pool.execute(_INSERT, trigger_id, SERVICE, event_type, status,
                           json.dumps(payload), org_id,
                           target["location_id"], target["system_id"])
        print(f"[demo-traffic] {target['venue']} / {target['system_name']} "
              f"{event_type}/{status} trigger={trigger_id}")


async def load_demo_org(pool):
    """Hard-scope guard: exits (SystemExit) when the demo org is absent, so the
    generator cannot run post-teardown."""
    org_id = await pool.fetchval(
        "SELECT id FROM organizations WHERE name = $1 AND metadata->>'demo_seed' = 'true'",
        DEMO_ORG_NAME)
    if org_id is None:
        print("[demo-traffic] demo org absent — apply "
              "/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql first. Exiting.")
        raise SystemExit(1)
    return org_id


async def load_targets(pool, org_id) -> list[dict]:
    """One target per ACTIVE display of the demo org (hard-scoped by the WHERE);
    each carries its system's first camera for render-lane scope."""
    rows = await pool.fetch(
        """
        SELECT s.id AS system_id, s.location_id, s.name AS system_name,
               l.name AS venue, d.screen_id AS display_screen_id,
               (SELECT c.screen_id FROM cameras c
                 WHERE c.system_id = s.id AND c.status <> 'retired'
                 ORDER BY c.screen_id LIMIT 1) AS camera_screen_id
        FROM systems s
        JOIN locations l ON l.id = s.location_id
        JOIN displays d ON d.system_id = s.id AND d.status = 'active'
        WHERE s.organization_id = $1
        """, org_id)
    return [dict(r) for r in rows if r["camera_screen_id"] is not None]


async def run(rate: float, failure_pct: float, duration_s: float | None) -> None:
    import asyncpg  # local import so unit tests never need the driver

    pool = await asyncpg.create_pool(
        os.getenv("DATABASE_URL", "postgresql://mras:mras@localhost:5432/mras"))
    try:
        org_id = await load_demo_org(pool)
        targets = await load_targets(pool, org_id)
        if not targets:
            print("[demo-traffic] no seeded active displays — exiting")
            raise SystemExit(1)
        # weighted venue activity: stable per-venue weights, some venues run hot
        weights = [1 + (hash(t["venue"]) % 5) for t in targets]
        print(f"[demo-traffic] {len(targets)} display targets, "
              f"rate={rate}/min, failure={failure_pct}%. Ctrl-C to stop.")
        tasks: set = set()
        t0 = time.monotonic()
        while duration_s is None or time.monotonic() - t0 < duration_s:
            # hard-scope re-check: stop mid-run the moment teardown removes the org
            if await pool.fetchval(
                    "SELECT 1 FROM organizations WHERE id = $1", org_id) is None:
                print("[demo-traffic] demo org gone (teardown) — exiting")
                break
            target = random.choices(targets, weights=weights, k=1)[0]
            trigger_id = str(uuid.uuid4())
            fail = random.random() * 100.0 < failure_pct
            beats = build_sequence(trigger_id, target, fail=fail)
            task = asyncio.create_task(
                emit_sequence(pool, org_id, target, trigger_id, beats))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
            # jittered pacing around the fleet-wide rate
            await asyncio.sleep(random.uniform(0.5, 1.5) * 60.0 / rate)
        for task in tasks:  # let in-flight sequences finish cleanly
            await task
    finally:
        await pool.close()


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="God View demo-traffic generator")
    parser.add_argument("--rate", type=float, default=3.0,
                        help="run sequences per minute, fleet-wide (default 3)")
    parser.add_argument("--failure-pct", type=float, default=10.0,
                        help="percent of runs that take the failure path (default 10)")
    parser.add_argument("--duration", type=float, default=None,
                        help="stop after N seconds (default: run until Ctrl-C)")
    args = parser.parse_args(argv)
    try:
        asyncio.run(run(args.rate, args.failure_pct, args.duration))
    except KeyboardInterrupt:
        print("\n[demo-traffic] stopped")


if __name__ == "__main__":
    main()
```

- [ ] **5.5 Run to green:**

```bash
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py -q
```

Expected: `5 passed`.

- [ ] **5.6 Commit the green impl** — message: `feat: scripts/demo_traffic.py — org-hard-scoped event sequences, settle-window pacing, insert-time scope stamping (Globe Plan A T5)`.

---

## Task 6 — Full suite + live seed → generator → pulse → teardown drill

**Files** — none created; this is the verification gate. All commands run from the branch worktree.

**Interfaces**
- Consumes: everything from Tasks 1–5 deployed against the live dev stack.
- Produces: proof that the whole Plan-A surface works end-to-end and reverses to zero demo rows.

### Steps

- [ ] **6.1 Full relevant test suites** (all green before the live drill):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/ -q
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py tests/test_purge.py tests/test_schema_godview.py -q
```

Expected: all pass, zero failures (api suite includes the pre-existing projector/registry/godview tests — any regression there is a Plan-A bug). Note: repo-root `tests/test_aws_profile.py` is excluded only if it requires AWS env not present; if it runs green normally, run the whole dir instead: `python3 -m pytest tests/ --ignore tests/e2e -q`.

- [ ] **6.2 Confirm dev stack + deployed api image:**

```bash
cd /Users/jn/code/mras-ops && docker compose ps
python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/god-view/map').status)"
```

Expected: `postgres`, `mras-ops-api`, `mras-ops-projector` up; second command prints `200`. If the api image predates Tasks 3–4: `docker compose build mras-ops-api && docker compose up -d mras-ops-api`.

- [ ] **6.3 Apply the seed to the dev DB:**

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
docker exec mras-ops-postgres-1 psql -U mras -d mras -c \
  "SELECT count(*) FROM locations WHERE metadata->>'demo_seed'='true';" -c \
  "SELECT count(*) FROM systems WHERE organization_id='dea00000-0000-4000-8000-000000000001';" -c \
  "SELECT lat, lng FROM locations WHERE id='acc4e851-ab7a-4b59-989e-85cb8b597e14';"
```

Expected: `13` venues, `38` systems, and Demo Store now has lat/lng (37.7749, -122.4194). Re-apply the seed once more and re-run the counts — identical (idempotency, live).

- [ ] **6.4 Map shows the fleet:**

```bash
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
vs = d['venues']
print('venues:', len(vs))
print('worst set:', sorted({v['rollup']['worst_status'] for v in vs}))
print('plotted:', sum(1 for v in vs if v['lat'] is not None))
"
```

Expected: `venues: 14` (13 seeded + Demo Store), `worst set:` includes `offline` and `degraded` (status spread) and `active`; `plotted: 14` (Demo Store got coordinates).

- [ ] **6.5 Run the generator for 60 s** (the `--duration` flag exists for exactly this drill):

```bash
cd /Users/jn/code/mras-ops && python3 -m scripts.demo_traffic --rate 12 --duration 60
sleep 8   # projector settle (2s) + poll (1s) + slack: let the last beats fold
```

Expected: printed emissions (`[demo-traffic] <venue> / <system> composition/queued trigger=…` etc.), clean exit after ~60 s plus in-flight sequences.

- [ ] **6.6 Verify pulses via the endpoint + DB:**

```bash
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
tot = lambda k: sum(v['rollup'][k] for v in d['venues'])
print('runs_last_hour:', tot('runs_last_hour'), 'active:', tot('active_ad_runs'),
      'failures:', tot('failures_last_hour'))
assert tot('runs_last_hour') > 0, 'generator pulses did not reach the map rollup'
print('OK')
"
docker exec mras-ops-postgres-1 psql -U mras -d mras -c \
  "SELECT count(*) AS demo_ad_runs FROM ad_runs WHERE organization_id='dea00000-0000-4000-8000-000000000001';" -c \
  "SELECT count(*) AS skips FROM audit_logs WHERE action IN ('projector.skip','projector.resolve_miss') AND created_at > now() - interval '10 minutes';"
```

Expected: `runs_last_hour > 0` (OK printed); `demo_ad_runs > 0` (the projector folded generator events); `skips = 0` — any skip means a payload shape drifted from the handlers; investigate `audit_logs.after` before proceeding. Also spot-check a venue panel: fetch `/god-view/map/locations/{id}` for a venue with runs and confirm `ad_runs` is non-empty.

- [ ] **6.7 Post-teardown guard proof:** run teardown, then confirm the generator refuses to start:

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/teardown_demo_fleet.sql
python3 -m scripts.demo_traffic --duration 5; echo "exit=$?"
```

Expected: `[demo-traffic] demo org absent … Exiting.` and `exit=1`.

- [ ] **6.8 Verify zero demo rows and untouched real rows:**

```bash
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "
SELECT 'organizations' AS t, count(*) FROM organizations WHERE id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'locations', count(*) FROM locations WHERE metadata->>'demo_seed'='true'
UNION ALL SELECT 'location_participants', count(*) FROM location_participants WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'systems', count(*) FROM systems WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'cameras', count(*) FROM cameras WHERE screen_id LIKE 'demo-cam-%'
UNION ALL SELECT 'displays', count(*) FROM displays WHERE screen_id LIKE 'demo-disp-%'
UNION ALL SELECT 'screen_groups', count(*) FROM screen_groups WHERE metadata->>'demo_seed'='true'
UNION ALL SELECT 'ad_runs', count(*) FROM ad_runs WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'composition_runs', count(*) FROM composition_runs WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'playbacks', count(*) FROM playbacks WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'events', count(*) FROM events WHERE organization_id='dea00000-0000-4000-8000-000000000001'
UNION ALL SELECT 'events_payload_tag', count(*) FROM events WHERE payload->>'demo_seed'='true';" -c \
  "SELECT name, lat, lng FROM locations WHERE id='acc4e851-ab7a-4b59-989e-85cb8b597e14';" -c \
  "SELECT cursor > 0 AS cursor_advanced FROM projector_state WHERE id=1;"
```

Expected: **every count = 0**; Demo Store still has its lat/lng (teardown's leave-as-is set); `projector_state` untouched by teardown (cursor reflects normal folding, was never reset). `/god-view/map` now shows just the pre-seed venue list again.

- [ ] **6.9 Re-seed for Plan B** (Plan B's live Playwright E2E needs the fleet present — spec §7 sequencing):

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
```

- [ ] **6.10 Close out the branch:** self-review the diff (scoped to this plan only), request code review per `superpowers:requesting-code-review`, then have git-flow-manager push and open the PR titled `God View Globe Plan A: demo fleet seed, /god-view/map endpoints, demo-traffic generator` (structured description: Summary / Motivation / Implementation / Tests / Risks; note the plan file path and that merge must be a **merge commit** to preserve the red→green pairs). After merge: update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry, `repo@sha`) and `/Users/jn/code/minority_report_architecture/TODOS.md` if the lane is tracked there; file any deferred items as GitHub issues.

---

## Self-review (performed before finalizing this plan)

- **Spec coverage:** §4 → Tasks 3–4 (both endpoints, exact payload shape + the `composing`/`playing` split the §3 encodings require; one set-based query for `/map`; null-lat/lng venues listed). §5 → Tasks 1–2 (org + 13 venues real lat/lng, malls/airport/showroom, 2–5 systems, 1–2 cameras + 2–6 displays, screen_groups, status spread, tags, idempotency, guarded Demo Store UPDATE with discovered id `acc4e851-ab7a-4b59-989e-85cb8b597e14`, dependency-ordered teardown, cursor never touched). §6 → Task 5 (ordered sequences, jittered pacing ≥ settle window, failure path, insert-time org/system/location stamping + `payload.demo_seed`, hard scope + hard exit, `--rate`, prints emissions). §7 Plan A verification → Task 6 (suite + live smoke of both endpoints + seed→generator→pulse→teardown→zero-rows drill with exact SQL).
- **Spec deviations (justified):** (a) `metadata` doesn't exist on `systems`/`cameras`/`displays` — tag lands in `systems.config`; devices rely on org-join + `demo-` screen_id namespace (recon finding 2). (b) Teardown adds two cycle-breaker UPDATEs the spec's enumeration missed (`events.ad_run_id`, `unresolved_devices.event_id` — recon finding 3); `subject_observations`/`personalization_decisions` delete *before* `events` (they FK into it) while `ad_runs` deletes after the NULL-out — the spec's literal ordering is FK-impossible without this. (c) `/map` rollup adds `composing`/`playing` alongside `active_ad_runs` — §3's Live-mode encodings are uncomputable client-side without the split.
- **Placeholder scan:** no TBDs; every test and implementation block is complete code. The one intentional placeholder is the Demo Store *coordinates* (SF), flagged loudly in the seed comment as owner-adjustable — the id is real and the UPDATE is guarded.
- **Name/type consistency:** demo org uuid `dea00000-0000-4000-8000-000000000001` and org name `Demo Retail Group` identical across seed, teardown, both test files, and the generator; screen_id namespaces `demo-cam-*`/`demo-disp-*` consistent; `SETTLE_GAP_S`/`_STAMPS` names match between generator impl and tests; status-spread screen_ids in the seed UPDATEs verified against the generate_series arithmetic (e.g. `demo-disp-changi-1-2` exists because changi sys 1 has 2+(1·3)%5=5 displays).





