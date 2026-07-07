# God View Prototype — UX & Architecture Design

**Date:** 2026-07-07
**Status:** Approved (design phase) — ready for implementation planning
**Scope:** Composition/ad-run flow pages, Systems & Logs dashboard page, ScreenGroup schema addition.
**Explicitly out of scope for this phase:** map/globe view, viewer-exposure/attention analytics (both deferred — see §9).

## 1. Summary

Build a standalone God View prototype (new app, shadcn/ui, mock data first) covering four pages:
a composite **Main Dashboard**, a card-grid **Composition Activity** list, an n8n-style **Ad Detail**
flow-diagram page, and a table/list **Systems & Logs** page. The existing `mras-ops/frontend`
(Authoring + Activity Feed) is untouched; Activity Feed is kept in its current working state but
considered superseded/retired in favor of the new Systems & Logs event table.

This design reconciles two prior inputs:

- `/Users/jn/code/minority_report_architecture/docs/handoff-04-godview-ux-ui.md` — the most recent
  official scoping doc (2026-07-06), which locked the live-schema domain model and deferred
  viewer-exposure analytics.
- `/Users/jn/code/minority_report_architecture/docs/Godview_prototype_handoff.md` — an earlier
  planning conversation (pre-dating the Lane A schema merge) proposing a semantic-zoom map and a
  simplified object hierarchy. Most of its data-model asks (locations recursion, lat/lng, full
  location-type taxonomy) already shipped in Lane A; this design keeps its map/UI ideas but defers
  the map itself and translates all sketch field names to their real schema equivalents (see §2).

## 2. Reconciliation Notes (real schema vs. prior docs)

Per explicit instruction, **real DB column/table names are used throughout this spec and should be
used in all frontend/backend code** — no translation layer, no invented naming vocabulary.

- `Godview_prototype_handoff.md`'s claim that `location_id` "does not exist yet" is stale; it and
  `system_id`/`camera_id`/`display_id` have been live since the Lane A migration (mras-ops#34,
  merged 2026-06-30).
- Its simplified `ad_runs` sketch (`camera_id`, `screen_group_id`, `identity_id`) doesn't match the
  real `ad_runs` table (`display_id`, `target_subject_profile_id`, no `camera_id`). The real schema
  is used throughout this design.
- `screen_group_id` was proposed once on `cameras` in
  `/Users/jn/code/minority_report_architecture/docs/god-view-domain-model.md:787` but was dropped
  before implementation. This design reintroduces it properly as a first-class table (§7),
  simultaneously resolving the open zone/area question in
  `/Users/jn/code/minority_report_architecture/docs/handoff-03-peelback-orchestration-spec.md`.
- The full semantic-zoom location hierarchy (`country → region → city → district → campus →
  building → mall → airport → venue → store → floor → zone → area`) already exists today via
  `locations.location_type` + `locations.parent_location_id` self-reference
  (`/Users/jn/code/mras-ops/db/migrations/010_enums.sql:26`, `012_physical.sql:1-13`) — no schema
  work needed for this, only deferred for later (map phase) UI work.

## 3. Domain Taxonomy

```
Organization (organizations)
  organization_type: platform_operator | host | advertiser | agency_of_record | partner | vendor
  lifecycle_status
  └── parent_organization_id (self-referencing)

Location (locations) — recursive via parent_location_id
  location_type: country | region | city | district | campus | building | mall | airport
                 | venue | store | floor | zone | area
  lifecycle_status
  fields: country, region, state, city, address, lat, lng, timezone

  └── System (systems)
        system_type: onsite_mras | demo | lab | kiosk_cluster | edge_node
        lifecycle_status
        fields: zone, floor, lat, lng

        └── Device (devices) — device_type: camera | display | edge_node | player | sensor
              device_status
              ├── Camera (cameras) — camera_role, screen_id, stream_url
              └── Display (displays) — display_role, screen_id, resolution
                      └── Screen Group (screen_groups) — NEW, see §7
                            groups cameras/displays within a system (e.g. "Entrance Wall A")

Campaign (campaigns) → Ad (ads) → Ad Creative (ad_creatives)
  referenced by personalization_decisions.campaign_id/selected_ad_id, ad_runs.campaign_id/ad_id

Composition pipeline (per ad-run instance, correlated by trigger_id):
  Personalization Decision (personalization_decisions)
    → target_subject_profile_id, decision_type, decision_factors, confidence scores
    → Model Run (model_runs) — the AI inference behind the decision
  → Composition Run (composition_runs)
    → input_asset_id / output_asset_id (media_assets), component_id, render_mode
    → used_spoken_name / used_visible_name / used_likeness / used_voice_clone flags
  → Ad Run (ad_runs)
    → display_id, status (planned→composing→ready→dispatched→playing→completed/failed)
  → Playback (playbacks) — one row per (trigger_id, display_id); multi-display runs fan out here
  └── (deferred, Phase 3) Viewer Exposure (viewer_exposures) — watched/attention data

Health/observability (cross-cutting, feeds Systems & Logs):
  device_health_events (per device, device_status timeline)
  system_health_events (per system, lifecycle_status timeline)
  unresolved_devices (unregistered screen_ids seen in event stream)
  events (raw audit journal — currently powers /events/stream)
```

