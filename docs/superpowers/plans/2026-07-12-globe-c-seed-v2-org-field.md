# God View Globe v2 — Plan C: seed v2 (retailer split), teardown/generator org-SET, `/god-view/map` additive fields (mras-ops)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Lane 1 of Globe v2 its backend: split the seeded demo fleet among 4 fake retailer orgs under the `Demo Retail Group` umbrella (with 3 new same-city venues — closes mras-ops #55), convert the teardown and the demo-traffic generator from the single umbrella uuid to the demo-org-id SET, and add three additive fields to the map endpoints (`org` per venue, `rollup.last_run_created_at`, panel `ad_runs[].display_id`). Ends with a live seed-v2 → generator → endpoints → teardown drill on the dev stack.

**Architecture:** Everything modifies existing Plan-A surfaces in place — `/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql` and `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql` (plain SQL, applied manually, never via migrations), `/Users/jn/code/mras-ops/scripts/demo_traffic.py`, and `/Users/jn/code/mras-ops/api/src/godview/map.py`. No new endpoints, no `main.py` changes (both map routes are already wired — `/Users/jn/code/mras-ops/api/src/main.py:409-423`), no schema changes. The seed's critical v2 mechanism is an **explicit idempotent UPDATE** that reassigns already-seeded systems onto their retailer org (the live dev DB is v1-seeded; `ON CONFLICT DO NOTHING` cannot reassign).

