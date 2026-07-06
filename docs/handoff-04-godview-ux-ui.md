# Handoff 04 — God View UX/UI: Projects → Systems → Status

**Created:** 2026-07-06 · **For:** a fresh session starting the God View operator-dashboard UI.
**Scope of this phase (owner-set):** the **project (org) → systems → status** operational view.
Audience analytics (`viewer_exposures` "who watched what") is a *later* phase — see §7.

> Read first: `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (top entries),
> `/Users/jn/code/minority_report_architecture/TODOS.md`, and this session's memory. Then this doc.

---

## 1. What this phase is

Build the **God View**: the operator's fleet dashboard. Three nested views:

1. **Projects** — every organization (the "project"), each with a rolled-up status.
2. **Systems** — drill into a project → its MRAS systems, each with status + device health.
3. **Status** — drill into a system → its devices (cameras/displays) with live status,
   `last_seen`, health-event history, the God View **projector pipeline health**, and any
   **unresolved (unregistered) devices**.

This is greenfield UI on top of a **fully-built data model**. The backend hierarchy exists; the
**read API and the UI do not yet** (see §5). Both are the work.

---

## 2. What works today (so you don't re-derive it)

The whole MRAS pipeline is live and validated end-to-end (5 repos, dev stack in Docker):

- **Perception → composition → display → God View fold** all green. A real walk-up enrolls a
  subject, recognizes them, renders a personalized ad, and the projector folds events into
  `viewer_exposures` with `watched=TRUE` and live gaze. (Details:
  memory `project-godview-e2e-validated`, `docs/SESSION_LOG.md`.)
- **Display peel-back shipped + live-validated 2026-07-06** (mras-composer `main @ 3cf52ea`):
  opener on all owned displays → round 2 peels to `floor(N/2)` (min 1) → done, presence-independent.
- **A/B demo ads seeded** (mras-ops `db/seeds/001_demo_ab_ads.sql`, PR #41): round 2's two peel
  screens now show distinct variants via the `comp-helloname` Remotion composition.

**Bottom line for you:** the events journal, the summary tables, and the org→…→display hierarchy
are populated and correct. You are building the *window* onto data that already flows.

---

## 3. The domain — what "project → systems → status" maps to

The hierarchy is **org → location → system → device → camera/display**, modeled in
`/Users/jn/code/mras-ops/db/migrations/012_physical.sql` (org itself in `011_accounts.sql`).
Enums are defined once in `/Users/jn/code/mras-ops/db/migrations/010_enums.sql`.

| UI concept | Table | Key columns | Status column |
|---|---|---|---|
| **Project** | `organizations` | `id`, `name`, `organization_type`, `parent_organization_id` (self-FK, org tree), `metadata` | `status` → **`lifecycle_status`** (planned/active/inactive/degraded/offline/retired) |
| (place) | `locations` | `id`, `parent_location_id`, `name`, `location_type`, geo | `lifecycle_status` |
| **System** | `systems` | `id`, `name`, `system_type` (onsite_mras/demo/lab/kiosk_cluster/edge_node), `organization_id` (NOT NULL), `location_id` (NOT NULL), `zone`, `floor`, `config` | `lifecycle_status` |
| Device | `devices` | `id`, `system_id` (NOT NULL), `device_type` (camera/display/edge_node/player/sensor), `name`, `external_device_key`, `serial_number`, **`last_seen_at`** | `status` → **`device_status`** (active/degraded/offline/retired) |
| **Camera** | `cameras` | `device_id`, `system_id`, `name`, `camera_role`, `stream_url`, `screen_id` (e.g. `screen_0`), `last_seen_at` | `device_status` |
| **Display** | `displays` | `device_id`, `system_id`, `name`, `screen_id` (NOT NULL), `display_role`, `resolution_width/height`, `last_seen_at` | `device_status` |

**⚠️ Two different status enums.** Org/location/system use **`lifecycle_status`**; device/camera/display
use **`device_status`**. The UI must render/color them as two distinct vocabularies — don't unify blindly.

**Health / "status over time":**
- `device_health_events` (device_id, `device_status`, detail, observed_at) and
  `system_health_events` (system_id, `lifecycle_status`, detail, observed_at) — append-only series.
- For *current* status, read the `status` column on the entity itself (or latest health event per id).

**Pipeline health & registration gaps (great God-View surfaces):**
- `projector_state` (singleton id=1: `cursor`, `last_event_ts`, `updated_at`, `projector_ver`) —
  `/Users/jn/code/mras-ops/db/migrations/019_projector_state.sql`. Already served (see §4).
- `unresolved_devices` (screen_id, kind, first/last_seen_at, seen_count) —
  `/Users/jn/code/mras-ops/db/migrations/020_device_registry.sql`. Screen_ids seen in events before a
  device is registered → an "unregistered device" alert list.

---

## 4. Where things are (grounded code map)

### Frontend — `mras-ops-frontend`
- Source: `/Users/jn/code/mras-ops/frontend/`, app in `/Users/jn/code/mras-ops/frontend/src/`.
- **Stack:** React 18 + TypeScript + **Vite 5** (not Next). Vitest + Testing Library for tests.
  Runtime deps are only `react` + `react-dom` — **no router, no state lib, no data-fetching lib,
  no CSS framework.**
- **The entire app is 3 files:**
  - `/Users/jn/code/mras-ops/frontend/src/main.tsx` — entry.
  - `/Users/jn/code/mras-ops/frontend/src/App.tsx` — a two-tab shell (`'authoring' | 'feed'`) via
    `useState` (no routes). Tab 2 "Activity Feed" tails `EventSource(`${OPS_API}/events/stream`)`,
    keeps last 200 events in a table.
  - `/Users/jn/code/mras-ops/frontend/src/Authoring.tsx` — advertiser tool (upload component,
    CRUD ads, preview).
  - API client: `/Users/jn/code/mras-ops/frontend/src/api.ts`.
- **Styling:** no Tailwind/CSS-modules/component-lib. All inline `style={{…}}`. De-facto dark theme
  hardcoded in `App.tsx`: `monospace`, bg `#111`, text `#eee`, accent `#4af`, error `#f88`, muted
  `#888`. **No shared theme module** — a God View design system starts fresh.
