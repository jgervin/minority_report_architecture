# God View Flat Map v3 — "Command Map" (2026-07-13)

**Status:** owner-directed design (decisions locked 2026-07-12 late session); pending outside
review — same process as v2 (outside opinion → amendments → plans → gate-check → build in a
FRESH session; see the v2 precedent in `docs/SESSION_LOG.md` 2026-07-12 (c)–(e)).
**Builds on:** Globe v2 (all three lanes live — spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md`).
**Visual references:** owner-supplied screenshots 2026-07-12 (in chat; archive to
`dashboard_images_ideas/` at build time): (1) dark navy/violet logistics command dashboard with
central styled map; (2) same family, close-up with entity cards, route lines, numbered stops,
task badges; (3) light transit dashboard — reference for the 2D ICONOGRAPHY only (vehicles/stops
as crisp glyphs with labels, layer-toggle chips, detail popover cards), NOT its light palette.

## 1. Goal

A **flat 2D map command view** (`/map`) that matches the app's dark navy/violet scheme, with the
**globe shrunken into a corner** as the planet-scale picker. Clicking a globe dot flies the flat
map to that country → city → building. On the flat map, groups, fleets, screens, and cameras
render as **proper 2D graphics** (glyphs/sprites/cards per reference 3's iconography) — not the
globe's sphere nodes. The flat map becomes the preferred day-to-day detail surface; the
full-screen globe remains the cinematic macro view.

## 2. Owner decisions (locked 2026-07-12, this session — do NOT re-ask)

| Decision | Choice |
|---|---|
| Full-screen globe explosion | **Keep both surfaces** — `/globe` stays exactly as shipped (explosion and all); the flat map is a parallel, richer detail view. (Owner separately dislikes the sphere nodes — see §8 futures; do not rework them in v3.) |
| Map engine | **Mapbox GL JS** — owner-chosen over MapLibre/Google. Token via `VITE_MAPBOX_TOKEN` env (never committed); free tier 50k loads/mo. Custom dark style matching the app theme. |
| Corner globe behavior | **v1 semantics only**: location dots + health/live encodings + pulse rings. NO explosion, NO arcs required (recon whether arcs read at mini size — planner's call), dots-only interactions. |
| Globe-dot click | Flat map **flies to** that venue's country/city/building (staged zoom); selecting a cluster flies to the city. |
| Building-level rendering | Groups, fleets (systems), screens, cameras as **2D glyphs + cards** (reference 3 iconography, reference 1/2 palette): distinct icons per type, status color ring/badge, name labels, click → existing detail panels. |
| Arc streak styling (v2 tuning, ships tonight) | Slow "candy-cane" stripes: multi-stripe dash pattern crawling slowly along org arcs, replacing the fast single streak — both for the lit-highlight loop and the recognition sweep. |

## 3. Page & interaction design (godview-prototype)

New route **`/map`**, nav item "Map" after "Globe" in Shell. Full-bleed like `/globe`:

- **Flat map center-stage** (`<FlatMapCanvas>`): Mapbox GL JS, custom dark style built from the
  app's theme tokens (bg/elev/border/dim/accent — extract the exact hex values from the Tailwind
  theme at plan time). Reference-1 look: muted navy landmass, near-black water, faint roads at
  city zoom, no POI noise. Style JSON lives in-repo (`src/map/style.json` or Studio-exported and
  committed) so the look is versioned.
- **Corner globe** (bottom-left, ~280–320px, collapsible): reuses the SHIPPED `GlobeCanvas` in a
  "mini" mode — v1 dots + rings only (props already support empty arcs/labels/explosion=null;
  recon at plan time whether a `mini` flag is needed to suppress chips/rail interactions).
  Auto-rotates when idle like v1. Clicking a dot/cluster does NOT open globe panels — it drives
  the flat map (`flyTo` staged: country zoom → city → building per current map zoom).
- **Zoom-semantic layers on the flat map** (mirrors the concept doc's "largest meaningful
  aggregate"):
  - World/country: venue markers with rollup badges (name + counts pill, health tone).
  - City: venue markers de-clustered, org-colored halo (matches globe org palette).
  - Building (venue selected/zoomed): the venue's topology laid out as 2D graphics — systems as
    group containers/cards, cameras and displays as GLYPH markers (camera icon, screen icon)
    with status ring + name label, connectors as thin styled lines (NOT the globe's 3D tubes).
    Uses real device lat/lng where present (schema has per-device lat/lng); falls back to a
    deterministic layout around the venue point when null (same sorted-ids discipline as
    explodeSelectors — reuse its pure helpers where possible).
- **Detail cards**: clicking any glyph opens the reference-2-style floating card anchored to the
  marker (name, status, last_seen, duty/screen-group, links) — data via the EXISTING
  `fetchMapLocation`/`fetchObjectDetail`; the right-panel components (VenuePanel/NodePanel) are
  the fallback if anchored cards prove heavy (planner decides, spec prefers anchored cards for
  the reference look).
- **Pulses on the flat map**: reuse the shipped delta engines (`diffFarPulses`/`diffDeepPulses`
  + `usePollDelta` — they are pure/portable by design): venue marker pulse at far zoom;
  camera→system→display animated line pulse at building zoom (Mapbox line-dasharray animation or
  a custom layer). Candy-cane pacing from the v2 tuning applies here too.
- **Mode switcher/legend/rail**: reuse ModeLegend + VenueRail (they're map-agnostic components).

## 4. Data

No backend changes expected: `/god-view/map` (venues + org + rollups + `last_run_created_at`),
`/god-view/map/locations/{id}` (systems/cameras/displays + ad_runs w/ display_id), and
`fetchObjectDetail` cover everything. Device-level lat/lng exists in the schema (012_physical);
seeded devices may have null coords — the deterministic-fallback layout (above) absorbs that.
If the planner finds a gap, additive-only per the standing rule.

## 5. Build plan sketch (planner refines)

Two plans, standard process: **Plan G** (map shell: Mapbox integration + dark style + corner
globe + fly-to wiring + zoom-semantic venue layer) then **Plan H** (building-level 2D topology +
detail cards + pulses). Frontend-only (godview-prototype). Worktrees, TDD red→green pairs,
task reviews, strongest-model final review, merge commits, live Playwright E2E per plan —
unchanged v2 process. Mapbox testability: the canvas is WebGL — same jsdom guard/tripwire
discipline as globe.gl (dynamic import behind a guard, pure selectors for everything testable).

## 6. Out of scope (v3)

- Retiring or redesigning the globe explosion (kept as-is by owner decision; sphere-node sprite
  redesign is a captured future, §8).
- Editing from the map (Fleet owns writes). Auth/tenant scoping (project-wide deferral).
- Offline venue operation of the flat map (Mapbox is a hosted dependency — the globe remains the
  offline-safe surface; note in README).
- Satellite/terrain imagery; routing/traffic semantics on connectors.

## 7. Risks / trade-offs

- **Mapbox token + metering**: requires an account token in env; free tier 50k loads/mo is ample
  for dev/demo but it's an external metered dependency (owner accepted). Token absence must
  degrade gracefully (page renders rail + corner globe + a "map unavailable" state, mirroring
  the WebGL fallback discipline).
- **Two WebGL contexts on one page** (Mapbox + mini globe): plausible perf cost on TV hardware —
  plan must budget a live check; mitigation = pause the mini globe's rotation/render when the
  flat map is animating (or on demand).
- Bundle: mapbox-gl is ~250KB gz — code-split like globe.gl (own lazy chunk, license note).

## 8. Futures captured (not v3)

- Globe explosion node sprites (owner: "not fond of the ugly circles") — replace spheres with
  camera/screen glyph sprites; candidate for a later globe polish lane (noted on godview #22).
- SSE push for pulses (unchanged from v2 deferral). Volume/Error/Campaign modes on both surfaces.
