# God View Schema (Lane A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 6-table Phase-0 schema with the clean-slate God View / MRAS SaaS data model (21+ tables) as an ordered SQL migration set in `mras-ops`, verified by schema-assertion tests.

**Architecture:** Clean-slate rebuild authorized while pre-alpha (all data is disposable test data). The migration set lives in `/Users/jn/code/mras-ops/db/migrations/` and is applied by Postgres `docker-entrypoint-initdb.d` on a fresh volume. Tests apply the same SQL into a throwaway database (`mras_schema_test`) via `asyncpg` and assert tables, enums, scope columns, foreign keys, and idempotency keys. Mutable summary tables are written later by a projector (separate plan); this Lane only delivers their target schema + idempotency constraints.

**Tech Stack:** Postgres 16 (`postgres:16-alpine`), `pgcrypto`, `asyncpg`, `pytest` (`asyncio_mode=auto`).

## Global Constraints

- Postgres **16**; extension **pgcrypto** (`gen_random_uuid()`).
- Every new table PK is `id uuid PRIMARY KEY DEFAULT gen_random_uuid()` **except** `events` (`id bigserial` — projector cursor; Decision 8).
- Timestamps `timestamptz`; `created_at NOT NULL DEFAULT now()`; `updated_at` where the row mutates.
- Shared enum types via `CREATE TYPE`; never inline-repeat a value set (DRY fold).
- Scope columns nullable `uuid` with `REFERENCES` where the parent exists, on `events` and every summary table (Decision 2).
- RBAC: **no** `users/roles/permissions`; one `user_org_scopes` table (Decision 1).
- `subject_profiles` is the only people table; no `identities` (Decision 4).
- Idempotency: `ad_runs` UNIQUE(`trigger_id`); `playbacks` UNIQUE(`trigger_id`,`display_id`) (Decision 3).
- `cameras`/`displays` carry `screen_id text` (runtime-string bridge; Decision 10).
- `subject_embeddings.embedding_type` enum = `face` only (drop speculative values; fold).
- Privacy machinery NOT built (Decision 9 accepted risk); `subject_profile_merges` IS built.
- **Git is delegated to the `git-flow-manager` subagent** (repo rule); commit steps below describe intent — the executor routes them through that subagent on branch `feat/godview-schema-lane-a`.

**Prerequisite:** the dockerized Postgres must be running (`cd /Users/jn/code/mras-ops && docker compose up -d postgres`). The default maintenance database `postgres` is used to create/drop the throwaway test DB.

---

## File Structure

- Create: `db/migrations/010_enums.sql` — extension + shared enum types.
- Create: `db/migrations/011_accounts.sql` — `organizations`, `organization_relationships`, `user_org_scopes`.
- Create: `db/migrations/012_physical.sql` — `locations`, `location_participants`, `systems`, `devices`, `cameras`, `displays`, `device_health_events`, `system_health_events`.
- Create: `db/migrations/013_people.sql` — `subject_profiles`, `identity_enrollments`, `subject_embeddings`, `subject_observations`, `identity_matches`, `observation_tracks`, `subject_profile_merges`, `blocklist_entries`.
- Create: `db/migrations/014_creative.sql` — `media_assets`, `campaigns`, `campaign_rules`, `components`, `ads`, `ad_creatives`, `creative_approvals`.
- Create: `db/migrations/015_runs.sql` — `personalization_decisions`, `composition_runs`, `ad_runs`, `playbacks`, `viewer_exposures`, `model_runs`.
- Create: `db/migrations/016_events_audit.sql` — `events` (bigserial + scope), `audit_logs`.
- Create: `db/migrations/017_indexes.sql` — live-feed/drilldown indexes.
- Delete: `db/migrations/001_initial.sql`, `002_custom_components.sql`, `003_identity_embeddings.sql` (replaced — clean slate).
- Create: `api/tests/test_schema_godview.py` — schema-assertion tests + DB fixture.

> Migration files are numbered `010+` so an operator can see the old set was retired, and `ls` order = apply order. On a fresh volume Postgres runs them alphabetically; the deletions ensure the old shells don't also run.

---

### Task 1: Test harness + enum types

**Files:**
- Create: `api/tests/test_schema_godview.py`
- Create: `db/migrations/010_enums.sql`
- Delete: `db/migrations/001_initial.sql`, `db/migrations/002_custom_components.sql`, `db/migrations/003_identity_embeddings.sql`

**Interfaces:**
- Produces: a pytest fixture `schema_db` (module-scoped `asyncpg.Connection` to a freshly-built `mras_schema_test` DB with all `db/migrations/*.sql` applied in filename order). Every later task adds assertions against this same fixture.

- [ ] **Step 1: Write the failing test (harness + enum assertions)**

Create `api/tests/test_schema_godview.py`:

```python
"""God View clean-slate schema assertions.

Applies every db/migrations/*.sql into a throwaway database and asserts the
schema matches docs/superpowers/specs/2026-06-30-godview-schema-lane-a-design.md.

Requires the dockerized Postgres running:
    cd /Users/jn/code/mras-ops && docker compose up -d postgres
"""
import glob
import os
import pathlib

import asyncpg
import pytest

MIGRATIONS = sorted(
    glob.glob(str(pathlib.Path(__file__).resolve().parents[2] / "db" / "migrations" / "*.sql"))
)
ADMIN_DSN = os.environ.get("ADMIN_DATABASE_URL", "postgresql://mras:mras@localhost:5432/postgres")
TEST_DB = "mras_schema_test"
TEST_DSN = "postgresql://mras:mras@localhost:5432/" + TEST_DB


@pytest.fixture(scope="module")
async def schema_db():
    admin = await asyncpg.connect(ADMIN_DSN)
    await admin.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
    await admin.execute(f"CREATE DATABASE {TEST_DB}")
    await admin.close()

    conn = await asyncpg.connect(TEST_DSN)
    for path in MIGRATIONS:
        sql = pathlib.Path(path).read_text()
        await conn.execute(sql)
    yield conn
    await conn.close()

    admin = await asyncpg.connect(ADMIN_DSN)
    await admin.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
    await admin.close()


async def _enum_values(conn, type_name):
    rows = await conn.fetch(
        "SELECT e.enumlabel FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid "
        "WHERE t.typname = $1 ORDER BY e.enumsortorder",
        type_name,
    )
    return [r["enumlabel"] for r in rows]


async def test_shared_enums_exist(schema_db):
    assert await _enum_values(schema_db, "ad_run_status") == [
        "planned", "composing", "ready", "dispatched", "playing", "completed", "failed", "canceled",
    ]
    assert await _enum_values(schema_db, "playback_status") == [
        "dispatched", "started", "ended", "failed", "interrupted", "unknown",
    ]
    assert "active" in await _enum_values(schema_db, "embedding_status")
    assert await _enum_values(schema_db, "embedding_type") == ["face"]


async def test_role_label_enum_has_eight_canonical_roles(schema_db):
    roles = await _enum_values(schema_db, "role_label")
    assert "Operator.SeniorSystemAdmin" in roles
    assert "AgencyOfRecord.Standard" in roles
    assert len(roles) == 8
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && docker compose up -d postgres && python -m pytest api/tests/test_schema_godview.py -v`
Expected: FAIL — the old migrations still define `identities` etc. and none of the new enum types exist, so `test_shared_enums_exist` errors/asserts false.

- [ ] **Step 3: Delete the old migrations and create `010_enums.sql`**

Delete `db/migrations/001_initial.sql`, `db/migrations/002_custom_components.sql`, `db/migrations/003_identity_embeddings.sql`.

Create `db/migrations/010_enums.sql`:

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TYPE device_status      AS ENUM ('active','degraded','offline','retired');
CREATE TYPE lifecycle_status   AS ENUM ('planned','active','inactive','degraded','offline','retired');
CREATE TYPE embedding_status   AS ENUM ('pending','active','rejected','expired','deleted');
CREATE TYPE embedding_type     AS ENUM ('face');
CREATE TYPE profile_status     AS ENUM ('anonymous','known','merged','blocklisted','deleted');
CREATE TYPE role_label         AS ENUM (
  'Customer.OptInIdentified','Customer.Anonymous','Customer.Blocklisted',
  'Host.IT','Advertiser.ReadOnly','AgencyOfRecord.Standard',
  'Operator.SystemAdmin','Operator.SeniorSystemAdmin');
CREATE TYPE organization_type  AS ENUM ('platform_operator','host','advertiser','agency_of_record','partner','vendor');
CREATE TYPE decision_type      AS ENUM ('identity','demographic','contextual','scheduled','manual','fallback','blocked_suppressed','error_recovery');
CREATE TYPE ad_run_status      AS ENUM ('planned','composing','ready','dispatched','playing','completed','failed','canceled');
CREATE TYPE playback_status    AS ENUM ('dispatched','started','ended','failed','interrupted','unknown');
CREATE TYPE composition_status AS ENUM ('queued','selected','rendering','rendered','failed','canceled');
CREATE TYPE exposure_role      AS ENUM ('target','viewer','bystander','possible_viewer');
CREATE TYPE identity_status    AS ENUM ('known','anonymous','unmatched','suppressed');
CREATE TYPE match_status       AS ENUM ('matched','no_match','below_threshold','suppressed','blocked');
CREATE TYPE blocklist_type     AS ENUM ('biometric_opt_out','personalization_opt_out','legal_hold','manual_suppression','safety');
CREATE TYPE scope_level        AS ENUM ('global','organization','location','system');
CREATE TYPE asset_type         AS ENUM ('image','frame','clip','video','audio','thumbnail','composite','model_artifact');
CREATE TYPE device_type        AS ENUM ('camera','display','edge_node','player','sensor');
CREATE TYPE camera_role        AS ENUM ('detection','enrollment','audience_measurement','security_context');
CREATE TYPE display_role       AS ENUM ('primary_ad','secondary_ad','ambient','status');
CREATE TYPE location_type      AS ENUM ('country','region','city','district','campus','building','mall','airport','venue','store','floor','zone','area');
CREATE TYPE system_type        AS ENUM ('onsite_mras','demo','lab','kiosk_cluster','edge_node');
CREATE TYPE participant_role   AS ENUM ('host','tenant','operator','advertiser','agency','maintenance_partner','reporting_viewer');
CREATE TYPE enrollment_scope   AS ENUM ('global','organization','location','system');
CREATE TYPE enrollment_source  AS ENUM ('manual_upload','crm_import','loyalty_import','admin_created','camera_enroll','camera_match');
CREATE TYPE render_mode        AS ENUM ('prebuilt','template_overlay','remotion','ffmpeg','genai_video','fallback');
CREATE TYPE personalization_type AS ENUM ('none','demographic','contextual','identity','name','likeness','hybrid','fallback','suppressed');
CREATE TYPE model_run_type     AS ENUM ('recognition','demographic_estimation','mood_detection','gaze_detection','ad_decision','video_generation','voice_generation','object_detection','composition');
CREATE TYPE actor_type         AS ENUM ('user','system','model','api');
CREATE TYPE detection_type     AS ENUM ('face','body','eyes','group','demographic','object');
CREATE TYPE observation_match  AS ENUM ('no_match','matched_known','matched_anonymous','new_anonymous','suppressed','ignored');
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_shared_enums_exist api/tests/test_schema_godview.py::test_role_label_enum_has_eight_canonical_roles -v`
Expected: PASS (2 passed). Other tests in the file don't exist yet.

- [ ] **Step 5: Commit**

```bash
git add api/tests/test_schema_godview.py db/migrations/010_enums.sql
git rm db/migrations/001_initial.sql db/migrations/002_custom_components.sql db/migrations/003_identity_embeddings.sql
git commit -m "feat(db): clean-slate schema — shared enum types + retire Phase-0 migrations"
```

---

### Task 2: Account/access tables

**Files:**
- Create: `db/migrations/011_accounts.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_account_tables`)

**Interfaces:**
- Consumes: enum types from Task 1 (`organization_type`, `role_label`).
- Produces: `organizations(id)`, `user_org_scopes(user_id, organization_id, role)` referenced by later scope columns and RBAC.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_schema_godview.py`:

```python
async def _table_exists(conn, name):
    return await conn.fetchval(
        "SELECT to_regclass($1) IS NOT NULL", "public." + name
    )


async def _column_type(conn, table, column):
    return await conn.fetchval(
        "SELECT data_type FROM information_schema.columns "
        "WHERE table_name = $1 AND column_name = $2",
        table, column,
    )


async def test_account_tables(schema_db):
    for t in ("organizations", "organization_relationships", "user_org_scopes"):
        assert await _table_exists(schema_db, t), f"missing {t}"
    # RBAC collapsed to a thin scope map — no relational RBAC tables (Decision 1)
    for absent in ("users", "roles", "permissions", "user_memberships"):
        assert not await _table_exists(schema_db, absent), f"{absent} must not exist"
    assert await _column_type(schema_db, "user_org_scopes", "user_id") == "uuid"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_account_tables -v`
Expected: FAIL — `organizations` does not exist.

- [ ] **Step 3: Create `011_accounts.sql`**

```sql
CREATE TABLE organizations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    organization_type organization_type NOT NULL,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    parent_organization_id uuid REFERENCES organizations(id),
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organization_relationships (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    from_organization_id uuid NOT NULL REFERENCES organizations(id),
    to_organization_id   uuid NOT NULL REFERENCES organizations(id),
    relationship text NOT NULL,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Decision 1: Supabase Auth owns users + JWT role claims; Postgres holds only a
-- thin scope map for row-level filtering. user_id is the Supabase auth subject.
CREATE TABLE user_org_scopes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL,
    organization_id uuid NOT NULL REFERENCES organizations(id),
    location_id     uuid,
    role            role_label NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, organization_id, role)
);
CREATE INDEX user_org_scopes_user_idx ON user_org_scopes (user_id);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_account_tables -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/011_accounts.sql api/tests/test_schema_godview.py
git commit -m "feat(db): account/access tables (organizations, thin user_org_scopes RBAC)"
```

---

### Task 3: Physical deployment tables

**Files:**
- Create: `db/migrations/012_physical.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_physical_tables`)

**Interfaces:**
- Consumes: `organizations(id)` (Task 2); enums `location_type`, `system_type`, `device_type`, `camera_role`, `display_role`, `participant_role`, `lifecycle_status`, `device_status`.
- Produces: `locations(id)`, `systems(id)`, `cameras(id)`, `displays(id)` — the scope targets every later table FKs to. `cameras.screen_id`/`displays.screen_id` are the runtime-string bridge.

- [ ] **Step 1: Write the failing test**

Append:

```python
async def test_physical_tables(schema_db):
    for t in ("locations", "location_participants", "systems", "devices",
              "cameras", "displays", "device_health_events", "system_health_events"):
        assert await _table_exists(schema_db, t), f"missing {t}"
    # Decision 10: runtime-string bridge lives on the device rows
    assert await _column_type(schema_db, "cameras", "screen_id") == "text"
    assert await _column_type(schema_db, "displays", "screen_id") == "text"
    # self-referential location hierarchy
    assert await _column_type(schema_db, "locations", "parent_location_id") == "uuid"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_physical_tables -v`
Expected: FAIL — `locations` does not exist.

- [ ] **Step 3: Create `012_physical.sql`**

