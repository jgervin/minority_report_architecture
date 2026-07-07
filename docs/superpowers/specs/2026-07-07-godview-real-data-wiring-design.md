# God View Real-Data Wiring — Design

**Date:** 2026-07-07
**Status:** Approved (design phase) — ready for implementation planning
**Scope:** Add scale-safe read-only God View endpoints to `mras-ops/api`, and wire the standalone `godview-prototype` app off its mock fixtures onto those endpoints.
**Depends on:** the God View schema (`mras-ops/db/migrations/010`–`025`, incl. `screen_groups`) and the built prototype (`godview-prototype`, PR #1 merged).

## 1. Summary

The `godview-prototype` app currently renders four pages from a static typed mock `db` (`src/data/fixtures.ts`) via pure client selectors. This design replaces the mock with live reads from `mras-ops/api`, **scale-safe to 200k+ rows**: aggregation and filtered lists are computed server-side (SQL `GROUP BY`, `WHERE`, keyset pagination); only bounded payloads (single-run detail, one system's devices, a page of rows/events) are shaped client-side by the retained selectors. Updates are by **polling** (5s) on the live surfaces; the existing SSE `/events/stream` is not used in this pass. Tenant-scoping stays deferred (unscoped reads), consistent with the prototype spec.

## 2. Decisions locked (from brainstorming)

- **Per-page endpoints**, not one snapshot — each page fetches only what it renders.
- **db-shaped entity slices for bounded payloads**, so the retained client selectors run unchanged; **server-shaped aggregates/pages for unbounded data** (counts, filtered lists) — a deliberate hybrid.
- **Scale-safe from the start:** server aggregates for counts, server-side filter + keyset pagination for lists, on-demand drill-down. No API rewrite later.
- **Polling** (5s) for live surfaces; SSE deferred.

## 3. Why the naive "db-slice + client selectors everywhere" fails at scale

The prototype's selectors iterate arrays in JS. That is correct only for **bounded** inputs. At 200k+ rows these break and MUST move server-side:

- `fleetSummary` counts every system by status → would ship all systems to the browser. → server `GROUP BY status`.
- `systemsKpis` / `systemsWithRollup` scan all systems → server aggregate + paginated rows.
- Composition Activity filters run client-side over a fetched slice → only filter what was fetched, miss matches. → server `WHERE` + pagination.
- Dashboard ships all cameras to derive ~6 readings → server caps to the shown set.

Bounded selectors survive unchanged: `adRunGraph` (one run), `eventLog` (a page), `adRunCards` (maps a page), `systemDrilldown` (one system).

## 4. Endpoints (`mras-ops/api`)

All are read-only `GET`, added as thin `@app.get(...)` routes in `api/src/main.py` with query logic in a new helper module `api/src/godview/` (mirroring `api/src/projector/status.py`: `async def get_x(conn, ...) -> dict|list`). Existing conventions: raw asyncpg via the module `_db` pool, `async with _db.acquire() as conn` for multi-query endpoints, plain `dict(row)` serialization, `json.loads` only for jsonb string columns, no Pydantic response models required, snake_case JSON. CORS is already `*`. `DATABASE_URL` env is already wired.

### 4.1 `GET /god-view/dashboard`
O(1) payload regardless of fleet size.
```
{
  "fleet": { "total": int, "active": int, "degraded": int, "offline": int },   // GROUP BY systems.status
  "active_count": int,                                                          // count of ad_runs in (composing,dispatched,playing)
  "active_runs": [ { "id","status","started_at","system_id","system_name" } ], // LIMIT ~5, newest first
  "failure_count": int,                                                         // failures in the last 4h (window is a helper constant)
  "failures": [ { "id","severity","message","where","when","ad_run_id"? } ],    // LIMIT ~5, newest first
  "camera_readings": [ { "camera_id","name","system_name","status","face_count","confidence" } ] // LIMIT ~6
}
```
- `fleet` buckets map `lifecycle_status`: `active`→healthy; `degraded`; `offline`; `total` = count of **all** `systems` rows (matches the page's "N systems across M organizations"). Only these buckets the UI shows are required.
- `failures` unifies two sources newest-first: failed `ad_runs` (message + severity `crit` from their `composition_runs.error_code`; `ad_run_id` set for deep-link) and recent `device_health_events`/`system_health_events` with status in (`offline`→crit, `degraded`→warn) (`where` = system/device friendly name; no `ad_run_id`).
- `camera_readings.face_count`/`confidence` derived from `subject_observations` in the **last 60s** joined to `cameras` by `screen_id` (window is a helper constant; exact aggregation columns confirmed against `subject_observations` in the plan — if it lacks a usable per-camera confidence, degrade to count-only and note it).

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
- `adRunCards` becomes a pure mapper over `items` (client-side filtering removed).

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
  "kpis": { "total_systems": int, "healthy_pct": number, "unresolved_devices": int },  // server-computed; unresolved from unresolved_devices
  "items": [ { "id","name","org_name","location_name","system_type","status","device_count" } ], // device_count via subquery/JOIN
  "next_cursor": string | null
}
```
`systemsWithRollup` becomes a mapper over `items`.

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
  - *Main Dashboard* — `usePolling(fetchDashboard)`; render `fleet`/`active_runs`/`failures`/`camera_readings` directly (dashboard selectors retire); badge from `fetchProjectorStatus`.
  - *Composition Activity* — filter state → `fetchAdRuns(params)` (debounced); `adRunCards` maps `items`; "Load more" uses `next_cursor`; dropdowns from `fetchAdRunFilters`.
  - *Systems & Logs* — `fetchSystems({search})` (debounced search) for KPIs + rows (`systemsWithRollup` maps `items`); expanding a row calls `fetchSystem(id)` → `systemDrilldown`; event log from `fetchEvents` with "Load more"; unresolved banner from `kpis.unresolved_devices`.
  - *Ad Detail* — `fetchAdRun(id)` on mount (optionally polled) → mini-`db` → `adRunGraph`.
- **Retained:** `src/data/fixtures.ts` + the kept selectors (`adRunGraph`, `adRunCards`, `systemDrilldown`, `eventLog`) + their unit tests. Retired selectors' logic now lives in SQL and is tested server-side.
- **`.env.example`** documents `VITE_OPS_API_URL`.
- **States:** per-page loading skeletons, an error banner with retry (keep last-good), and empty states (no systems / no active compositions / empty log).

## 6. Testing

- **Backend (TDD, where correctness now lives):** helper-level tests per endpoint against a throwaway Postgres, using the existing `api/tests/conftest.py` `projector_pool` fixture (applies all migrations). Seed rows, call the helper (`get_dashboard(conn)`, `get_ad_runs(conn, filters, cursor, limit)`, `get_systems(conn, search, cursor, limit)`, `get_system(conn, id)`, `get_events(conn, cursor, limit)`, `get_ad_run(conn, id)`), assert:
  - aggregates correct (seed 3 systems / 2 active → `fleet.active == 2`, `healthy_pct` correct);
  - filters correct (seed runs across 2 systems, filter by one → only its runs);
  - pagination correct (seed > limit rows → `next_cursor` returned, page size respected, following the cursor returns the next distinct page with no overlap/gap);
  - unified sources correct (a failed ad_run and a device health drop both appear in dashboard failures / events, newest first);
  - jsonb `detail` serialized to a string; friendly names resolved.
  Run: `cd api && pytest` (needs `docker compose up -d postgres`). No HTTP test client exists; testing the helpers matches the repo's established pattern.
- **Frontend (TDD):** `api.ts` (mock `fetch`, assert URL/params + parsing), `usePolling` (fake timers: fetch on mount + each interval; last-good retained on error), page components (mock `api.ts` returning fixture-shaped pages; assert render + a filter change refetches + expanding a row fetches detail). Retained selector unit tests unchanged.

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