**Tech Stack:** PostgreSQL 16 (dockerized, `mras-ops-postgres-1`), FastAPI + asyncpg (ops-api container `mras-ops-mras-ops-api-1` on :8080), pytest + pytest-asyncio (throwaway-DB fixtures), plain-SQL seeds, stdlib-argparse asyncpg script.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md` §2 (owner decisions), §3 Lane 1 (seed v2, teardown SET, generator retargeting, API additions), §6 (build plan: Plan C precedes Plan D).

**Predecessor plan (format + surfaces):** `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-12-globe-a-seed-endpoints-generator.md` — its recon findings (payload shapes, FK cycles, test harness, projector pacing) all still bind; only the deltas are re-recon'd below.

---

## Recon findings that bind this plan (read before implementing)

Verified against the repos on 2026-07-12 (post-Plan-A merge). Where the spec's assumptions differ, the finding wins.

1. **`organization_type` has NO `retailer` value** — `('platform_operator','host','advertiser','agency_of_record','partner','vendor')` at `/Users/jn/code/mras-ops/db/migrations/010_enums.sql:12`. Retailer orgs are `'host'`, like the umbrella. Do NOT touch the enum (an enum migration would also require projector-container rebuild for asyncpg codec staleness — avoided entirely).
2. **Org hierarchy plumbing exists, unused until now:** `organizations.parent_organization_id uuid REFERENCES organizations(id)` (`/Users/jn/code/mras-ops/db/migrations/011_accounts.sql:6`) and `organization_relationships` with `from_organization_id`/`to_organization_id` both `NOT NULL REFERENCES organizations(id)`, free-text `relationship` (`011_accounts.sql:12-19`). **No ON DELETE CASCADE anywhere** ⇒ teardown must delete relationship rows before orgs, and retailer orgs (whose `parent_organization_id` references the umbrella) before the umbrella. Only two references to `organization_relationships` exist in the repo (the migration + a schema test) — nothing else reads it; the seed is its first writer.
3. **`systems.organization_id` is `NOT NULL`** (`/Users/jn/code/mras-ops/db/migrations/012_physical.sql:29`). Consequence for the API: `/god-view/map` lists only locations with ≥1 system (`JOIN sys` at `/Users/jn/code/mras-ops/api/src/godview/map.py:98`), so the venue `org` field can never actually be null today — it is still **typed nullable** in the contract (spec §3) and the code carries the null branch.
4. **The v1 teardown hardcodes the umbrella uuid in 28 places** across `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql` (lines 26, 28, 31, 38, 40, 44, 46, 48, 50, 54, 56, 58, 60, 62, 64, 66, 68, 74, 80, 85, 88, 93, 96, 99, 102, 104, 106, 113 — enumerated statement-by-statement in Task 2). Every one becomes the org-id SET; a missed one silently strands retailer-attributed rows.
5. **The v1 seed's reassignment hook already exists:** the `demo_systems` temp table (`/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql:56-64`) carries deterministic system `id` + `slug` + `sys_idx` for every demo system — extending it with the retailer org id gives the v2 UPDATE its join source. All v1 invariants stay: `md5('demo-fleet:…')::uuid` ids, `demo-` screen_id namespace, tags (`metadata.demo_seed` on org/locations/participants/groups, `config` on systems), guarded Demo Store lat/lng UPDATE (`seed_demo_fleet.sql:124-129`).
6. **Generator is single-org end-to-end today** (`/Users/jn/code/mras-ops/scripts/demo_traffic.py`): org resolved by NAME + tag (`load_demo_org`, lines 131-141), targets `WHERE s.organization_id = $1` (lines 144-159, no `s.organization_id` in the SELECT), events stamped with the one org passed into `emit_sequence` (lines 110-128, `$6`), mid-run recheck on that same id (lines 181-184). After the split the umbrella owns ZERO systems ⇒ unmodified, it prints "no seeded active displays — exiting" and hard-exits (safe, but dead). The existing unit suite (`/Users/jn/code/mras-ops/tests/test_demo_traffic.py`) pins the old signature: `TARGET` dict without `organization_id` (lines 12-19), `emit_sequence(pool, org_id, target, …)` asserted at lines 78-88, and the drain test (line 110) mocks `pool.fetchval`→org-id and a single `pool.fetch`→targets (lines 125-128) — all three must move with the code.
7. **Events MUST be stamped with the TARGET system's org, not the umbrella's:** the projector resolves scope by joining the device to `systems` and reading `s.organization_id` (`/Users/jn/code/mras-ops/api/src/projector/scope.py:29-41`), then back-stamps that org onto the events row unconditionally (`_backstamp` — `UPDATE events SET organization_id=$2, …` at `/Users/jn/code/mras-ops/api/src/projector/fold.py:104-122`). Umbrella-stamping would mean the back-stamp *changes* the value instead of overwriting with identical values — breaking the invariant and making pre-fold and post-fold rows disagree. Stamping the target's org keeps insert-time scope == back-stamped scope.
8. **`ad_runs.display_id` exists and the projector populates it:** column at `/Users/jn/code/mras-ops/db/migrations/015_runs.sql:67-95` (`display_id uuid REFERENCES displays(id)`); the ad_run handler upserts it with `COALESCE(EXCLUDED.display_id, ad_runs.display_id)` from display-scope events (`/Users/jn/code/mras-ops/api/src/projector/handlers.py:317-354`). The panel query simply doesn't select it (`/Users/jn/code/mras-ops/api/src/godview/map.py:169-174`). Camera-scope-only runs (e.g. the generator's failure path, which never leaves the render lane) keep it NULL — the field is nullable.
9. **`last_run_created_at` is a one-line rollup addition:** the `tr` CTE already exposes `ar_created_at` (`map.py:57`) and the `act` CTE already aggregates per location (`map.py:70-83`) — `max(ar_created_at)` slots in beside `runs_last_hour`. Deliberately **unwindowed** (max over ALL the venue's ad_runs): it is Lane 3's monotone "new run" delta signal and must never move backwards as old runs age out of a window.
10. **`get_map_location`'s `ad_runs` rows are built with `dict(r)`** (`map.py:169`) — adding `ar.display_id` to the SELECT automatically lands the key in the JSON; no Python shaping needed.
11. **Test harness (unchanged from Plan A, re-verified):** api DB tests in `/Users/jn/code/mras-ops/api/tests/` run with `cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/ -q` against a throwaway `mras_projector_test` DB (module-scoped `projector_pool` builds it from migrations, `/Users/jn/code/mras-ops/api/tests/conftest.py:27-45`). The function-scoped `godview_isolate` fixture runs `TRUNCATE organizations, locations, … CASCADE` (`conftest.py:69-77`) — the `CASCADE` also empties `organization_relationships` and `user_org_scopes` (they FK into `organizations`), so seed-v2 tests need no fixture change. Repo-root script tests: `cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py -q`. Both need dockerized Postgres up (`docker compose up -d postgres`); the generator unit tests are AsyncMock-only (no DB).
12. **Live dev DB state:** v1-seeded (13 venues, 38 systems, ALL on the umbrella org) after Plan A's step 6.9 re-seed. Seed v2 applied there must move all 38 existing systems onto retailers **and** add the 3 new venues — this exact path is drilled in Task 6. Real rows in the leave-as-is set: "Demo Org" `55bf0abd-def0-47e1-847a-86ea9c7d7f0b`, "Demo System" `d8d2d05d-0a73-463b-b5d1-fec94255fe78`, "Demo Store" `acc4e851-ab7a-4b59-989e-85cb8b597e14` (holds the seed-granted lat/lng; teardown never touches it).
13. **Same-city venues must byte-match the cluster key:** the globe cluster selector keys on `city|country`, so the new venues reuse the exact v1 strings — `'New York'/'US'` (pairs with `fifthave`), `'London'/'GB'` (pairs with `wlondon`), `'Dubai'/'AE'` (pairs with `dubai`).
14. **ops-api code is baked into the image** (no bind mount): Task 4/5 live checks and the Task 6 drill need `cd /Users/jn/code/mras-ops && docker compose build mras-ops-api && docker compose up -d mras-ops-api`. No projector rebuild (no projector code changes, no enum changes).

## Global Constraints

- **No schema changes, no new migrations, no enum edits.** Retailers are `organization_type 'host'`.
- **All git via the `git-flow-manager` subagent** — the executor never runs raw `git`/`gh`. One branch for this plan, e.g. `feat/globe-c-seed-v2-org-field`, created from `main`. **Red test commit separate from green impl commit** (the red must be run and seen failing before the impl is written). Merge commits (not squash) at PR time.
- **API changes are ADDITIVE ONLY.** Every existing key of `/god-view/map` and `/god-view/map/locations/{id}` stays byte-identical (name, type, position semantics) — the live Plan-B frontend polls these endpoints in production and Plan D's gate-check diffs the Contract section below field-by-field.
- **The demo-org uuid family** (used identically in seed, teardown, generator, tests, drill):

  | uuid | name | role |
  |---|---|---|
  | `dea00000-0000-4000-8000-000000000001` | Demo Retail Group | umbrella (v1) |
  | `dea00000-0000-4000-8000-000000000002` | Northline Apparel | retailer |
  | `dea00000-0000-4000-8000-000000000003` | Vantage Motors | retailer |
  | `dea00000-0000-4000-8000-000000000004` | Corebrew Coffee | retailer |
  | `dea00000-0000-4000-8000-000000000005` | Meridian Screens | retailer |

- **Never touch `projector_state`** in seed or teardown; the real Demo Org / Demo System / Demo Store rows (incl. Demo Store's lat/lng) are the leave-as-is set.
- `curl`/`wget` may be blocked — all HTTP live checks use `python3` + `urllib.request` one-liners.
- Dev-stack precondition for live steps: `cd /Users/jn/code/mras-ops && docker compose ps` shows `postgres`, `mras-ops-api`, `mras-ops-projector` up.
- Reference every file by absolute path in commits/PR/docs.

## Contract — new/changed API fields (gate-check target for Plan D)

Exact JSON contract of every field this plan adds. Nothing else changes.

**`GET /god-view/map`** — each element of `"venues"`:

- **NEW top-level key `"org"`** — sibling of `"name"`/`"lat"`/`"lng"`/`"rollup"` (NOT inside `"rollup"`). Type: `{"id": string, "name": string} | null`.
  - `"org.id"`: string (uuid) — the venue's **dominant org**: the `organizations` row owning the most `systems` at that location, derived from `systems.organization_id` only.
  - `"org.name"`: string — `organizations.name`, joined server-side.
  - Tie-break is deterministic: `ORDER BY count DESC, organization_id ASC`.
  - `null` when the venue has no systems with an org — **unreachable today** (`/map` lists only locations with ≥1 system and `systems.organization_id` is NOT NULL), but the field is typed nullable and the server carries the null branch.
  - The REAL demo venue ("Demo Store") surfaces its real org (`"Demo Org"`) here — correct behavior; Plan D's org-chip legend must tolerate single-venue orgs with zero arcs.
- **NEW key `"rollup"."last_run_created_at"`**: string (ISO-8601 timestamptz) `| null` — `max(ad_runs.created_at)` over ALL the venue's ad_runs, **no time window** (monotone; Lane 3's "new run" delta signal). `null` when the venue has no ad_runs.

**`GET /god-view/map/locations/{id}`** — each element of `"ad_runs"`:

- **NEW key `"display_id"`**: string (uuid) `| null` — `ad_runs.display_id`, populated by the projector from display-scope events; `null` for runs that never reached the playback lane (e.g. failure-path runs).

**Unchanged-but-relied-on (note for Plan D, zero backend work):** panel `"systems"[]."cameras"[]/"displays"[]` rows already include `"screen_id": string | null` (`/Users/jn/code/mras-ops/api/src/godview/map.py:149-156`) — the spec's `MapSystemDevice.screen_id` amendment is a frontend-type-only change.

---

## Task 1 — Seed v2: retailer orgs, same-city venues, idempotent reassignment (`seed_demo_fleet.sql`)

**Files**
- Modify: `/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql`
- Test: `/Users/jn/code/mras-ops/api/tests/test_demo_seed.py` (extend + update)

**Interfaces**
- Consumes: `organizations` (incl. `parent_organization_id`), `organization_relationships` (011), the v1 venue/system/device machinery (012/025), enum value `host` (010).
- Produces: 4 retailer orgs (`…0002`–`…0005`, type `host`, `parent_organization_id` = umbrella, `metadata.demo_seed`), 4 `organization_relationships` rows (umbrella→retailer, deterministic `md5('demo-fleet:orgrel:'||slug)::uuid` ids), 16 venues (13 v1 + `hudson`/`battersea`/`emirates` same-city), 45 systems each owned by its venue's single retailer (northline 12, vantage 13, corebrew 8, meridian 12; umbrella 0), and — the CRITICAL piece — an **explicit idempotent `UPDATE systems … FROM demo_systems`** that moves already-seeded systems onto their retailer, so the file works identically on a fresh DB, on the live v1-seeded dev DB, and on re-runs.
- Venue→retailer split (deterministic, single retailer per venue, every retailer globe-spanning with ≥2 venues so Plan D's arcs have something to draw):

  | retailer | venues (slug) |
  |---|---|
  | Northline Apparel | moa, wlondon, siam, fifthave |
  | Vantage Motors | kop, century, berlin, dubai |
  | Corebrew Coffee | aventura, yorkdale, partdieu, hudson |
  | Meridian Screens | chadstone, changi, battersea, emirates |

- `location_participants` stay on the umbrella for ALL venues (deliberate: no endpoint reads participants for org identity; one shape for v1-era and v2-era rows keeps fresh and live DBs convergent; teardown scopes them by the org SET regardless).

### Steps

- [ ] **1.1 Write the failing tests** — in `/Users/jn/code/mras-ops/api/tests/test_demo_seed.py`, replace the module constants block (lines 12-14) with:

```python
SEED = pathlib.Path(__file__).resolve().parents[2] / "db" / "seed" / "seed_demo_fleet.sql"
DEMO_ORG = "dea00000-0000-4000-8000-000000000001"  # umbrella (v1 name kept)
DEMO_RETAILERS = {
    "dea00000-0000-4000-8000-000000000002": "Northline Apparel",
    "dea00000-0000-4000-8000-000000000003": "Vantage Motors",
    "dea00000-0000-4000-8000-000000000004": "Corebrew Coffee",
    "dea00000-0000-4000-8000-000000000005": "Meridian Screens",
}
DEMO_ORG_UUIDS = [uuid.UUID(DEMO_ORG)] + [uuid.UUID(k) for k in DEMO_RETAILERS]
REAL_DEMO_LOCATION = "acc4e851-ab7a-4b59-989e-85cb8b597e14"  # dev-DB "Demo Store"
```

(add `import uuid` next to the existing imports), update the two org-keyed queries in `test_seed_fleet_shape_per_venue_and_system` from `organization_id = $1 … DEMO_ORG` to `organization_id = ANY($1::uuid[]) … DEMO_ORG_UUIDS` (the per-venue count, the shape query, the `config` tag check, and the stray-screen_id check — all four), change the venue-count band in `test_seed_creates_tagged_org_and_venues` from `12 <= len(venues) <= 15` to `15 <= len(venues) <= 18` and the per-venue floor in `test_seed_fleet_shape_per_venue_and_system` from `>= 12` to `>= 15`, extend `test_seed_idempotent`'s two count snapshots with `(SELECT count(*) FROM organizations) AS o, (SELECT count(*) FROM organization_relationships) AS orl`, and append:

```python
async def test_seed_retailer_orgs_linked_under_umbrella(projector_pool):
    await _apply_seed(projector_pool)
    # 'retailer' is not an organization_type value (010_enums.sql:12) — hosts.
    rows = await projector_pool.fetch(
        "SELECT id, name, organization_type::text AS t, parent_organization_id, "
        "metadata->>'demo_seed' AS tag FROM organizations WHERE id = ANY($1::uuid[]) "
        "AND id <> $2", DEMO_ORG_UUIDS, uuid.UUID(DEMO_ORG))
    assert {str(r["id"]): r["name"] for r in rows} == DEMO_RETAILERS
    for r in rows:
        assert r["t"] == "host"
        assert str(r["parent_organization_id"]) == DEMO_ORG
        assert r["tag"] == "true"
    links = await projector_pool.fetch(
        "SELECT from_organization_id, to_organization_id, relationship "
        "FROM organization_relationships WHERE from_organization_id = $1",
        uuid.UUID(DEMO_ORG))
    assert {str(l["to_organization_id"]) for l in links} == set(DEMO_RETAILERS)
    assert all(l["relationship"] == "umbrella" for l in links)


async def test_seed_split_one_retailer_per_venue_umbrella_empty(projector_pool):
    await _apply_seed(projector_pool)
    # umbrella owns ZERO systems after the split
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM systems WHERE organization_id = $1",
        uuid.UUID(DEMO_ORG)) == 0
    # each seeded venue is single-retailer by construction
    multi = await projector_pool.fetchval(
        "SELECT count(*) FROM (SELECT location_id FROM systems "
        "WHERE organization_id = ANY($1::uuid[]) "
        "GROUP BY location_id HAVING count(DISTINCT organization_id) > 1) x",
        DEMO_ORG_UUIDS)
    assert multi == 0
    # every retailer owns >=2 venues (Plan D arcs need a chain to draw)
    per_retailer = await projector_pool.fetch(
        "SELECT organization_id, count(DISTINCT location_id) AS venues "
        "FROM systems WHERE organization_id = ANY($1::uuid[]) GROUP BY organization_id",
        DEMO_ORG_UUIDS)
    assert len(per_retailer) == 4
    assert all(r["venues"] >= 2 for r in per_retailer)


