# Multi-Camera TODO-8 — Plan B: mras-ops Registry, Admin API & God View Surfacing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The ops side of spec Phases C–D: migration 027 (`standby` camera_role + `cameras.failover_eligible`), an audited `PATCH /cameras/{camera_id}` admin endpoint, and additive `camera_role` / `failover_eligible` / `effective_duty` fields in the God View systems drill-down. No vision-runtime code (that is Plan A); no frontend (contract only, stated in Interfaces).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-08-multicam-roles-failover-design.md` (§5.5 is this plan's scope; §7 migration caveat; decisions 9, 12, 13 bind it)

**Tech stack:** FastAPI + asyncpg (thin routes in `api/src/main.py`, query logic in `api/src/*` modules), raw-SQL migrations in `db/migrations/`, pytest with the throwaway-Postgres `projector_pool`/`godview_isolate` fixtures.

All paths relative to `/Users/jn/code/mras-ops` unless absolute. Tests require the dockerized Postgres:
`cd /Users/jn/code/mras-ops && docker compose up -d postgres`, then
`cd /Users/jn/code/mras-ops/api && python -m pytest tests/<file> -v`.

---

## Global Constraints (verbatim from the spec — binding)

- Decision 9: "**Failover eligibility is explicit**: new column `cameras.failover_eligible boolean NOT NULL DEFAULT false` (additive migration). An admin marks which watchers may act as ID. Default false = nothing changes for existing installs."
- Decision 12: "**Admin API is small and audited**: `PATCH /cameras/{camera_id}` accepting `camera_role`, `status`, `failover_eligible` — journaled as `camera_admin` events (who/what/when)."
- Decision 13: "**New enum value `standby`** added to `camera_role` (additive `ALTER TYPE ... ADD VALUE`)."
- Decision 10 (journal side): "duty *transitions* are journaled to the append-only `events` table (`event_type='camera_duty'`) so God View/audit can reconstruct history."
- §5.5 God View: "extend `GET /god-view/systems/{id}` cameras block additively with `camera_role`, `failover_eligible`, and `effective_duty` (from the latest `camera_duty` event; `unknown` when none)."
- §2 invariant: "**identity is permanent; desired role is admin truth; effective duty is runtime truth.**" → the PATCH endpoint must never touch `id`, `name`, `device_id`; God View must render duty and role as separate fields.
- §7: "`ALTER TYPE ADD VALUE` cannot run inside a transaction block on older PG (apply migration standalone — same manual-apply posture as 025/026)."
- §8: auth on the admin endpoint is explicitly out of scope ("single-operator dev posture") — "who" in the audit event is `service='mras-ops'`, no user id.

**Reality notes discovered during investigation (constraints on the code below):**
- `cameras.status` is `device_status` (`active|degraded|offline|retired`) — NOT `lifecycle_status`; there is no `inactive` on cameras. Validation uses the real enum. (Spec §2/§5.3 corrected accordingly.)
- `events` columns: `id bigserial, trigger_id uuid NOT NULL, ts timestamptz DEFAULT now(), service text, event_type text, status text, payload jsonb, asset_ref, organization_id, location_id, system_id, display_id, camera_id, ...` (016). Vision's `log_journal_event` chokepoint (`/Users/jn/code/mras-vision/src/journal.py`) inserts ONLY `(trigger_id, ts, service, event_type, status, payload)` — it does **not** stamp the first-class `camera_id` column. Therefore `effective_duty` must match on `payload->>'camera_id'` (Interface I3 makes this binding on Plan A).
- `api/tests/conftest.py` `godview_isolate` already TRUNCATEs both `cameras` and `events` — new tests get a clean slate with zero fixture changes. `projector_pool` applies `db/migrations/*.sql` in sorted order, so 027 is picked up automatically.
- Postgres is 16-alpine; on PG ≥ 12 `ALTER TYPE ... ADD VALUE` is legal inside a transaction *as long as the new value is not used in the same transaction* — migration 027 never uses `'standby'`, so it is safe under conftest's single `execute()` AND under psql. The §7 standalone-apply posture still applies to the live dev DB (initdb scripts only run on fresh volumes).
- asyncpg + enums: send enum values as **text with a server-side cast** (`$n::camera_role`) and read them back as `::text`. This sidesteps stale client-side enum codec caches on pooled connections opened before the `ALTER TYPE` (the live stack still needs an api restart after applying 027 — see Task 5).