```sql
CREATE TABLE locations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_location_id uuid REFERENCES locations(id),
    name        text NOT NULL,
    location_type location_type NOT NULL,
    country text, region text, state text, city text, address text,
    lat numeric, lng numeric, timezone text,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX locations_parent_idx ON locations (parent_location_id);

CREATE TABLE location_participants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    location_id uuid NOT NULL REFERENCES locations(id),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    role        participant_role NOT NULL,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    starts_at timestamptz, ends_at timestamptz,
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE systems (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    location_id uuid NOT NULL REFERENCES locations(id),
    name        text NOT NULL,
    system_type system_type NOT NULL DEFAULT 'onsite_mras',
    zone text, floor text, lat numeric, lng numeric, timezone text,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    config      jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX systems_location_idx ON systems (location_id);

CREATE TABLE devices (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    system_id   uuid NOT NULL REFERENCES systems(id),
    location_id uuid REFERENCES locations(id),
    device_type device_type NOT NULL,
    name        text NOT NULL,
    external_device_key text, serial_number text,
    status      device_status NOT NULL DEFAULT 'active',
    last_seen_at timestamptz, lat numeric, lng numeric, zone text, floor text,
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE cameras (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id   uuid REFERENCES devices(id),
    system_id   uuid NOT NULL REFERENCES systems(id),
    location_id uuid REFERENCES locations(id),
    name        text,
    camera_role camera_role NOT NULL DEFAULT 'detection',
    stream_url  text,
    screen_id   text,            -- runtime string the vision service emits (e.g. 'screen_0')
    status      device_status NOT NULL DEFAULT 'active',
    last_seen_at timestamptz, calibration jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cameras_screen_id_idx ON cameras (screen_id);

CREATE TABLE displays (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id   uuid REFERENCES devices(id),
    system_id   uuid NOT NULL REFERENCES systems(id),
    location_id uuid REFERENCES locations(id),
    name        text,
    screen_id   text NOT NULL,   -- runtime string the kiosk emits (e.g. 'display-2')
    display_role display_role NOT NULL DEFAULT 'primary_ad',
    resolution_width int, resolution_height int,
    status      device_status NOT NULL DEFAULT 'active',
    last_seen_at timestamptz, calibration jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX displays_screen_id_idx ON displays (screen_id);

CREATE TABLE device_health_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id   uuid NOT NULL REFERENCES devices(id),
    status      device_status NOT NULL,
    detail      jsonb NOT NULL DEFAULT '{}',
    observed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX device_health_device_idx ON device_health_events (device_id, observed_at DESC);

CREATE TABLE system_health_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    system_id   uuid NOT NULL REFERENCES systems(id),
    status      lifecycle_status NOT NULL,
    detail      jsonb NOT NULL DEFAULT '{}',
    observed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX system_health_system_idx ON system_health_events (system_id, observed_at DESC);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_physical_tables -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/012_physical.sql api/tests/test_schema_godview.py
git commit -m "feat(db): physical deployment tables (locations/systems/devices/cameras/displays + health)"
```

---

### Task 4: People / identity tables

**Files:**
- Create: `db/migrations/013_people.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_people_tables`)

**Interfaces:**
- Consumes: `organizations(id)`, `locations(id)`, `systems(id)`, `cameras(id)` (Tasks 2-3); enums `profile_status`, `embedding_status`, `embedding_type`, `match_status`, `blocklist_type`, `scope_level`, `enrollment_scope`, `enrollment_source`, `detection_type`, `observation_match`.
- Produces: `subject_profiles(id)` (single people keyspace), `subject_embeddings(status)` (reconciler target), `subject_observations(id)`, `observation_tracks(id)` referenced by runs/exposures.

> `media_assets` is referenced by `subject_profiles.primary_photo_asset_id` and others but is created in Task 5. To avoid an ordering cycle, photo/asset FKs in this task are plain `uuid` columns **without** a `REFERENCES` clause; Task 5 adds the FK via `ALTER TABLE`. This keeps each migration independently appliable in filename order.

- [ ] **Step 1: Write the failing test**

Append:

```python
async def _has_unique(conn, table, cols):
    rows = await conn.fetch(
        """
        SELECT array_agg(a.attname ORDER BY a.attnum) AS cols
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN unnest(c.conkey) AS k(attnum) ON true
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE t.relname = $1 AND c.contype = 'u'
        GROUP BY c.oid
        """,
        table,
    )
    return [sorted(r["cols"]) for r in rows]


async def test_people_tables(schema_db):
    for t in ("subject_profiles", "identity_enrollments", "subject_embeddings",
              "subject_observations", "identity_matches", "observation_tracks",
              "subject_profile_merges", "blocklist_entries"):
        assert await _table_exists(schema_db, t), f"missing {t}"
    # Decision 4: no legacy identity tables
    for absent in ("identities", "identity_embeddings"):
        assert not await _table_exists(schema_db, absent), f"{absent} must not exist"
    # Decision 5: embedding lifecycle gate for the reconciler
    assert await _column_type(schema_db, "subject_embeddings", "qdrant_point_id") == "text"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_people_tables -v`
Expected: FAIL — `subject_profiles` does not exist.

- [ ] **Step 3: Create `013_people.sql`**