async def test_seed_same_city_venue_pairs(projector_pool):
    # mras-ops #55: same-city venues so clustering triggers live. Cluster key is
    # city|country — strings must byte-match.
    await _apply_seed(projector_pool)
    pairs = await projector_pool.fetch(
        "SELECT city, country, count(*) AS n FROM locations "
        "WHERE metadata->>'demo_seed' = 'true' GROUP BY city, country "
        "HAVING count(*) >= 2")
    keys = {(r["city"], r["country"]) for r in pairs}
    assert {("New York", "US"), ("London", "GB"), ("Dubai", "AE")} <= keys


async def test_seed_v2_reassigns_systems_from_v1_umbrella_state(projector_pool):
    """THE v2-critical path: the live dev DB is v1-seeded (every demo system on
    the umbrella org). ON CONFLICT DO NOTHING cannot reassign — the explicit
    UPDATE must. Simulate v1 state, re-apply, assert the split lands."""
    await _apply_seed(projector_pool)
    await projector_pool.execute(
        "UPDATE systems SET organization_id = $1 WHERE config->>'demo_seed' = 'true'",
        uuid.UUID(DEMO_ORG))
    before = await projector_pool.fetchval("SELECT count(*) FROM systems")
    await _apply_seed(projector_pool)  # re-apply = reassign, never duplicate
    assert await projector_pool.fetchval("SELECT count(*) FROM systems") == before
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM systems WHERE organization_id = $1",
        uuid.UUID(DEMO_ORG)) == 0
    on_retailers = await projector_pool.fetchval(
        "SELECT count(*) FROM systems WHERE organization_id = ANY($1::uuid[]) "
        "AND organization_id <> $2", DEMO_ORG_UUIDS, uuid.UUID(DEMO_ORG))
    assert on_retailers == before
```

- [ ] **1.2 Run it and watch it fail** (dev postgres up: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_seed.py -q
```

Expected failures: the 4 new tests fail on assertions (no retailer orgs, umbrella owns all 38 systems, no same-city pairs), and `test_seed_creates_tagged_org_and_venues` fails its new `15 <=` band (v1 seeds 13 venues). The v1 seed file exists, so failures are assertion errors, not `FileNotFoundError`.

- [ ] **1.3 Commit the red test** — message: `test: red — seed v2 retailer orgs/split/same-city/reassignment (Globe Plan C T1)` (executor delegates every commit to the git-flow-manager subagent).

- [ ] **1.4 Rewrite the seed** — replace `/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql` with:

```sql
-- /Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql
-- God View Globe v2 / Plan C (spec 2026-07-12 §3): "Demo Retail Group" umbrella
-- + 4 fake retailer orgs, 16 venues (3 same-city — mras-ops #55), retailer split.
-- Seeds live OUTSIDE db/migrations/ on purpose — initdb applies migrations on
-- fresh volumes and fake data must never bake into every fresh DB.
-- Apply manually:
--   docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
-- Idempotent AND reassigning: fixed/derived uuids + ON CONFLICT DO NOTHING for
-- inserts; the v2 retailer split is applied by an EXPLICIT UPDATE (ON CONFLICT
-- DO NOTHING never updates, so on the live v1-seeded dev DB an insert-only v2
-- would silently leave every system on the umbrella). Works identically on a
-- fresh DB, on the v1-seeded dev DB, and on re-runs (all no-ops the 2nd time).
-- Reverse with /Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql.
-- Scope: org-id family dea00000-0000-4000-8000-000000000001..0005 is primary;
-- metadata.demo_seed=true on orgs/locations/location_participants/screen_groups;
-- systems carry it in config (no metadata column); cameras/displays have
-- neither — identified by the demo- screen_id namespace + their system join.

BEGIN;

-- Umbrella (v1). Retailers are organization_type 'host' — the enum has no
-- 'retailer' value (db/migrations/010_enums.sql:12); do NOT invent one.
INSERT INTO organizations (id, name, organization_type, status, metadata)
VALUES ('dea00000-0000-4000-8000-000000000001', 'Demo Retail Group', 'host',
        'active', '{"demo_seed": true}')
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE demo_orgs (slug text, id uuid, name text) ON COMMIT DROP;
INSERT INTO demo_orgs VALUES
  ('northline', 'dea00000-0000-4000-8000-000000000002', 'Northline Apparel'),
  ('vantage',   'dea00000-0000-4000-8000-000000000003', 'Vantage Motors'),
  ('corebrew',  'dea00000-0000-4000-8000-000000000004', 'Corebrew Coffee'),
  ('meridian',  'dea00000-0000-4000-8000-000000000005', 'Meridian Screens');

INSERT INTO organizations (id, name, organization_type, status,
                           parent_organization_id, metadata)
SELECT id, name, 'host', 'active',
       'dea00000-0000-4000-8000-000000000001', '{"demo_seed": true}'
FROM demo_orgs
ON CONFLICT DO NOTHING;

-- Umbrella -> retailer links (011_accounts.sql:12-19). Deterministic ids so
-- re-runs are no-ops. Teardown deletes these BEFORE the orgs (both FK columns
-- are NOT NULL REFERENCES organizations, no cascade).
INSERT INTO organization_relationships
    (id, from_organization_id, to_organization_id, relationship, status)
SELECT md5('demo-fleet:orgrel:' || slug)::uuid,
       'dea00000-0000-4000-8000-000000000001', id, 'umbrella', 'active'
FROM demo_orgs
ON CONFLICT DO NOTHING;

-- Venue catalog: 16 venues (13 v1 + 3 v2 same-city), real coordinates; org is
-- the single retailer owning every system at that venue (venues are
-- single-retailer by construction). SAME-CITY RULE (mras-ops #55): the new
-- hudson/battersea/emirates rows byte-match their partners' city|country
-- ('New York'/'US', 'London'/'GB', 'Dubai'/'AE') — the cluster selector keys
-- on that exact string pair.
CREATE TEMP TABLE demo_venues (
    slug text, name text, ltype text, city text, country text, tz text,
    lat numeric, lng numeric, n_systems int, org text
) ON COMMIT DROP;
INSERT INTO demo_venues VALUES
  ('moa',      'Mall of America',                'mall',    'Bloomington',     'US', 'America/Chicago',      44.8549,  -93.2422, 4, 'northline'),
  ('kop',      'King of Prussia Mall',           'mall',    'King of Prussia', 'US', 'America/New_York',     40.0885,  -75.3946, 3, 'vantage'),
  ('century',  'Westfield Century City',         'mall',    'Los Angeles',     'US', 'America/Los_Angeles',  34.0584, -118.4173, 3, 'vantage'),
  ('aventura', 'Aventura Mall',                  'mall',    'Aventura',        'US', 'America/New_York',     25.9565,  -80.1428, 2, 'corebrew'),
  ('yorkdale', 'Yorkdale Shopping Centre',       'mall',    'Toronto',         'CA', 'America/Toronto',      43.7255,  -79.4522, 2, 'corebrew'),
  ('wlondon',  'Westfield London',               'mall',    'London',          'GB', 'Europe/London',        51.5079,   -0.2216, 4, 'northline'),
  ('berlin',   'Mall of Berlin',                 'mall',    'Berlin',          'DE', 'Europe/Berlin',        52.5100,   13.3805, 2, 'vantage'),
  ('partdieu', 'Westfield La Part-Dieu',         'mall',    'Lyon',            'FR', 'Europe/Paris',         45.7610,    4.8570, 2, 'corebrew'),
  ('dubai',    'The Dubai Mall',                 'mall',    'Dubai',           'AE', 'Asia/Dubai',           25.1972,   55.2796, 5, 'vantage'),
  ('siam',     'Siam Paragon',                   'mall',    'Bangkok',         'TH', 'Asia/Bangkok',         13.7462,  100.5347, 2, 'northline'),
  ('chadstone','Chadstone Shopping Centre',      'mall',    'Melbourne',       'AU', 'Australia/Melbourne', -37.8859,  145.0838, 3, 'meridian'),
  ('changi',   'Changi Airport Terminal 3',      'airport', 'Singapore',       'SG', 'Asia/Singapore',        1.3554,  103.9866, 4, 'meridian'),
  ('fifthave', 'Fifth Avenue Flagship Showroom', 'store',   'New York',        'US', 'America/New_York',     40.7638,  -73.9730, 2, 'northline'),
  ('hudson',   'The Shops at Hudson Yards',      'mall',    'New York',        'US', 'America/New_York',     40.7539,  -74.0022, 2, 'corebrew'),
  ('battersea','Battersea Power Station',        'mall',    'London',          'GB', 'Europe/London',        51.4791,   -0.1465, 2, 'meridian'),
  ('emirates', 'Mall of the Emirates',           'mall',    'Dubai',           'AE', 'Asia/Dubai',           25.1181,   55.2008, 3, 'meridian');

INSERT INTO locations (id, name, location_type, city, country, lat, lng, timezone, status, metadata)
SELECT md5('demo-fleet:loc:' || slug)::uuid, name, ltype::location_type,
       city, country, lat, lng, tz, 'active', '{"demo_seed": true}'
FROM demo_venues
ON CONFLICT DO NOTHING;

-- Participants stay on the UMBRELLA for all venues (v1 shape, deliberately):
-- nothing reads participants for org identity, and one shape keeps fresh and
-- live DBs convergent. Teardown scopes these by the org-id SET.
INSERT INTO location_participants (id, location_id, organization_id, role, status, metadata)
SELECT md5('demo-fleet:lp:' || slug)::uuid, md5('demo-fleet:loc:' || slug)::uuid,
       'dea00000-0000-4000-8000-000000000001', 'host', 'active', '{"demo_seed": true}'
FROM demo_venues
ON CONFLICT DO NOTHING;

-- Systems: n_systems per venue, deterministic ids, retailer org carried along.
CREATE TEMP TABLE demo_systems ON COMMIT DROP AS
SELECT md5('demo-fleet:sys:' || v.slug || ':' || i)::uuid          AS id,
       md5('demo-fleet:loc:' || v.slug)::uuid                     AS location_id,
       v.slug                                                     AS slug,
       i                                                          AS sys_idx,
       o.id                                                       AS organization_id,
       (ARRAY['Entrance Wall A','Food Court Wall','Atrium Displays',
              'Concourse Screens','Promenade Wall'])[i]           AS name,
       (ARRAY['Level 1','Food Court','Atrium','Concourse B','Promenade'])[i] AS zone
FROM demo_venues v
JOIN demo_orgs o ON o.slug = v.org, generate_series(1, v.n_systems) AS i;

INSERT INTO systems (id, organization_id, location_id, name, system_type, zone, status, config)
SELECT id, organization_id, location_id, name,
       'onsite_mras', zone, 'active', '{"demo_seed": true}'
FROM demo_systems
ON CONFLICT DO NOTHING;

-- V2 RETAILER SPLIT — EXPLICIT IDEMPOTENT REASSIGNMENT (outside-review
-- amendment, CRITICAL): the live dev DB is v1-seeded, every demo system sits on
-- the umbrella org, and the INSERT above touches none of them. Move each
-- existing demo system onto its retailer. Fresh DBs and re-runs: 0 rows.
UPDATE systems s
SET organization_id = ds.organization_id, updated_at = now()
FROM demo_systems ds
WHERE s.id = ds.id
  AND s.organization_id IS DISTINCT FROM ds.organization_id;

-- One screen_group per system (every demo system has >=2 displays).
INSERT INTO screen_groups (id, system_id, location_id, name, group_type, status, metadata)
SELECT md5('demo-fleet:grp:' || slug || ':' || sys_idx)::uuid, id, location_id,
       name || ' Group', 'zone', 'active', '{"demo_seed": true}'
FROM demo_systems
ON CONFLICT DO NOTHING;

-- Cameras: 1-2 per system (1 + sys_idx % 2). screen_id is globally UNIQUE (020)
-- so the demo- namespace guarantees no collision with real devices.
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

-- Status spread so Health mode has something to show. Deterministic screen_ids;
-- idempotent UPDATEs (unchanged from v1).
UPDATE displays SET status = 'degraded'
WHERE screen_id IN ('demo-disp-wlondon-2-1', 'demo-disp-moa-3-2', 'demo-disp-dubai-4-1');
UPDATE displays SET status = 'offline', last_seen_at = now() - interval '3 hours'
WHERE screen_id = 'demo-disp-changi-1-2';
UPDATE cameras SET status = 'degraded'
WHERE screen_id = 'demo-cam-century-2-1';
UPDATE cameras SET status = 'offline', last_seen_at = now() - interval '5 hours'
WHERE screen_id = 'demo-cam-kop-1-1';

-- Real demo box gets coordinates so it plots as the one live dot (v1,
-- unchanged). GUARDED single-row UPDATE: locations.id
-- acc4e851-ab7a-4b59-989e-85cb8b597e14 is the dev DB's "Demo Store" (verified
-- live 2026-07-12). "lat IS NULL" guard: never clobbers owner-set coordinates.
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

Expected: `9 passed` (5 v1 tests updated + 4 new). **Known cross-file red until Task 2:** `tests/test_demo_teardown.py` now fails (its activity-injection helper picks a system `WHERE organization_id = <umbrella>` and finds none) — that is Task 2's red, do not "fix" it here.

- [ ] **1.6 Commit the green impl** — message: `feat: seed v2 — 4 retailer orgs under the umbrella, 16 venues (3 same-city, closes #55), explicit idempotent system reassignment (Globe Plan C T1)`.

---

## Task 2 — Teardown v2: org-id SET conversion, relationships-before-orgs, retailers-before-umbrella (`teardown_demo_fleet.sql`)

**Files**
- Modify: `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql`
- Test: `/Users/jn/code/mras-ops/api/tests/test_demo_teardown.py` (extend + update)

**Interfaces**
- Consumes: the org-id family from Task 1; the FK graph (no cascades): `organization_relationships.from/to_organization_id NOT NULL → organizations` (011:12-19), retailer `parent_organization_id → umbrella` (011:6), plus every v1 dependency.
- Produces: the SAME dependency-ordered teardown with **every umbrella-uuid predicate widened to the SET** via a `demo_org_ids` temp table, plus two new final steps (delete `organization_relationships`, then retailer orgs, then the umbrella). All v1 invariants hold: `events.ad_run_id` + `unresolved_devices.event_id` cycle-breaker NULL-outs first, `projector_state` never touched, Demo Org/System/Store leave-as-is, idempotent re-runs.

**Exhaustive predicate inventory (verify against the pre-change file — every one converts, none may be missed).** The umbrella uuid appears **28 times across 20 statements** in the v1 file `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql`:

| v1 lines | statement | occurrences |
|---|---|---|
| 26, 28 | `UPDATE events SET ad_run_id = NULL` (ad_runs org + systems subquery) | 2 |
| 31 | `UPDATE unresolved_devices SET event_id = NULL` (events org) | 1 |
| 38, 40 | `DELETE FROM viewer_exposures` (org + systems subquery) | 2 |
| 44, 46 | `DELETE FROM identity_matches` (subject_observations org + systems subquery) | 2 |
| 48, 50 | `DELETE FROM playbacks` (org + systems subquery) | 2 |
| 54, 56 | `DELETE FROM ad_runs` (org + systems subquery) | 2 |
| 58, 60 | `DELETE FROM composition_runs` (org + systems subquery) | 2 |
| 62, 64 | `DELETE FROM personalization_decisions` (org + systems subquery) | 2 |
| 66, 68 | `DELETE FROM subject_observations` (org + systems subquery) | 2 |
| 74 | `DELETE FROM events` (org; payload clause stays as-is) | 1 |
| 80 | `DELETE FROM observation_tracks` (systems subquery; `demo-cam-%` clause stays) | 1 |
| 85 | `DELETE FROM device_health_events` (devices→systems subquery) | 1 |
| 88 | `DELETE FROM system_health_events` (systems subquery) | 1 |
| 93 | `DELETE FROM cameras` (systems subquery) | 1 |
| 96 | `DELETE FROM displays` (systems subquery) | 1 |
| 99 | `DELETE FROM screen_groups` (systems subquery) | 1 |
| 102 | `DELETE FROM devices` (systems subquery) | 1 |
| 104 | `DELETE FROM systems` (org) | 1 |
| 106 | `DELETE FROM location_participants` (org) | 1 |
| 113 | `DELETE FROM organizations` (id) — becomes the two-step retailers-then-umbrella delete | 1 |

(The `DELETE FROM locations` statement at v1 lines 109-111 is tag+orphan-scoped, not org-scoped — unchanged.)

### Steps

- [ ] **2.1 Write the failing tests** — in `/Users/jn/code/mras-ops/api/tests/test_demo_teardown.py`: replace the `DEMO_ORG` constant block (line ~14) with the same `DEMO_ORG` / `DEMO_RETAILERS` / `DEMO_ORG_UUIDS` constants as Task 1.1; update `_inject_demo_activity` to pick a **retailer-owned** system and stamp **its** org (the v2-realistic shape — the generator stamps target orgs after Task 3):

```python
async def _inject_demo_activity(pool):
    """Simulate v2 generator + projector output: activity attributed to a
    RETAILER org (never the umbrella — post-split the umbrella owns no systems),
    incl. an events row BACK-STAMPED with ad_run_id (the FK cycle) and an
    unresolved_devices row pointing at a demo event."""
    row = await pool.fetchrow(
        "SELECT s.id AS system_id, s.organization_id, s.location_id, d.screen_id "
        "FROM systems s JOIN displays d ON d.system_id = s.id "
        "WHERE s.organization_id = ANY($1::uuid[]) LIMIT 1", DEMO_ORG_UUIDS)
    assert row is not None and str(row["organization_id"]) != DEMO_ORG
    trig = uuid.uuid4()
    comp_id = await pool.fetchval(
        "INSERT INTO composition_runs (trigger_id, organization_id, location_id, system_id, status) "
        "VALUES ($1,$2,$3,$4,'rendered') RETURNING id",
        trig, row["organization_id"], row["location_id"], row["system_id"])
    ad_run_id = await pool.fetchval(
        "INSERT INTO ad_runs (trigger_id, organization_id, location_id, system_id, "
        "composition_run_id, status) VALUES ($1,$2,$3,$4,$5,'completed') RETURNING id",
        trig, row["organization_id"], row["location_id"], row["system_id"], comp_id)
    await pool.execute(
        "INSERT INTO playbacks (trigger_id, screen_id, ad_run_id, organization_id, "
        "location_id, system_id, status) VALUES ($1,$2,$3,$4,$5,$6,'ended')",
        trig, row["screen_id"], ad_run_id, row["organization_id"],
        row["location_id"], row["system_id"])
    event_id = await pool.fetchval(
        "INSERT INTO events (trigger_id, service, event_type, status, payload, "
        "organization_id, location_id, system_id, ad_run_id) "
        "VALUES ($1,'mras-composer','ad_run','completed',$2::jsonb,$3,$4,$5,$6) RETURNING id",
        trig, json.dumps({"demo_seed": True, "screen_id": row["screen_id"],
                          "screen_kind": "display"}),
        row["organization_id"], row["location_id"], row["system_id"], ad_run_id)
    await pool.execute(
        "INSERT INTO unresolved_devices (screen_id, kind, event_id) VALUES ($1,'display',$2)",
        "demo-disp-never-registered", event_id)
    return trig
```

then update `test_teardown_leaves_zero_demo_rows`: every org-parameterized check switches from `= $1 … uuid.UUID(DEMO_ORG)` to `= ANY($1::uuid[]) … DEMO_ORG_UUIDS`, and the `organizations` check becomes `"SELECT count(*) FROM organizations WHERE id = ANY($1::uuid[])"`; update `test_teardown_idempotent`'s final assert the same way; and append:

```python
async def test_teardown_removes_relationships_and_all_five_orgs(projector_pool):
    await _apply(projector_pool, SEED)
    await _apply(projector_pool, TEARDOWN)
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM organization_relationships "
        "WHERE from_organization_id = ANY($1::uuid[]) "
        "   OR to_organization_id = ANY($1::uuid[])", DEMO_ORG_UUIDS) == 0
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM organizations WHERE id = ANY($1::uuid[])",
        DEMO_ORG_UUIDS) == 0
```

- [ ] **2.2 Run it and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_teardown.py -q
```

Expected failure: **`asyncpg.exceptions.ForeignKeyViolationError` applying the v1 teardown** — its final `DELETE FROM organizations WHERE id = '…0001'` hits the retailers' `parent_organization_id` FK (and their `organization_relationships` rows). This IS the bug the SET conversion fixes; all 4 tests error/fail.

- [ ] **2.3 Commit the red test** — message: `test: red — teardown v2 org-SET zero-rows, relationships-before-orgs, retailer-attributed activity (Globe Plan C T2)`.

- [ ] **2.4 Rewrite the teardown** — replace `/Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql` with (every statement identical to v1 except the predicate source and the new step 5-tail; keep all v1 comments about cycle-breakers/cursor/leave-as-is intact, updated to say "org-id SET"):

```sql
-- /Users/jn/code/mras-ops/db/seed/teardown_demo_fleet.sql
-- Reverses /Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql (v2: umbrella +
-- 4 retailer orgs) plus everything the demo-traffic generator + projector
-- derived from it (spec 2026-07-12 §3).
-- Apply manually (stop scripts/demo_traffic.py first):
--   docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/teardown_demo_fleet.sql
--
-- V2: scope is the DEMO-ORG-ID SET below — v1 hardcoded the umbrella uuid in
-- 28 predicates; ANY single-uuid predicate left behind silently strands
-- retailer-attributed rows. EVERY org predicate reads from demo_org_ids.
-- EXPLICIT DEPENDENCY ORDER (no ON DELETE CASCADE anywhere):
--   * events.ad_run_id -> ad_runs is BACK-STAMPED by the projector fold —
--     NULL it for demo rows before deleting ad_runs (FK cycle via
--     personalization_decisions).
--   * unresolved_devices.event_id -> events — NULL it for demo events.
--   * organization_relationships rows go BEFORE the orgs (both FK columns
--     NOT NULL, no cascade); retailer orgs BEFORE the umbrella (their
--     parent_organization_id references it).
-- NEVER reset projector_state / never "rebuild" the projector as cleanup.
-- LEAVE-AS-IS SET: the real "Demo Org" (55bf0abd-...), "Demo System"
-- (d8d2d05d-...), and "Demo Store" (acc4e851-...) rows — including the lat/lng
-- the seed gave Demo Store — are intentionally untouched.
-- Idempotent: every statement is scoped; re-running deletes nothing.

BEGIN;

CREATE TEMP TABLE demo_org_ids ON COMMIT DROP AS
SELECT unnest(ARRAY[
    'dea00000-0000-4000-8000-000000000001',  -- Demo Retail Group (umbrella)
    'dea00000-0000-4000-8000-000000000002',  -- Northline Apparel
    'dea00000-0000-4000-8000-000000000003',  -- Vantage Motors
    'dea00000-0000-4000-8000-000000000004',  -- Corebrew Coffee
    'dea00000-0000-4000-8000-000000000005'   -- Meridian Screens
]::uuid[]) AS id;

-- 0. Cycle breakers
UPDATE events SET ad_run_id = NULL
WHERE ad_run_id IN (
    SELECT id FROM ad_runs
    WHERE organization_id IN (SELECT id FROM demo_org_ids)
       OR system_id IN (SELECT id FROM systems
                        WHERE organization_id IN (SELECT id FROM demo_org_ids)));
UPDATE unresolved_devices SET event_id = NULL
WHERE event_id IN (SELECT id FROM events
                   WHERE organization_id IN (SELECT id FROM demo_org_ids)
                      OR payload->>'demo_seed' = 'true');

-- 1. Projector-derived activity leaves. Scoped by org AND by demo systems
-- (belt-and-braces: a row folded before back-stamping still carries the demo
-- system scope).
DELETE FROM viewer_exposures
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM identity_matches
WHERE subject_observation_id IN (
    SELECT id FROM subject_observations
    WHERE organization_id IN (SELECT id FROM demo_org_ids)
       OR system_id IN (SELECT id FROM systems
                        WHERE organization_id IN (SELECT id FROM demo_org_ids)));
DELETE FROM playbacks
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));

