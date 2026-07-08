# God View Real-Data — Plan A: ops-api read endpoints

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add read-only God View endpoints to `mras-ops/api` that return bounded, scale-safe payloads (server-side `GROUP BY` counts, `WHERE`/`ORDER`/`LIMIT` selection, keyset pagination) for the godview-prototype dashboard.

**Architecture:** Query logic lives in a new `api/src/godview/` package — one helper module per page, each exposing `async def get_x(conn, ...) -> dict|list`, mirroring `api/src/projector/status.py`. Thin `@app.get(...)` routes in `api/src/main.py` acquire a connection from the module `_db` pool and delegate. Helpers are unit-tested against a throwaway Postgres using the existing `api/tests/conftest.py::projector_pool` fixture (applies every migration).

**Tech Stack:** FastAPI, asyncpg (raw SQL, no ORM), pytest + `asyncio_mode=auto` against dockerized Postgres.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-07-godview-real-data-wiring-design.md`

## Global Constraints

- Repo: `/Users/jn/code/mras-ops`. All git delegated to the `git-flow-manager` subagent — never run raw git as the main agent. One branch for this plan: `feat/godview-read-endpoints` off `main`.
- Tests require dockerized Postgres: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`.
- Run tests from the `api/` directory: `cd /Users/jn/code/mras-ops/api && pytest tests/<file> -v`. Imports resolve as `src.godview.<module>` only when cwd is `api/` (there is no installed package). Test config is `api/tests/pytest.ini` (`asyncio_mode = auto`, module-scoped loops).
- Mirror existing conventions exactly: raw SQL via asyncpg; `async with _db.acquire() as conn:` for multi-query endpoints; return plain `dict(row)`/lists; let FastAPI serialize `uuid.UUID`→str and `datetime`→ISO-8601; extract jsonb display text in SQL (`detail->>'message'`) so no `json.loads` is needed; no Pydantic response models. CORS is already `allow_origins=["*"]`; no change needed.
- **Enums are real values (from `010_enums.sql`), never invent:** `ad_run_status = (planned,composing,ready,dispatched,playing,completed,failed,canceled)`; `composition_status = (queued,selected,rendering,rendered,failed,canceled)`; `playback_status = (dispatched,started,ended,failed,interrupted,unknown)`; `lifecycle_status = (planned,active,inactive,degraded,offline,retired)`; `device_status = (active,degraded,offline,retired)`. "Active" ad-runs = `composing,dispatched,playing`. Composition "done" = `selected,rendered`.
- **Schema facts to honor:** `playbacks.display_id` is nullable, `playbacks.screen_id` is `NOT NULL text`; `subject_observations` has `camera_id` (uuid FK) and `face_quality_score` (numeric, nullable), **no** `screen_id` and **no** count column; `device_health_events.status` is `device_status`, `system_health_events.status` is `lifecycle_status`, both `detail` columns are `jsonb`; `ad_runs.system_id`/`campaign_id`/`composition_run_id` are nullable FKs; `unresolved_devices` is a global table keyed `(screen_id, kind)`.
- **Cursor encoding (keyset pagination):** an opaque string `"<iso8601>|<uuid>"`. A helper `encode_cursor(ts, id)` / `decode_cursor(s)` lives in `api/src/godview/paging.py` and is shared by all paginated endpoints. `next_cursor` is `null` when the page is not full.
- No new DB migration in this plan (schema already has everything, incl. `025_screen_groups`).

---

### Task 1: `godview` package + cursor helpers + camera-readings helper

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/godview/__init__.py` (empty)
- Create: `/Users/jn/code/mras-ops/api/src/godview/paging.py`
- Create: `/Users/jn/code/mras-ops/api/src/godview/readings.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_paging.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_readings.py`

**Interfaces:**
- Produces:
  - `encode_cursor(ts: datetime, row_id) -> str` and `decode_cursor(s: str | None) -> tuple[datetime, uuid.UUID] | tuple[None, None]` in `src.godview.paging`.
  - `async def readings_for_system(conn, system_id) -> dict[str, dict]` in `src.godview.readings` — returns `{ "<camera_uuid_str>": {"face_count": int, "confidence": float} }` for every camera in the system, aggregated over the last 60s of `subject_observations`.
  - `WINDOW_SECONDS = 60` constant in `src.godview.readings`.

- [ ] **Step 1: Ensure Postgres is up**

Run: `cd /Users/jn/code/mras-ops && docker compose up -d postgres`
Expected: postgres container running.

- [ ] **Step 2: Write the failing cursor test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_paging.py`:

```python
"""Keyset cursor round-trip for God View pagination."""
import uuid
from datetime import datetime, timezone

from src.godview.paging import encode_cursor, decode_cursor


def test_encode_decode_roundtrip():
    ts = datetime(2026, 7, 6, 18, 41, 3, tzinfo=timezone.utc)
    rid = uuid.UUID("00000000-0000-0000-0000-0000000000ab")
    token = encode_cursor(ts, rid)
    assert isinstance(token, str)
    ts2, rid2 = decode_cursor(token)
    assert ts2 == ts
    assert rid2 == rid


def test_decode_none_is_null_pair():
    assert decode_cursor(None) == (None, None)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_paging.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview'`.

- [ ] **Step 4: Create the package + paging helper**

Create `/Users/jn/code/mras-ops/api/src/godview/__init__.py` (empty file).

Create `/Users/jn/code/mras-ops/api/src/godview/paging.py`:

```python
"""Opaque keyset cursors for God View list endpoints.

A cursor is "<iso8601-timestamp>|<row-uuid>". Endpoints ORDER BY a
(timestamp, id) pair and resume strictly after the cursor's pair.
"""
import uuid
from datetime import datetime


def encode_cursor(ts: datetime, row_id) -> str:
    return f"{ts.isoformat()}|{row_id}"


def decode_cursor(s: str | None):
    if not s:
        return (None, None)
    iso, _, rid = s.partition("|")
    return (datetime.fromisoformat(iso), uuid.UUID(rid))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_paging.py -v`
Expected: PASS (2 tests).

- [ ] **Step 6: Write the failing readings test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_readings.py`:

```python
"""Per-camera detection readings aggregated from subject_observations (last 60s)."""
import uuid

from src.godview.readings import readings_for_system