```sql
CREATE TABLE subject_profiles (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid REFERENCES organizations(id),
    global_subject_key text,
    status      profile_status NOT NULL DEFAULT 'anonymous',
    display_name text, first_name text, last_name text,
    external_customer_id text,
    primary_photo_asset_id uuid,            -- FK added in 014 (media_assets)
    first_seen_at timestamptz, last_seen_at timestamptz,
    created_from_observation_id uuid,
    confidence_level text,
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE identity_enrollments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_profile_id uuid NOT NULL REFERENCES subject_profiles(id),
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    enrollment_scope enrollment_scope NOT NULL DEFAULT 'system',
    source      enrollment_source NOT NULL,
    external_person_id text,
    consent_status text,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE observation_tracks (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    system_id   uuid REFERENCES systems(id),
    camera_id   uuid REFERENCES cameras(id),
    subject_profile_id uuid REFERENCES subject_profiles(id),
    camera_track_id text,
    started_at timestamptz, ended_at timestamptz,
    max_identity_confidence numeric, track_confidence numeric,
    observation_count int NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE subject_observations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    bigint,                     -- FK added in 016 (events)
    trigger_id  uuid,
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    camera_id   uuid REFERENCES cameras(id),
    observation_track_id uuid REFERENCES observation_tracks(id),
    frame_asset_id uuid,                    -- FK added in 014
    clip_asset_id  uuid,                    -- FK added in 014
    observed_at timestamptz NOT NULL,
    detection_type detection_type NOT NULL,
    subject_profile_id uuid REFERENCES subject_profiles(id),
    camera_track_id text,
    bounding_box jsonb, face_quality_score numeric, identity_confidence numeric,
    demographic_snapshot jsonb, mood_snapshot jsonb, attention_snapshot jsonb,
    match_status observation_match NOT NULL DEFAULT 'no_match',
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id)
);
CREATE INDEX subject_observations_track_idx ON subject_observations (observation_track_id);

CREATE TABLE subject_embeddings (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_profile_id uuid NOT NULL REFERENCES subject_profiles(id),
    identity_enrollment_id uuid REFERENCES identity_enrollments(id),
    qdrant_collection text NOT NULL,
    qdrant_point_id   text NOT NULL,
    embedding_type embedding_type NOT NULL DEFAULT 'face',
    source      text NOT NULL,
    source_asset_id uuid,                   -- FK added in 014
    source_observation_id uuid REFERENCES subject_observations(id),
    quality_score numeric, model_name text, model_version text,
    status      embedding_status NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz
);
CREATE INDEX subject_embeddings_active_idx ON subject_embeddings (subject_profile_id) WHERE status = 'active';

CREATE TABLE identity_matches (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_observation_id uuid NOT NULL REFERENCES subject_observations(id),
    candidate_subject_profile_id uuid REFERENCES subject_profiles(id),
    candidate_embedding_id uuid REFERENCES subject_embeddings(id),
    match_status match_status NOT NULL,
    confidence numeric, threshold numeric,
    model_name text, model_version text, qdrant_score numeric, rank int,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE subject_profile_merges (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    from_subject_profile_id uuid NOT NULL REFERENCES subject_profiles(id),
    to_subject_profile_id   uuid NOT NULL REFERENCES subject_profiles(id),
    merge_reason text NOT NULL,
    confidence numeric,
    merged_by_user_id uuid,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE blocklist_entries (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_profile_id uuid REFERENCES subject_profiles(id),
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    scope       scope_level NOT NULL DEFAULT 'global',
    blocklist_type blocklist_type NOT NULL,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    reason      text,
    created_by_user_id uuid,
    starts_at timestamptz NOT NULL DEFAULT now(), ends_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_people_tables -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/013_people.sql api/tests/test_schema_godview.py
git commit -m "feat(db): people/identity tables (subject_profiles single keyspace, embeddings, observations, merges, blocklist)"
```

---

### Task 5: Creative tables + deferred asset FKs

**Files:**
- Create: `db/migrations/014_creative.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_creative_tables`)

**Interfaces:**
- Consumes: `organizations(id)`, `subject_profiles`, `subject_observations`, `subject_embeddings` (for the deferred `ALTER TABLE ... ADD FOREIGN KEY`).
- Produces: `media_assets(id)`, `campaigns(id)`, `ads(id)`, `components(id)` referenced by the runs tables (Task 6).

- [ ] **Step 1: Write the failing test**

Append:

```python
async def _fk_target(conn, table, column):
    return await conn.fetchval(
        """
        SELECT ccu.table_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name
        JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = $1 AND kcu.column_name = $2
        LIMIT 1
        """,
        table, column,
    )


async def test_creative_tables(schema_db):
    for t in ("media_assets", "campaigns", "campaign_rules", "components",
              "ads", "ad_creatives", "creative_approvals"):
        assert await _table_exists(schema_db, t), f"missing {t}"
    # old serial-id campaigns shell must be gone (Decision 6) — new one is uuid
    assert await _column_type(schema_db, "campaigns", "id") == "uuid"
    # deferred asset FK now resolved
    assert await _fk_target(schema_db, "subject_profiles", "primary_photo_asset_id") == "media_assets"
    assert await _fk_target(schema_db, "subject_embeddings", "source_asset_id") == "media_assets"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_creative_tables -v`
Expected: FAIL — `media_assets` does not exist.

- [ ] **Step 3: Create `014_creative.sql`**