-- 2. Runs (children before parents: ad_runs -> composition_runs -> decisions)
DELETE FROM ad_runs
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM composition_runs
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM personalization_decisions
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM subject_observations
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));

-- 3. Journal rows (payload clause is belt-and-braces for rows that escaped
-- org-stamping).
DELETE FROM events
WHERE organization_id IN (SELECT id FROM demo_org_ids)
   OR payload->>'demo_seed' = 'true';

-- 4. Remaining derived rows keyed on demo devices/systems
DELETE FROM observation_tracks
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids))
   OR camera_screen_id LIKE 'demo-cam-%';
DELETE FROM device_health_events
WHERE device_id IN (SELECT id FROM devices
                    WHERE system_id IN (SELECT id FROM systems
                                        WHERE organization_id IN (SELECT id FROM demo_org_ids)));
DELETE FROM system_health_events
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));

-- 5. Devices -> groups -> systems -> participants -> orphaned venues ->
--    org links -> retailer orgs -> umbrella
DELETE FROM cameras
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM displays
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM screen_groups
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM devices
WHERE system_id IN (SELECT id FROM systems
                    WHERE organization_id IN (SELECT id FROM demo_org_ids));
DELETE FROM systems
WHERE organization_id IN (SELECT id FROM demo_org_ids);
DELETE FROM location_participants
WHERE organization_id IN (SELECT id FROM demo_org_ids);
-- Only ORPHANED seeded venues — and never Demo Store (it is untagged).
DELETE FROM locations
WHERE metadata->>'demo_seed' = 'true'
  AND NOT EXISTS (SELECT 1 FROM systems s WHERE s.location_id = locations.id);
-- Org links first (both FK columns NOT NULL -> organizations, no cascade) …
DELETE FROM organization_relationships
WHERE from_organization_id IN (SELECT id FROM demo_org_ids)
   OR to_organization_id   IN (SELECT id FROM demo_org_ids);
-- … then retailers (parent_organization_id -> umbrella) …
DELETE FROM organizations
WHERE id IN (SELECT id FROM demo_org_ids)
  AND id <> 'dea00000-0000-4000-8000-000000000001';
-- … then the umbrella.
DELETE FROM organizations
WHERE id = 'dea00000-0000-4000-8000-000000000001';

COMMIT;
```

- [ ] **2.5 Run to green** (teardown + seed suites together — Task 1's cross-file red must clear here):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_demo_teardown.py tests/test_demo_seed.py -q
```

Expected: `13 passed` (4 teardown + 9 seed).

- [ ] **2.6 Commit the green impl** — message: `feat: teardown v2 — org-id SET (28 predicates converted), relationships-before-orgs, retailers-before-umbrella, cursor untouched (Globe Plan C T2)`.

---

## Task 3 — Generator retargeting: org SET + per-target org stamping (`scripts/demo_traffic.py`)

**Files**
- Modify: `/Users/jn/code/mras-ops/scripts/demo_traffic.py`
- Test: `/Users/jn/code/mras-ops/tests/test_demo_traffic.py` (extend + update; AsyncMock-only, no DB)

**Interfaces**
- Consumes: the seeded v2 fleet (org-id family); the projector back-stamp contract (recon 7).
- Produces:
  - `DEMO_UMBRELLA_ORG` + `DEMO_ORG_IDS` constants (the uuid family; replaces `DEMO_ORG_NAME` — name-based resolution goes away, the deterministic family is the contract).
  - `load_demo_orgs(pool) -> list[str]` (replaces `load_demo_org`): fetches the PRESENT members of the family (tag-checked); **hard-exits (`SystemExit(1)`) when the umbrella is absent** (the seed sentinel — cannot run post-teardown).
  - `load_targets(pool, org_ids)`: `WHERE s.organization_id = ANY($1::uuid[])` and the SELECT now carries `s.organization_id` per target row.
  - `emit_sequence(pool, target, trigger_id, beats, …)` (org param REMOVED): every events row stamped with **`target["organization_id"]`** — the target system's org, never the umbrella — so the projector's back-stamp (`fold.py:104-122`, org from the system row via `scope.py:29-41`) overwrites with identical values.
  - Mid-run recheck keys on the **umbrella as sentinel** (spec-approved): teardown removes the whole family in one transaction, so the umbrella's disappearance is the set's disappearance. Hard-scope/hard-exit discipline, pacing, sequences, payload shapes: unchanged.