async def _seed_system_with_camera(pool):
    org = uuid.uuid4()
    loc = uuid.uuid4()
    sysid = uuid.uuid4()
    cam = uuid.uuid4()
    await pool.execute(
        "INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','advertiser')", org)
    await pool.execute(
        "INSERT INTO locations (id,name,location_type) VALUES ($1,'Loc','store')", loc)
    await pool.execute(
        "INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,'Sys')",
        sysid, org, loc)
    await pool.execute(
        "INSERT INTO cameras (id,system_id,name,screen_id) VALUES ($1,$2,'Cam','scr_t1')",
        cam, sysid)
    return sysid, cam


async def test_counts_recent_observations_and_averages_quality(projector_pool):
    sysid, cam = await _seed_system_with_camera(projector_pool)
    # two recent observations, quality 0.8 and 0.6 -> count 2, avg 0.7
    for q in (0.8, 0.6):
        await projector_pool.execute(
            "INSERT INTO subject_observations (camera_id,system_id,observed_at,detection_type,face_quality_score) "
            "VALUES ($1,$2, now(), 'face', $3)", cam, sysid, q)
    # one stale observation (2 minutes ago) must be excluded
    await projector_pool.execute(
        "INSERT INTO subject_observations (camera_id,system_id,observed_at,detection_type,face_quality_score) "
        "VALUES ($1,$2, now() - interval '120 seconds', 'face', 0.9)", cam, sysid)

    readings = await readings_for_system(projector_pool, sysid)
    r = readings[str(cam)]
    assert r["face_count"] == 2
    assert abs(r["confidence"] - 0.7) < 1e-6


async def test_camera_with_no_observations_reads_zero(projector_pool):
    sysid, cam = await _seed_system_with_camera(projector_pool)
    readings = await readings_for_system(projector_pool, sysid)
    assert readings[str(cam)] == {"face_count": 0, "confidence": 0.0}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_readings.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview.readings'`.

- [ ] **Step 8: Implement the readings helper**

Create `/Users/jn/code/mras-ops/api/src/godview/readings.py`:

```python
"""Per-camera live detection readings, derived from subject_observations.

face_count = number of observations for the camera in the last WINDOW_SECONDS;
confidence = average face_quality_score over that window (NULL -> 0.0).
subject_observations links to a camera via camera_id (there is no screen_id).
"""

WINDOW_SECONDS = 60


async def readings_for_system(conn, system_id) -> dict:
    rows = await conn.fetch(
        """
        SELECT c.id AS camera_id,
               COALESCE(o.face_count, 0)          AS face_count,
               COALESCE(o.confidence, 0)::float8  AS confidence
        FROM cameras c
        LEFT JOIN LATERAL (
            SELECT count(*) AS face_count, avg(so.face_quality_score) AS confidence
            FROM subject_observations so
            WHERE so.camera_id = c.id
              AND so.observed_at >= now() - make_interval(secs => $2)
        ) o ON true
        WHERE c.system_id = $1
        """,
        system_id, WINDOW_SECONDS,
    )
    return {
        str(r["camera_id"]): {"face_count": r["face_count"], "confidence": r["confidence"]}
        for r in rows
    }
```

- [ ] **Step 9: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_readings.py -v`
Expected: PASS (2 tests).

- [ ] **Step 10: Commit (delegate to git-flow-manager)**

Delegate: create branch `feat/godview-read-endpoints` off `main` in `/Users/jn/code/mras-ops`; stage `api/src/godview/__init__.py`, `api/src/godview/paging.py`, `api/src/godview/readings.py`, `api/tests/test_godview_paging.py`, `api/tests/test_godview_readings.py`; commit:
```
feat: godview package scaffold — keyset cursors + camera readings helper
```
Do not open a PR yet (opened after the final task).

---

### Task 2: `GET /god-view/dashboard`

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/godview/dashboard.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_dashboard.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (add import + route)

**Interfaces:**
- Consumes: nothing from other godview modules (self-contained; readings for the dashboard's ~6 cameras are computed inline against the recent-observation set, not `readings_for_system`).
- Produces: `async def get_dashboard(conn) -> dict` with keys `fleet` (`{total,active,degraded,offline}`), `org_count` (int), `active_count` (int), `active_runs` (list of `{id,status,started_at,system_id,system_name}`, ≤5), `recent_failed_runs` (list of `{id,system_id,system_name,ended_at,error_code}`, ≤10), `recent_health_drops` (list of `{kind,ref_id,ref_name,status,detail,observed_at}`, ≤10), `camera_rows` (list of `{camera_id,name,system_name,status,face_count,confidence}`, ≤6).

- [ ] **Step 1: Write the failing test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_dashboard.py`:

```python
"""God View dashboard: server-computed counts + bounded candidate rows."""
import uuid

from src.godview.dashboard import get_dashboard


async def _org_loc(pool):
    org, loc = uuid.uuid4(), uuid.uuid4()
    await pool.execute("INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','advertiser')", org)
    await pool.execute("INSERT INTO locations (id,name,location_type) VALUES ($1,'Loc','store')", loc)
    return org, loc


async def _system(pool, org, loc, name, status):
    sid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO systems (id,organization_id,location_id,name,status) VALUES ($1,$2,$3,$4,$5)",
        sid, org, loc, name, status)
    return sid


async def test_fleet_counts_by_status(projector_pool):
    org, loc = await _org_loc(projector_pool)
    await _system(projector_pool, org, loc, "A", "active")
    await _system(projector_pool, org, loc, "B", "active")
    await _system(projector_pool, org, loc, "C", "degraded")
    d = await get_dashboard(projector_pool)
    assert d["fleet"]["total"] == 3
    assert d["fleet"]["active"] == 2
    assert d["fleet"]["degraded"] == 1
    assert d["fleet"]["offline"] == 0
    assert d["org_count"] == 1  # one organization seeded by _org_loc


async def test_active_runs_are_bounded_and_labeled(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _system(projector_pool, org, loc, "Sys1", "active")
    # one active (playing) and one completed run
    for status in ("playing", "completed"):
        await projector_pool.execute(
            "INSERT INTO ad_runs (trigger_id,system_id,status,started_at) VALUES ($1,$2,$3, now())",
            uuid.uuid4(), sid, status)
    d = await get_dashboard(projector_pool)
    assert d["active_count"] == 1
    assert len(d["active_runs"]) == 1
    assert d["active_runs"][0]["status"] == "playing"
    assert d["active_runs"][0]["system_name"] == "Sys1"


async def test_recent_failed_runs_carry_error_code(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _system(projector_pool, org, loc, "Sys1", "active")
    trig = uuid.uuid4()
    comp = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO composition_runs (id,trigger_id,status,error_code) VALUES ($1,$2,'failed','OVERLAY_RENDER_TIMEOUT')",
        comp, trig)
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,system_id,composition_run_id,status,ended_at) VALUES ($1,$2,$3,'failed', now())",
        trig, sid, comp)
    d = await get_dashboard(projector_pool)
    assert len(d["recent_failed_runs"]) == 1
    assert d["recent_failed_runs"][0]["error_code"] == "OVERLAY_RENDER_TIMEOUT"
    assert d["recent_failed_runs"][0]["system_name"] == "Sys1"


async def test_recent_health_drops_unify_device_and_system(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _system(projector_pool, org, loc, "Sys1", "active")
    # system health drop
    await projector_pool.execute(
        "INSERT INTO system_health_events (system_id,status,detail,observed_at) "
        "VALUES ($1,'offline', '{\"message\":\"system down\"}'::jsonb, now())", sid)
    # device health drop, device projected as a camera named "CamX"
    dev = uuid.uuid4()
    await projector_pool.execute("INSERT INTO devices (id,device_type) VALUES ($1,'camera')", dev)
    await projector_pool.execute(
        "INSERT INTO cameras (id,system_id,device_id,name,screen_id) VALUES ($1,$2,$3,'CamX','scr_x')",
        uuid.uuid4(), sid, dev)
    await projector_pool.execute(
        "INSERT INTO device_health_events (device_id,status,detail,observed_at) "
        "VALUES ($1,'degraded', '{\"message\":\"lagging\"}'::jsonb, now())", dev)

    d = await get_dashboard(projector_pool)
    kinds = {h["kind"] for h in d["recent_health_drops"]}
    assert kinds == {"system", "device"}
    dev_row = next(h for h in d["recent_health_drops"] if h["kind"] == "device")
    assert dev_row["ref_name"] == "CamX"
    assert dev_row["detail"] == "lagging"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_dashboard.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview.dashboard'`.