```sql
CREATE TABLE media_assets (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid REFERENCES organizations(id),
    asset_type  asset_type NOT NULL,
    storage_url text NOT NULL,
    mime_type text, duration_ms int, width int, height int,
    source      text NOT NULL,
    sha256_hash text,
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE campaigns (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid REFERENCES organizations(id),
    name        text NOT NULL,
    status      lifecycle_status NOT NULL DEFAULT 'active',
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE campaign_rules (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id uuid NOT NULL REFERENCES campaigns(id),
    rule        jsonb NOT NULL DEFAULT '{}',
    priority    int NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- components/ads keep their shipped shape (002_custom_components.sql), now uuid-consistent + FKs into the creative model.
CREATE TABLE components (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL, slug text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'bundling' CHECK (status IN ('bundling','ready','failed')),
    error text, props_schema jsonb, created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL, base_video text NOT NULL,
    component_id uuid NOT NULL REFERENCES components(id),
    campaign_id uuid REFERENCES campaigns(id),
    default_props jsonb NOT NULL DEFAULT '{}'::jsonb,
    personalized_field text NOT NULL DEFAULT 'text',
    is_active boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ads_is_active_idx ON ads (is_active);

CREATE TABLE ad_creatives (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ad_id       uuid NOT NULL REFERENCES ads(id),
    media_asset_id uuid REFERENCES media_assets(id),
    variant     text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE creative_approvals (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ad_id       uuid NOT NULL REFERENCES ads(id),
    status      text NOT NULL DEFAULT 'pending',
    reviewed_by_user_id uuid,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Resolve the deferred asset FKs from 013 (media_assets did not exist yet).
ALTER TABLE subject_profiles
    ADD CONSTRAINT subject_profiles_photo_fk
    FOREIGN KEY (primary_photo_asset_id) REFERENCES media_assets(id);
ALTER TABLE subject_observations
    ADD CONSTRAINT subject_observations_frame_fk
    FOREIGN KEY (frame_asset_id) REFERENCES media_assets(id);
ALTER TABLE subject_observations
    ADD CONSTRAINT subject_observations_clip_fk
    FOREIGN KEY (clip_asset_id) REFERENCES media_assets(id);
ALTER TABLE subject_embeddings
    ADD CONSTRAINT subject_embeddings_asset_fk
    FOREIGN KEY (source_asset_id) REFERENCES media_assets(id);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_creative_tables -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/014_creative.sql api/tests/test_schema_godview.py
git commit -m "feat(db): creative tables (media_assets, fresh uuid campaigns, ads/components + deferred asset FKs)"
```

---

### Task 6: Decision / run / playback tables + idempotency keys

**Files:**
- Create: `db/migrations/015_runs.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_runs_tables`, `test_idempotency_keys`)

**Interfaces:**
- Consumes: `organizations`, `locations`, `systems`, `displays`, `campaigns`, `ads`, `components`, `media_assets`, `subject_profiles`, `subject_observations`, `observation_tracks`; enums `decision_type`, `composition_status`, `ad_run_status`, `playback_status`, `exposure_role`, `identity_status`, `personalization_type`, `render_mode`, `model_run_type`.
- Produces: `ad_runs(id)`, `playbacks(id)`, `viewer_exposures(id)` — the projector's write targets, with the idempotency keys from Decision 3.

- [ ] **Step 1: Write the failing tests**

Append:

```python
async def test_runs_tables(schema_db):
    for t in ("personalization_decisions", "composition_runs", "ad_runs",
              "playbacks", "viewer_exposures", "model_runs"):
        assert await _table_exists(schema_db, t), f"missing {t}"
    # Decision 12: target watch is a nullable bool; bystanders use probability
    assert await _column_type(schema_db, "ad_runs", "target_watched") == "boolean"
    assert await _column_type(schema_db, "viewer_exposures", "watch_probability") == "numeric"


async def test_idempotency_keys(schema_db):
    # Decision 3: projector replay-safety enforced by unique natural keys
    assert ["trigger_id"] in await _has_unique(schema_db, "ad_runs")
    assert ["display_id", "trigger_id"] in await _has_unique(schema_db, "playbacks")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_runs_tables api/tests/test_schema_godview.py::test_idempotency_keys -v`
Expected: FAIL — `ad_runs` does not exist.

- [ ] **Step 3: Create `015_runs.sql`**