### Steps

- [ ] **3.1 Write the failing tests** — in `/Users/jn/code/mras-ops/tests/test_demo_traffic.py`:

  1. Change the import (line 9-10) to:

```python
from scripts.demo_traffic import (DEMO_ORG_IDS, DEMO_UMBRELLA_ORG, SETTLE_GAP_S,
                                  build_sequence, emit_sequence, load_demo_orgs,
                                  run)
```

  2. Add to `TARGET` (line 12-19): `"organization_id": "dea00000-0000-4000-8000-000000000002",  # Northline — a RETAILER, deliberately not the umbrella`.
  3. Rewrite `test_emit_sequence_stamps_scope_and_timestamps` (lines 74-100): call becomes `await emit_sequence(pool, TARGET, "trig-2", beats, sleep=sleep)` and the org assertion becomes:

```python
        # stamped with the TARGET system's org — NEVER the umbrella. The
        # projector back-stamps org from the system row; insert-time value must
        # match so the back-stamp overwrites with identical values.
        assert args[6] == TARGET["organization_id"]
        assert args[6] != DEMO_UMBRELLA_ORG
```

  (all other assertions in that test unchanged).
  4. Replace `test_load_demo_org_hard_exits_when_absent` (lines 103-107) with:

```python
async def test_load_demo_orgs_hard_exits_when_umbrella_absent():
    # retailers alone are not enough — the umbrella is the seed sentinel
    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=[{"id": o} for o in DEMO_ORG_IDS[1:]])
    with pytest.raises(SystemExit):
        await load_demo_orgs(pool)


async def test_load_demo_orgs_returns_present_subset():
    pool = AsyncMock()
    present = [DEMO_ORG_IDS[0], DEMO_ORG_IDS[2]]  # umbrella + one retailer
    pool.fetch = AsyncMock(return_value=[{"id": o} for o in present])
    assert await load_demo_orgs(pool) == present
    # targets query is scoped to exactly the present set
    sql = pool.fetch.await_args.args[0]
    assert "ANY($1::uuid[])" in sql
```

  5. Update the drain regression test (lines 110-131): give every fabricated target `"organization_id": DEMO_ORG_IDS[1 + i % 4]`, and replace the single `pool.fetch` mock with the two-fetch shape (org resolution first, then targets):

```python
    pool.fetch = AsyncMock(side_effect=[
        [{"id": o} for o in DEMO_ORG_IDS],       # load_demo_orgs
        [dict(t) for t in targets],              # load_targets
    ])
```

  (`pool.fetchval` still returns the umbrella id — it now serves only the mid-run sentinel recheck.)

- [ ] **3.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py -q
```

Expected failure: `ImportError: cannot import name 'load_demo_orgs' from 'scripts.demo_traffic'` (collection error — every test fails).

- [ ] **3.3 Commit the red test** — message: `test: red — demo_traffic org-SET targeting, per-target org stamping, umbrella-sentinel hard-exit (Globe Plan C T3)`.

- [ ] **3.4 Implement** — in `/Users/jn/code/mras-ops/scripts/demo_traffic.py`:

  1. Replace the `DEMO_ORG_NAME` constant (line 40) with:

```python
DEMO_UMBRELLA_ORG = "dea00000-0000-4000-8000-000000000001"  # Demo Retail Group
# The deterministic demo-org uuid family (seed v2): umbrella + 4 retailers.
# Targets are scoped to the PRESENT members of this set; events are stamped
# with each target system's own org (the projector back-stamps org from the
# system row — api/src/projector/scope.py — and must overwrite with identical
# values).
DEMO_ORG_IDS = [
    DEMO_UMBRELLA_ORG,
    "dea00000-0000-4000-8000-000000000002",  # Northline Apparel
    "dea00000-0000-4000-8000-000000000003",  # Vantage Motors
    "dea00000-0000-4000-8000-000000000004",  # Corebrew Coffee
    "dea00000-0000-4000-8000-000000000005",  # Meridian Screens
]
```

  2. Replace `load_demo_org` (lines 131-141) with:

```python
async def load_demo_orgs(pool) -> list:
    """Hard-scope guard: return the PRESENT members of the demo-org family.
    The umbrella is the seed sentinel — hard-exit when it is absent (the
    generator cannot run post-teardown; teardown removes the whole family in
    one transaction)."""
    rows = await pool.fetch(
        "SELECT id FROM organizations "
        "WHERE id = ANY($1::uuid[]) AND metadata->>'demo_seed' = 'true'",
        DEMO_ORG_IDS)
    present = [str(r["id"]) for r in rows]
    if DEMO_UMBRELLA_ORG not in present:
        print("[demo-traffic] demo umbrella org absent — apply "
              "/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql first. Exiting.")
        raise SystemExit(1)
    return present
```

  3. In `load_targets` (lines 144-159): signature becomes `load_targets(pool, org_ids)`, the SELECT gains `s.organization_id,` after `s.id AS system_id,`, and the WHERE becomes `WHERE s.organization_id = ANY($1::uuid[])` with `org_ids` passed as the parameter. Docstring: "One target per ACTIVE display of the demo-org SET (hard-scoped by the WHERE); each row carries its system's org for insert-time stamping."
  4. In `emit_sequence` (lines 110-128): signature becomes `emit_sequence(pool, target, trigger_id, beats, sleep=asyncio.sleep, clock=time.monotonic)` (org param removed) and the execute call stamps `target["organization_id"]` as `$6`. Add to the docstring: "Events are stamped with the TARGET system's org (never the umbrella) so the projector's back-stamp overwrites with identical values."
  5. In `run` (lines 162-198): `org_id = await load_demo_org(pool)` → `org_ids = await load_demo_orgs(pool)`; `load_targets(pool, org_id)` → `load_targets(pool, org_ids)`; the mid-run recheck (lines 181-184) queries `DEMO_UMBRELLA_ORG` (sentinel) with the message `"[demo-traffic] demo umbrella org gone (teardown) — exiting"`; the emit call becomes `emit_sequence(pool, target, trigger_id, beats)`.
  6. Remove nothing else — pacing, weights, drain snapshot, `--rate/--failure-pct/--duration` are untouched. (`DEMO_ORG_NAME` is gone because this change made it unused.)

- [ ] **3.5 Run to green:**

```bash
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py -q
```

Expected: `7 passed` (5 updated + 2 new; the drain regression still passes with the two-fetch mock).

- [ ] **3.6 Commit the green impl** — message: `feat: demo_traffic v2 — org-SET targets, events stamped with each target system's org, umbrella-sentinel hard-exit (Globe Plan C T3)`.

---

## Task 4 — `GET /god-view/map`: additive `org` + `rollup.last_run_created_at`

**Files**
- Modify: `/Users/jn/code/mras-ops/api/src/godview/map.py` (`_MAP_SQL` + `get_map`)
- Test: `/Users/jn/code/mras-ops/api/tests/test_godview_map.py` (append tests)

**Interfaces**
- Consumes: `systems.organization_id` (NOT NULL — recon 3) joined to `organizations.name`; the existing `act` CTE's `ar_created_at` (recon 9).
- Produces: the Contract section's `/map` additions — `venue.org` (dominant org, tie-break `count DESC, organization_id ASC`, name joined) and `venue.rollup.last_run_created_at` (`max(ar_created_at)`, unwindowed). **No `main.py` change** (route wired at `main.py:409-413`); still ONE set-based query.

### Steps

- [ ] **4.1 Write the failing tests** — append to `/Users/jn/code/mras-ops/api/tests/test_godview_map.py`:

```python
# --------------------------------------------------------------------------- #
# Globe v2 additive fields: venue org + rollup.last_run_created_at (Plan C)
# --------------------------------------------------------------------------- #
async def _named_org(pool, org_id, name):
    await pool.execute(
        "INSERT INTO organizations (id,name,organization_type) VALUES ($1,$2,'host')",
        uuid.UUID(org_id), name)
    return uuid.UUID(org_id)


async def test_map_org_is_dominant_by_system_count_with_name(projector_pool):
    a = await _named_org(projector_pool, "aaaaaaaa-0000-4000-8000-000000000001", "Alpha Retail")
    b = await _named_org(projector_pool, "bbbbbbbb-0000-4000-8000-000000000001", "Beta Retail")
    loc = await _venue(projector_pool, "V")
    await _system(projector_pool, a, loc, "S1")
    await _system(projector_pool, a, loc, "S2")
    await _system(projector_pool, b, loc, "S3")
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["org"] == {"id": a, "name": "Alpha Retail"}  # 2 systems beat 1


async def test_map_org_tiebreak_is_count_desc_then_org_id(projector_pool):
    # equal counts -> lower organization_id wins (deterministic, testable)
    lo = await _named_org(projector_pool, "10000000-0000-4000-8000-000000000001", "Low Org")
    hi = await _named_org(projector_pool, "20000000-0000-4000-8000-000000000001", "High Org")
    loc = await _venue(projector_pool, "V")
    await _system(projector_pool, hi, loc, "S-hi")
    await _system(projector_pool, lo, loc, "S-lo")
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["org"] == {"id": lo, "name": "Low Org"}


async def test_map_last_run_created_at_none_without_runs(projector_pool):
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    await _system(projector_pool, org, loc)
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["last_run_created_at"] is None
    assert v["org"] is not None  # org present even with zero activity


async def test_map_last_run_created_at_is_unwindowed_max(projector_pool):
    # NOT windowed like runs_last_hour: a 2h-old run still counts; the max is
    # monotone (Lane 3's "new run" delta signal must never move backwards).
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status,created_at) "
        "VALUES ($1,$2,$3,'completed', now() - interval '2 hours')",
        uuid.uuid4(), loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    first = v["rollup"]["last_run_created_at"]
    assert first is not None
    assert v["rollup"]["runs_last_hour"] == 0  # windowed sibling disagrees — by design
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status) "
        "VALUES ($1,$2,$3,'completed')", uuid.uuid4(), loc, sid)
    v = _venue_by_name(await get_map(projector_pool), "V")
    assert v["rollup"]["last_run_created_at"] > first  # advanced
```