- [ ] **Step 3: Implement the dashboard helper**

Create `/Users/jn/code/mras-ops/api/src/godview/dashboard.py`:

```python
"""God View main-dashboard read: O(1) payload regardless of fleet size.

Returns server-computed counts + a handful of bounded candidate rows. All
view-shaping (KPI mapping, failure merge/rank) happens in the client selectors;
this only bounds the data.
"""

_ACTIVE_STATUSES = ("composing", "dispatched", "playing")
_HEALTH_WINDOW_SECS = 60  # readings window for camera_rows


async def get_dashboard(conn) -> dict:
    fleet_rows = await conn.fetch("SELECT status::text AS status, count(*) AS n FROM systems GROUP BY status")
    counts = {r["status"]: r["n"] for r in fleet_rows}
    fleet = {
        "total": sum(counts.values()),
        "active": counts.get("active", 0),
        "degraded": counts.get("degraded", 0),
        "offline": counts.get("offline", 0),
    }
    org_count = await conn.fetchval("SELECT count(*) FROM organizations")

    active_count = await conn.fetchval(
        "SELECT count(*) FROM ad_runs WHERE status = ANY($1::ad_run_status[])", list(_ACTIVE_STATUSES))
    active_runs = [dict(r) for r in await conn.fetch(
        """
        SELECT ar.id, ar.status::text AS status, ar.started_at, ar.system_id, s.name AS system_name
        FROM ad_runs ar
        LEFT JOIN systems s ON s.id = ar.system_id
        WHERE ar.status = ANY($1::ad_run_status[])
        ORDER BY ar.started_at DESC NULLS LAST, ar.id DESC
        LIMIT 5
        """,
        list(_ACTIVE_STATUSES),
    )]

    recent_failed_runs = [dict(r) for r in await conn.fetch(
        """
        SELECT ar.id, ar.system_id, s.name AS system_name, ar.ended_at, cr.error_code
        FROM ad_runs ar
        LEFT JOIN systems s ON s.id = ar.system_id
        LEFT JOIN composition_runs cr ON cr.id = ar.composition_run_id
        WHERE ar.status = 'failed'
        ORDER BY ar.ended_at DESC NULLS LAST, ar.id DESC
        LIMIT 10
        """
    )]

    recent_health_drops = [dict(r) for r in await conn.fetch(
        """
        SELECT * FROM (
            SELECT 'device' AS kind, dhe.id, dhe.device_id AS ref_id,
                   COALESCE(cam.name, disp.name, dhe.device_id::text) AS ref_name,
                   dhe.status::text AS status,
                   COALESCE(dhe.detail->>'message', dhe.detail::text) AS detail,
                   dhe.observed_at
            FROM device_health_events dhe
            LEFT JOIN cameras cam ON cam.device_id = dhe.device_id
            LEFT JOIN displays disp ON disp.device_id = dhe.device_id
            WHERE dhe.status IN ('offline','degraded')
            UNION ALL
            SELECT 'system' AS kind, she.id, she.system_id AS ref_id,
                   s.name AS ref_name, she.status::text AS status,
                   COALESCE(she.detail->>'message', she.detail::text) AS detail,
                   she.observed_at
            FROM system_health_events she
            JOIN systems s ON s.id = she.system_id
            WHERE she.status IN ('offline','degraded')
        ) u
        ORDER BY u.observed_at DESC, u.id DESC
        LIMIT 10
        """
    )]

    camera_rows = [dict(r) for r in await conn.fetch(
        """
        SELECT agg.camera_id, c.name, s.name AS system_name, c.status::text AS status,
               agg.face_count, agg.confidence::float8 AS confidence
        FROM (
            SELECT so.camera_id,
                   count(*) AS face_count,
                   COALESCE(avg(so.face_quality_score), 0) AS confidence
            FROM subject_observations so
            WHERE so.camera_id IS NOT NULL
              AND so.observed_at >= now() - make_interval(secs => $1)
            GROUP BY so.camera_id
            ORDER BY face_count DESC
            LIMIT 6
        ) agg
        JOIN cameras c ON c.id = agg.camera_id
        JOIN systems s ON s.id = c.system_id
        """,
        _HEALTH_WINDOW_SECS,
    )]

    return {
        "fleet": fleet,
        "org_count": org_count,
        "active_count": active_count,
        "active_runs": active_runs,
        "recent_failed_runs": recent_failed_runs,
        "recent_health_drops": recent_health_drops,
        "camera_rows": camera_rows,
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_dashboard.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the route in main.py**

In `/Users/jn/code/mras-ops/api/src/main.py`, add to the import block (next to `from src.projector.status import get_projector_status`):

```python
from src.godview.dashboard import get_dashboard
```

Add a route (place it just above the `@app.get("/projector/status")` handler):

```python
@app.get("/god-view/dashboard")
async def god_view_dashboard():
    async with _db.acquire() as conn:
        return await get_dashboard(conn)
