# Plan K — Remotion Source: Backend (mras-ops) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the uploaded Remotion `.tsx` source in Postgres and expose it (plus creative metadata) through `GET /god-view/ad-runs/:id` so god view can render it inside the Composition node.

**Architecture:** Three surgical changes in `mras-ops`: (1) migration `029` adds a nullable `source text` column to `components`; (2) `POST /components` stores the already-in-hand source string in its existing INSERT; (3) `get_ad_run()`'s composition query LEFT JOINs `components` and `ads` so `composition_run` carries `source`, `component_slug`, `props_schema`, `default_props`, `personalized_field`, `base_video` (all nullable). No new endpoints, no sidecar changes.

**Tech Stack:** PostgreSQL (asyncpg), FastAPI, pytest with the throwaway-DB fixture in `/Users/jn/code/mras-ops/api/tests/conftest.py` (applies every `db/migrations/*.sql` in sorted order — a new `029` file is picked up automatically).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-17-remotion-source-node.md`

## Global Constraints

- Work in a dedicated worktree branch of `mras-ops` under `.claude/worktrees/` (e.g. `feat/remotion-source-backend`). Implementers start every session with `cd <worktree> && pwd`; the bare checkout `/Users/jn/code/mras-ops` is READ-ONLY reference.
- **Implementers never run git.** Each red test and its green implementation are committed as SEPARATE commits by the `git-flow-manager` subagent (stage test file → commit; stage impl file → commit). Commit steps below name the files and messages.
- Tests require the dockerized Postgres: `cd /Users/jn/code/mras-ops && docker compose up -d postgres` (run once before Task 1).
- Test command shape (from the worktree's `api/` directory): `python3 -m pytest tests/test_components_source.py -v`. Baseline sanity first: `python3 -m pytest tests/test_godview_ad_runs.py -v` must pass before any change.
- Response contract: new fields are ADDITIVE and nullable; existing `composition_run` keys are unchanged (frontend fixture compatibility).
- All file references in commits/PRs use absolute paths.

---

### Task 1 (K1): Migration 029 — `components.source` column

**Files:**
- Create: `db/migrations/029_component_source.sql` (worktree-relative; bare-repo reference `/Users/jn/code/mras-ops/db/migrations/`)
- Test: `api/tests/test_components_source.py` (new file)

**Interfaces:**
- Produces: nullable `components.source text` column — Tasks K2/K3 read and write it.

- [ ] **Step 1: Verify baseline is green**

Run (from worktree `api/`): `python3 -m pytest tests/test_godview_ad_runs.py -v`
Expected: all PASS. If Postgres is down: `cd <worktree root> && docker compose up -d postgres` first.

- [ ] **Step 2: Write the failing test**

Create `api/tests/test_components_source.py`:

```python
"""Component source persistence: migration 029 + ingest storage + god-view exposure.

Spec: /Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-17-remotion-source-node.md
"""
import uuid

import pytest

pytestmark = pytest.mark.usefixtures("godview_isolate")

SOURCE = 'export const Hello = ({name}) => <div className="hi">{name}</div>;'


async def test_components_source_column_persists(projector_pool):
    slug = f"comp-{uuid.uuid4()}"
    await projector_pool.execute(
        "INSERT INTO components (name, slug, source) VALUES ('C', $1, $2)", slug, SOURCE)
    assert await projector_pool.fetchval(
        "SELECT source FROM components WHERE slug = $1", slug) == SOURCE
```

- [ ] **Step 3: Run test to verify it fails**

Run: `python3 -m pytest tests/test_components_source.py -v`
Expected: FAIL with `UndefinedColumnError: column "source" of relation "components" does not exist`

- [ ] **Step 4: Commit the red test** (via git-flow-manager)

Stage only `api/tests/test_components_source.py`.
Message: `test: components.source column persists uploaded Remotion source (red)`

- [ ] **Step 5: Write the migration**

Create `db/migrations/029_component_source.sql`:

```sql
-- 029: persist the raw Remotion .tsx uploaded via POST /components so god view
-- can display it inside the Composition node. Nullable: components ingested
-- before this migration have no stored source (re-ingest to populate).
ALTER TABLE components ADD COLUMN source text;
```

- [ ] **Step 6: Run test to verify it passes**

Run: `python3 -m pytest tests/test_components_source.py -v`
Expected: PASS (conftest applies `029_*.sql` automatically — module-scoped fixture builds a fresh DB, so a plain re-run picks it up).

- [ ] **Step 7: Commit the green implementation** (via git-flow-manager)

Stage only `db/migrations/029_component_source.sql`.
Message: `feat: migration 029 — components.source column for Remotion .tsx (green)`

---

### Task 2 (K2): Persist source on ingest (`POST /components`)

**Files:**
- Modify: `api/src/main.py:68-79` (the `INSERT INTO components` inside `upload_component`)
- Test: `api/tests/test_components_source.py` (append)

**Interfaces:**
- Consumes: `components.source` column from Task K1; the existing `source` local variable in `upload_component` (`api/src/main.py:60`).
- Produces: every newly ingested/re-ingested component row has `source` populated (upsert overwrites on slug conflict).

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_components_source.py`:

```python
import io

from starlette.datastructures import UploadFile

import src.main as main


class _FakeResp:
    status_code = 200

    def __init__(self, slug):
        self._slug = slug

    def json(self):
        return {"slug": self._slug, "status": "ready", "error": None,
                "propsSchema": {"type": "object"}}


class _FakeSidecar:
    """Stands in for httpx.AsyncClient so no overlay sidecar is needed."""

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def post(self, url, json=None):
        return _FakeResp("comp-" + json["name"].lower())


async def test_upload_component_persists_source(projector_pool, monkeypatch):
    monkeypatch.setattr(main, "_db", projector_pool)
    monkeypatch.setattr(main.httpx, "AsyncClient", _FakeSidecar)
    name = f"hello{uuid.uuid4().hex[:8]}"
    upload = UploadFile(io.BytesIO(SOURCE.encode()), filename="Hello.tsx")
    resp = await main.upload_component(name=name, file=upload)
    assert await projector_pool.fetchval(
        "SELECT source FROM components WHERE slug = $1", resp["slug"]) == SOURCE
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/test_components_source.py::test_upload_component_persists_source -v`
Expected: FAIL with `assert None == 'export const Hello...'` (column exists, INSERT doesn't fill it). If it instead errors on `UploadFile(...)`, match the installed starlette signature — `UploadFile(file=io.BytesIO(...), filename=...)` on older versions.

- [ ] **Step 3: Commit the red test** (via git-flow-manager)

Stage only `api/tests/test_components_source.py`.
Message: `test: POST /components persists uploaded source (red)`

- [ ] **Step 4: Implement — add source to the INSERT**

In `api/src/main.py`, replace the `fetchrow` call (currently lines 68-79) with:

```python
    row = await _db.fetchrow(
        "INSERT INTO components (name, slug, status, error, props_schema, source) "
        "VALUES ($1,$2,$3,$4,$5::jsonb,$6) "
        "ON CONFLICT (slug) DO UPDATE SET status=EXCLUDED.status, "
        "error=EXCLUDED.error, props_schema=EXCLUDED.props_schema, source=EXCLUDED.source "
        "RETURNING id",
        name,
        body["slug"],
        body["status"],
        body.get("error"),
        json.dumps(body.get("propsSchema") or {}),
        source,
    )
```

(No other changes — the endpoint's response shape stays as-is.)

- [ ] **Step 5: Run the whole file to verify green**

Run: `python3 -m pytest tests/test_components_source.py -v`
Expected: both tests PASS.

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `api/src/main.py`.
Message: `feat: persist Remotion source on component ingest (green)`

---

### Task 3 (K3): Expose source + creative metadata in `GET /god-view/ad-runs/:id`

**Files:**
- Modify: `api/src/godview/ad_runs.py:69-76` (composition fetchrow) and `:114-120` (return assembly)
- Test: `api/tests/test_components_source.py` (append)

**Interfaces:**
- Consumes: `components.source` (K1). Joins `components` on `composition_runs.component_id` and `ads` on `composition_runs.ad_id`.
- Produces: `composition_run` response object gains `component_slug: str|None`, `source: str|None`, `props_schema: dict|None`, `default_props: dict|None`, `personalized_field: str|None`, `base_video: str|None`. Plan L's `apiTypes.ts` mirrors exactly these names.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/test_components_source.py`:

```python
from src.godview.ad_runs import get_ad_run


async def _seed_run_with_component(pool, *, with_ad=True):
    slug = f"comp-{uuid.uuid4()}"
    comp_id = await pool.fetchval(
        "INSERT INTO components (name, slug, source, props_schema) "
        "VALUES ('Comp', $1, $2, '{\"type\": \"object\"}'::jsonb) RETURNING id",
        slug, SOURCE)
    ad_id = None
    if with_ad:
        ad_id = await pool.fetchval(
            "INSERT INTO ads (name, base_video, component_id, default_props, personalized_field) "
            "VALUES ('Ad', 'base.mp4', $1, '{\"text\": \"Hello\"}'::jsonb, 'name') RETURNING id",
            comp_id)
    trig, cr, run = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await pool.execute(
        "INSERT INTO composition_runs (id, trigger_id, render_mode, status, ad_id, component_id) "
        "VALUES ($1, $2, 'remotion', 'rendered', $3, $4)", cr, trig, ad_id, comp_id)
    await pool.execute(
        "INSERT INTO ad_runs (id, trigger_id, composition_run_id, status) "
        "VALUES ($1, $2, $3, 'completed')", run, trig, cr)
    return run, slug


async def test_ad_run_detail_carries_component_source(projector_pool):
    run, slug = await _seed_run_with_component(projector_pool)
    d = await get_ad_run(projector_pool, run)
    cr = d["composition_run"]
    assert cr["source"] == SOURCE
    assert cr["component_slug"] == slug
    assert cr["props_schema"] == {"type": "object"}
    assert cr["default_props"] == {"text": "Hello"}
    assert cr["personalized_field"] == "name"
    assert cr["base_video"] == "base.mp4"
    # pre-existing keys still present
    assert cr["render_mode"] == "remotion"
    assert str(cr["component_id"])


async def test_ad_run_detail_null_safe_without_component(projector_pool):
    trig, cr_id, run = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO composition_runs (id, trigger_id, render_mode, status) "
        "VALUES ($1, $2, 'prebuilt', 'selected')", cr_id, trig)
    await projector_pool.execute(
        "INSERT INTO ad_runs (id, trigger_id, composition_run_id, status) "
        "VALUES ($1, $2, $3, 'completed')", run, trig, cr_id)
    d = await get_ad_run(projector_pool, run)
    cr = d["composition_run"]
    for field in ("source", "component_slug", "props_schema",
                  "default_props", "personalized_field", "base_video"):
        assert cr[field] is None
    assert cr["render_mode"] == "prebuilt"
```

Note: `ad_runs.status` values come from the `ad_run_status` enum; `'completed'` is used by existing fixtures. `ad_runs.system_id` is nullable (`db/migrations/015_runs.sql:72`) so no org/loc/system seeding is needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_components_source.py -v -k "detail"`
Expected: both FAIL with `KeyError: 'source'` (fields absent from today's response).

- [ ] **Step 3: Commit the red tests** (via git-flow-manager)

Stage only `api/tests/test_components_source.py`.
Message: `test: ad-run detail carries component source + creative metadata (red)`

- [ ] **Step 4: Implement — LEFT JOIN components/ads into the composition query**

In `api/src/godview/ad_runs.py`, replace the `comp = await conn.fetchrow(...)` block (currently lines 69-76) with:

```python
    comp = await conn.fetchrow(
        """SELECT cr.id, cr.render_mode::text AS render_mode, cr.status::text AS status,
                  cr.error_code, cr.error_message, cr.used_likeness, cr.used_voice_clone,
                  cr.ad_id, cr.component_id, cr.input_asset_id, cr.output_asset_id,
                  cr.used_spoken_name, cr.used_visible_name,
                  c.slug AS component_slug, c.source, c.props_schema,
                  a.default_props, a.personalized_field, a.base_video
           FROM composition_runs cr
           LEFT JOIN components c ON c.id = cr.component_id
           LEFT JOIN ads a ON a.id = cr.ad_id
           WHERE cr.id = (SELECT composition_run_id FROM ad_runs WHERE id = $1)""",
        ad_run_id)
```

Then in the return assembly (currently lines 114-120), replace
`"composition_run": dict(comp) if comp else None,` with a decoded version — asyncpg returns
jsonb as `str`, and `_jsonb` (defined just above the return) only decodes string values:

```python
    return {
        "ad_run": dict(ar),
        "personalization_decision": _jsonb(dec, "decision_factors") if dec else None,
        "composition_run": _jsonb(_jsonb(comp, "props_schema"), "default_props") if comp else None,
        "playbacks": [dict(p) for p in plays],
        "viewer_exposure": dict(exposure),
    }
```

(`_jsonb` accepts any mapping — it calls `dict()` on its argument — so chaining is safe, and
`None` jsonb values pass through untouched.)

- [ ] **Step 5: Run the full file + regression suite**

Run: `python3 -m pytest tests/test_components_source.py tests/test_godview_ad_runs.py -v`
Expected: all PASS (existing detail tests only assert on pre-existing keys — additive fields don't break them).

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `api/src/godview/ad_runs.py`.
Message: `feat: god-view ad-run detail joins component source + creative metadata (green)`

---

### Task 4 (K4): Dev-stack deployment + live verification (controller checklist — not a subagent task)

After the PR is review-approved and merged to `mras-ops@main`:

- [ ] Apply migration 029 to the EXISTING dev volume (init scripts only run on fresh DBs):
  `cd /Users/jn/code/mras-ops && docker compose exec -T postgres psql -U mras -d mras < db/migrations/029_component_source.sql`
  (If the dev DB name differs, read `POSTGRES_DB` in `/Users/jn/code/mras-ops/docker-compose.yml` and substitute.)
- [ ] Rebuild + restart the api: `docker compose up -d --build mras-ops-api`
- [ ] Re-ingest the demo Remotion component so its row has `source` (curl is guard-blocked — use Python httpx, e.g. `mras-vision/.venv/bin/python`): multipart POST to `http://localhost:8080/components` with `name` + the demo `.tsx` file (the sidecar copy lives at `mras-overlays` container path `src/custom/<slug>.tsx`; the original `.tsx` is in the repo/demo assets used at M4 ingest).
- [ ] Trigger a fresh remotion ad-run (existing demo trigger recipe in `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` Operational Reference), then GET `http://localhost:8080/god-view/ad-runs/<id>` via httpx and confirm `composition_run.source` is the `.tsx` text.