- [ ] **4.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected failure: the 4 new tests fail with `KeyError: 'org'` / `KeyError: 'last_run_created_at'`; the 10 pre-existing tests stay green.

- [ ] **4.3 Commit the red test** — message: `test: red — /god-view/map venue org (dominant, deterministic tie-break) + rollup.last_run_created_at (Globe Plan C T4)`.

- [ ] **4.4 Implement** — in `/Users/jn/code/mras-ops/api/src/godview/map.py`:

  1. In `_MAP_SQL`, add one line to the `act` CTE (after the `failures_last_hour` line at line 78):

```sql
           max(ar_created_at)                                                AS last_run_created_at,
```

  2. Add a new CTE after `act` (before the closing `)` join to the outer SELECT — i.e. `act` gains a trailing comma and this follows):

```sql
vorg AS (
    -- Dominant org per venue, derived truthfully from systems.organization_id
    -- (NOT NULL — 012_physical.sql:29). Deterministic tie-break: most systems
    -- first, then lowest organization_id; name joined for the client org chip.
    SELECT DISTINCT ON (location_id) location_id, organization_id, org_name
    FROM (
        SELECT s.location_id, s.organization_id, o.name AS org_name,
               count(*) AS n
        FROM systems s
        JOIN organizations o ON o.id = s.organization_id
        GROUP BY s.location_id, s.organization_id, o.name
    ) t
    ORDER BY location_id, n DESC, organization_id
)
```

  3. In the outer SELECT: add `vorg.organization_id AS org_id, vorg.org_name,` (after the `worst_status` CASE) and `act.last_run_created_at,` (next to `act.last_activity_at`); add `LEFT JOIN vorg ON vorg.location_id = l.id` after the `LEFT JOIN act` line.
  4. In `get_map` (lines 105-130): the venue dict gains, after `"lng"`:

```python
            "org": ({"id": r["org_id"], "name": r["org_name"]}
                    if r["org_id"] is not None else None),
```

  and the `"rollup"` dict gains `"last_run_created_at": r["last_run_created_at"],` next to `"last_activity_at"`.
  5. Extend the module docstring's encodings block with two lines: `org — dominant org by system count, tie-break count DESC then organization_id; nullable by type, unreachable-null today (map venues always have systems, systems.organization_id NOT NULL)` and `last_run_created_at — max(ad_runs.created_at), UNWINDOWED (monotone new-run delta signal for the globe pulse)`.

- [ ] **4.5 Run to green:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected: `14 passed`.

- [ ] **4.6 Commit the green impl** — message: `feat: /god-view/map — additive venue org (dominant, count DESC/org_id tie-break) + rollup.last_run_created_at (Globe Plan C T4)`.

---

## Task 5 — Panel `ad_runs[].display_id` (additive)

**Files**
- Modify: `/Users/jn/code/mras-ops/api/src/godview/map.py` (`get_map_location` ad_runs query)
- Test: `/Users/jn/code/mras-ops/api/tests/test_godview_map.py` (append test)

**Interfaces**
- Consumes: `ad_runs.display_id` (015_runs.sql:67-95; projector-populated from display-scope events — recon 8).
- Produces: the Contract's panel addition — each `ad_runs` row carries `"display_id": uuid | null`. One-line SELECT change; the rows are built with `dict(r)` (recon 10) so no Python shaping.

### Steps

- [ ] **5.1 Write the failing test** — append to `/Users/jn/code/mras-ops/api/tests/test_godview_map.py`:

```python
async def test_panel_ad_runs_carry_display_id(projector_pool):
    # Lane 3's traveling pulse needs the display end of each run. display_id is
    # projector-populated from display-scope events; camera-scope-only runs
    # (e.g. generator failure path) legitimately keep it NULL.
    org = await _org(projector_pool)
    loc = await _venue(projector_pool, "V")
    sid = await _system(projector_pool, org, loc, "S")
    disp = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO displays (id,system_id,screen_id) VALUES ($1,$2,'disp-x')",
        disp, sid)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,display_id,status) "
        "VALUES ($1,$2,$3,$4,'completed')", uuid.uuid4(), loc, sid, disp)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,location_id,system_id,status) "
        "VALUES ($1,$2,$3,'failed')", uuid.uuid4(), loc, sid)
    panel = await get_map_location(projector_pool, loc)
    by_status = {r["status"]: r for r in panel["ad_runs"]}
    assert by_status["completed"]["display_id"] == disp
    assert by_status["failed"]["display_id"] is None  # nullable, key always present
```

- [ ] **5.2 Run and watch it fail:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected failure: the new test fails with `KeyError: 'display_id'`; the other 14 stay green.

- [ ] **5.3 Commit the red test** — message: `test: red — panel ad_runs display_id, nullable (Globe Plan C T5)`.

- [ ] **5.4 Implement** — in `/Users/jn/code/mras-ops/api/src/godview/map.py`, the `ad_runs` query inside `get_map_location` (lines 169-174) gains `ar.display_id,` after `ar.system_id,`:

```python
    ad_runs = [dict(r) for r in await conn.fetch(
        "SELECT ar.id, ar.status::text AS status, ar.system_id, ar.display_id, "
        "s.name AS system_name, "
        "ar.started_at, ar.ended_at, ar.created_at "
        "FROM ad_runs ar LEFT JOIN systems s ON s.id = ar.system_id "
        "WHERE ar.location_id = $1 "
        "ORDER BY ar.created_at DESC, ar.id DESC LIMIT $2", location_id, limit)]
```

- [ ] **5.5 Run to green:**

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/test_godview_map.py -q
```

Expected: `15 passed`.

- [ ] **5.6 Commit the green impl** — message: `feat: /god-view/map/locations/{id} — ad_runs rows carry display_id (Globe Plan C T5)`.

---

## Task 6 — Full suites + live drill v2 (v1-seeded dev DB → seed v2 → generator → asserts → teardown → re-seed)

**Files** — none created; this is the verification gate. All commands run from the branch worktree.

**Interfaces**
- Consumes: Tasks 1–5 deployed against the live dev stack, whose DB is **already v1-seeded** (recon 12) — the drill proves the reassignment path on real data, not just in the throwaway DB.
- Produces: proof of every hard requirement — split live, clustering-ready same-city venues, org field per venue, `last_run_created_at` advancing, `display_id` in panel runs, 0 projector skips, org back-stamp identity, teardown to zero rows across the whole family, cursor + Demo Store intact, generator guard.

### Steps

- [ ] **6.1 Full relevant test suites** (all green before the live drill):

```bash
cd /Users/jn/code/mras-ops/api && python3 -m pytest tests/ -q
cd /Users/jn/code/mras-ops && python3 -m pytest tests/test_demo_traffic.py tests/test_purge.py tests/test_schema_godview.py -q
```

Expected: all pass, zero failures (the api suite includes the projector/registry/godview tests — any regression there is a Plan-C bug).

- [ ] **6.2 Deploy + capture pre-state** (api image must contain Tasks 4–5 — code is baked in, recon 14):

```bash
cd /Users/jn/code/mras-ops && docker compose ps
docker compose build mras-ops-api && docker compose up -d mras-ops-api
docker exec mras-ops-postgres-1 psql -U mras -d mras -c \
  "SELECT count(*) AS v1_umbrella_systems FROM systems WHERE organization_id='dea00000-0000-4000-8000-000000000001';" -c \
  "SELECT cursor FROM projector_state WHERE id=1;"
```

Expected: `postgres`, `mras-ops-api`, `mras-ops-projector` up; `v1_umbrella_systems = 38` (the v1-seeded state — if 0, the DB was torn down since Plan A; the drill still proceeds and exercises the fresh path instead). **Record the cursor value** for 6.8.

- [ ] **6.3 Apply seed v2 to the live dev DB + prove idempotency AND reassignment:**

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
docker exec mras-ops-postgres-1 psql -U mras -d mras -c \
  "SELECT count(*) FROM locations WHERE metadata->>'demo_seed'='true';" -c \
  "SELECT o.name, count(s.id) FROM organizations o LEFT JOIN systems s ON s.organization_id=o.id \
   WHERE o.id::text LIKE 'dea00000-%' GROUP BY o.name ORDER BY o.name;" -c \
  "SELECT count(*) FROM organization_relationships WHERE from_organization_id='dea00000-0000-4000-8000-000000000001';" -c \
  "SELECT city, country, count(*) FROM locations WHERE metadata->>'demo_seed'='true' \
   GROUP BY city, country HAVING count(*)>=2 ORDER BY city;"
```

Expected: `16` venues; org/system split exactly `Corebrew Coffee 8, Demo Retail Group 0, Meridian Screens 12, Northline Apparel 12, Vantage Motors 13` (the 38 pre-existing systems REASSIGNED + 7 new); `4` relationship rows; same-city rows for `Dubai/AE`, `London/GB`, `New York/US`. Re-apply the seed once more and re-run all four queries — identical output (idempotency, live).

- [ ] **6.4 Map shows the org field + the clustering-ready fleet:**