```

- [ ] **Step 6: Commit (delegate to git-flow-manager)**

Delegate: stage `api/src/godview/dashboard.py`, `api/tests/test_godview_dashboard.py`, `api/src/main.py`; commit:
```
feat: GET /god-view/dashboard — fleet counts + bounded active/failure/reading rows
```

---

### Task 3: `GET /god-view/ad-runs` (list + filters) and `GET /god-view/ad-runs/filters`

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/godview/ad_runs.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_ad_runs.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (import + 2 routes)

**Interfaces:**
- Consumes: `encode_cursor`, `decode_cursor` from `src.godview.paging`.
- Produces:
  - `async def get_ad_runs(conn, *, status=None, system_id=None, campaign_id=None, since=None, cursor=None, limit=50) -> dict` → `{"items": [...], "next_cursor": str|None}`. Each item: `{id,status,started_at,system_id,system_name,location_name,campaign_id,campaign_name,stage_decision,stage_composition,stage_playback}`. Ordered by `(created_at DESC, id DESC)`; keyset cursor on `(created_at, id)`.
  - `async def get_ad_run_filters(conn) -> dict` → `{"systems": [{"id","name"}], "campaigns": [{"id","name"}]}` (only those referenced by ad_runs).

- [ ] **Step 1: Write the failing test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_ad_runs.py`:

```python
"""God View ad-runs list: server-side filter + keyset pagination + stage flags."""
import uuid

from src.godview.ad_runs import get_ad_runs, get_ad_run_filters


async def _org_loc_sys(pool, sys_name="Sys1"):
    org, loc, sid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await pool.execute("INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','advertiser')", org)
    await pool.execute("INSERT INTO locations (id,name,location_type) VALUES ($1,'Loc','store')", loc)
    await pool.execute("INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,$4)", sid, org, loc, sys_name)
    return org, loc, sid


async def _campaign(pool, org, name):
    cid = uuid.uuid4()
    await pool.execute("INSERT INTO campaigns (id,organization_id,name) VALUES ($1,$2,$3)", cid, org, name)
    return cid


async def test_filter_by_system(projector_pool):
    org, loc, s1 = await _org_loc_sys(projector_pool, "Sys1")
    _, _, s2 = await _org_loc_sys(projector_pool, "Sys2")
    await projector_pool.execute("INSERT INTO ad_runs (trigger_id,system_id,status) VALUES ($1,$2,'playing')", uuid.uuid4(), s1)
    await projector_pool.execute("INSERT INTO ad_runs (trigger_id,system_id,status) VALUES ($1,$2,'playing')", uuid.uuid4(), s2)
    page = await get_ad_runs(projector_pool, system_id=s1)
    assert len(page["items"]) == 1
    assert page["items"][0]["system_name"] == "Sys1"


async def test_stage_flags_reflect_pipeline(projector_pool):
    org, loc, sid = await _org_loc_sys(projector_pool)
    trig = uuid.uuid4()
    dec = uuid.uuid4()
    comp = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO personalization_decisions (id,trigger_id,event_id,decision_type) VALUES ($1,$2, nextval('events_id_seq'), 'identity')",
        dec, trig)
    await projector_pool.execute("INSERT INTO composition_runs (id,trigger_id,status) VALUES ($1,$2,'rendered')", comp, trig)
    run = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO ad_runs (id,trigger_id,system_id,personalization_decision_id,composition_run_id,status) "
        "VALUES ($1,$2,$3,$4,$5,'playing')", run, trig, sid, dec, comp)
    await projector_pool.execute(
        "INSERT INTO playbacks (ad_run_id,trigger_id,screen_id,status) VALUES ($1,$2,'scr_p','ended')", run, trig)
    page = await get_ad_runs(projector_pool)
    item = next(i for i in page["items"] if str(i["id"]) == str(run))
    assert item["stage_decision"] is True
    assert item["stage_composition"] is True
    assert item["stage_playback"] is True


async def test_keyset_pagination_no_overlap(projector_pool):
    org, loc, sid = await _org_loc_sys(projector_pool)
    for _ in range(5):
        await projector_pool.execute("INSERT INTO ad_runs (trigger_id,system_id,status) VALUES ($1,$2,'playing')", uuid.uuid4(), sid)
    p1 = await get_ad_runs(projector_pool, limit=2)
    assert len(p1["items"]) == 2
    assert p1["next_cursor"] is not None
    p2 = await get_ad_runs(projector_pool, limit=2, cursor=p1["next_cursor"])
    ids1 = {str(i["id"]) for i in p1["items"]}
    ids2 = {str(i["id"]) for i in p2["items"]}
    assert ids1.isdisjoint(ids2)
    assert len(p2["items"]) == 2


async def test_filters_list_only_referenced(projector_pool):
    org, loc, sid = await _org_loc_sys(projector_pool, "SysUsed")
    cid = await _campaign(projector_pool, org, "CampUsed")
    await _campaign(projector_pool, org, "CampUnused")
    await projector_pool.execute(
        "INSERT INTO ad_runs (trigger_id,system_id,campaign_id,status) VALUES ($1,$2,$3,'playing')", uuid.uuid4(), sid, cid)
    f = await get_ad_run_filters(projector_pool)
    assert [s["name"] for s in f["systems"]] == ["SysUsed"]
    assert [c["name"] for c in f["campaigns"]] == ["CampUsed"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_ad_runs.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview.ad_runs'`.

- [ ] **Step 3: Implement the ad-runs helpers**

Create `/Users/jn/code/mras-ops/api/src/godview/ad_runs.py`:

```python
"""God View composition-activity list + filter options.

Server does the filtering and keyset pagination (unbounded over ad_runs); the
client adRunCards selector maps the returned page. Pagination orders by
(created_at, id) — created_at is NOT NULL and monotonic, so the cursor is stable.
"""
from src.godview.paging import encode_cursor, decode_cursor


async def get_ad_runs(conn, *, status=None, system_id=None, campaign_id=None,
                      since=None, cursor=None, limit=50) -> dict:
    cur_ts, cur_id = decode_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT ar.id, ar.status::text AS status, ar.started_at, ar.created_at,
               ar.system_id, s.name AS system_name, l.name AS location_name,
               ar.campaign_id, cmp.name AS campaign_name,
               (ar.personalization_decision_id IS NOT NULL) AS stage_decision,
               (cr.status IN ('selected','rendered'))       AS stage_composition,
               EXISTS (SELECT 1 FROM playbacks p WHERE p.ad_run_id = ar.id AND p.status = 'ended') AS stage_playback
        FROM ad_runs ar
        LEFT JOIN systems s   ON s.id = ar.system_id
        LEFT JOIN locations l ON l.id = ar.location_id
        LEFT JOIN campaigns cmp ON cmp.id = ar.campaign_id
        LEFT JOIN composition_runs cr ON cr.id = ar.composition_run_id
        WHERE ($1::ad_run_status IS NULL OR ar.status = $1::ad_run_status)
          AND ($2::uuid IS NULL OR ar.system_id = $2::uuid)
          AND ($3::uuid IS NULL OR ar.campaign_id = $3::uuid)
          AND ($4::timestamptz IS NULL OR ar.created_at >= $4::timestamptz)
          AND ($5::timestamptz IS NULL OR (ar.created_at, ar.id) < ($5::timestamptz, $6::uuid))
        ORDER BY ar.created_at DESC, ar.id DESC
        LIMIT $7
        """,
        status, system_id, campaign_id, since, cur_ts, cur_id, limit + 1,
    )
    items = [dict(r) for r in rows[:limit]]
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = encode_cursor(last["created_at"], last["id"])
    for it in items:
        it.pop("created_at", None)  # internal ordering key, not part of the contract
    return {"items": items, "next_cursor": next_cursor}


async def get_ad_run_filters(conn) -> dict:
    systems = [dict(r) for r in await conn.fetch(
        "SELECT DISTINCT s.id, s.name FROM systems s JOIN ad_runs ar ON ar.system_id = s.id ORDER BY s.name")]
    campaigns = [dict(r) for r in await conn.fetch(
        "SELECT DISTINCT c.id, c.name FROM campaigns c JOIN ad_runs ar ON ar.campaign_id = c.id ORDER BY c.name")]
    return {"systems": systems, "campaigns": campaigns}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_ad_runs.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the routes in main.py**

Add import: `from src.godview.ad_runs import get_ad_runs, get_ad_run_filters`.

Add routes (above `/projector/status`). Note: the fixed `/god-view/ad-runs/filters` route MUST be declared BEFORE the parameterized `/god-view/ad-runs/{ad_run_id}` route (Task 4) so it is matched first.

```python
@app.get("/god-view/ad-runs")
async def god_view_ad_runs(status: str | None = None, system_id: str | None = None,
                           campaign_id: str | None = None, since: str | None = None,
                           cursor: str | None = None, limit: int = 50):
    from datetime import datetime
    limit = max(1, min(limit, 100))
    since_ts = datetime.fromisoformat(since) if since else None
    async with _db.acquire() as conn:
        return await get_ad_runs(conn, status=status, system_id=system_id,
                                 campaign_id=campaign_id, since=since_ts,
                                 cursor=cursor, limit=limit)


@app.get("/god-view/ad-runs/filters")
async def god_view_ad_run_filters():
    async with _db.acquire() as conn:
        return await get_ad_run_filters(conn)
```

- [ ] **Step 6: Commit (delegate to git-flow-manager)**

Delegate: stage `api/src/godview/ad_runs.py`, `api/tests/test_godview_ad_runs.py`, `api/src/main.py`; commit:
```
feat: GET /god-view/ad-runs (filtered, keyset-paginated) + /ad-runs/filters
```

---

### Task 4: `GET /god-view/ad-runs/{ad_run_id}` (detail)

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/godview/ad_runs.py` (add `get_ad_run`)
- Modify: `/Users/jn/code/mras-ops/api/tests/test_godview_ad_runs.py` (add test)
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (add route)

**Interfaces:**
- Produces: `async def get_ad_run(conn, ad_run_id) -> dict | None` → `None` if the ad_run does not exist, else `{"ad_run": {...}, "personalization_decision": {...}|None, "composition_run": {...}|None, "playbacks": [...]}`. Selected columns must include everything the client `adRunGraph` reads: on `ad_run` — `id,trigger_id,status,started_at,ended_at,system_id`; on `personalization_decision` — `id,decision_type,decision_confidence,decision_factors`; on `composition_run` — `id,render_mode,status,error_code,error_message,used_likeness,used_voice_clone`; on each `playback` — `id,status,display_id,screen_id,error_code,error_message`.

- [ ] **Step 1: Write the failing test**

Append to `/Users/jn/code/mras-ops/api/tests/test_godview_ad_runs.py`:

```python
from src.godview.ad_runs import get_ad_run


async def test_ad_run_detail_bundles_pipeline(projector_pool):
    org, loc, sid = await _org_loc_sys(projector_pool)
    trig = uuid.uuid4()
    dec = uuid.uuid4()
    comp = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO personalization_decisions (id,trigger_id,event_id,decision_type,decision_confidence,decision_factors) "
        "VALUES ($1,$2, nextval('events_id_seq'), 'identity', 0.91, '{\"k\":\"v\"}'::jsonb)", dec, trig)
    await projector_pool.execute(
        "INSERT INTO composition_runs (id,trigger_id,render_mode,status,error_code) VALUES ($1,$2,'template_overlay','failed','OVERLAY_RENDER_TIMEOUT')",
        comp, trig)
    run = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO ad_runs (id,trigger_id,system_id,personalization_decision_id,composition_run_id,status) "
        "VALUES ($1,$2,$3,$4,$5,'failed')", run, trig, sid, dec, comp)
    await projector_pool.execute(
        "INSERT INTO playbacks (ad_run_id,trigger_id,screen_id,status) VALUES ($1,$2,'scr_p','failed')", run, trig)

    d = await get_ad_run(projector_pool, run)
    assert str(d["ad_run"]["id"]) == str(run)
    assert d["personalization_decision"]["decision_type"] == "identity"
    assert d["composition_run"]["error_code"] == "OVERLAY_RENDER_TIMEOUT"
    assert len(d["playbacks"]) == 1


async def test_ad_run_detail_missing_returns_none(projector_pool):
    assert await get_ad_run(projector_pool, uuid.uuid4()) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_ad_runs.py -k detail -v`
Expected: FAIL — `ImportError: cannot import name 'get_ad_run'`.