---

## File Structure

- Create `db/migrations/027_camera_failover.sql` — enum value, column, partial index.
- Create `api/src/cameras.py` — `patch_camera()` (update + journal in one transaction) + `CameraPatch` pydantic model + writable-value sets.
- Modify `api/src/main.py` — thin `PATCH /cameras/{camera_id}` route (import from `src.cameras`).
- Modify `api/src/godview/systems.py` — `get_system` cameras query gains `camera_role`, `failover_eligible`, `effective_duty`.
- Create `api/tests/test_camera_admin.py` — schema + `patch_camera` real-DB tests + route validation tests.
- Modify `api/tests/test_godview_systems.py` — drill-down duty-field tests.

---

## Interfaces (what Plan A and the future frontend build against)

**I1 — `PATCH /cameras/{camera_id}` (ops-api, :8080)**
```
Request:  JSON object with ANY NON-EMPTY SUBSET of exactly these fields:
  camera_role       "detection" | "enrollment" | "audience_measurement" | "security_context" | "standby"
  status            "active" | "degraded" | "offline" | "retired"        (device_status)
  failover_eligible boolean
Errors:   422 unknown field or invalid enum value (pydantic extra="forbid" / Literal)
          400 non-uuid camera_id · 400 empty patch ("no updatable fields provided")
          404 unknown camera_id ("camera not found")
Response 200:
  { "id": uuid, "name": str|null, "system_id": uuid, "screen_group_id": uuid|null,
    "camera_role": str, "status": str, "failover_eligible": bool, "updated_at": iso8601 }
```

**I2 — `camera_admin` journal event (written by this endpoint, same transaction as the UPDATE)**
```
events row: service='mras-ops', event_type='camera_admin', status='success',
            trigger_id=fresh uuid4, ts=now() (default),
            system_id=<camera's system>, camera_id=<camera>   (first-class scope columns stamped)
payload:    { "camera_id": "<uuid>", "changes": { "<field>": {"from": ..., "to": ...}, ... } }
```

