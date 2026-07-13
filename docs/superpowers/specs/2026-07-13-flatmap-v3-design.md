# God View Flat Map v3 — "Command Map" (2026-07-13)

**Status:** owner-directed design (decisions locked 2026-07-12 late session); **outside review
COMPLETE 2026-07-13 — verdict PROCEED-WITH-AMENDMENTS (2 BLOCKING · 6 IMPORTANT · 4 MINOR); all
amendments folded into this spec** (see
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-outside-review.md`
for the full evidence-cited review). Same process as v2 (outside opinion → amendments → plans →
gate-check → build in a FRESH session; see the v2 precedent in `docs/SESSION_LOG.md` 2026-07-12
(c)–(e)). Next step: Plans G/H via read-only planners.
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

New route **`/map`**, nav item "Map" after "Globe" in Shell. Full-bleed like `/globe`. Wiring is
trivial and additive (review Amendment 9): add `{ path: "/map", element: <FlatMap /> }` to the flat
`createBrowserRouter` array in `src/routes.tsx`; add `{ to: "/map", label: "Map" }` after the
`/globe` entry in the static nav array in `src/components/Shell.tsx` (God View group); the page wraps
itself in `<Shell crumb="Map">` (pattern: `Globe.tsx`).

- **Flat map center-stage** (`<FlatMapCanvas>`): Mapbox GL JS, custom dark style built from the
  app's theme tokens (bg/elev/border/dim/accent — extract the exact hex values from the Tailwind
  theme at plan time). Reference-1 look: muted navy landmass, near-black water, faint roads at
  city zoom, no POI noise. Style JSON lives in-repo (`src/map/style.json` or Studio-exported and
  committed) so the look is versioned.
- **Corner globe** (bottom-left, ~280–320px, collapsible): reuses the SHIPPED `GlobeCanvas` for v1
  dots + rings only. **No `mini` flag is needed for rendering** (review Amendment 3): passing empty
  `arcs`/`labels`, `explosion=null`, `farPulses=null`, `deepPulses=null`, `liveSystems=∅`,
  `highlightOrgId=null`, `focus=null` already yields exactly v1 (dots + live-mode status rings);
  chips and the rail live in `Globe.tsx`, not in `GlobeCanvas`, so the mini page simply does not
  mount them; click routing is a page-supplied `onDotClick` handler; and the mini globe never flies
  because the page never sets `focus` (the fly effect is `if (!focus) return`). Auto-rotate stays on
  (desired v1 idle behavior). **The one component change required (review Amendment 2): add a
  `paused?: boolean` prop to `GlobeCanvas` in Plan G that calls globe.gl `pauseAnimation()` when true
  / `resumeAnimation()` when false** (verify exact method names against globe.gl 2.46.1 at build) —
  `autoRotate=false` stops the spin but NOT the render loop, so it is not the GPU-cost lever. The
  page sets `paused` while a Mapbox `flyTo`/zoom is in flight (Mapbox `movestart`→`moveend`).
  Clicking a dot/cluster does NOT open globe panels — it drives the flat map (`flyTo` staged: country
  zoom → city → building per current map zoom).
- **Two independent camera states** (review Amendment 10): the page owns BOTH the Mapbox map camera
  AND the mini globe's `pov` state. The mini globe's dot set comes from `clusterVenues(venues,
  altitude)`, which needs the globe pov altitude (city clusters vs venue dots) — it is independent of
  the Mapbox camera. Track globe pov via `GlobeCanvas`'s `onPovChange`, exactly as `Globe.tsx` does.
- **Zoom-semantic layers on the flat map** (mirrors the concept doc's "largest meaningful
  aggregate"):
  - World/country: venue markers with rollup badges (name + counts pill, health tone).
  - City: venue markers de-clustered, org-colored halo (matches globe org palette).
  - Building (venue selected/zoomed): the venue's topology laid out as 2D graphics — systems as
    group containers/cards, cameras and displays as GLYPH markers (camera icon, screen icon)
    with status ring + name label, connectors as thin styled lines (NOT the globe's 3D tubes).
    **Layout is deterministic-fallback ONLY in v3 (review Amendment 1 — BLOCKING).** The
    `/god-view/map/locations/{id}` endpoint returns NO per-device coordinates: `MapSystemDevice`
    has no `lat`/`lng` (`apiTypes.ts:143`), `map.py` selects none, and the `cameras`/`displays`
    tables carry no lat/lng columns at all (only the unexposed `devices` table does,
    `012_physical.sql:49`). So there is no real-coords branch to build — glyphs are ALWAYS laid out
    by a deterministic layout around the venue anchor point. **Real per-device positioning is a
    future additive backend lane** (add `lat,lng` to the camera/display SELECTs in `map.py` + to
    `MapSystemDevice`), explicitly OUT OF SCOPE for v3.
  - Fallback-layout reuse (review Amendment 4): reuse explodeSelectors' **sorted-ids determinism**
    (`byId`) and the **cos-lat ring-offset math** (`ringPoint`), NOT its degree constants or
    `explodeVenue` itself. Those helpers are currently module-private and their radii are DEGREES
    sized for the globe's macro band (`SYSTEM_RING_DEG=1.8` ≈ 200 km — absurd at building zoom). In
    Plan G, extract `byId`+`ringPoint` into a shared pure module (e.g. `src/data/layoutGeometry.ts`)
    and re-export from explodeSelectors so the globe path is byte-unchanged. The flat-map fallback
    (Plan H) reuses those primitives but supplies its **own building-scale radii in METERS**,
    converting to lat/lng offsets at the venue anchor (Mapbox projection).
- **Detail cards — panels FIRST, anchored cards as a follow-on refinement (review Amendment 6).**
  Plan H ships the reference-2 look via the EXISTING right-panel components as the buildable, tested
  first cut: reuse `VenuePanel` (self-polls `fetchMapLocation(locationId)` — drop-in) and `NodePanel`
  (fed by the page's `useVenueDetailPoll` `detail`, which the building layer already runs). Both are
  currently framed as a right slide-in. **Anchored floating cards** (positioned against a moving
  Mapbox marker, with collision/z-order handling) are net-new surface with their own edge cases —
  they are the v3 aspiration but a **follow-on refinement, NOT a Plan H gate**. Data via the existing
  `fetchMapLocation`/`fetchObjectDetail`.
- **Pulses on the flat map (review Amendment 5 — split reuse precisely):** reuse the PURE delta
  ENGINES verbatim — `diffFarPulses`, `diffDeepPulses`, `attributionCamera`, `deepPulsePath`,
  `usePollDelta` (no three/globe coupling; `deepPulsePath` resolves camera→system→display waypoints
  against any nodes built with the `${type}:${id}` key convention + lat/lng, altitude `0`). The
  venue-ring/sweep-arc datum BUILDERS (`pulseRingDatum`, `sweepArcDatum`) and `pulseLayer.ts` are
  globe.gl/three-render-specific and are **NOT** reused — the flat map gets a **NEW Mapbox pulse
  renderer** (line-dasharray animation or a custom marker): venue marker pulse at far zoom;
  camera→system→display animated line pulse at building zoom. Candy-cane pacing from the v2 tuning is
  the aesthetic goal here, not a code reuse.
- **Mode switcher/legend/rail**: reuse ModeLegend + VenueRail (they're map-agnostic components).

## 4. Data

No backend changes expected: `/god-view/map` (venues + org + rollups + `last_run_created_at`),
`/god-view/map/locations/{id}` (systems/cameras/displays + ad_runs w/ display_id), and
`fetchObjectDetail` cover everything. **Correction (review Amendment 1):** the map-location endpoint
does NOT expose per-device coordinates — the `devices` table has `lat`/`lng` (012_physical) but the
god-view camera/display projection does not select or return them (`MapSystemDevice` has no lat/lng;
`cameras`/`displays` tables have no lat/lng columns). The building layer therefore uses the
deterministic-fallback layout unconditionally (§3); "no backend changes" holds precisely BECAUSE the
real-coords path is out of scope. Exposing per-device coords is a future additive lane (additive-only
per the standing rule).

## 5. Build plan sketch (planner refines)

Two plans, standard process: **Plan G** (map shell) then **Plan H** (building-level topology +
cards + pulses). Frontend-only (godview-prototype). Worktrees, TDD red→green pairs, task reviews,
strongest-model final review, merge commits, live Playwright E2E per plan — unchanged v2 process.

**Plan G scope — and it OWNS the shared contracts Plan H consumes (review Amendment 7):** Mapbox
integration + dark style + corner globe (incl. the `paused` prop on `GlobeCanvas`) + staged fly-to
wiring + zoom-semantic venue layer, PLUS these three contracts authored in G so Plan H is pure
rendering:
  1. a pure `mapTier(zoom)` selector (world / city / building) + a "selected/zoomed venue" selector
     — the Mapbox-zoom analog of the globe's `explosionTier`/`explodedVenueId`; Plan G's fly-to
     staging must land at zooms this selector agrees with;
  2. the deterministic fallback-layout pure module (§3 / Amendment 4) with the shared
     `byId`/`ringPoint` extraction;
  3. the token/WebGL fallback seam (below) that Plan H's layers render inside.

**Plan H scope:** building-level 2D glyphs/cards (panels-first per Amendment 6) + the new Mapbox
pulse renderer (Amendment 5). Pure rendering against Plan G's contracts.

**Token / no-WebGL fallback seam (review Amendment 8):** render `<FlatMapCanvas>` ONLY when
`hasWebGL() && !!import.meta.env.VITE_MAPBOX_TOKEN`; otherwise a `data-testid="map-unavailable"`
panel in the map region. The rail is ALWAYS rendered; the corner globe renders whenever
`hasWebGL()`. The token check is a synchronous env read decidable BEFORE any dynamic import — never
load mapbox-gl without a token. Add `VITE_MAPBOX_TOKEN` to `.env.example` (documented, value
uncommitted).

**Mapbox testability (review Amendment 11):** the canvas is WebGL — same jsdom guard/tripwire
discipline as globe.gl (dynamic import behind `hasWebGL()`, pure selectors for everything testable:
`mapTier`, fallback layout, pulse deltas). Four mapbox-gl-specific gotchas beyond the globe pattern:
(a) set `mapboxgl.accessToken` before `new mapboxgl.Map(...)` — gate on the token env check, not just
`hasWebGL()`; (b) `import "mapbox-gl/dist/mapbox-gl.css"` must live INSIDE the dynamically-imported
module so vitest/jsdom never evaluates it (mirrors how `pulseLayer.ts` isolates its heavy imports);
(c) mapbox-gl spins a vector-tile Web Worker jsdom lacks — fine as long as the whole module sits
behind the `hasWebGL() && token` dynamic-import guard; (d) `mapboxgl.supported()` is deprecated in
v3 — rely on `hasWebGL()` + a try/catch around `new Map`, not `supported()`.

**Theme tokens for the dark style:** extract the exact hexes from `tailwind.config.ts` (verified
present): `bg #0a0d12, elev #12161d, sidebar #0d1016, border #212734, dim #8b93a3, faint #5b6472,
accent #45c4ff` + `ok/warn/crit/off` status colors.

## 6. Out of scope (v3)

- Retiring or redesigning the globe explosion (kept as-is by owner decision; sphere-node sprite
  redesign is a captured future, §8).
- Editing from the map (Fleet owns writes). Auth/tenant scoping (project-wide deferral).
- Offline venue operation of the flat map (Mapbox is a hosted dependency — the globe remains the
  offline-safe surface; note in README).
- Satellite/terrain imagery; routing/traffic semantics on connectors.

## 7. Risks / trade-offs

- **Mapbox token + metering**: requires an account token in env; free tier 50k loads/mo is ample
  for dev/demo but it's an external metered dependency (owner accepted). Token absence degrades
  gracefully via the exact synchronous seam specified in §5 (Amendment 8): rail always rendered,
  corner globe whenever `hasWebGL()`, `data-testid="map-unavailable"` in the map region.
- **Two WebGL contexts on one page** (Mapbox + mini globe): plausible perf cost on TV hardware —
  plan must budget a live check. **Mitigation = the new `paused` prop on `GlobeCanvas` calling
  globe.gl `pauseAnimation()`/`resumeAnimation()` (Amendment 2), driven by Mapbox
  `movestart`→`moveend`.** Note: `autoRotate=false` stops the spin but NOT the render loop, so it is
  NOT the GPU-cost lever — `pauseAnimation` is. The ~16-context browser cap is irrelevant at 2
  contexts; the real cost is GPU/memory.
- Bundle: mapbox-gl is ~250KB gz — code-split like globe.gl (own lazy chunk). **License (Amendment
  12): mapbox-gl v3.x is proprietary (Mapbox TOS, NOT the BSD/OSS MapLibre fork the owner
  rejected).** Do NOT strip the Mapbox attribution/logo control (TOS requirement); document the
  proprietary license + the 50k-load metering in the README next to the offline-safety note.

## 8. Futures captured (not v3)

- Globe explosion node sprites (owner: "not fond of the ugly circles") — replace spheres with
  camera/screen glyph sprites; candidate for a later globe polish lane (noted on godview #22).
- SSE push for pulses (unchanged from v2 deferral). Volume/Error/Campaign modes on both surfaces.