- [ ] **Step 3: Implement `get_ad_run`**

Append to `/Users/jn/code/mras-ops/api/src/godview/ad_runs.py`:

```python
async def get_ad_run(conn, ad_run_id) -> dict | None:
    ar = await conn.fetchrow(
        "SELECT id,trigger_id,status::text AS status,started_at,ended_at,system_id FROM ad_runs WHERE id = $1",
        ad_run_id)
    if ar is None:
        return None
    dec = await conn.fetchrow(
        """SELECT id, decision_type::text AS decision_type, decision_confidence, decision_factors
           FROM personalization_decisions
           WHERE id = (SELECT personalization_decision_id FROM ad_runs WHERE id = $1)""",
        ad_run_id)
    comp = await conn.fetchrow(
        """SELECT id, render_mode::text AS render_mode, status::text AS status,
                  error_code, error_message, used_likeness, used_voice_clone
           FROM composition_runs
           WHERE id = (SELECT composition_run_id FROM ad_runs WHERE id = $1)""",
        ad_run_id)
    plays = await conn.fetch(
        "SELECT id, status::text AS status, display_id, screen_id, error_code, error_message "
        "FROM playbacks WHERE ad_run_id = $1 ORDER BY created_at",
        ad_run_id)

    def _jsonb(row, field):
        import json
        d = dict(row)
        if isinstance(d.get(field), str):
            d[field] = json.loads(d[field])
        return d

    return {
        "ad_run": dict(ar),
        "personalization_decision": _jsonb(dec, "decision_factors") if dec else None,
        "composition_run": dict(comp) if comp else None,
        "playbacks": [dict(p) for p in plays],
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_ad_runs.py -v`
Expected: PASS (all ad-runs tests).

- [ ] **Step 5: Wire the route in main.py**

Add import to the existing ad_runs import line: `from src.godview.ad_runs import get_ad_runs, get_ad_run_filters, get_ad_run`.

Add route (must be declared AFTER `/god-view/ad-runs/filters`):

```python
@app.get("/god-view/ad-runs/{ad_run_id}")
async def god_view_ad_run(ad_run_id: str):
    async with _db.acquire() as conn:
        result = await get_ad_run(conn, ad_run_id)
    if result is None:
        raise HTTPException(status_code=404, detail="ad_run not found")
    return result
```

- [ ] **Step 6: Commit (delegate to git-flow-manager)**

Delegate: stage `api/src/godview/ad_runs.py`, `api/tests/test_godview_ad_runs.py`, `api/src/main.py`; commit:
```
feat: GET /god-view/ad-runs/{id} — pipeline detail for the ad-detail graph
```

---

### Task 5: `GET /god-view/systems` (list + counts) and `GET /god-view/systems/{id}` (drill-down)

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/godview/systems.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_systems.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (import + 2 routes)

**Interfaces:**
- Consumes: `encode_cursor`, `decode_cursor` from `src.godview.paging`; `readings_for_system` from `src.godview.readings`.
- Produces:
  - `async def get_systems(conn, *, search=None, cursor=None, limit=50) -> dict` → `{"counts": {"total_systems","active_systems","unresolved_devices"}, "items": [{id,name,org_name,location_name,system_type,status,device_count}], "next_cursor": str|None}`. Ordered by `(name ASC, id ASC)`; keyset cursor on `(name, id)`.
  - `async def get_system(conn, system_id) -> dict | None` → `None` if missing, else `{"system": {...}, "screen_groups": [{id,name,group_type}], "cameras": [{id,name,status,screen_group_id,face_count,confidence}], "displays": [{id,name,status,screen_id,screen_group_id}]}`.

- [ ] **Step 1: Write the failing test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_systems.py`:

```python
"""God View systems list (counts + search + keyset) and drill-down."""
import uuid

from src.godview.systems import get_systems, get_system


async def _org_loc(pool):
    org, loc = uuid.uuid4(), uuid.uuid4()
    await pool.execute("INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Acme','advertiser')", org)
    await pool.execute("INSERT INTO locations (id,name,location_type) VALUES ($1,'Mall','mall')", loc)
    return org, loc


async def _sys(pool, org, loc, name, status="active"):
    sid = uuid.uuid4()
    await pool.execute("INSERT INTO systems (id,organization_id,location_id,name,status) VALUES ($1,$2,$3,$4,$5)",
                       sid, org, loc, name, status)
    return sid


async def test_counts_and_device_rollup(projector_pool):
    org, loc = await _org_loc(projector_pool)
    s1 = await _sys(projector_pool, org, loc, "Alpha", "active")
    await _sys(projector_pool, org, loc, "Beta", "degraded")
    await projector_pool.execute("INSERT INTO cameras (id,system_id,name,screen_id) VALUES ($1,$2,'C','scr_c1')", uuid.uuid4(), s1)
    await projector_pool.execute("INSERT INTO displays (id,system_id,screen_id) VALUES ($1,$2,'scr_d1')", uuid.uuid4(), s1)
    await projector_pool.execute("INSERT INTO unresolved_devices (screen_id,kind) VALUES ('scr_ghost','display')")

    page = await get_systems(projector_pool)
    assert page["counts"]["total_systems"] == 2
    assert page["counts"]["active_systems"] == 1
    assert page["counts"]["unresolved_devices"] == 1
    alpha = next(i for i in page["items"] if i["name"] == "Alpha")
    assert alpha["device_count"] == 2
    assert alpha["org_name"] == "Acme"
    assert alpha["location_name"] == "Mall"


async def test_search_filters_by_name(projector_pool):
    org, loc = await _org_loc(projector_pool)
    await _sys(projector_pool, org, loc, "Lobby One")
    await _sys(projector_pool, org, loc, "Bay Two")
    page = await get_systems(projector_pool, search="lobby")
    assert [i["name"] for i in page["items"]] == ["Lobby One"]


async def test_keyset_pagination_by_name(projector_pool):
    org, loc = await _org_loc(projector_pool)
    for n in ("Aaa", "Bbb", "Ccc"):
        await _sys(projector_pool, org, loc, n)
    p1 = await get_systems(projector_pool, limit=2)
    assert [i["name"] for i in p1["items"]] == ["Aaa", "Bbb"]
    assert p1["next_cursor"] is not None
    p2 = await get_systems(projector_pool, limit=2, cursor=p1["next_cursor"])
    assert [i["name"] for i in p2["items"]] == ["Ccc"]