## 4. Information Architecture / Site Map

```
God View (app shell: left sidebar + topbar, shadcn dark theme, standalone new app)
│
├── Main Dashboard (/)                          index/home, composite view only —
│   no node-diagram here. Pulls the single highest-priority summary from each page below:
│   - Fleet health KPI row (systems healthy/degraded/offline counts + sparkline)
│   - "Composing now" strip (top active ad-run cards, live)
│   - "Recent failures" list (top 5, links into Ad Detail / Systems & Logs)
│   - Live camera reading ticker (detection output + stream/device health combined)
│
├── Composition Activity (/compositions)        "cards as ads" list page
│   Grid of ad-run cards (system, campaign, status, timestamps, mini pipeline-stage dots)
│   Search/filter by system, status, campaign, time range
│   Click a card → Ad Detail
│
├── Ad Detail (/compositions/:ad_run_id)         n8n-style flow page — the ONLY page
│   using the flow-diagram layout
│   Node graph: Trigger → Personalization Decision (+ Decision-Input satellite nodes)
│   → Composition Run (+ Creative-Input satellite nodes) → Ad Run → Playback(s)
│   (fans out per display). Ghosted/locked Viewer Exposure node marks the Phase 3 seam.
│   Click a node → right-side inspector panel with full column values
│
├── Systems & Logs (/systems)                    table/list dashboard
│   Search/filter bar + small KPI row (total systems, healthy %, unresolved-device count)
│   Systems table (org/location/system/type/status/device count) → row click → drill-down
│   System drill-down: cameras/displays grouped by screen_group, each camera card
│   combining live detection reading + stream/device health
│   Chronological event/log table (supersedes Activity Feed's role)
│   Banner for unresolved_devices when present
│
├── Authoring (/authoring)                       existing, carried over as-is
│
└── Activity Feed                                existing, left in its current working
    state, shown in nav with a "legacy" badge — not actively developed further

(deferred, later work, in this order — not to be confused with the MRAS Phase 0/1/2 numbering
 used elsewhere in the project; these are God View-specific follow-ons:)
  Next:  Viewer Exposure / attention analytics
  Later: Map / globe view
```

## 5. User Journeys

Only persona in scope (auth/tenant-scoping deferred): the **platform operator**
(`Operator.SystemAdmin` / `Operator.SeniorSystemAdmin`).

**Journey 1 — "Is everything healthy?" (routine check).** Open Main Dashboard → scan fleet
health KPI row + sparkline trend → optionally click a degraded count → lands on Systems & Logs
pre-filtered to degraded.

**Journey 2 — "Why did this ad fail?" (incident investigation).** See a failure in Main
Dashboard's alert list → click deep-links straight to the specific Ad Detail (not a manual search)
→ scan the node graph for the red/failed node → open it, read `error_code`/`error_message` and its
Creative/Decision-Input satellites → understand failure class → optionally jump to Systems & Logs
to check whether the same system has other failures.

**Journey 3 — "What's live at this venue right now?" (spot check).** Navigate to Systems & Logs →
search/filter by org or location → open the system drill-down → see cameras/displays grouped by
`screen_group` with live reading + health per camera → jump to Composition Activity filtered to
this system to see what's actually playing.

## 6. Page Specs

**App shell (all pages):** Left sidebar grouped into "God View" (Main Dashboard, Composition
Activity, Systems & Logs) and "Tools" (Authoring, Activity Feed — muted "legacy" badge). Topbar:
breadcrumb, search, and a persistent pipeline-health badge (from the existing `/projector/status`
ok/warn/crit) visible on every page. Dark shadcn theme.

**Main Dashboard (`/`):** KPI card row (Systems Healthy, Active Compositions, Failures (Nh),
Pipeline Lag — each with sparkline); "Composing Now" horizontal strip of compact ad-run cards;
"Recent Failures" list (last 5); "Live Camera Readings" ticker (detection + health combined).

