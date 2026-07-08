# God View Real-Data Wiring — Design

**Date:** 2026-07-07
**Status:** Approved (design phase) — ready for implementation planning
**Scope:** Add scale-safe read-only God View endpoints to `mras-ops/api`, and wire the standalone `godview-prototype` app off its mock fixtures onto those endpoints.
**Depends on:** the God View schema (`mras-ops/db/migrations/010`–`025`, incl. `screen_groups`) and the built prototype (`godview-prototype`, PR #1 merged).

## 1. Summary

The `godview-prototype` app currently renders four pages from a static typed mock `db` (`src/data/fixtures.ts`) via pure client selectors. This design replaces the mock with live reads from `mras-ops/api`, **scale-safe to 200k+ rows**: aggregation and filtered lists are computed server-side (SQL `GROUP BY`, `WHERE`, keyset pagination); only bounded payloads (single-run detail, one system's devices, a page of rows/events) are shaped client-side by the retained selectors. Updates are by **polling** (5s) on the live surfaces; the existing SSE `/events/stream` is not used in this pass. Tenant-scoping stays deferred (unscoped reads), consistent with the prototype spec.

## 2. Decisions locked (from brainstorming)

- **Per-page endpoints**, not one snapshot — each page fetches only what it renders.
- **All view-shaping logic stays in the client selectors** (KPI math, failure merge/ranking, stage dots, screen_group grouping, graph building) — none is duplicated server-side. Every selector is retained and unit-tested.
- **The server does only data access that cannot scale in the browser**: `GROUP BY` counts, `WHERE`/`ORDER`/`LIMIT` selection of bounded candidate rows, keyset pagination, and per-row subquery counts. It returns bounded rows + raw counts, NOT finished view-models.
- **Scale-safe from the start:** because the server never returns more than a bounded page / small count, the client selectors always operate on bounded inputs. No API rewrite later.
- **Polling** (5s) for live surfaces; SSE deferred.

## 3. Division of labor: client keeps the logic, server bounds the data

Every client selector is **retained** — the selector layer remains the single home of view-shaping logic and stays unit-tested. Nothing is duplicated server-side.

What moves server-side is strictly **data access that cannot happen in the browser at scale** — you cannot ship 200k rows to the client to count, filter, or rank them. So the server does the SQL that bounds the data, and hands the selectors a small, already-bounded input to shape:

| Client selector (kept) | Its input, now bounded by the server |
|---|---|
| `fleetSummary` | server returns raw status counts `{total, active, degraded, offline}`; selector derives the KPI view (healthy = active, etc.) |
| `systemsKpis` | server returns raw counts `{total_systems, active_systems, unresolved_devices}`; selector computes `healthy_pct = active/total` |
| `recentFailures` | server returns the top-~10 candidate failed-run rows + top-~10 health-drop rows (`WHERE…ORDER BY…LIMIT`); selector merges, maps severity/message, orders, takes top-5 |
| `activeAdRuns` | server returns the ~5 active runs (`WHERE status IN(...) LIMIT`); selector maps them |
| `adRunCards` | server returns one filtered, paginated page of runs (`WHERE`+keyset); selector maps rows → cards |
| `systemsWithRollup` | server returns one page of systems with per-row `device_count` (subquery); selector maps rows |
| `systemDrilldown` | server returns one system's cameras/displays/screen_groups; selector groups them |
| `eventLog` | server returns one page of unified health events; selector maps rows |
| `adRunGraph` | server returns one run + its decision/composition/playbacks; selector builds nodes/edges |
| `camerasWithReading` | server returns the ~6 relevant camera rows + their recent-observation aggregate; selector formats |

The **filter/search on a list is a fetch parameter** (which page to load), not client logic removed — the card/row shaping still lives in the selector. The only genuinely server-side computations are `COUNT`, `ORDER/LIMIT` selection, and keyset pagination — none of which is view logic.

## 4. Endpoints (`mras-ops/api`)

All are read-only `GET`, added as thin `@app.get(...)` routes in `api/src/main.py` with query logic in a new helper module `api/src/godview/` (mirroring `api/src/projector/status.py`: `async def get_x(conn, ...) -> dict|list`). Existing conventions: raw asyncpg via the module `_db` pool, `async with _db.acquire() as conn` for multi-query endpoints, plain `dict(row)` serialization, `json.loads` only for jsonb string columns, no Pydantic response models required, snake_case JSON. CORS is already `*`. `DATABASE_URL` env is already wired.

### 4.1 `GET /god-view/dashboard`
O(1) payload regardless of fleet size. Returns bounded rows + raw counts; the client `fleetSummary`/`activeAdRuns`/`recentFailures`/`camerasWithReading` selectors shape them.
```
{
  "fleet": { "total": int, "active": int, "degraded": int, "offline": int },        // GROUP BY systems.status; client fleetSummary maps to KPI
  "active_count": int,                                                               // count of ad_runs in (composing,dispatched,playing)
  "active_runs": [ { "id","status","started_at","system_id","system_name" } ],       // WHERE active ORDER BY started_at DESC LIMIT ~5
  "recent_failed_runs": [ { "id","system_id","system_name","ended_at","error_code" } ], // WHERE status='failed' ORDER BY ended_at DESC LIMIT ~10; error_code JOINed from composition_runs
  "recent_health_drops": [ { "kind","ref_id","ref_name","status","detail","observed_at" } ], // device+system health WHERE status IN(offline,degraded) ORDER BY observed_at DESC LIMIT ~10
  "camera_rows": [ { "camera_id","name","system_name","status","face_count","confidence" } ] // LIMIT ~6
}
```
- `fleet` buckets map `lifecycle_status`: `active`→healthy; `degraded`; `offline`; `total` = count of **all** `systems` rows. Client `fleetSummary` derives the displayed KPI.
- The server returns the top-~10 candidate rows from **each** failure source separately (not a merged/shaped list); the client `recentFailures` selector merges them, maps severity (`error_code`/`offline`→crit, `degraded`→warn), builds the message + `where` + `ad_run_id` (deep-link, from failed runs only), orders newest-first, and takes the top 5. Top-10 per source guarantees the merged top-5 is correct.
- `camera_rows.face_count`/`confidence` derived from `subject_observations` in the **last 60s** joined to `cameras` by **`camera_id`** (`subject_observations` has no `screen_id`): `face_count = count(*)` of recent observations for the camera, `confidence = avg(face_quality_score)` (nullable → `COALESCE(...,0)`). Window is a helper constant. Client `camerasWithReading` formats.

### 4.2 `GET /god-view/ad-runs`
Composition Activity list. Server-side filter + keyset pagination.
Query params: `status`, `system_id`, `campaign_id`, `since` (ISO ts), `cursor` (opaque keyset on `(started_at, id)`), `limit` (default 50, max 100).
```
{
  "items": [ {
    "id","status","started_at","system_id","system_name","location_name",
    "campaign_id","campaign_name",
    "stage_decision": bool,    // personalization_decision_id present
    "stage_composition": bool, // its composition_run.status in (selected,rendered)
    "stage_playback": bool     // any playback.status = 'ended'
  } ],
  "next_cursor": string | null
}
```
- Labels JOINed server-side (system/location/campaign names) so the client maps rows directly.
- The client `adRunCards` selector maps `items` → cards. The filter/search is a fetch parameter (the server pre-filters the page); the card-shaping logic stays in the selector.

### 4.3 `GET /god-view/ad-runs/filters`
Filter-dropdown options, bounded to entities with recent activity.
```
{ "systems": [ {"id","name"} ], "campaigns": [ {"id","name"} ] }
```
Note: at very large scale these become typeahead-backed; documented as a follow-up, out of scope here.

### 4.4 `GET /god-view/systems`
Systems & Logs list. Server aggregates + search + pagination.
Query params: `search` (substring over system/org/location name), `cursor` (keyset on `(name, id)`), `limit` (default 50).
```
{
  "counts": { "total_systems": int, "active_systems": int, "unresolved_devices": int },  // raw counts; unresolved from unresolved_devices
  "items": [ { "id","name","org_name","location_name","system_type","status","device_count" } ], // device_count via subquery/JOIN
  "next_cursor": string | null
}
```
The client `systemsKpis` selector computes `healthy_pct = active_systems/total_systems` from `counts`; `systemsWithRollup` maps `items`.

### 4.5 `GET /god-view/systems/{id}`
On-demand drill-down when a system row is expanded.
```
{
  "system": { "id","name","status", ... },
  "screen_groups": [ { "id","name","group_type" } ],
  "cameras":  [ { "id","name","status","screen_group_id","face_count","confidence" } ], // readings joined
  "displays": [ { "id","name","status","screen_id","screen_group_id" } ]
}
```
`systemDrilldown` runs on this payload (grouping cameras/displays by `screen_group_id`, ungrouped fallback).

### 4.6 `GET /god-view/events`
Paginated unified event/health log.
Query params: `cursor` (keyset on `(observed_at, id)`), `limit` (default 50).
```
{
  "items": [ { "id","kind":"device"|"system","ref_id","ref_name","status","detail","observed_at" } ],
  "next_cursor": string | null
}
```
UNION of `device_health_events` + `system_health_events`, newest first. `detail` is jsonb in both tables → serialize a **display string** (e.g. `detail->>'message'`, else a formatted summary); `ref_name` resolves device/system friendly name. `eventLog` maps `items`.

### 4.7 Reuse `GET /god-view/ad-runs/{ad_run_id}` and `GET /projector/status`
- `GET /god-view/ad-runs/{ad_run_id}` (Ad Detail): `{ "ad_run": {...}, "personalization_decision": {...}|null, "composition_run": {...}|null, "playbacks": [...] }`. Client builds a small `db`-shaped object and runs `adRunGraph` unchanged.
- `GET /projector/status` already exists — the pipeline-health badge polls it (replaces the hardcoded "Pipeline OK · 0.8s").

## 5. Frontend changes (`godview-prototype`)

- **`src/data/api.ts`** — typed fetchers over `const OPS_API = import.meta.env.VITE_OPS_API_URL ?? "http://localhost:8080"` (mirrors the mras-ops frontend): `fetchDashboard()`, `fetchAdRuns(params)`, `fetchAdRunFilters()`, `fetchSystems(params)`, `fetchSystem(id)`, `fetchEvents(params)`, `fetchAdRun(id)`, `fetchProjectorStatus()`. Bare `fetch`, snake_case, throw on `!res.ok`.
- **`src/hooks/usePolling.ts`** — `usePolling(fn, intervalMs=5000)` → `{data, loading, error, refetch}`; fetch on mount + interval; **keep last-good data on a failed poll** (page does not blank); clear timer on unmount.
- **Page wiring:**
  - *Main Dashboard* — `usePolling(fetchDashboard)`; `fleetSummary(fleet)`, `activeAdRuns(active_runs)`, `recentFailures(recent_failed_runs, recent_health_drops)`, `camerasWithReading(camera_rows)` shape the bounded payload for render; badge from `fetchProjectorStatus`.
  - *Composition Activity* — filter state → `fetchAdRuns(params)` (debounced); `adRunCards` maps `items`; "Load more" uses `next_cursor`; dropdowns from `fetchAdRunFilters`.
  - *Systems & Logs* — `fetchSystems({search})` (debounced search) → `systemsKpis(counts)` for the KPI strip + `systemsWithRollup(items)` for rows; expanding a row calls `fetchSystem(id)` → `systemDrilldown`; event log from `fetchEvents` → `eventLog` with "Load more"; unresolved banner from `counts.unresolved_devices`.
  - *Ad Detail* — `fetchAdRun(id)` on mount (optionally polled) → mini-`db` → `adRunGraph`.
- **Every selector is retained** and stays unit-tested client-side. Selectors adapt only in that they now receive their input from the API payload (a bounded slice) instead of the full mock `db`; their signatures may shift from `(db)` to `(payload)` but the shaping logic is unchanged. `src/data/fixtures.ts` stays as the test seed for those unit tests.
- **`.env.example`** documents `VITE_OPS_API_URL`.
- **States:** per-page loading skeletons, an error banner with retry (keep last-good), and empty states (no systems / no active compositions / empty log).

## 6. Testing

- **Backend (TDD — covers only the data-access the server owns: counts, filters, keyset pagination, unions):** helper-level tests per endpoint against a throwaway Postgres, using the existing `api/tests/conftest.py` `projector_pool` fixture (applies all migrations). Seed rows, call the helper (`get_dashboard(conn)`, `get_ad_runs(conn, filters, cursor, limit)`, `get_systems(conn, search, cursor, limit)`, `get_system(conn, id)`, `get_events(conn, cursor, limit)`, `get_ad_run(conn, id)`), assert:
  - counts correct (seed 3 systems / 2 active → `fleet.active == 2`, `counts.active_systems == 2`);
  - filters correct (seed runs across 2 systems, filter by one → only its runs);
  - pagination correct (seed > limit rows → `next_cursor` returned, page size respected, following the cursor returns the next distinct page with no overlap/gap);
  - unified sources correct (a failed ad_run and a device health drop both appear in dashboard failures / events, newest first);
  - jsonb `detail` serialized to a string; friendly names resolved.
  Run: `cd api && pytest` (needs `docker compose up -d postgres`). No HTTP test client exists; testing the helpers matches the repo's established pattern.
- **Frontend (TDD):** `api.ts` (mock `fetch`, assert URL/params + parsing), `usePolling` (fake timers: fetch on mount + each interval; last-good retained on error), page components (mock `api.ts` returning fixture-shaped pages; assert render + a filter change refetches + expanding a row fetches detail). The selector unit tests stay (fixtures as seed) — where a selector's signature shifts from `(db)` to `(payload slice)`, its test updates only the input it passes, not the asserted logic.

## 7. Decomposition (two plans, backend first)

The contract must be real before the client binds to it.

1. **Plan A — `mras-ops/api` God View read endpoints** (`api/src/godview/` helpers + `main.py` routes + `api/tests/` helper tests). Independently shippable/testable; PR to `mras-ops`.
2. **Plan B — `godview-prototype` real-data wiring** (`api.ts`, `usePolling`, page wiring, badge, states, tests). Built to Plan A's contract; integration once both land.

## 8. Out of scope / follow-ups

- SSE live updates (polling only this pass).
- Tenant/auth scoping (deferred, unscoped reads).
- Typeahead-backed filter dropdowns at very large scale (§4.3).
- Viewer-exposure analytics and the map/globe (later God View phases, unchanged).
- Handoff-04 §5's granular per-resource REST endpoints — superseded by these page-scoped scale-safe endpoints for the prototype's needs.