async def test_drilldown_groups_devices(projector_pool):
    org, loc = await _org_loc(projector_pool)
    sid = await _sys(projector_pool, org, loc, "Alpha")
    grp = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO screen_groups (id,system_id,name,group_type) VALUES ($1,$2,'Wall A','ad_cluster')", grp, sid)
    await projector_pool.execute(
        "INSERT INTO cameras (id,system_id,screen_group_id,name,screen_id) VALUES ($1,$2,$3,'C1','scr_c1')", uuid.uuid4(), sid, grp)
    await projector_pool.execute(
        "INSERT INTO displays (id,system_id,screen_group_id,screen_id) VALUES ($1,$2,$3,'scr_d1')", uuid.uuid4(), sid, grp)

    d = await get_system(projector_pool, sid)
    assert d["system"]["name"] == "Alpha"
    assert len(d["screen_groups"]) == 1
    assert d["cameras"][0]["screen_group_id"] == grp
    assert "face_count" in d["cameras"][0]
    assert d["displays"][0]["screen_id"] == "scr_d1"


async def test_drilldown_missing_returns_none(projector_pool):
    assert await get_system(projector_pool, uuid.uuid4()) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_systems.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview.systems'`.

- [ ] **Step 3: Implement the systems helpers**

Create `/Users/jn/code/mras-ops/api/src/godview/systems.py`:

```python
"""God View systems list (server counts + search + keyset) and per-system drill-down.

Counting devices and systems is unbounded, so it happens in SQL; the client
systemsWithRollup/systemsKpis selectors map the returned page/counts. Drill-down
is fetched on demand (one system's devices), so its readings use readings_for_system.
"""
from src.godview.paging import encode_cursor, decode_cursor
from src.godview.readings import readings_for_system


async def get_systems(conn, *, search=None, cursor=None, limit=50) -> dict:
    total = await conn.fetchval("SELECT count(*) FROM systems")
    active = await conn.fetchval("SELECT count(*) FROM systems WHERE status = 'active'")
    unresolved = await conn.fetchval("SELECT count(*) FROM unresolved_devices")

    cur_name, cur_id = decode_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT s.id, s.name, o.name AS org_name, l.name AS location_name,
               s.system_type::text AS system_type, s.status::text AS status,
               (SELECT count(*) FROM cameras c  WHERE c.system_id  = s.id)
             + (SELECT count(*) FROM displays d WHERE d.system_id = s.id) AS device_count
        FROM systems s
        LEFT JOIN organizations o ON o.id = s.organization_id
        LEFT JOIN locations l     ON l.id = s.location_id
        WHERE ($1::text IS NULL
               OR s.name ILIKE '%' || $1 || '%'
               OR o.name ILIKE '%' || $1 || '%'
               OR l.name ILIKE '%' || $1 || '%')
          AND ($2::text IS NULL OR (s.name, s.id) > ($2::text, $3::uuid))
        ORDER BY s.name ASC, s.id ASC
        LIMIT $4
        """,
        search, cur_name, cur_id, limit + 1,
    )
    items = [dict(r) for r in rows[:limit]]
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = encode_cursor_name(last["name"], last["id"])
    return {
        "counts": {"total_systems": total, "active_systems": active, "unresolved_devices": unresolved},
        "items": items,
        "next_cursor": next_cursor,
    }


def encode_cursor_name(name: str, row_id) -> str:
    return f"{name}|{row_id}"


async def get_system(conn, system_id) -> dict | None:
    system = await conn.fetchrow(
        "SELECT id,name,status::text AS status,system_type::text AS system_type FROM systems WHERE id = $1",
        system_id)
    if system is None:
        return None
    groups = await conn.fetch(
        "SELECT id,name,group_type::text AS group_type FROM screen_groups WHERE system_id = $1 ORDER BY name",
        system_id)
    readings = await readings_for_system(conn, system_id)
    cams = await conn.fetch(
        "SELECT id,name,status::text AS status,screen_group_id FROM cameras WHERE system_id = $1 ORDER BY name",
        system_id)
    displays = await conn.fetch(
        "SELECT id,name,status::text AS status,screen_id,screen_group_id FROM displays WHERE system_id = $1 ORDER BY name",
        system_id)
    cameras = []
    for c in cams:
        d = dict(c)
        r = readings.get(str(c["id"]), {"face_count": 0, "confidence": 0.0})
        d["face_count"] = r["face_count"]
        d["confidence"] = r["confidence"]
        cameras.append(d)
    return {
        "system": dict(system),
        "screen_groups": [dict(g) for g in groups],
        "cameras": cameras,
        "displays": [dict(x) for x in displays],
    }
```

Note: `get_systems` decodes the cursor with the shared `decode_cursor` (which splits on `|`) but encodes with a name-based `encode_cursor_name` because this endpoint's sort key is `(name, id)`, not `(timestamp, id)`. `decode_cursor` returns `(name_str, uuid)` here — the first element is treated as text in the `$2::text` comparison, which is correct.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_systems.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Wire the routes in main.py**

Add import: `from src.godview.systems import get_systems, get_system`.

Add routes (fixed-then-parameterized ordering; place above `/projector/status`):

```python
@app.get("/god-view/systems")
async def god_view_systems(search: str | None = None, cursor: str | None = None, limit: int = 50):
    limit = max(1, min(limit, 100))
    async with _db.acquire() as conn:
        return await get_systems(conn, search=search, cursor=cursor, limit=limit)


@app.get("/god-view/systems/{system_id}")
async def god_view_system(system_id: str):
    async with _db.acquire() as conn:
        result = await get_system(conn, system_id)
    if result is None:
        raise HTTPException(status_code=404, detail="system not found")
    return result
```

- [ ] **Step 6: Commit (delegate to git-flow-manager)**

Delegate: stage `api/src/godview/systems.py`, `api/tests/test_godview_systems.py`, `api/src/main.py`; commit:
```
feat: GET /god-view/systems (counts+search+keyset) and /systems/{id} drill-down
```

---

### Task 6: `GET /god-view/events` (paginated unified health log)

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/godview/events.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_godview_events.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (import + route)

**Interfaces:**
- Consumes: `encode_cursor`, `decode_cursor` from `src.godview.paging`.
- Produces: `async def get_events(conn, *, cursor=None, limit=50) -> dict` → `{"items": [{id,kind,ref_id,ref_name,status,detail,observed_at}], "next_cursor": str|None}`. UNION of `device_health_events` + `system_health_events`, newest first, keyset on `(observed_at, id)`.