```sql
CREATE TABLE personalization_decisions (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_id  uuid,
    event_id    bigint,                     -- FK added in 016
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    campaign_id uuid REFERENCES campaigns(id),
    selected_ad_id uuid REFERENCES ads(id),
    selected_creative_id uuid REFERENCES ad_creatives(id),
    decision_type decision_type NOT NULL,
    target_subject_profile_id uuid REFERENCES subject_profiles(id),
    target_observation_id uuid REFERENCES subject_observations(id),
    identity_confidence numeric, demographic_confidence numeric, decision_confidence numeric,
    decision_factors jsonb NOT NULL DEFAULT '{}',
    prompt_used text,
    model_run_id uuid,                      -- FK added later in this file
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE model_runs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type    model_run_type NOT NULL,
    provider text, model_name text, model_version text,
    input_asset_id uuid REFERENCES media_assets(id),
    output_asset_id uuid REFERENCES media_assets(id),
    prompt_template_id uuid, prompt_text text, parameters jsonb,
    latency_ms int, cost_estimate numeric,
    status      text NOT NULL DEFAULT 'success',
    error_code text, error_message text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE personalization_decisions
    ADD CONSTRAINT personalization_decisions_model_fk
    FOREIGN KEY (model_run_id) REFERENCES model_runs(id);

CREATE TABLE composition_runs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_id  uuid,
    personalization_decision_id uuid REFERENCES personalization_decisions(id),
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    ad_id       uuid REFERENCES ads(id),
    component_id uuid REFERENCES components(id),
    render_mode render_mode NOT NULL DEFAULT 'prebuilt',
    status      composition_status NOT NULL DEFAULT 'queued',
    input_asset_id  uuid REFERENCES media_assets(id),
    output_asset_id uuid REFERENCES media_assets(id),
    used_spoken_name boolean NOT NULL DEFAULT false,
    used_visible_name boolean NOT NULL DEFAULT false,
    used_likeness boolean NOT NULL DEFAULT false,
    used_voice_clone boolean NOT NULL DEFAULT false,
    render_progress numeric, error_code text, error_message text,
    started_at timestamptz, ended_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ad_runs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_id  uuid,
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    display_id  uuid REFERENCES displays(id),
    campaign_id uuid REFERENCES campaigns(id),
    ad_id       uuid REFERENCES ads(id),
    personalization_decision_id uuid REFERENCES personalization_decisions(id),
    composition_run_id uuid REFERENCES composition_runs(id),
    target_subject_profile_id uuid REFERENCES subject_profiles(id),
    personalization_type personalization_type NOT NULL DEFAULT 'none',
    used_spoken_name boolean NOT NULL DEFAULT false,
    used_visible_name boolean NOT NULL DEFAULT false,
    used_likeness boolean NOT NULL DEFAULT false,
    used_voice_clone boolean NOT NULL DEFAULT false,
    target_watched boolean,                 -- exact via trigger_id (Decision 12)
    target_watch_probability numeric,
    estimated_total_viewers int, estimated_identified_viewers int, estimated_anonymous_viewers int,
    status      ad_run_status NOT NULL DEFAULT 'planned',
    started_at timestamptz, ended_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (trigger_id)                      -- Decision 3: one ad_run per trigger
);

CREATE TABLE playbacks (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ad_run_id   uuid REFERENCES ad_runs(id),
    composition_run_id uuid REFERENCES composition_runs(id),
    trigger_id  uuid,
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    display_id  uuid NOT NULL REFERENCES displays(id),
    media_asset_id uuid REFERENCES media_assets(id),
    screen_id   text,
    status      playback_status NOT NULL DEFAULT 'dispatched',
    dispatched_at timestamptz, started_at timestamptz, ended_at timestamptz,
    duration_ms int, error_code text, error_message text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (trigger_id, display_id)          -- Decision 3: one playback per trigger+display
);

CREATE TABLE viewer_exposures (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ad_run_id   uuid NOT NULL REFERENCES ad_runs(id),
    playback_id uuid REFERENCES playbacks(id),
    subject_profile_id uuid REFERENCES subject_profiles(id),
    subject_observation_id uuid REFERENCES subject_observations(id),
    observation_track_id uuid REFERENCES observation_tracks(id),
    role        exposure_role NOT NULL,
    identity_status identity_status NOT NULL DEFAULT 'unmatched',
    identity_confidence numeric,
    watch_probability numeric,              -- bystanders (Decision 12)
    watched     boolean,                    -- targets only, exact via trigger_id
    gaze_duration_ms int, visible_duration_ms int, attending_fraction numeric,
    distance_estimate_m numeric,
    mood_label text, mood_confidence numeric, expression_label text, expression_confidence numeric,
    demographic_snapshot jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX viewer_exposures_ad_run_idx ON viewer_exposures (ad_run_id);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_runs_tables api/tests/test_schema_godview.py::test_idempotency_keys -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/015_runs.sql api/tests/test_schema_godview.py
git commit -m "feat(db): decision/run/playback/exposure tables + idempotency unique keys"
```

---

### Task 7: `events` (bigserial + scope) + audit_logs + deferred event FKs

**Files:**
- Create: `db/migrations/016_events_audit.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_events_scope`, `test_legacy_absent`)

**Interfaces:**
- Consumes: `locations`, `systems`, `displays`, `cameras`, `subject_profiles`, `ad_runs` (for scope FKs); `subject_observations`/`personalization_decisions` (for the deferred `event_id` FK).
- Produces: `events(id bigserial)` with scope columns — the projector's cursor source and live-feed source.

- [ ] **Step 1: Write the failing tests**

Append:

```python
async def test_events_scope(schema_db):
    assert await _table_exists(schema_db, "events")
    # Decision 8: events keeps an integer cursor, NOT a uuid PK
    assert await _column_type(schema_db, "events", "id") == "bigint"
    # Decision 2: first-class scope columns on the journal
    for col in ("location_id", "system_id", "display_id", "camera_id",
                "subject_profile_id", "ad_run_id"):
        assert await _column_type(schema_db, "events", col) == "uuid", f"events.{col} missing"
    assert await _fk_target(schema_db, "events", "system_id") == "systems"


async def test_legacy_absent(schema_db):
    for absent in ("identities", "identity_embeddings", "users", "roles", "permissions"):
        assert not await _table_exists(schema_db, absent), f"{absent} must not exist"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_events_scope api/tests/test_schema_godview.py::test_legacy_absent -v`
Expected: `test_events_scope` FAILS (no `events` table yet); `test_legacy_absent` PASSES (old migrations already deleted).

- [ ] **Step 3: Create `016_events_audit.sql`**

```sql
-- Append-only journal (D19). Keeps bigserial id as the projector cursor (Decision 8).
CREATE TABLE events (
    id          bigserial PRIMARY KEY,
    trigger_id  uuid NOT NULL,
    ts          timestamptz NOT NULL DEFAULT now(),
    service     text NOT NULL,
    event_type  text NOT NULL,
    status      text NOT NULL,
    payload     jsonb NOT NULL DEFAULT '{}',
    asset_ref   text,
    -- Decision 2: first-class scope columns (nullable; stamped by writers going forward)
    organization_id uuid REFERENCES organizations(id),
    location_id uuid REFERENCES locations(id),
    system_id   uuid REFERENCES systems(id),
    display_id  uuid REFERENCES displays(id),
    camera_id   uuid REFERENCES cameras(id),
    subject_profile_id uuid REFERENCES subject_profiles(id),
    ad_run_id   uuid REFERENCES ad_runs(id)
);

CREATE TABLE audit_logs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id uuid,
    actor_type  actor_type NOT NULL,
    action      text NOT NULL,
    entity_type text NOT NULL,
    entity_id   text NOT NULL,
    before jsonb, after jsonb, ip_address text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Resolve deferred event_id FKs from 013/015 (events did not exist yet).
ALTER TABLE subject_observations
    ADD CONSTRAINT subject_observations_event_fk
    FOREIGN KEY (event_id) REFERENCES events(id);
ALTER TABLE personalization_decisions
    ADD CONSTRAINT personalization_decisions_event_fk
    FOREIGN KEY (event_id) REFERENCES events(id);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_events_scope api/tests/test_schema_godview.py::test_legacy_absent -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrations/016_events_audit.sql api/tests/test_schema_godview.py
git commit -m "feat(db): events journal with bigserial cursor + scope columns, audit_logs, deferred event FKs"
```

