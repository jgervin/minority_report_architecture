# God View — ScreenGroup Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class `screen_groups` table (and nullable `screen_group_id` FK on `cameras`/`displays`) to the mras-ops God View schema, verified by schema-assertion tests.

**Architecture:** One new ordered SQL migration `db/migrations/025_screen_groups.sql` in the `mras-ops` repo, applied by the existing throwaway-DB schema test harness. This groups cameras/displays within a system (e.g. "Entrance Wall A") and simultaneously resolves the open zone/area question in `docs/handoff-03-peelback-orchestration-spec.md`. Purely additive — no existing table is altered destructively.

**Tech Stack:** PostgreSQL (asyncpg-applied migrations), Python `pytest` + `asyncpg` schema assertions.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-07-godview-prototype-ux-design.md` §7.

## Global Constraints

- Repo: `/Users/jn/code/mras-ops`. All git is delegated to the `git-flow-manager` subagent — never run raw git as the main agent.
- Migrations are numbered, ordered, and idempotent-on-fresh-DB. Next free number is **025** (024 is the highest existing migration).
- `010_enums.sql` is frozen (already applied in every environment); new enums are defined in their own later migration, never by editing `010`.
- Follow `db/migrations/012_physical.sql` conventions exactly: `uuid PRIMARY KEY DEFAULT gen_random_uuid()`, `REFERENCES table(id)`, `jsonb NOT NULL DEFAULT '{}'`, `timestamptz NOT NULL DEFAULT now()` for `created_at`/`updated_at`, index name style `<table>_<col>_idx`.
- The schema test requires dockerized Postgres: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`.
- Test file to extend: `/Users/jn/code/mras-ops/tests/test_schema_godview.py` (uses helpers `_table_exists`, `_column_type`, `_column_is_nullable`, `_fk_target`, `_enum_values` already defined there).

---

### Task 1: Add `screen_groups` table + FKs migration, verified by schema tests

**Files:**
- Create: `/Users/jn/code/mras-ops/db/migrations/025_screen_groups.sql`
- Modify: `/Users/jn/code/mras-ops/tests/test_schema_godview.py` (append one test function)
- Test: same file (`tests/test_schema_godview.py`)

**Interfaces:**
- Consumes: existing `systems(id)`, `locations(id)`, `cameras`, `displays` tables and the `lifecycle_status` enum (all from migrations 010–012).
- Produces: table `screen_groups`, enum type `screen_group_type` (`zone`/`ad_cluster`/`custom`), and nullable `cameras.screen_group_id` / `displays.screen_group_id` FKs pointing at `screen_groups(id)`. Consumed later by the God View prototype's Systems & Logs page and by peel-back orchestration.

- [ ] **Step 1: Ensure Postgres is up**

Run: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`
Expected: postgres container running (or already up).

- [ ] **Step 2: Write the failing test**

Append to `/Users/jn/code/mras-ops/tests/test_schema_godview.py`:

```python
async def test_screen_groups_table(schema_db):
    # table exists
    assert await _table_exists(schema_db, "screen_groups"), "missing screen_groups"

    # new enum with exactly these values, in order
    assert await _enum_values(schema_db, "screen_group_type") == ["zone", "ad_cluster", "custom"]

    # core columns and types
    assert await _column_type(schema_db, "screen_groups", "id") == "uuid"
    assert await _column_type(schema_db, "screen_groups", "system_id") == "uuid"
    assert await _column_type(schema_db, "screen_groups", "location_id") == "uuid"
    assert await _column_type(schema_db, "screen_groups", "name") == "text"
    assert await _column_type(schema_db, "screen_groups", "metadata") == "jsonb"

    # system_id is required, location_id is optional (denormalized, matches cameras/displays)
    assert await _column_is_nullable(schema_db, "screen_groups", "system_id") is False
    assert await _column_is_nullable(schema_db, "screen_groups", "location_id") is True

    # FK back-references
    assert await _fk_target(schema_db, "screen_groups", "system_id") == "systems"
    assert await _fk_target(schema_db, "screen_groups", "location_id") == "locations"

    # nullable grouping FK added to BOTH device projections
    assert await _column_type(schema_db, "displays", "screen_group_id") == "uuid"
    assert await _column_type(schema_db, "cameras", "screen_group_id") == "uuid"
    assert await _column_is_nullable(schema_db, "displays", "screen_group_id") is True
    assert await _column_is_nullable(schema_db, "cameras", "screen_group_id") is True
    assert await _fk_target(schema_db, "displays", "screen_group_id") == "screen_groups"
    assert await _fk_target(schema_db, "cameras", "screen_group_id") == "screen_groups"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest tests/test_schema_godview.py::test_screen_groups_table -v`
Expected: FAIL — `missing screen_groups` (the migration doesn't exist yet, so the throwaway DB has no such table).

- [ ] **Step 4: Write the migration**

Create `/Users/jn/code/mras-ops/db/migrations/025_screen_groups.sql`:

```sql
-- 025_screen_groups.sql: first-class grouping of cameras/displays within a system.
-- Serves God View (Systems & Logs drill-down groups devices by wall/zone) and the
-- peel-back orchestration's open zone/area question (see handoff-03).
-- New enum defined here rather than in 010_enums.sql (010 is frozen / already applied).