**Composition Activity (`/compositions`):** Search/filter bar (system, status, campaign, time
range); grid of ad-run cards with status badge + mini pipeline-stage dots; paginated.

**Ad Detail (`/compositions/:ad_run_id`):** Breadcrumb + status badge + system/location/campaign
context line. Node graph (built with `reactflow`): Trigger → Personalization Decision (branching
Decision-Input satellite: subject profile, decision_type, confidence, decision_factors) →
Composition Run (branching Creative-Input satellite: ad/component/input_asset/personalization
flags/output_asset) → Ad Run → Playback (one node per display, fans out). Ghosted/locked Viewer
Exposure node, visually present but disabled — marks where the next God View follow-on (§9) will
attach. Click any node → right-side inspector with full column values + error detail. Node color
follows the health-mode vocabulary (green/yellow/red/gray) for future consistency with the later
map work.

**Systems & Logs (`/systems`):** Search/filter bar + small KPI row. Systems table
(org/location/system/type/status/device count), row click → drill-down. Drill-down: cameras/
displays grouped by `screen_group`, each camera card combining live detection reading + stream/
device health. Chronological event/log table below. Banner for `unresolved_devices` when present.

A working HTML wireframe of the Main Dashboard and Ad Detail pages was reviewed and approved during
design; see the session artifact for the visual reference (dark console theme, monospace for
data/status, sans for headings/body).

## 7. New Schema: ScreenGroup

Resolves both the God View grouping need and the open zone/area question in
`handoff-03-peelback-orchestration-spec.md` — one concept, one table.

**New migration `025_screen_groups.sql`** (in `mras-ops/db/migrations/`, following the exact
conventions of `012_physical.sql`):

```sql
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

Design decisions:
- **`group_type` discriminator** instead of two tables — `'zone'` covers peel-back's area/movement
  grouping, `'ad_cluster'` covers "these displays should show the same ad together," `'custom'` is
  the catch-all.
- **Nullable FK on `displays`/`cameras`, not a join table** — no evidence a display/camera needs
  simultaneous multi-group membership today; a join table can replace this later without touching
  other tables (YAGNI).
- **`ad_runs` gets no new column** — shared-group membership across playbacks in one ad run is
  derivable via `playbacks → displays.screen_group_id`.
- **Both `cameras` and `displays` get the FK** (the original domain-model draft only proposed it on
  `cameras`) because the Systems & Logs drill-down groups both together under one wall/zone.

## 8. Build Approach

- **New standalone app** (e.g. `godview-prototype/`), not an extension of `mras-ops/frontend` — the
  production stack is expected to differ from this shadcn-based prototype, so the two are kept
  decoupled.
- **Stack:** React + Vite + TypeScript + shadcn/ui (Tailwind) + `reactflow` for the Ad Detail node
  graph.
- **Mock data first:** build against realistic fixtures matching real schema shapes (real
  table/column names, real enum values) before wiring any new ops-api endpoints. Wire to live data
  once the IA/pages are validated.
- **Dark theme**, extending the existing ops-console aesthetic (monospace for data/status figures,
  sans for headings/body), consistent with the wireframes reviewed in this design session.

## 9. Out of Scope / Phasing

(These are God View-specific follow-ons, not to be confused with the MRAS Phase 0/1/2 numbering
used elsewhere in the project.)

- **Next: Viewer Exposure / attention analytics.** Wires `viewer_exposures`
  (watched, gaze/attention fields) into Ad Detail and Main Dashboard. Explicitly comes **before**
  the map/globe work.
- **Later: Map / globe view.** The semantic-zoom map concept from
  `Godview_prototype_handoff.md` (dot-per-aggregate at each zoom level, health/live-adrun/volume/
  error/campaign map modes) is preserved as a future direction but is not part of this build. No
  schema work is needed for it beyond what already exists (§2).
- Auth/tenant-scoping enforcement remains deferred (per `handoff-04-godview-ux-ui.md` §6).
- Biometric privacy/blocklist machinery remains deferred to production go-live (standing item,
  unrelated to this build).

## 10. Open Items for Implementation Planning

- Exact mock-data fixture set needed to make all four pages feel populated (multiple orgs,
  locations, systems, a mix of healthy/degraded/failed states, at least one multi-display
  screen_group).
- Whether `reactflow`'s auto-layout or a hand-authored fixed layout is used for the Ad Detail graph
  (the wireframe used fixed positions).
- Exact ops-api endpoints to build once mock data is validated (deferred per §8, but the eventual
  list should follow `handoff-04-godview-ux-ui.md` §5's endpoint set, plus new endpoints for
  `screen_groups` and the Systems & Logs event/log table).