- [ ] **Step 1: Write the failing test**

Create `/Users/jn/code/mras-ops/api/tests/test_godview_events.py`:

```python
"""God View unified health-event log, keyset paginated newest-first."""
import uuid

from src.godview.events import get_events


async def _system(pool, name="Sys1"):
    org, loc, sid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await pool.execute("INSERT INTO organizations (id,name,organization_type) VALUES ($1,'Org','advertiser')", org)
    await pool.execute("INSERT INTO locations (id,name,location_type) VALUES ($1,'Loc','store')", loc)
    await pool.execute("INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,$4)", sid, org, loc, name)
    return sid


async def test_unifies_and_serializes_detail_string(projector_pool):
    sid = await _system(projector_pool)
    await projector_pool.execute(
        "INSERT INTO system_health_events (system_id,status,detail,observed_at) "
        "VALUES ($1,'degraded', '{\"message\":\"cpu high\"}'::jsonb, now())", sid)
    page = await get_events(projector_pool)
    assert page["items"][0]["kind"] == "system"
    assert page["items"][0]["ref_name"] == "Sys1"
    assert page["items"][0]["detail"] == "cpu high"


async def test_keyset_orders_newest_first_no_overlap(projector_pool):
    sid = await _system(projector_pool)
    for i in range(3):
        await projector_pool.execute(
            "INSERT INTO system_health_events (system_id,status,detail,observed_at) "
            "VALUES ($1,'active', '{}'::jsonb, now() - make_interval(secs => $2))", sid, i)
    p1 = await get_events(projector_pool, limit=2)
    assert len(p1["items"]) == 2
    assert p1["next_cursor"] is not None
    # newest first: item0.observed_at >= item1.observed_at
    assert p1["items"][0]["observed_at"] >= p1["items"][1]["observed_at"]
    p2 = await get_events(projector_pool, limit=2, cursor=p1["next_cursor"])
    ids1 = {str(i["id"]) for i in p1["items"]}
    ids2 = {str(i["id"]) for i in p2["items"]}
    assert ids1.isdisjoint(ids2)
    assert len(p2["items"]) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_events.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.godview.events'`.

- [ ] **Step 3: Implement the events helper**

Create `/Users/jn/code/mras-ops/api/src/godview/events.py`:

```python
"""God View unified health/event log.

UNION of device + system health events into the prototype's LogRow shape, newest
first, keyset paginated on (observed_at, id). Device events resolve a friendly
name from the projected camera/display; jsonb detail becomes a display string.
"""
from src.godview.paging import encode_cursor, decode_cursor


async def get_events(conn, *, cursor=None, limit=50) -> dict:
    cur_ts, cur_id = decode_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT * FROM (
            SELECT 'device' AS kind, dhe.id, dhe.device_id AS ref_id,
                   COALESCE(cam.name, disp.name, dhe.device_id::text) AS ref_name,
                   dhe.status::text AS status,
                   COALESCE(dhe.detail->>'message', dhe.detail::text) AS detail,
                   dhe.observed_at
            FROM device_health_events dhe
            LEFT JOIN cameras cam  ON cam.device_id  = dhe.device_id
            LEFT JOIN displays disp ON disp.device_id = dhe.device_id
            UNION ALL
            SELECT 'system' AS kind, she.id, she.system_id AS ref_id,
                   s.name AS ref_name, she.status::text AS status,
                   COALESCE(she.detail->>'message', she.detail::text) AS detail,
                   she.observed_at
            FROM system_health_events she
            JOIN systems s ON s.id = she.system_id
        ) u
        WHERE ($1::timestamptz IS NULL OR (u.observed_at, u.id) < ($1::timestamptz, $2::uuid))
        ORDER BY u.observed_at DESC, u.id DESC
        LIMIT $3
        """,
        cur_ts, cur_id, limit + 1,
    )
    items = [dict(r) for r in rows[:limit]]
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = encode_cursor(last["observed_at"], last["id"])
    return {"items": items, "next_cursor": next_cursor}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_events.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the route in main.py**

Add import: `from src.godview.events import get_events`.

Add route (above `/projector/status`):

```python
@app.get("/god-view/events")
async def god_view_events(cursor: str | None = None, limit: int = 50):
    limit = max(1, min(limit, 100))
    async with _db.acquire() as conn:
        return await get_events(conn, cursor=cursor, limit=limit)
```

- [ ] **Step 6: Run the whole God View suite + commit**

Run: `cd /Users/jn/code/mras-ops/api && pytest tests/test_godview_paging.py tests/test_godview_readings.py tests/test_godview_dashboard.py tests/test_godview_ad_runs.py tests/test_godview_systems.py tests/test_godview_events.py -v`
Expected: all PASS.

Delegate: stage `api/src/godview/events.py`, `api/tests/test_godview_events.py`, `api/src/main.py`; commit:
```
feat: GET /god-view/events — paginated unified health log
```

Then open a PR targeting `main`:
- Title: `feat: God View read endpoints (dashboard, ad-runs, systems, events)`
- Body sections: Summary (scale-safe read API for the godview-prototype), Endpoints (the 7 routes), Tests (helper-level against throwaway Postgres, counts/filters/keyset asserted), Risks (read-only, unscoped per deferred auth; no schema change).
- Do NOT merge; report the PR number.

---

## Self-Review

- **Spec coverage:** §4.1 dashboard → Task 2; §4.2 ad-runs list → Task 3; §4.3 filters → Task 3; §4.4 systems list+counts → Task 5; §4.5 drill-down → Task 5; §4.6 events → Task 6; §4.7 ad-run detail → Task 4; `/projector/status` reuse needs no backend work (already exists). Cursor helper (§Global Constraints) → Task 1. camera_readings derivation (§4.1) → Task 1 helper + inline in Task 2.
- **Placeholder scan:** none — every helper and test is literal. `since` parsing uses `datetime.fromisoformat` in the route.
- **Type consistency:** `encode_cursor`/`decode_cursor` used consistently; systems endpoint documents its name-keyed cursor variant (`encode_cursor_name`) and why `decode_cursor`'s tuple is reused. `readings_for_system` returns `{camera_str: {face_count, confidence}}` and is consumed that way in `get_system`. All status columns cast `::text`. Route ordering note (fixed `/filters` before `/{ad_run_id}`) is called out in Tasks 3 and 4.
- **Route registration risk:** all God View routes are added above `/projector/status`; `HTTPException` is already imported in `main.py`.