CREATE TYPE screen_group_type AS ENUM ('zone', 'ad_cluster', 'custom');

CREATE TABLE screen_groups (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    system_id   uuid NOT NULL REFERENCES systems(id),
    location_id uuid REFERENCES locations(id),   -- denormalized, matches cameras/displays convention
    name        text NOT NULL,                    -- e.g. "Entrance Wall A"
    group_type  screen_group_type NOT NULL DEFAULT 'custom',
    status      lifecycle_status NOT NULL DEFAULT 'active',
    metadata    jsonb NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX screen_groups_system_idx ON screen_groups (system_id);

ALTER TABLE displays ADD COLUMN screen_group_id uuid REFERENCES screen_groups(id);
ALTER TABLE cameras  ADD COLUMN screen_group_id uuid REFERENCES screen_groups(id);
CREATE INDEX displays_screen_group_idx ON displays (screen_group_id);
CREATE INDEX cameras_screen_group_idx  ON cameras  (screen_group_id);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest tests/test_schema_godview.py::test_screen_groups_table -v`
Expected: PASS.

- [ ] **Step 6: Run the full schema suite to confirm no regressions**

Run: `cd /Users/jn/code/mras-ops && python -m pytest tests/test_schema_godview.py -v`
Expected: all pre-existing tests still PASS (the migration is additive; nothing else changes).

- [ ] **Step 7: Commit (delegate to git-flow-manager)**

Delegate to the `git-flow-manager` subagent: create branch `feat/godview-screen-groups` off `main` in `/Users/jn/code/mras-ops`, stage exactly `db/migrations/025_screen_groups.sql` and `tests/test_schema_godview.py`, commit as:

```
feat: add screen_groups table + camera/display grouping FK

Adds 025_screen_groups.sql (screen_group_type enum, screen_groups table,
nullable screen_group_id on cameras/displays). Verified by schema assertions.
Resolves the zone/area grouping question from handoff-03 and backs the
God View Systems & Logs drill-down. Spec: 2026-07-07-godview-prototype-ux-design.md §7.
```

Then open a PR targeting `main` with Summary / Motivation / Tests / Risks sections. Do not merge; report the PR number back.

---

## Self-Review

- **Spec coverage:** Spec §7 (screen_groups table, `group_type` discriminator with `zone`/`ad_cluster`/`custom`, nullable FK on both `cameras` and `displays`, `location_id` denormalization, no `ad_runs` change) — all covered by Task 1. The spec's "no new column on `ad_runs`" is satisfied by omission (nothing in this plan touches `ad_runs`).
- **Placeholder scan:** none — the migration SQL and test code are complete and literal.
- **Type consistency:** enum values `('zone','ad_cluster','custom')` match between the migration and the `_enum_values` assertion; FK targets (`systems`, `locations`, `screen_groups`) match between migration and `_fk_target` assertions.