- **Data fetching:** native `fetch()` + `EventSource`. Base URLs in `api.ts`/`App.tsx`:
  `OPS_API = import.meta.env.VITE_OPS_API_URL ?? "http://localhost:8080"`,
  `COMPOSER = import.meta.env.VITE_COMPOSER_URL ?? "http://localhost:8002"`.
- **Port:** in the stack it serves on **:3000** (Dockerfile `--host 0.0.0.0 --port 3000`, compose
  maps `3000:3000`). A bare host `npm run dev` would be Vite's default 5173.

### ops-api — `mras-ops-api` (:8080)
- Source: `/Users/jn/code/mras-ops/api/src/main.py`. **FastAPI**, async `asyncpg` pool (`_db`),
  `httpx` to the overlay sidecar. Same image runs the projector worker
  (`/Users/jn/code/mras-ops/api/src/projector/`, command `python -m src.projector`, no HTTP).
- **Existing routes:** `POST/GET /components`, `POST/GET/PATCH/DELETE /ads`,
  `DELETE /components/{id}`, `GET /events/stream` (SSE), **`GET /projector/status`**
  (`{cursor, last_event_ts, backlog, lag_seconds, health: ok|warn|crit}`; logic in
  `/Users/jn/code/mras-ops/api/src/projector/status.py`), `GET /health`.
- **God-View read endpoints that EXIST:** only `GET /projector/status` and the `GET /events/stream`
  feed. **Everything else in §3 is unexposed.**
- **CORS:** wide open (`allow_origins=["*"]`). **Auth:** NONE on any endpoint. `user_org_scopes` /
  `role_label` are modeled in the DB (`010`/`011`) but ops-api neither reads nor enforces them.

---

## 5. The gap (this is the work)

1. **No read API for the hierarchy.** Add GET endpoints to
   `/Users/jn/code/mras-ops/api/src/main.py` (copy the existing `_db` asyncpg pattern). Minimum set:

   | Endpoint | Returns | Backing tables |
   |---|---|---|
   | `GET /orgs` | projects list + rolled-up status + system/device counts | `organizations` (+ counts from `systems`,`devices`) |
   | `GET /orgs/{id}/systems` | systems under a project, each w/ status + device rollup | `systems`, `devices` |
   | `GET /systems/{id}` | one system + its cameras/displays + current status | `systems`, `cameras`, `displays`, `devices` |
   | `GET /systems/{id}/health` | recent health events for a system + its devices | `system_health_events`, `device_health_events` |
   | `GET /unresolved-devices` | unregistered screen_ids seen in events | `unresolved_devices` |
   | (have it) `GET /projector/status` | pipeline lag/health | `projector_state` |

   TDD these in the api service (it has a test setup). Keep them read-only.

2. **No UI framework decisions made.** The current 3-file app has no router, no data layer, no
   design system. A multi-view drill-down (projects → systems → status) needs at least routing and a
   data-fetching approach. See §6 for the decisions to lock first.

---

## 6. Decisions to make up front (surface to owner before building)

These are genuine forks — don't pick silently:

- **Design language.** The existing app is deliberately barebones (monospace ops console). Options:
  (a) **extend the current dark ops-console aesthetic** (fast, cohesive with the Activity Feed, no
  new deps) vs (b) **introduce a design system** (e.g. Tailwind + a component set) for a richer
  operator dashboard. Recommend (a) for the first cut — a status dashboard reads well as a dense dark
  console, and it keeps the greenfield small — then revisit.