**I3 — `camera_duty` event contract (BINDING ON PLAN A — effective_duty resolution depends on it)**
```
events row: service='mras-vision', event_type='camera_duty', status='success'
payload:    { "camera_id": "<registry uuid AS STRING>", "from": <duty>, "to": <duty>,
              "reason": str, "lease_scope": str }
duty vocabulary (lowercase §5.3 states): "standby" | "watching" | "primary_id" | "acting_id" | "idle_offline"
```
`payload.camera_id` is REQUIRED (vision's `log_journal_event` does not stamp the `camera_id` column; ops matches on the payload key).

**I4 — `GET /god-view/systems/{id}` cameras block (additive; existing keys unchanged)**
```
"cameras": [ { "id", "name", "status", "screen_group_id", "face_count", "confidence",   ← existing
               "camera_role": str,                                                      ← NEW (admin truth)
               "failover_eligible": bool,                                               ← NEW
               "effective_duty": str } ]                                                ← NEW (runtime truth)
effective_duty = payload->>'to' of the LATEST camera_duty event for that camera (by events.id),
                 or "unknown" when none exists. Pass-through: God View does not validate the
                 vocabulary, it renders what the runtime journaled (I3).
```

---

### Task 1: Migration 027 — `standby`, `failover_eligible`, duty index

**Files:** Create `db/migrations/027_camera_failover.sql`; Create `api/tests/test_camera_admin.py` (schema section)

- [ ] **Step 1: Write the failing tests**

```python
# api/tests/test_camera_admin.py
"""TODO-8 Phase C (ops side): migration 027 + audited PATCH /cameras/{id}."""
import uuid

import pytest

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def _org_loc_sys(pool, name="Sys1"):
    org, loc, sid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await pool.execute("INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','advertiser')", org)
    await pool.execute("INSERT INTO locations (id,name,location_type) VALUES ($1,'Loc','store')", loc)
    await pool.execute("INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,$4)", sid, org, loc, name)
    return org, loc, sid


async def _camera(pool, sid, name="Cam1"):
    cid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO cameras (id,system_id,name,screen_id) VALUES ($1,$2,$3,'scr_c1')",
        cid, sid, name)  # 3 placeholders, 3 args (outside-review fix M1)
    return cid


# --- migration 027 -----------------------------------------------------------

async def test_camera_role_enum_has_standby(projector_pool):
    rows = await projector_pool.fetch("SELECT unnest(enum_range(NULL::camera_role))::text AS v")
    assert "standby" in {r["v"] for r in rows}


async def test_failover_eligible_defaults_false(projector_pool):
    _, _, sid = await _org_loc_sys(projector_pool)
    cid = await _camera(projector_pool, sid)
    assert await projector_pool.fetchval(
        "SELECT failover_eligible FROM cameras WHERE id = $1", cid) is False
```

- [ ] **Step 2: Run and watch them fail**

```
cd /Users/jn/code/mras-ops/api && python -m pytest tests/test_camera_admin.py -v
```
Expected: `test_camera_role_enum_has_standby` FAILED (`AssertionError: 'standby' not in {...}`); `test_failover_eligible_defaults_false` FAILED (`asyncpg.exceptions.UndefinedColumnError: column "failover_eligible" does not exist`).

- [ ] **Step 3: Write the migration**

```sql
-- db/migrations/027_camera_failover.sql
-- TODO-8 Phase C: multi-camera roles & failover (spec decisions 9 & 13). Additive only.
--
-- ALTER TYPE ... ADD VALUE is legal inside a transaction on PG >= 12 ONLY IF the new
-- value is not used in the same transaction — this file never uses 'standby', so it is
-- safe under both initdb and the test harness's single execute(). For the EXISTING dev
-- DB apply it manually/standalone (initdb scripts only run on fresh volumes — same
-- posture as 025/026); command in the plan's Task 5.
ALTER TYPE camera_role ADD VALUE IF NOT EXISTS 'standby';

-- Decision 9: explicit failover eligibility; default false = no behavior change.
ALTER TABLE cameras ADD COLUMN failover_eligible boolean NOT NULL DEFAULT false;

-- Serves God View effective_duty: latest camera_duty event per camera. Partial +
-- expression index — NOTE: the first expression index in this schema (023 is
-- partial-on-(ts) precedent for the partial part only). Only duty *transitions*
-- are indexed (rare rows), so it stays tiny while keeping the per-camera
-- latest-event probe off the unbounded append-only events heap.
CREATE INDEX IF NOT EXISTS events_camera_duty_idx
    ON events ((payload->>'camera_id'), id DESC)
    WHERE event_type = 'camera_duty';
```

- [ ] **Step 4: Re-run — both tests PASS** (conftest picks up 027 via the sorted glob; no fixture edits).
- [ ] **Step 5: Commit**

```
db: migration 027 — standby camera_role, cameras.failover_eligible, camera_duty index (TODO-8 Phase C)
```

---

### Task 2: `patch_camera` — validated update + `camera_admin` journal, one transaction

**Files:** Create `api/src/cameras.py`; Extend `api/tests/test_camera_admin.py`

- [ ] **Step 1: Write the failing tests** (append to `test_camera_admin.py`)

```python
from src.cameras import patch_camera  # add to imports at top


# --- patch_camera ------------------------------------------------------------

async def test_patch_updates_fields_and_returns_row(projector_pool):
    _, _, sid = await _org_loc_sys(projector_pool)
    cid = await _camera(projector_pool, sid)
    async with projector_pool.acquire() as conn:
        row = await patch_camera(conn, cid, {"camera_role": "standby", "failover_eligible": True})
    assert row["camera_role"] == "standby"
    assert row["failover_eligible"] is True
    assert row["status"] == "active"          # untouched field preserved
    assert row["name"] == "Cam1"              # identity never changes (spec §2)


async def test_patch_status_only(projector_pool):
    _, _, sid = await _org_loc_sys(projector_pool)
    cid = await _camera(projector_pool, sid)
    async with projector_pool.acquire() as conn:
        row = await patch_camera(conn, cid, {"status": "offline"})
    assert row["status"] == "offline"
    assert row["camera_role"] == "detection"  # role untouched (decision 12: offline != demote)


async def test_patch_journals_camera_admin_event(projector_pool):
    _, _, sid = await _org_loc_sys(projector_pool)
    cid = await _camera(projector_pool, sid)
    async with projector_pool.acquire() as conn:
        await patch_camera(conn, cid, {"camera_role": "standby"})
    ev = await projector_pool.fetchrow(
        "SELECT service, status, system_id, camera_id, payload FROM events "
        "WHERE event_type = 'camera_admin' ORDER BY id DESC LIMIT 1")
    assert ev is not None and ev["service"] == "mras-ops" and ev["status"] == "success"
    assert ev["camera_id"] == cid and ev["system_id"] == sid
    import json
    payload = json.loads(ev["payload"])
    assert payload["changes"]["camera_role"] == {"from": "detection", "to": "standby"}


async def test_patch_unknown_camera_returns_none_and_journals_nothing(projector_pool):
    async with projector_pool.acquire() as conn:
        assert await patch_camera(conn, uuid.uuid4(), {"camera_role": "standby"}) is None
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM events WHERE event_type = 'camera_admin'") == 0
```

- [ ] **Step 2: Run and watch them fail** — `ModuleNotFoundError: No module named 'src.cameras'`.

```
cd /Users/jn/code/mras-ops/api && python -m pytest tests/test_camera_admin.py -v
```

- [ ] **Step 3: Implement**

```python
# api/src/cameras.py
"""Admin camera-registry updates (TODO-8 Phase C, spec decision 12).

patch_camera applies a partial update to exactly the three admin-writable
fields (camera_role, status, failover_eligible) and journals the change as a
`camera_admin` event IN THE SAME TRANSACTION — an audited write either fully
happens (row + journal) or not at all. Identity columns (id, name, device_id)
are never writable here (spec §2 invariant). Enum values travel as text with
server-side casts, so pooled connections opened before migration 027's
ALTER TYPE need no client-side enum-codec refresh.
"""
import json
import uuid
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict

# cameras.status is device_status (NOT lifecycle_status): no 'planned'/'inactive'.
class CameraPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")  # decision 12: no other fields writable
    camera_role: Optional[Literal["detection", "enrollment", "audience_measurement",
                                  "security_context", "standby"]] = None
    status: Optional[Literal["active", "degraded", "offline", "retired"]] = None
    failover_eligible: Optional[bool] = None


_RETURNING = ("id, name, system_id, screen_group_id, camera_role::text AS camera_role, "
              "status::text AS status, failover_eligible, updated_at")


async def patch_camera(conn, camera_id: uuid.UUID, fields: dict):
    """Apply an already-schema-validated {field: value} patch. None = unknown id."""
    async with conn.transaction():
        before = await conn.fetchrow(
            "SELECT camera_role::text AS camera_role, status::text AS status, "
            "failover_eligible, system_id FROM cameras WHERE id = $1 FOR UPDATE",
            camera_id)
        if before is None:
            return None
        row = await conn.fetchrow(
            "UPDATE cameras SET "
            "  camera_role       = COALESCE($2::camera_role, camera_role), "
            "  status            = COALESCE($3::device_status, status), "
            "  failover_eligible = COALESCE($4::boolean, failover_eligible), "
            "  updated_at        = now() "
            "WHERE id = $1 RETURNING " + _RETURNING,
            camera_id, fields.get("camera_role"), fields.get("status"),
            fields.get("failover_eligible"))
        changes = {k: {"from": before[k], "to": row[k]} for k in fields}
        await conn.execute(
            "INSERT INTO events (trigger_id, service, event_type, status, payload, "
            "                    system_id, camera_id) "
            "VALUES ($1, 'mras-ops', 'camera_admin', 'success', $2::jsonb, $3, $4)",
            uuid.uuid4(),
            json.dumps({"camera_id": str(camera_id), "changes": changes}),
            before["system_id"], camera_id)
    return dict(row)
```

(`COALESCE($4::boolean, ...)` is None-vs-False safe: `False` is not NULL, so an explicit `failover_eligible: false` patch sticks.)

- [ ] **Step 4: Re-run — all Task 2 tests PASS.**
- [ ] **Step 5: Commit**

```
api: patch_camera — validated camera registry update journaled as camera_admin (TODO-8 Phase C)
```

---

### Task 3: `PATCH /cameras/{camera_id}` route — thin, strict validation

**Files:** Modify `api/src/main.py`; Extend `api/tests/test_camera_admin.py` (route section)

- [ ] **Step 1: Write the failing tests** (append; mocked-pool TestClient pattern from `test_registry.py`)

```python
# --- route validation (TestClient + mocked pool, per test_registry.py) -------

def _client(monkeypatch):
    from unittest.mock import AsyncMock
    from fastapi.testclient import TestClient
    from src.main import app
    monkeypatch.setenv("DATABASE_URL", "postgresql://fake/fake")
    monkeypatch.setattr("src.main.asyncpg.create_pool", AsyncMock(return_value=AsyncMock()))
    return TestClient(app)


def test_route_rejects_unknown_field(monkeypatch):
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"name": "evil"})
    assert r.status_code == 422  # extra="forbid": identity is not writable (spec §2)


def test_route_rejects_bad_enum_value(monkeypatch):
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"camera_role": "boss"})
    assert r.status_code == 422


def test_route_rejects_bad_uuid_and_empty_patch(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.patch("/cameras/not-a-uuid", json={"status": "offline"}).status_code == 400
        assert client.patch(f"/cameras/{uuid.uuid4()}", json={}).status_code == 400


def test_route_404_on_unknown_camera(monkeypatch):
    from unittest.mock import AsyncMock
    monkeypatch.setattr("src.main.patch_camera", AsyncMock(return_value=None))
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"camera_role": "standby"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run and watch them fail** — 405/404 (route does not exist), then `AttributeError: src.main has no attribute 'patch_camera'`.

- [ ] **Step 3: Implement the route** (in `main.py`, after the ads block; add `from src.cameras import CameraPatch, patch_camera` to imports)

```python
# ---------------------------------------------------------------------------
# Cameras (admin registry — TODO-8 Phase C; auth deliberately absent, spec §8)
# ---------------------------------------------------------------------------

@app.patch("/cameras/{camera_id}")
async def update_camera(camera_id: str, patch: CameraPatch):
    try:
        cam_uuid = uuid.UUID(camera_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid id")
    fields = patch.model_dump(exclude_none=True)
    if not fields:
        raise HTTPException(status_code=400, detail="no updatable fields provided")
    async with _db.acquire() as conn:
        row = await patch_camera(conn, cam_uuid, fields)
    if row is None:
        raise HTTPException(status_code=404, detail="camera not found")
    return row
```

- [ ] **Step 4: Run the whole file — all tests PASS.** Also run `python -m pytest tests/test_registry.py tests/test_godview_systems.py -v` (no regressions).
- [ ] **Step 5: Commit**

```
api: PATCH /cameras/{camera_id} — strict-validated, audited admin endpoint (TODO-8 Phase C)
```

---

### Task 4: God View drill-down — `camera_role`, `failover_eligible`, `effective_duty`

**Files:** Modify `api/src/godview/systems.py` (`get_system`); Extend `api/tests/test_godview_systems.py`

- [ ] **Step 1: Write the failing tests** (append to `test_godview_systems.py`)

```python
async def _duty_event(pool, cam, frm, to):
    await pool.execute(
        "INSERT INTO events (trigger_id, service, event_type, status, payload) "
        "VALUES ($1, 'mras-vision', 'camera_duty', 'success', "
        "        jsonb_build_object('camera_id', $2::text, 'from', $3::text, 'to', $4::text, "
        "                           'reason', 'test', 'lease_scope', 'sys:x'))",
        uuid.uuid4(), str(cam), frm, to)


async def test_drilldown_camera_duty_fields_defaults(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _sys(projector_pool, org, loc, "Alpha")
    await projector_pool.execute(
        "INSERT INTO cameras (id,system_id,name,screen_id,failover_eligible) "
        "VALUES ($1,$2,'C1','scr_c1',true)", uuid.uuid4(), sid)
    c = (await get_system(projector_pool, sid))["cameras"][0]
    assert c["camera_role"] == "detection"       # column default = admin truth
    assert c["failover_eligible"] is True
    assert c["effective_duty"] == "unknown"      # no camera_duty events yet (spec §5.5)


async def test_drilldown_effective_duty_latest_event_wins(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _sys(projector_pool, org, loc, "Alpha")
    cam_a, cam_b = uuid.uuid4(), uuid.uuid4()
    for cid, name in ((cam_a, "A"), (cam_b, "B")):
        await projector_pool.execute(
            "INSERT INTO cameras (id,system_id,name,screen_id) VALUES ($1,$2,$3,'scr')", cid, sid, name)
    await _duty_event(projector_pool, cam_a, "standby", "watching")
    await _duty_event(projector_pool, cam_a, "watching", "acting_id")   # newest for A
    await _duty_event(projector_pool, cam_b, "standby", "primary_id")
    by_name = {c["name"]: c for c in (await get_system(projector_pool, sid))["cameras"]}
    assert by_name["A"]["effective_duty"] == "acting_id"   # latest event, not first
    assert by_name["B"]["effective_duty"] == "primary_id"  # per-camera isolation
```

- [ ] **Step 2: Run and watch them fail** — `KeyError: 'camera_role'` / `'effective_duty'`.

- [ ] **Step 3: Implement** — in `get_system`, replace the `cams = await conn.fetch(...)` query with:

```python
    cams = await conn.fetch(
        """
        SELECT c.id, c.name, c.status::text AS status, c.screen_group_id,
               c.camera_role::text AS camera_role, c.failover_eligible,
               COALESCE((
                   SELECT e.payload->>'to'
                   FROM events e
                   WHERE e.event_type = 'camera_duty'
                     AND e.payload->>'camera_id' = c.id::text
                   ORDER BY e.id DESC
                   LIMIT 1
               ), 'unknown') AS effective_duty
        FROM cameras c
        WHERE c.system_id = $1
        ORDER BY c.name
        """,
        system_id)
```

Everything downstream (`face_count`/`confidence` merge, response dict) is untouched — the new keys ride along in `dict(c)`, keeping the payload strictly additive (issue-#44 / `viewer_exposure` precedent in `ad_runs.py`).

Scale posture (God View pattern — be honest in the module docstring or a comment): the drill-down is one system's cameras (a handful of rows); each `effective_duty` sub-select is a single-row ordered probe of `events_camera_duty_idx` (partial: only `camera_duty` rows; expression: `payload->>'camera_id'`; `id DESC` matches the ORDER BY). Without 027's index this would be a sequential scan of the unbounded journal per camera — the index is the smallest safe approach and stays proportional to duty *transitions*, not traffic.

- [ ] **Step 4: Run the full file — all systems tests PASS**, then the whole suite: `python -m pytest tests -v`.
- [ ] **Step 5: Commit**

```
godview: surface camera_role/failover_eligible/effective_duty in system drill-down (TODO-8 Phase D)
```

---

### Task 5: Live verification against the running :8080 stack

Manual checklist (dev machine, `cd /Users/jn/code/mras-ops`):

- [ ] 1. Stack up: `docker compose up -d postgres` (plus `mras-ops-api` after step 3).
- [ ] 2. **Apply 027 standalone** (initdb only runs on fresh volumes; migrations dir is already mounted read-only in the postgres container):
  `docker compose exec postgres psql -U mras -d mras -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/027_camera_failover.sql`
  Verify: `docker compose exec postgres psql -U mras -d mras -c "SELECT enum_range(NULL::camera_role)"` includes `standby`; `... -c "\d cameras"` shows `failover_eligible boolean not null default false`.
- [ ] 3. Rebuild/restart the api (new code AND fresh pooled connections post-ALTER TYPE): `docker compose up -d --build mras-ops-api mras-ops-projector`.
- [ ] 4. Pick a camera: `docker compose exec postgres psql -U mras -d mras -c "SELECT id, system_id, name, camera_role, status FROM cameras LIMIT 5"`.
- [ ] 5. PATCH happy path: `curl -s -X PATCH localhost:8080/cameras/<CAM_ID> -H 'content-type: application/json' -d '{"camera_role":"standby","failover_eligible":true}' | jq` → 200, `camera_role=standby`, `failover_eligible=true`, `name` unchanged.
- [ ] 6. Rejections: `-d '{"name":"evil"}'` → 422; `-d '{"camera_role":"boss"}'` → 422; unknown uuid → 404; `/cameras/nope` → 400.
- [ ] 7. Audit: `... psql ... -c "SELECT service, camera_id, payload FROM events WHERE event_type='camera_admin' ORDER BY id DESC LIMIT 3"` shows the change with from/to.
- [ ] 8. God View: `curl -s localhost:8080/god-view/systems/<SYSTEM_ID> | jq '.cameras'` → new fields present, `effective_duty:"unknown"` (Plan A hasn't journaled duties yet).
- [ ] 9. Simulate Plan A: insert a `camera_duty` event per Interface I3 via psql (`jsonb_build_object('camera_id','<CAM_ID>','from','standby','to','watching','reason','manual-test','lease_scope','sys:x')`); re-curl step 8 → `effective_duty:"watching"`.
- [ ] 10. Index proof: `EXPLAIN` the step-9 lookup shape → `Index Scan using events_camera_duty_idx`.
- [ ] 11. Restore: PATCH the camera back (`{"camera_role":"detection","failover_eligible":false}`); delete the fake duty event if desired.
