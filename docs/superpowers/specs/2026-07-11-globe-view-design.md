# God View Globe — Design (2026-07-11)

**Status:** owner-approved design; outside-reviewed (opus, fresh context) 2026-07-12 — verdict
SOUND WITH AMENDMENTS, all 11 amendments applied below (teardown enumeration, generator
event-stamping, status-encoding alignment, WebGL guards).
**Realizes:** the semantic-zoom map concept in
`/Users/jn/code/minority_report_architecture/docs/Godview_prototype_handoff.md`, phased as "Later"
in `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-07-godview-prototype-ux-design.md`
§9 — all its prerequisites (dashboard, Ad Detail, Systems & Logs, viewer exposure, Fleet P1–P2)
have shipped, so this lane is unblocked.
**Visual reference:** owner-supplied images in
`/Users/jn/code/minority_report_architecture/dashboard_images_ideas/` (security-ops globe
dashboards: dot-covered globe with side rails; satellite detail card; collision-tooltip close-up).

## 1. Goal

A cinematic, operational **Globe page** in godview-prototype: the whole fleet at a glance on a 3D
globe — venue dots encode health and live ad activity, clicking a venue drills into its systems
and devices, and everything routes into the existing detail pages. The globe is the macro view;
it never replaces Ad Detail / Systems / Fleet ("Map = where things are happening; AdRun view =
exactly what happened").

## 2. Owner decisions (made 2026-07-11, this session)

| Decision | Choice |
|---|---|
| Fake fleet data | **Seed the dev Postgres** (tagged, reversible) — globe reads real ops-api end-to-end; the real demo box is one live dot among the seeded venues |
| Zoom depth | **Globe → venue dot, then overlay panel** — no in-globe building interiors; panel lists systems → cameras/displays and routes to existing pages |
| Map modes (v1) | **Health + Live AdRun** (mode switcher built once; Volume/Error/Campaign are later encodings on the same pipeline) |
| Demo motion | **Demo-traffic generator** through the real `events` journal → projector → summaries spine; opt-in, hard-scoped to the demo org |
| Globe rendering | **Open-source globe.gl** (owner-requested; https://globe.gl/), not hand-rolled three.js |

## 3. Page & interaction design (godview-prototype)

New route **`/globe`**, "Globe" nav item in
`/Users/jn/code/godview-prototype/src/components/Shell.tsx` (after Fleet). Full-bleed dark canvas:

- **Globe center-stage** (`<GlobeCanvas>`): auto-rotates slowly when idle; user drag/zoom stops it.
- **Mode switcher + legend (top):** `Health` | `Live Ad Runs`. Encodings are defined against
  what the projector actually produces (outside-review amendment; `device_status` has no
  "failing", and `ad_runs.status` is only ever planned/dispatched/playing/completed/failed —
  `composing`/`ready` are unmapped no-ops in `/Users/jn/code/mras-ops/api/src/projector/routing.py`):
  - Health: worst device status per venue — `active`→green, `degraded`→yellow,
    `offline`/`retired`→gray; **red is reserved for activity failures**
    (`failures_last_hour > 0`), not a device status.
  - Live AdRun: ring pulse = "composing-ish" (`ad_runs.status='planned'` OR an open
    `composition_runs` in queued/rendering), solid glow = playing (`status in
    (dispatched, playing)` OR an open playback), red ring = `failed` in the last N minutes,
    dim = idle.
- **Venue rail (left):** all venues sorted worst-first (Health mode) or most-active-first
  (Live mode), monospace stats per row; clicking a row flies the camera to that dot and opens
  its panel. Mirrors the country list in the reference image.
- **Venue panel (right, slide-in on dot/rail click):** venue header (name, city/country, type,
  rollup line per the concept doc — "8 systems · 3 playing · 1 camera warning · last ad 14s ago"),
  then systems list, each expandable to cameras/displays with status + `last_seen_at`, plus
  recent/active ad runs. Links out: ad run → `/compositions/:adRunId`; system → `/systems/:id`;
  "Manage in Fleet" → `/fleet`.
- **Semantic aggregation:** beyond a camera-altitude threshold, venues cluster into one
  city dot showing rolled-up counts ("Dallas · 3 venues · 12 systems"); below it, venues render
  individually. Clustering is a pure client-side selector keyed on `city`/lat-lng (testable
  without WebGL). This is v1's slice of the concept doc's "dot = largest meaningful aggregate."
- **Hover tooltip:** the concept doc's dot summary for whatever the dot is (city cluster or venue).

**Rendering implementation:** globe.gl used **directly** (no `react-globe.gl` wrapper — avoids a
React-19 peer-dependency risk; the library is framework-agnostic and mounts into a ref'd div).
One `GlobeCanvas.tsx` owns the imperative surface (init, points/rings data updates, camera
flights, dispose on unmount); everything else is normal declarative React fed by selectors.
Guardrails (outside-review amendments): globe.gl/three is instantiated **only inside the
ref-mount effect**, feature-guarded on WebGL availability — never at module top level or in a
render path — so jsdom unit tests of the rail/panel/legend never touch three, and a venue
TV/kiosk browser without WebGL gets a graceful fallback (the rail still lists the whole fleet
instead of a blank page). Each poll **diffs the points/rings data into the existing globe
instance — never re-inits it** (hours-long TV sessions). **Earth textures are bundled locally**
as Vite asset imports (relative to the app `base`, never absolute `/...` paths, which 404 on a
deployed prototype and render the globe black) — public-domain NASA Blue Marble/night-lights,
no CDN fetches, so the page works with no internet at a venue. Decorative arcs: **out of scope
v1** (they'd encode nothing real in MRAS; cheap flourish later).

## 4. Data (mras-ops ops-api — read-only, no schema changes)

The Lane-A schema already has everything the concept doc's "fields this forces" list demands
(verified against `/Users/jn/code/mras-ops/db/migrations/012_physical.sql`: `locations` has
country/region/state/city/address/**lat/lng**/timezone + the full `location_type` enum; systems
and devices carry zone/floor/lat/lng/`last_seen_at`). Two new endpoints beside the existing
god-view read API:

- **`GET /god-view/map`** → `{ venues: [{ location_id, name, location_type, city, country, lat,
  lng, rollup: { systems, cameras, displays, worst_status, active_ad_runs, composing_count,
  playing_count, runs_last_hour, failures_last_hour, last_activity_at } }] }` — one row per venue
  (locations that have systems). `composing_count`/`playing_count` split `active_ad_runs` by
  phase so the Live-mode pulse-vs-glow encodings have a data source (Plan-B recon addition;
  additive).
  **There are no summary/rollup tables** (outside-review correction): the existing god-view
  endpoints compute aggregates on the fly from base tables (the projector writes into `ad_runs`,
  `playbacks`, `composition_runs`, etc.), and this endpoint does the same — **one set-based
  query** (GROUP BY `location_id` over the run/device tables joined to `locations`), not
  per-venue subqueries. Trivial at 15 venues; add an `ad_runs(location_id, started_at)` index
  only if the fleet ever makes it matter. Venues without lat/lng are returned with
  `lat/lng: null` and listed in the rail but not plotted (the real demo box gets coordinates in
  the seed session so it plots).
- **`GET /god-view/map/locations/{id}`** → venue panel payload: `{ location, systems: [{ id,
  name, zone, status, cameras: [...], displays: [...] }], ad_runs: [recent/active, keyset-limited] }`.

Frontend polls `/god-view/map` with the existing `usePolling` hook (same cadence as the
dashboard); the panel endpoint is fetched on open + polled while open.

## 5. Seed data (mras-ops)

`/Users/jn/code/mras-ops/db/seed/seed_demo_fleet.sql` + `teardown_demo_fleet.sql` — **seeds live
outside `db/migrations/`** (initdb applies migrations on fresh volumes; fake data must never bake
into every fresh DB). Applied manually, same pattern as standalone migrations
(`docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql`).

- One fake **organization "Demo Retail Group"** owns every seeded system
  (`systems.organization_id`) — the org id is the primary scoping tag. Belt-and-braces:
  every seeded row also carries `metadata.demo_seed = true` (locations/devices/etc. all have
  `metadata jsonb`).
- **~12–15 venues** with real coordinates across US/EU/APAC — malls, one airport, one showroom
  (`location_type` values `mall`/`airport`/`store` already exist), each with **2–5 systems**
  (named like the concept doc: "Entrance Wall A", "Food Court Wall"), each system **1–2 cameras +
  2–6 displays** (+ screen_groups where multi-display). A spread of statuses so Health mode has
  something to show: mostly healthy, a couple of warning/offline devices. Tagging correction
  (Plan-A recon): `metadata.demo_seed=true` goes on rows that actually have `metadata` jsonb
  (locations, devices); `systems` carry it in `config`; cameras/displays are scoped via the org
  join plus a `demo-` `screen_id` namespace.
- **Teardown is an explicit dependency-ordered delete** scoped to the demo org. The schema FKs
  have **no ON DELETE CASCADE anywhere** (verified across all migrations), and two activity
  tables FK **into** `events` (`subject_observations.event_id`, `personalization_decisions
  .event_id` — migration 016), so the order is (outside-review amendment): projector-derived
  activity rows first (`viewer_exposures`, `identity_matches`, `subject_observations`,
  `personalization_decisions`, `playbacks`, `composition_runs`, `ad_runs`,
  `observation_tracks`, `device_health_events`/`system_health_events` for seeded devices) →
  demo-org `events` rows → cameras/displays/devices → screen_groups → systems →
  location_participants → orphaned seeded locations → org. **FK cycle (Plan-A recon):** the
  projector back-stamps `events.ad_run_id`, and `personalization_decisions.event_id → events` +
  `ad_runs.personalization_decision_id → personalization_decisions` close a cycle — teardown first NULLs
  `events.ad_run_id` (and `unresolved_devices.event_id`) for demo-scoped rows, then deletes in
  the order above. **Never reset the projector cursor / "rebuild" the projector as a cleanup
  step** — re-folding the shared journal is a live-DB
  hazard; demo-scoped deletes are sufficient. Seed is idempotent (re-running is a no-op or
  clean refresh); teardown leaves zero seeded rows.
- The real demo location/system rows are untouched, with one guarded exception: the seed gives
  the real demo location its lat/lng so it plots — a separate, logged
  `UPDATE locations ... WHERE id = '<specific id>'` (never a broad match), listed in teardown's
  explicit "leave as-is" set so teardown never nulls it back.
- **No seeded ads or subject_profiles are required** (outside-review simplification): the ad/
  campaign/subject FKs on the activity tables are all nullable, and the globe rollups need only
  `ad_runs.status` + scope. Skipped in v1; seed demo ads later only if Ad Detail drill-down
  should show a real ad name.

## 6. Demo-traffic generator (mras-ops)

`/Users/jn/code/mras-ops/scripts/demo_traffic.py` — opt-in terminal script (Ctrl-C to stop):

- Emits **minimal well-formed event sequences** into the append-only `events` journal —
  composition → ad_run → playback **in that order** (FK-link lookups by shared `trigger_id`
  expect the sibling row to exist; out-of-order links null and the "playing" glow gets flaky),
  with jittered pacing, weighted venue activity, and an occasional failure path — for **seeded
  venues only** (hard-scoped: refuses any system whose `organization_id` is not the demo org,
  and **hard-exits if the demo org is absent**, so it cannot run post-teardown). Payloads are
  minimal (`trigger_id`, `screen_id`, `screen_kind`, `status`, timestamps) — nullable ad/subject
  FKs are omitted; a payload referencing a non-existent `ad_id` would FK-violate and roll back
  the projector's per-event savepoint, silently dropping the pulse. Exact shapes are recon'd
  from the emitting services + projector handlers at plan time (standing recon-first rule).
- **Every emitted `events` row is stamped with `organization_id` + `system_id` + `location_id`
  at insert** (columns exist and are nullable; the projector's back-stamp overwrites with the
  identical resolved values) and `payload.demo_seed=true`. Without this, events still inside
  the projector's 2 s settle window at Ctrl-C would have NULL org and escape a scoped teardown,
  folding later into orphaned demo activity (outside-review amendment).
- Rate-configurable (`--rate`, default gentle: a few runs/minute fleet-wide); prints what it
  emits. Pacing respects the projector's settle window (`settle_ms=2000` + `poll_ms=1000` ⇒
  pulses trail inserts by ~2–3 s — status beats are scheduled no tighter than that; this lag is
  expected, not a bug). Doubles as projector load/soak tooling.
- The generator takes no advisory lock and never projects — it only appends to `events`; the
  projector's single-writer discipline is untouched (outside review confirmed this is sound).
- Journal hygiene: teardown = stop generator → delete demo-org-scoped rows (per §5 order).

## 7. Build plan & verification

Two plans, Fleet-P1/P2-style, standard process (worktrees, TDD red→green commit pairs, per-branch
strongest-model review, merge commits, PR per plan, live E2E always):

- **Plan A (mras-ops):** seed + teardown SQL, `/god-view/map` + `/god-view/map/locations/{id}`
  endpoints, demo-traffic generator. TDD against the dev DB (endpoint rollup correctness, seed
  idempotency, teardown-leaves-zero-rows, generator scoping refusal).
- **Plan B (godview-prototype):** `GlobeCanvas`, clustering/rollup selectors (pure functions —
  unit-TDD), mode switcher + legend, venue rail, venue panel, routing links, polling. Final
  **live Playwright E2E** (memory rule): globe renders, dots present, mode switch works, venue
  click → panel → link into Ad Detail. Note: headless WebGL needs a software-GL launch flag
  (SwiftShader) — plan B must budget for it; if headless WebGL proves flaky, the E2E asserts on
  the DOM surfaces (rail, panel, legend, tooltips) with the canvas mounted, and a headed
  screenshot pass covers the visual.

Sequencing: Plan A merges first (Plan B's live E2E needs the seeded fleet + endpoints).

## 8. Out of scope (v1)

- Volume / Error / Campaign map modes (the mode-switcher pipeline is built to take them later).
- Arcs and other decorative flourishes; satellite/orbit imagery from the reference designs.
- In-globe deep zoom below venue level (systems/devices live in the panel).
- Mobile-first polish: the page stays usable at 390px (rail/panel become sheets consistent with
  the existing responsive patterns) but the globe is a desktop/TV-first surface.
- Auth/tenant scoping (deferred project-wide), biometric-privacy machinery (deferred to
  production go-live).
- Editing anything from the globe (Fleet owns writes).

## 9. Risks / trade-offs (accepted)

- three.js via globe.gl adds ~600 KB gzipped to an internal dashboard — accepted.
- Client-side clustering is O(venues) per poll — trivial at 15 venues, fine into the hundreds;
  server-side clustering only if the fleet ever makes it matter.
- Seeded fake data lives in the dev DB alongside real demo data — mitigated by org-scoping +
  metadata tag + explicit teardown; never runs on a production DB (seeds are manual by design).
- globe.gl is imperative inside React — contained in one component with a dispose path; the rest
  of the page stays declarative and testable.