---

### Task 8: Live-feed / drilldown indexes + full-suite green

**Files:**
- Create: `db/migrations/017_indexes.sql`
- Modify: `api/tests/test_schema_godview.py` (add `test_feed_indexes`)

**Interfaces:**
- Consumes: `events`, `ad_runs` (from prior tasks).
- Produces: nothing new for later tasks; this finalizes query performance for the projector + live feed.

- [ ] **Step 1: Write the failing test**

Append:

```python
async def _index_names(conn, table):
    rows = await conn.fetch(
        "SELECT indexname FROM pg_indexes WHERE tablename = $1", table
    )
    return {r["indexname"] for r in rows}


async def test_feed_indexes(schema_db):
    ev = await _index_names(schema_db, "events")
    assert "events_system_ts_idx" in ev
    assert "events_location_ts_idx" in ev
    assert "events_ad_run_idx" in ev
    assert "events_ts_desc_idx" in ev
    assert "events_trigger_id_idx" in ev
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py::test_feed_indexes -v`
Expected: FAIL — `events_system_ts_idx` not found.

- [ ] **Step 3: Create `017_indexes.sql`**

```sql
-- Preserve the Phase-0 access paths.
CREATE INDEX events_ts_desc_idx    ON events (ts DESC);
CREATE INDEX events_trigger_id_idx ON events (trigger_id);
-- Decision 2: scoped live-feed + drilldown shapes.
CREATE INDEX events_system_ts_idx   ON events (system_id, ts DESC);
CREATE INDEX events_location_ts_idx ON events (location_id, ts DESC);
CREATE INDEX events_ad_run_idx      ON events (ad_run_id) WHERE ad_run_id IS NOT NULL;
```

- [ ] **Step 4: Run the FULL suite to verify everything passes together**

Run: `cd /Users/jn/code/mras-ops && python -m pytest api/tests/test_schema_godview.py -v`
Expected: all tests PASS (enums, accounts, physical, people, creative, runs, idempotency, events scope, legacy absent, feed indexes).

- [ ] **Step 5: Commit**

```bash
git add db/migrations/017_indexes.sql api/tests/test_schema_godview.py
git commit -m "feat(db): live-feed/drilldown indexes; full God View schema green"
```

---

### Task 9: Apply clean-slate to the dev database + smoke check

**Files:** none (operational).

**Interfaces:** none.

> Because Postgres only runs `docker-entrypoint-initdb.d` on a **fresh** volume, applying the clean-slate to the running dev DB means dropping the volume. All current data is disposable test data (Decision 4) — this is authorized while pre-alpha.

- [ ] **Step 1: Recreate the dev DB volume from the new migration set**

```bash
cd /Users/jn/code/mras-ops
docker compose down -v
docker compose up -d postgres
```

- [ ] **Step 2: Verify the schema loaded (smoke)**

```bash
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "\dt" | grep -E "subject_profiles|ad_runs|events"
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT to_regclass('public.identities');"
```
Expected: the first prints the three table rows; the second prints `(null)` (legacy table gone).

- [ ] **Step 3: Confirm app boots against the new schema**

```bash
cd /Users/jn/code/mras-ops && docker compose up -d
docker compose logs --tail=20 mras-ops-api | grep -iE "error|listening|started"
```
Expected: api starts; no schema errors. (Re-enroll of test faces is a vision task, separate lane.)

- [ ] **Step 4: Commit (docs only — no code in this task)**

No commit; operational verification only. If any migration error surfaces, fix the offending `db/migrations/01x_*.sql` under the failing task and re-run its test.

---

## Self-Review

**1. Spec coverage:** Every spec §7 acceptance criterion maps to a task — (1) Task 9 apply + Tasks 1-8 fixture; (2) Task 7 `events.id=bigint`, others uuid; (3) Task 1 enum reject; (4) Tasks 6-7 scope columns + FKs; (5) Task 6 idempotency uniques; (6) Task 3 `screen_id`; (7) Task 4 `subject_embeddings` active index; (8) Tasks 2/4/7 legacy-absent; (9) Task 8 indexes. Spec §6 inventory: all 21+ tables created across Tasks 2-7.

**2. Placeholder scan:** No "TBD"/"add validation"/"similar to" — every step ships exact SQL, exact test code, exact commands and expected output.

**3. Type consistency:** Cross-task FK targets (`subject_profiles`, `ad_runs`, `media_assets`, `events`) use the deferred-FK pattern (plain `uuid` column in the earlier task, `ALTER TABLE ADD FOREIGN KEY` in the task that creates the target) so each migration applies cleanly in filename order. Enum names referenced in later DDL all exist in `010_enums.sql`. `events.id` is `bigserial`/`bigint`; every other PK is `uuid` — asserted in `test_events_scope`.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-30-godview-schema-lane-a.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session via executing-plans, batch with checkpoints.

Which approach?