```bash
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
vs = d['venues']
print('venues:', len(vs))
assert all('org' in v and 'last_run_created_at' in v['rollup'] for v in vs)
names = sorted({v['org']['name'] for v in vs if v['org']})
print('org names:', names)
demo_store = next(v for v in vs if v['name'] == 'Demo Store')
print('Demo Store org:', demo_store['org'])
"
```

Expected: `venues: 17` (16 seeded + Demo Store); every venue has both new keys; org names = the 4 retailers **plus `Demo Org`** — the real venue surfacing its real org is CORRECT behavior (Contract note; Plan D's chip legend tolerates single-venue orgs).

- [ ] **6.5 Run the generator, verify pulses + org integrity:**

```bash
cd /Users/jn/code/mras-ops && python3 -m scripts.demo_traffic --rate 12 --duration 60
sleep 8   # projector settle (2s) + poll (1s) + slack
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
tot = lambda k: sum(v['rollup'][k] for v in d['venues'])
assert tot('runs_last_hour') > 0, 'generator pulses did not reach the rollup'
lr = [v['rollup']['last_run_created_at'] for v in d['venues'] if v['rollup']['last_run_created_at']]
assert lr, 'no last_run_created_at anywhere'
print('runs_last_hour:', tot('runs_last_hour'), '| venues with last_run:', len(lr))
"
docker exec mras-ops-postgres-1 psql -U mras -d mras -c \
  "SELECT count(*) AS skips FROM audit_logs WHERE action IN ('projector.skip','projector.resolve_miss') AND created_at > now() - interval '10 minutes';" -c \
  "SELECT count(*) AS org_mismatch FROM events e JOIN systems s ON s.id = e.system_id WHERE e.organization_id <> s.organization_id;" -c \
  "SELECT count(*) AS umbrella_runs FROM ad_runs WHERE organization_id='dea00000-0000-4000-8000-000000000001';" -c \
  "SELECT count(*) AS retailer_runs FROM ad_runs WHERE organization_id::text LIKE 'dea00000-%';"
```

Expected: generator prints emissions across retailer venues and exits cleanly; `runs_last_hour > 0`; **`skips = 0`** (any skip = payload drift — investigate `audit_logs.after` before proceeding); **`org_mismatch = 0`** (insert-time org == back-stamped org — recon 7's invariant held live); `umbrella_runs = 0` and `retailer_runs > 0` (all activity attributed to retailers).

- [ ] **6.6 `last_run_created_at` advances (Lane 3's delta signal, observed live):**

```bash
LR_BEFORE=$(python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
print(max(v['rollup']['last_run_created_at'] or '' for v in d['venues']))
")
cd /Users/jn/code/mras-ops && python3 -m scripts.demo_traffic --rate 20 --duration 20
sleep 8
LR_BEFORE="$LR_BEFORE" python3 -c "
import json, os, urllib.request
before = os.environ['LR_BEFORE'].strip()
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
after = max(v['rollup']['last_run_created_at'] or '' for v in d['venues'])
assert after > before, f'did not advance: {before} -> {after}'
print('advanced:', before, '->', after)
"
```

Expected: `advanced: … -> …` (strictly greater ISO timestamp).

- [ ] **6.7 Panel `display_id` live:**

```bash
python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('http://localhost:8080/god-view/map'))
loc = next(v['location_id'] for v in d['venues'] if v['rollup']['runs_last_hour'] > 0)
p = json.load(urllib.request.urlopen(f'http://localhost:8080/god-view/map/locations/{loc}'))
runs = p['ad_runs']
assert all('display_id' in r for r in runs), 'display_id key missing'
assert any(r['display_id'] for r in runs), 'no run reached the playback lane?'
print('ad_runs:', len(runs), '| with display_id:', sum(1 for r in runs if r['display_id']))
"
```

Expected: key present on every row; ≥1 non-null (failure-path runs are legitimately null).

- [ ] **6.8 Teardown to zero across the whole family + guard proof:**

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/teardown_demo_fleet.sql
python3 -m scripts.demo_traffic --duration 5; echo "exit=$?"
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "
SELECT 'organizations' AS t, count(*) FROM organizations WHERE id::text LIKE 'dea00000-%'
UNION ALL SELECT 'organization_relationships', count(*) FROM organization_relationships
UNION ALL SELECT 'locations', count(*) FROM locations WHERE metadata->>'demo_seed'='true'
UNION ALL SELECT 'location_participants', count(*) FROM location_participants WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'systems', count(*) FROM systems WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'cameras', count(*) FROM cameras WHERE screen_id LIKE 'demo-cam-%'
UNION ALL SELECT 'displays', count(*) FROM displays WHERE screen_id LIKE 'demo-disp-%'
UNION ALL SELECT 'screen_groups', count(*) FROM screen_groups WHERE metadata->>'demo_seed'='true'
UNION ALL SELECT 'ad_runs', count(*) FROM ad_runs WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'composition_runs', count(*) FROM composition_runs WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'playbacks', count(*) FROM playbacks WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'events', count(*) FROM events WHERE organization_id::text LIKE 'dea00000-%'
UNION ALL SELECT 'events_payload_tag', count(*) FROM events WHERE payload->>'demo_seed'='true';" -c \
  "SELECT name, lat, lng FROM locations WHERE id='acc4e851-ab7a-4b59-989e-85cb8b597e14';" -c \
  "SELECT cursor FROM projector_state WHERE id=1;"
```

Expected: generator prints the umbrella-absent message and `exit=1`; **every count = 0** (the `dea00000-%` prefix sweeps the whole family — a non-zero anywhere means a predicate escaped the SET conversion); Demo Store still has its lat/lng (leave-as-is); the cursor is ≥ the 6.2 value and was never reset (it advanced only by normal folding during the drill).

- [ ] **6.9 Re-seed for Plan D** (its live Playwright E2E needs the split fleet present — spec §6 lane order):

```bash
cd /Users/jn/code/mras-ops && docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql
```

- [ ] **6.10 Close out the branch:** self-review the diff (scoped to this plan only — the two seed files, `scripts/demo_traffic.py`, `api/src/godview/map.py`, and the three test files), request code review per `superpowers:requesting-code-review`, then have git-flow-manager push and open the PR titled `God View Globe Plan C: seed v2 retailer split, teardown/generator org-SET, /god-view/map additive org fields` (structured description: Summary / Motivation / Implementation / Tests / Risks; state that the merge must be a **merge commit** to preserve the red→green pairs, that the PR closes mras-ops #55, and quote the Contract section verbatim for Plan D). After merge: update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry with `repo@sha`; note the live dev DB now carries seed v2 and the api image needs a rebuild wherever it is redeployed) and `/Users/jn/code/minority_report_architecture/TODOS.md` if tracked; file any deferred items as GitHub issues.

---

## Self-review (performed before finalizing this plan)

- **Spec coverage (amended §3 Lane 1):** retailer orgs `…0002`–`…0005` as `'host'` with `organization_relationships` links → Task 1 (enum reality respected — recon 1); **explicit idempotent reassignment UPDATE** (the CRITICAL amendment) → Task 1.4 + the dedicated `test_seed_v2_reassigns_systems_from_v1_umbrella_state` + drilled on the real v1-seeded DB in 6.3; same-city venues closing #55 with byte-matched `city|country` keys → Task 1 + `test_seed_same_city_venue_pairs` + 6.3; teardown SET over **all 28 enumerated predicates** with relationships-before-orgs and retailers-before-umbrella → Task 2 (inventory table + full file); generator `ANY(set)` targets, per-target org stamping (back-stamp identity — recon 7), umbrella-sentinel recheck, hard-scope/hard-exit preserved → Task 3; additive `org` (dominant, deterministic tie-break, name joined, nullable-by-type) + `last_run_created_at` (unwindowed max in the `act` CTE) + panel `display_id` → Tasks 4–5 + the Contract section; live drill mirroring Plan A's Task 6 with the new assertions (org per venue incl. Demo Store's real org, `last_run_created_at` advancing, `display_id` present, 0 skips, org-mismatch 0, zero rows post-teardown, cursor + Demo Store lat/lng intact) → Task 6.
- **Deliberate choices (flagged, not drifts):** (a) `location_participants` stay on the umbrella — nothing reads them for org identity, one shape keeps fresh/live DBs convergent, teardown SET covers them either way. (b) Retailer rows also set `parent_organization_id` — the spec's teardown amendment explicitly anticipates it ("if parent_organization_id is set") and it makes Task 2's red a real observed FK violation rather than a hypothetical. (c) `last_run_created_at` is unwindowed by design (monotone delta signal — spec §3/§5). (d) The org `null` branch is coded but unreachable today (recon 3) — typed nullable per spec.
- **Cross-file red discipline:** Task 1 knowingly reds `test_demo_teardown.py` (documented in 1.5); Task 2's red captures it and 2.5 runs both files to green. No other cross-file effects: map tests are self-contained (Tasks 4–5 additive), generator tests are AsyncMock-only.
- **Name/type consistency:** the uuid family and the four retailer names are identical across seed, teardown, generator constants, all three test files, and the drill SQL (`dea00000-%` prefix sweeps in 6.8 deliberately match the family). System-count arithmetic checked: v1 13 venues = 38 systems; +hudson(2)+battersea(2)+emirates(3) = 45; per retailer northline 4+4+2+2=12, vantage 3+3+2+5=13, corebrew 2+2+2+2=8, meridian 3+4+2+3=12 — sums to 45 and matches 6.3's expected output.
- **Placeholder scan:** no TBDs; every SQL/Python/test block is complete. The Demo Store coordinates remain the v1 SF placeholder (owner-adjustable, unchanged by this plan).
