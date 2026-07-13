# Flat Map v3 "Command Map" — Outside-Opinion Review (2026-07-13)

**Reviewer role:** fresh-context senior frontend architect. Same gate run for Globe v1/v2 lanes.
**Scope reviewed:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md`
against the live `/Users/jn/code/godview-prototype` codebase (and the mras-ops god-view endpoint it consumes).
**Read, not assumed:** GlobeCanvas, webgl.ts, routes/App/Shell, globe/topology/explode selectors,
pulseDelta, usePollDelta, useVenueDetailPoll, pulseLayer, api/apiTypes, ModeLegend/VenueRail/VenuePanel/NodePanel,
tailwind.config.ts/index.css, and `mras-ops/api/src/godview/map.py` + `db/migrations/012_physical.sql`.

I did **not** re-litigate the locked owner decisions (keep both surfaces / Mapbox GL / corner globe = v1 dots /
2D glyphs+cards). Everything below is HOW, not WHETHER.

---

## Verdict: **PROCEED-WITH-AMENDMENTS**

The spec's architecture is sound and most reuse claims hold. Two claims are wrong in ways that change the build
if left unamended: (1) the "real per-device lat/lng, no backend changes" data claim is false for the endpoint the
flat map actually calls — the building layout is **fallback-layout-only** in reality; (2) the named
two-WebGL-context mitigation ("pause the mini globe's render") is **not implementable through GlobeCanvas as
shipped** — it exposes no pause seam. Both have clean, small fixes. The rest are tightening.

**Amendment count:** 2 BLOCKING · 6 IMPORTANT · 4 MINOR.

---

## Amendments

### 1. [BLOCKING] "Real device lat/lng, no backend changes" is false for the map-location endpoint

**Concern.** §3 (building layer) says "Uses real device lat/lng where present (schema has per-device lat/lng)"
and §4 says "Device-level lat/lng exists in the schema (012_physical) … No backend changes expected." Both the
frontend type and the live endpoint contradict this.

**Evidence.**
- `godview-prototype/src/data/apiTypes.ts:143` — `MapSystemDevice` is `{ id; name; status; screen_id; last_seen_at }`.
  **No `lat`/`lng` field.** This is the only device shape `/god-view/map/locations/{id}` returns.
- `mras-ops/api/src/godview/map.py:177-182` — the camera/display SELECTs fetch
  `id, system_id, name, status, screen_id, last_seen_at` only. **No lat/lng selected.**
- `mras-ops/db/migrations/012_physical.sql:49` — `lat numeric, lng numeric` live on the **`devices`** table.
  The **`cameras`** (`:55-68`) and **`displays`** (`:71+`) tables the endpoint queries have **no lat/lng columns**;
  they reference `devices` only via a nullable `device_id`. So even at the DB layer, per-camera/display coords are
  not directly available to this query without a join through `devices`.

**Why it matters.** The "use real coords where present, fall back when null" dual-path in §3 has a **dead primary
branch** in v3: for cameras/displays there is no coord field to read at all. The building layout is therefore
**always** the deterministic fallback. Planning Plan H around a real-coords path is wasted work and a likely bug
(reading `device.lat` off a type that has none).

**Recommended change to the spec.** Rewrite the building-layer bullet to: *"Building-level glyphs are laid out by a
**deterministic fallback layout** around the venue anchor — the map-location endpoint returns no per-device
coordinates (`MapSystemDevice` has none; `cameras`/`displays` tables carry no lat/lng). Real per-device
positioning is a **future additive lane** (add `lat,lng` to the camera/display SELECTs in `map.py` + to
`MapSystemDevice`), explicitly out of scope for v3."* Strike "schema has per-device lat/lng" from §4 or qualify it
to "the `devices` table has lat/lng, but the god-view camera/display projection does not expose it."

---

### 2. [BLOCKING] The named two-WebGL mitigation ("pause the mini globe's render") has no seam in GlobeCanvas

**Concern.** §7 states the mitigation for two live WebGL contexts is "pause the mini globe's rotation/render when
the flat map is animating." As shipped, `GlobeCanvas` cannot be paused from outside, and pausing *rotation* does
not pause *rendering*.

**Evidence.**
- `GlobeCanvas.tsx:223-227` — `autoRotate` is set `true` unconditionally at init; the only stop path is an internal
  OrbitControls `"start"` listener. There is **no prop and no imperative ref** to control it from the parent.
- globe.gl renders on its own continuous rAF loop (three-render-objects). Setting `controls().autoRotate = false`
  stops the camera spin but the renderer **keeps drawing frames** — it does not idle the GPU. The GPU-cost lever is
  globe.gl's `pauseAnimation()` / `resumeAnimation()`, which `GlobeCanvas` never calls or surfaces.
- The component exposes only its prop bag (`:55-76`); no ref forwarding, no lifecycle hooks out.

**Why it matters.** The spec commits to a specific perf mitigation for the one genuinely new risk on TV hardware,
but the mitigation is not wireable against the component the spec reuses. Plan G would discover this at build time.

**Recommended change / planner directive.** Add a minimal, surgical seam to `GlobeCanvas` in **Plan G**: a
`paused?: boolean` prop whose effect calls `globe.pauseAnimation()` when true and `resumeAnimation()` when false
(verify exact method names against `globe.gl` 2.46.1 at build; they come from three-render-objects). The flat-map
page sets `paused` while a Mapbox `flyTo`/zoom is in flight (Mapbox fires `movestart`/`moveend`). This is the *only*
change `GlobeCanvas` needs for mini use — see Amendment 3. Budget the live two-context check the spec already asks
for, but note the real lever is `pauseAnimation`, not `autoRotate`.

---

### 3. [IMPORTANT] A `mini` flag is NOT needed for dots-only rendering — empty props already yield v1; the real gap is the pause seam

**Concern.** §3 leaves open "recon at plan time whether a `mini` flag is needed to suppress chips/rail
interactions." Reading the component, the answer is essentially **no flag needed** for rendering — which the
planner should be told outright so they don't build one.

**Evidence.**
- Passing `arcs={[]}`, `labels={[]}`, `explosion={null}`, `farPulses={null}`, `deepPulses={null}`,
  `liveSystems={new Set()}`, `highlightOrgId={null}`, `focus={null}` satisfies every required prop
  (`GlobeCanvas.tsx:55-76`) and renders exactly v1: dots (`pointsData`) + live-mode status rings (`ringsFor`,
  `globeSelectors.ts:198`). Empty arcs/labels arrays no-op their effects (`:273-301`).
- Chips and the rail are **not inside** `GlobeCanvas` — they live in `Globe.tsx:120-123`. The mini page simply
  doesn't render them; nothing to "suppress."
- Click routing needs no flag: `onDotClick` is a page-supplied handler (`Globe.tsx:104`). The mini page passes a
  handler that calls the flat map's `flyTo` instead of opening a panel.
- The mini globe must **not** fly on selection (it's a macro picker) — the page achieves that by simply never
  setting `focus` (the fly effect `:473` is `if (!focus) return`).
- Sizing is automatic: width/height come from the container via `ResizeObserver` (`:222,228`), so a ~300px box
  just works.

**Recommended change to the spec.** Replace the "recon whether a `mini` flag is needed" note with: *"No `mini`
flag is needed for rendering — empty arcs/labels/null-explosion already yield v1 dots+rings, and chips/rail are
page-level so they're simply not mounted. The only `GlobeCanvas` change required is the `paused` prop (Amendment 2).
Auto-rotate stays on (desired v1 idle behavior)."*

---

### 4. [IMPORTANT] "Reuse explodeSelectors' pure helpers" — the reusable helpers are private and their scale is globe-macro, not building-zoom

**Concern.** §3 says the fallback layout should reuse explodeSelectors' "sorted-ids discipline… reuse its pure
helpers where possible." The genuinely reusable pieces are **not exported**, and the geometry constants are sized
for the globe's macro band, not a building-zoom Mapbox view.

**Evidence.**
- The reusable primitives are `byId()` (`explodeSelectors.ts:88`, deterministic sort — the "sorted-ids discipline")
  and `ringPoint()` (`:81`, degree-offset with the mandatory `cos(lat)` correction). **Both are module-private** —
  not in the export list. `explodeVenue()` itself (`:95`) is *not* reusable: it returns an `ExplosionLayout` with
  `altitude`/`NODE_ALTITUDE` fields, a 9-point hull octagon, and globe-connector shapes — all globe-specific
  (`:38-45`, `:166-172`).
- The ring radii are **degrees**: `SYSTEM_RING_DEG = 1.8`, `DEVICE_RING_DEG = 3.2`, `HULL_RING_DEG = 4.2`
  (`:19-22`). 1.8° of latitude ≈ 200 km — correct for the globe's explode band, **absurd at building zoom**. A flat
  map fallback wants a metric offset (tens of meters) around the venue point, projected via Mapbox, not shared
  constants.

**Recommended change / planner directive.** In **Plan G**, extract `byId` + `ringPoint` into a shared pure module
(e.g. `src/data/layoutGeometry.ts`) and re-export from explodeSelectors so the globe path is unchanged (surgical).
The flat-map fallback in Plan H reuses **`byId` (determinism)** and **the `ringPoint` cos-lat idea** but supplies its
**own building-scale radii in meters**, converting to lat/lng offsets at the venue anchor. Spec should say "reuse
the *sorted-ids determinism and cos-lat ring math*, not the globe's degree constants or `explodeVenue` itself."

---

### 5. [IMPORTANT] Split the pulse reuse claim: delta ENGINES are portable, the datum BUILDERS and pulseLayer are globe-only

**Concern.** §3 says "reuse the shipped delta engines (`diffFarPulses`/`diffDeepPulses` + `usePollDelta`) — they
are pure/portable by design." True for the *engines*, but the same file's *rendering builders* are globe-coupled and
must not be reused; the spec should draw that line so the planner scopes new Mapbox rendering correctly.

**Evidence — portable (reuse verbatim):**
- `pulseDelta.diffFarPulses` (`pulseDelta.ts:21`) returns plain `{venueId,lat,lng,orgId}`; `diffDeepPulses`
  (`:60`) returns `{systemId,cameraId,displayId}`; `attributionCamera` (`:48`) and `deepPulsePath` (`:93`) are pure.
  `usePollDelta` (`usePollDelta.ts`) is pure React state — no three, no globe. All map-agnostic.
- `deepPulsePath` even reuses cleanly: it takes `nodes: Pick<ExplodedNode,'key'|'type'|'id'|'lat'|'lng'|'altitude'>`
  and matches on the `${type}:${id}` key. If the flat map builds its fallback nodes with the same key convention and
  lat/lng (altitude `0`), `deepPulsePath` resolves the camera→system→display waypoints unchanged.

**Evidence — globe-only (new Mapbox impl required):**
- `pulseRingDatum` (`:127`) emits a `RingDatum` with globe.gl `maxRadius`/`speed`/`repeatPeriod` units;
  `sweepArcDatum` (`:144`) emits an `OrgArcDatum` with globe arc-dash fields — neither maps to Mapbox layers.
- `pulseLayer.ts` (whole file) is three/`Line2`/`LineMaterial` and is dynamically imported behind the WebGL guard —
  **100% globe-coupled**, not reusable.

**Recommended change to the spec.** Amend §3 to: *"Reuse the pure delta engines (`diffFarPulses`,
`diffDeepPulses`, `attributionCamera`, `deepPulsePath`, `usePollDelta`). The venue-ring / sweep-arc datum builders
(`pulseRingDatum`, `sweepArcDatum`) and `pulseLayer.ts` are globe-render-specific and are **not** reused — the flat
map gets a **new** Mapbox pulse renderer (line-dasharray animation or a custom marker), targeting the candy-cane
pacing as an aesthetic goal, not a code reuse."*

---

### 6. [IMPORTANT] Panels (VenuePanel/NodePanel) are the lower-risk first cut; anchored cards are net-new — recommend panels for the first buildable slice

**Concern.** §3 prefers anchored floating cards, panels as fallback. Given the real components, panels are markedly
lower-risk and the spec's "planner decides" should carry a recommendation.

**Evidence.**
- `VenuePanel` (`VenuePanel.tsx:12`) self-polls `fetchMapLocation(locationId)` and is fully self-contained — drop
  it in, pass `locationId`. Zero new wiring.
- `NodePanel` (`NodePanel.tsx:14`) needs a `detail: MapLocationDetail` prop from a page-level venue detail poll plus
  `type`/`id` — the flat map page already has to run `useVenueDetailPoll` for the building layer, so `detail` is on
  hand. Reusable with modest wiring.
- **But both are framed as a right slide-in** (`bg-sidebar/95 border-l border-border`, `NodePanel.tsx:40`;
  `VenuePanel.tsx:66`). As "anchored-to-marker" cards they're the wrong frame — anchored cards are a **new**
  component (positioning against a moving Mapbox marker, collision handling, z-order over the canvas). That's real
  net-new surface with its own edge cases.

**Recommended change to the spec.** Keep the anchored-card look as the v3 aspiration, but direct the planner: *"Plan
H ships **panels first** (reuse `VenuePanel` self-polling; reuse `NodePanel` fed by the page's `useVenueDetailPoll`)
as the buildable, tested first cut. Anchored cards are a follow-on refinement, not a Plan H gate."* This de-risks the
plan without touching the locked 2D-glyphs+cards decision.

---

### 7. [IMPORTANT] Plan G must own the shared contracts Plan H consumes (zoom→tier selector, fallback-layout module, fallback seams) — otherwise Plan H blocks

**Concern.** The G/H boundary is drawn in a buildable place, but three contracts Plan H depends on are implicit.
Name them and assign them to Plan G, mirroring how the globe made `explosionTier`/`explodedVenueId` pure and
page-owned.

**Evidence / analogy.**
- The globe path put the zoom→behavior decision in a pure selector (`explodeSelectors.explosionTier`,
  `:47`; `explodedVenueId`, `:59`) and the page (`Globe.tsx:50-60`) drove it. The flat map needs the **Mapbox-zoom
  analog**: a pure `mapTier(zoom)` (world/city/building) + "which venue is selected/zoomed" selector. Plan H's
  building layer keys off it; Plan G's fly-to staging (`country→city→building`, §3) must land at zooms this selector
  agrees with. Shared contract → Plan G.
- The **fallback-layout pure module** (Amendment 4) is a Plan H input but should be *authored in Plan G* as the
  contract, so Plan H just renders.
- The **token-absent / no-WebGL fallback seam** (Amendment 8) is a Plan G shell concern that Plan H's layers must
  render inside.

**Recommended change to the spec.** In §5, expand Plan G's scope to explicitly include: *the pure `mapTier(zoom)`
+ selected-venue selectors, the deterministic fallback-layout module, and the token/WebGL fallback seam* — labeled as
"contracts Plan H consumes." Leaves Plan H = pure rendering + pulses + cards.

---

### 8. [IMPORTANT] Token-absent + no-WebGL fallback: specify the exact synchronous seam and the nesting

**Concern.** §7 says token absence must "degrade gracefully (rail + corner globe + 'map unavailable')," but doesn't
pin the seam, and the two failure modes (no token vs no WebGL) nest.

**Evidence.**
- `webgl.ts:hasWebGL()` is the existing guard; jsdom returns null so mapbox-gl is never imported in tests — the
  pattern transfers (Amendment 11). The **token** check is different: it's a synchronous env read
  (`import.meta.env.VITE_MAPBOX_TOKEN`), decidable **before** any dynamic import. `.env.example` currently defines
  only `VITE_OPS_API_URL` — `VITE_MAPBOX_TOKEN` must be added there (documented, uncommitted value).
- The corner globe itself needs WebGL. If WebGL is absent, **both** surfaces fall back (GlobeCanvas already renders
  `globe-fallback`, `:480-488`). If only the token is missing, the map falls back but the mini globe still runs.

**Recommended change / planner directive.** Cleanest seam: the flat-map page renders `<FlatMapCanvas>` only when
`hasWebGL() && !!import.meta.env.VITE_MAPBOX_TOKEN`; otherwise a `data-testid="map-unavailable"` panel in the map
region, with the rail always rendered and the corner globe rendered whenever `hasWebGL()`. Add `VITE_MAPBOX_TOKEN`
to `.env.example`. State that the token check is synchronous and gates the import (never load mapbox-gl without a
token).

---

### 9. [MINOR] Routing/nav wiring is trivial but name the exact files and the additive edit

**Concern.** §3 says "nav item 'Map' after 'Globe' in Shell." Just pin the two edits so the planner treats them as a
one-line task, not discovery.

**Evidence.** Routes are a flat `createBrowserRouter` array (`routes.tsx:9-16`) — add `{ path: "/map", element:
<FlatMap /> }`. Nav is a static array (`Shell.tsx:18-25`); add `{ to: "/map", label: "Map" }` after the `/globe`
entry in the "God View" group. Each page wraps itself in `<Shell crumb="Map">` (pattern: `Globe.tsx:113`).

**Recommended change.** Add these file/line references to §3/§5 so it's unambiguous.

---

### 10. [MINOR] The flat-map page must hold its own `pov`/zoom state to feed `clusterVenues` for the mini globe

**Concern.** The mini globe renders dots via `clusterVenues(venues, altitude)` (`Globe.tsx:35`,
`globeSelectors.ts:76`), which needs an altitude. The mini picker sits at macro zoom, but the page still must track
the mini globe's pov to compute its dot set (city clusters vs venue dots).

**Evidence.** `Globe.tsx:28,35` holds `pov` state and derives `dots` from it; `GlobeCanvas` reports pov via
`onPovChange` (`:172`). The flat-map page needs the same `pov` state for the mini globe (independent of the Mapbox
camera).

**Recommended change.** Note in §3 that the page owns two independent camera states: the Mapbox map camera and the
mini globe pov (the latter drives `clusterVenues`). Minor, but avoids a "why are there no dots" build stumble.

---

### 11. [MINOR] Mapbox testability transfers, with three concrete gotchas beyond the globe pattern

**Concern.** §5 says "same jsdom guard/tripwire discipline as globe.gl." The guard transfers, but mapbox-gl's init
differs from globe.gl in ways worth pre-flagging.

**Evidence / gotchas.**
- **Token before construct.** mapbox-gl requires `mapboxgl.accessToken = <token>` set before `new mapboxgl.Map(...)`
  — gate on the env check (Amendment 8), not just `hasWebGL()`.
- **CSS import.** mapbox-gl needs `import "mapbox-gl/dist/mapbox-gl.css"`. Keep it inside the dynamically-imported
  module so vitest/jsdom never evaluates it (mirrors how `pulseLayer.ts` isolates its heavy static imports,
  `pulseLayer.ts:9-12`).
- **Web Worker.** mapbox-gl spins a worker for vector tiles; jsdom has none. Fine as long as the whole module sits
  behind the `hasWebGL() && token` dynamic-import guard so tests never load it. Keep everything testable in **pure
  selectors** (mapTier, fallback layout, pulse deltas) exactly as the globe did.
- `mapboxgl.supported()` is deprecated in v3 — rely on `hasWebGL()` + a try/catch around `new Map`, not `supported()`.

**Recommended change.** Fold these four into §5's testability paragraph as the mapbox-gl-specific delta from the
globe pattern.

---

### 12. [MINOR] Mapbox GL v3 is proprietary (TOS + mandatory attribution) — the "license note" must mean "keep the logo/attribution"

**Concern.** §7 says "license note." mapbox-gl v3.x is **not** open source (Mapbox TOS); MapLibre was the OSS fork
the owner explicitly rejected (locked). The TOS requires the Mapbox wordmark and attribution stay visible.

**Evidence.** Owner decision (§2) locks Mapbox GL JS over MapLibre. mapbox-gl v3 ships under the Mapbox Terms of
Service, not BSD (that was ≤ v1.13 / MapLibre). Attribution control must not be hidden.

**Recommended change.** Change "license note" to a concrete directive: *"Do not strip the Mapbox attribution/logo
control (TOS requirement); document mapbox-gl's proprietary license + the 50k-load metering in the README next to
the offline-safety note."*

---

## Reuse-surface verification table

| Spec claim | Verified? | Note (file:line) |
|---|---|---|
| `GlobeCanvas` runs as v1 dots-only via empty arcs/labels/null explosion | **YES** | All required props satisfiable; empty arrays no-op (`GlobeCanvas.tsx:55-76,273-301`). No `mini` flag needed for rendering. |
| A `mini` flag is needed | **NO** | Chips/rail are page-level (`Globe.tsx:120-123`), not in the component; click routing is page-supplied (`:104`). Only a `paused` prop is needed. |
| Pause mini-globe render when flat map animates (§7 mitigation) | **NO (as written)** | No pause seam on `GlobeCanvas`; `autoRotate` ≠ render pause (`:223-227`). Needs new `paused`→`pauseAnimation()` prop. |
| `diffFarPulses`/`diffDeepPulses`/`usePollDelta` are pure/portable | **YES** | No three/globe imports (`pulseDelta.ts:21,60`; `usePollDelta.ts`). Map-agnostic. |
| `deepPulsePath`/`attributionCamera` reusable on flat map | **YES** | Pure, key-based (`pulseDelta.ts:48,93`); resolves against any nodes with `${type}:${id}` keys + lat/lng. |
| `pulseRingDatum`/`sweepArcDatum`/`pulseLayer` reusable | **NO** | globe.gl ring/arc units + three/Line2 (`pulseDelta.ts:127,144`; `pulseLayer.ts` whole file). New Mapbox renderer required. |
| Reuse explodeSelectors' pure helpers for fallback layout | **PARTIAL** | `byId`/`ringPoint` are the reusable bits but **private** (`explodeSelectors.ts:81,88`); `explodeVenue` is globe-shaped; ring constants are degrees/macro-scale (`:19-22`) — wrong at building zoom. |
| ModeLegend is map-agnostic/reusable | **YES** | Pure props `mode`/`onMode`, Tailwind only (`ModeLegend.tsx`). |
| VenueRail is map-agnostic/reusable | **YES** | Pure props, no globe (`VenueRail.tsx:6-11`). |
| VenuePanel/NodePanel usable as card fallback | **YES (as panels)** | VenuePanel self-polls (`VenuePanel.tsx:12`); NodePanel needs page `detail` (`NodePanel.tsx:14`). Both are right-panel-framed — **not** anchored cards (those are net-new). |
| Endpoints exist: `/god-view/map`, `/god-view/map/locations/{id}`, `fetchObjectDetail` | **YES** | `api.ts:105-107,61`; `mras-ops main.py:409,415`. |
| `/god-view/map` returns venues+org+rollups+`last_run_created_at` | **YES** | `apiTypes.ts:127-141` (org/rollup/`last_run_created_at` optional-additive). |
| Per-device lat/lng present in the map-location payload | **NO** | `MapSystemDevice` has none (`apiTypes.ts:143`); `map.py:177-182` selects no lat/lng; `cameras`/`displays` tables have no lat/lng columns (`012_physical.sql:55-77`). Only `devices` table has them (`:49`), unexposed. → building layout is fallback-only; "no backend changes" holds **only** if the real-coords path is dropped. |
| Theme tokens exist to build the Mapbox dark style | **YES** | `tailwind.config.ts` colors: `bg #0a0d12, elev #12161d, sidebar #0d1016, border #212734, dim #8b93a3, faint #5b6472, accent #45c4ff, ok/warn/crit/off`. Extract these exact hexes for style.json. |
| `mini` mode second WebGL context caps | Not a blocker | Browser ~16-context cap is irrelevant at 2 contexts; the real cost is GPU/memory on TV hardware — mitigation is Amendment 2. |

---

## Bottom line for the planner

Proceed. Before Plan H, land the two BLOCKING fixes in the spec: (1) building layout is **deterministic-fallback
only** (no real device coords in the endpoint), and (2) add a `paused` prop to `GlobeCanvas` in Plan G so the
two-context mitigation is actually wireable. Fold the reuse-line clarifications (Amendments 4, 5, 6) into the spec so
Plan H scopes new-vs-reused rendering correctly, and give Plan G the shared contracts (Amendment 7). The remaining
items are one-line tightenings.