- **Router.** Drill-down needs navigation. Recommend adding `react-router` (small, standard) over
  hand-rolled `useState` view switching once there are >2 views.
- **Data fetching.** Native `fetch` works, but projects/systems/status want polling + cache.
  Recommend a light layer (`react-query`/TanStack Query) *or* a tiny `usePolling` hook. Match the
  Activity Feed's live feel: status should refresh (SSE already exists for events; status can poll
  `/projector/status` + the new endpoints on an interval).
- **Auth / multi-tenant scoping.** `user_org_scopes` is modeled but unenforced. Decide whether this
  phase stays **open (single-operator demo)** or introduces the Supabase scope filter now.
  Recommend **defer** — build the views unscoped for the demo, leave the scope hook as a later lane
  (matches how blocklist/biometric-legal are deferred until production).
- **Status vocabulary in the UI.** Design the color/label mapping for BOTH enums
  (`lifecycle_status` for org/location/system; `device_status` for devices) — they differ.

---

## 7. Explicitly out of scope for this phase (later lanes)

- **Audience analytics / "who watched what."** `viewer_exposures` (`015_runs.sql`) is the payoff
  read model (role target/viewer/bystander, `watched`, gaze durations, demographic snapshot) with
  `ad_runs`/`playbacks` behind it. That's a *separate* God View phase — do not build it here unless
  the owner re-scopes.
- **Auth/tenant scoping enforcement** (see §6) — deferred.
- **Write/ops actions** (registering a device, retiring a system) — this phase is read-only status.

---

## 8. How to run & verify

```bash
# From /Users/jn/code/mras-ops
docker compose up -d --build          # or ./start-mras.sh (health-checks for you)
```
Ports: **frontend :3000**, **ops-api :8080** (`/health`, `/projector/status`), composer :8002,
postgres :5432 (DB `mras`, user/pass `mras/mras`, migrations auto-applied). `mras-vision` runs
NATIVE on macOS (camera), behind the `docker-vision` profile — not needed for God View UI work.

Poke the data you'll render:
```bash
# hierarchy rows already in the dev DB
docker compose exec -T postgres psql -U mras -d mras -c \
  "SELECT o.name org, s.name system, s.status FROM systems s JOIN organizations o ON o.id=s.organization_id;"
docker compose exec -T postgres psql -U mras -d mras -c \
  "SELECT name, device_type, status, last_seen_at FROM devices;"
curl -s http://localhost:8080/projector/status   # pipeline health JSON
```

**Git/process rules (unchanged):** never touch `main` directly; all git via the
`git-flow-manager` subagent; one worktree per ticket; TDD red→green committed separately; run a live
E2E (not just unit) before calling a UI task done; reference files by absolute path;
update `SESSION_LOG.md` before any reboot/`clear`. See
`/Users/jn/code/minority_report_architecture/CLAUDE.md`.

---

## 9. Suggested first steps (definition of done for step 1)

1. **Design spike** — get owner sign-off on §6 (aesthetic, router, data layer, scope-deferral).
2. **API lane** (mras-ops `api/`): TDD `GET /orgs`, `GET /orgs/{id}/systems`, `GET /systems/{id}`,
   `GET /systems/{id}/health`, `GET /unresolved-devices`. Red→green, contract tests on the JSON shape.
3. **UI lane** (mras-ops `frontend/`): add router + a `GodView` section with the three drill-down
   views wired to those endpoints; reuse the dark theme; status badges for both enums; live refresh.
4. **Verify:** load `http://localhost:3000`, drill project → system → device status against the real
   dev DB; confirm `/projector/status` health renders; a Playwright pass over the drill-down.

---

## 10. References

- **Session log:** `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (God View pipeline,
  peel-back, Operational Reference).
- **Schema:** `/Users/jn/code/mras-ops/db/migrations/` — esp. `010_enums.sql`, `011_accounts.sql`,
  `012_physical.sql`, `015_runs.sql`, `016_events_audit.sql`, `019_projector_state.sql`,
  `020_device_registry.sql`.
- **API:** `/Users/jn/code/mras-ops/api/src/main.py`, projector `/Users/jn/code/mras-ops/api/src/projector/`.
- **Frontend:** `/Users/jn/code/mras-ops/frontend/src/{main,App,Authoring,api}.tsx`.
- **Config convention** (if you add a service-config surface):
  `/Users/jn/code/minority_report_architecture/docs/config-convention.md`.
- **Peel-back spec** (prior lane, context): `/Users/jn/code/minority_report_architecture/docs/handoff-03-peelback-orchestration-spec.md`.
- **Memory:** `project-godview-e2e-validated`, `project-godview-schema-lane-a`, `project-phase1-progress`.
