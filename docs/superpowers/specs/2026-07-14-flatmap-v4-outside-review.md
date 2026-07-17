# Flat Map v4 — Outside Review (grounded, skeptical)

**Reviewer role:** fresh-context outside reviewer. **Verified against real code** in
`/Users/jn/code/godview-prototype` (read-only, no edits). **Reviewed docs:**
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-14-flatmap-v4-design.md`
and `.../2026-07-14-flatmap-v4-investigation.md`.

---

## Verdict: **PROCEED-WITH-AMENDMENTS**

The two root-cause diagnoses are correct against the code, the reuse surface is mostly respected,
and every change area is feasible. But two load-bearing decisions are wrong or under-specified as
written — the **§C "SDF-tinted" default** (unreliable in-browser) and the **§B DOM→symbol
migration** (under-specified, orphans a pure module). Neither warrants REWORK; the spec's skeleton
is sound. Fix the amendments below and split into two plans.

**Amendment counts: BLOCKING 2 · IMPORTANT 4 · MINOR 3.**

### The 2–4 most important amendments (one line each)
- **B1 (BLOCKING):** Drop SDF-in-browser as the §C default — lucide icons are *stroke* SVGs that
  rasterize to thin binary alpha (a poor SDF); use **non-SDF pre-tinted raster images** (kind × status, `sdf:false`), select by expression, no `icon-color`.
- **B2 (BLOCKING):** §B venue→symbol migration is under-specified — it *replaces* the pure module
  `src/data/venueMarkers.ts` + its test and must re-express the rollup badge / org-halo / status-ring; spec §7 currently omits venueMarkers.ts from the reuse surface (reuse violation risk).
- **I1 (IMPORTANT):** §A is not just retiring `nextFlyZoom` — the camera effect hardcodes
  `duration:1200` with no `essential:true` (`FlatMapCanvas.tsx:250`); it must honor the ~2 s
  one-hop duration and split `flyToVenue` (venue→building 15.5, cluster→city 11).
- **I4 (IMPORTANT):** Ship the pre-existing `anchor`-memo churn fix (#30) as part of this lane —
  the mini-globe autorotate re-renders FlatMap every frame, and `anchor` (`FlatMap.tsx:57`) is a
  fresh object each render → `nodes`/`building` recompute → building-glyph `setData` fires every
  frame. Adding a venue symbol layer on top of that makes the thrash worse.

### Recommended plan split
- **Plan I — Map data/visual layer (the risky, coupled work):** §A one-hop flyTo · §B declutter ·
  §C icons · §H building-node click. Shared contract = the icon-image registry + the symbol-layer
  feature schema. Do this first (it closes both hard bugs #31 and the label-stack bug).
- **Plan J — Chrome/controls (lower-risk, mostly independent React/CSS):** §D legend · §E panel
  collapse (both pages) · §F corner-globe reposition + size + zoom · §G map +/- buttons. Shared
  contract = the additive `GlobeCanvas` zoom prop (needed by §F only). Plan J touches no map data.

The two plans share almost nothing (only §F's GlobeCanvas prop), so the boundary is clean. Plan I
carries all the technical risk; Plan J is chrome. Sequence I → J.

---

## Amendments

### BLOCKING

**B1 — §C: reject SDF-in-browser as the default; use non-SDF pre-tinted rasters.**
Verified: lucide-react `1.23.0` **is** installed (`node_modules/lucide-react/package.json`), and
each icon exports its raw geometry as `__iconNode` (e.g.
`node_modules/lucide-react/dist/esm/icons/server.mjs` exports
`__iconNode = [["rect",{…}],["line",{…}],…]`). Crucially these are **stroke** primitives
(`fill:none`, `stroke:currentColor`, `stroke-width:2` via `defaultAttributes.mjs`), not filled
glyphs. Consequences:
- A true SDF needs a **distance transform** over the rasterized shape. A thin stroke rasterized to
  a binary alpha mask is a *degenerate* SDF — Mapbox interprets alpha as distance-from-edge with
  the edge at α≈0.75, so a binary mask renders blurry/haloed and scales badly. Generating a real
  distance-transform in-browser per icon is extra code for no payoff here.
- **Fix:** pre-render **N icon types × M statuses** small raster images (4 icons ×
  {ok,warn,crit,off} = 16), each already stroked in its status color, `map.addImage(name, bitmap,
  {sdf:false})` once on `load`. Symbol layer selects with
  `"icon-image": ["concat", ["get","kind"], "-", ["get","status"]]`. This gives per-status color
  (§C requirement) AND Mapbox collision (§B requirement) with zero distance-transform. Note:
  `icon-color` only tints SDF images, so per-status color *must* be baked into the raster — the
  expression picks the pre-tinted image; do not keep `icon-color:["get","color"]`.
- **Test isolation (same discipline as `mapboxImpl.ts`):** the pure, jsdom-testable seam is
  `__iconNode → SVG string` (string assembly, no canvas). The raster step (SVG string →
  `ImageBitmap`/`ImageData`) needs a canvas, which **jsdom does not have** — put it in a module
  reached only via `import(...)` behind the existing WebGL/`ready` guard (exactly how
  `mapboxImpl.ts` hides `mapbox-gl`). Unit-test the SVG-string builder; the raster runs only in the
  live E2E.
- Resolve §5 open-choice #5 to **non-SDF pre-tinted** (see M2). SDF is a *non-default* fallback only
  if the palette ever needs arbitrary runtime color (it doesn't — status is a fixed 4-value set).

**B2 — §B: the DOM→symbol migration is under-specified and orphans a pure module.**
Verified today: venues are DOM `mapboxgl.Marker`s (`FlatMapCanvas.tsx:164-166`) built by
`src/data/venueMarkers.ts` (`buildVenueMarker`), which carries the world-tier rollup badge
(`name · N sys`), the org-halo (`box-shadow`+`border`) and the health dot. **Nothing clicks the
venue marker** — confirmed: no `getElement`/`addEventListener`/`on("click")` on markers anywhere
(grep clean); selection is driven only by the rail (`FlatMap.tsx:103-107`) and the corner globe
(`FlatMap.tsx:89-92`). So migrating venues to a symbol layer breaks **no** click path — good — but:
- (a) The **rollup badge** (systems count) is expressible only as a *second* `text-field`/expression
  or must be dropped at world tier. State which.
- (b) The **org-halo / status-ring** does not survive as icon styling for free — re-express as
  `icon-halo-color`/`icon-halo-width` (status ring) plus either a second circle layer under the
  icon (org halo) or drop the org halo at world tier. State which.
- (c) `venueMarkers.ts` becomes **dead**, and `src/data/venueMarkers.test.ts` (4 assertions on
  `venue-marker` / `venue-rollup-badge`) goes with it. Per CLAUDE.md §3 this must be an explicit
  *replacement*, not an orphan: introduce a pure `src/data/venueFeatures.ts` (a direct parallel to
  the existing `src/data/buildingFeatures.ts`) that emits venue GeoJSON, and migrate the test.
  **Spec §7's reuse surface lists buildingFeatures/mapLayout/mapSelectors but omits
  `venueMarkers.ts`** — add it as "replaced by venueFeatures.ts," or you have an untracked orphan.
- **Pragmatic recommendation:** because §C (icons) is owner-locked and in scope anyway, do the full
  symbol-layer migration (it's the only thing that gives real Mapbox collision) — but *if scope has
  to be trimmed*, the cheap fallback that closes the reported label-stack bug alone is to **stop
  emitting the world-tier text badge** (render dot+icon only, reveal the name on hover/selected).
  That kills stacking in ~10 lines without a migration. Call this out as the fallback so the lane
  can descope under pressure.

### IMPORTANT

**I1 — §A: the flyTo effect itself must change, not just `nextFlyZoom`.** The camera effect
hardcodes `map.flyTo({ center, zoom: focus.zoom, duration: 1200 })` (`FlatMapCanvas.tsx:247-251`)
with no `essential:true` and no `curve`/`speed`. §A wants ~1.8–2.5 s and a one-hop feel, and
without `essential:true` Mapbox skips/jump-cuts the animation under `prefers-reduced-motion` or a
backgrounded tab. Also `flyToVenue` (`FlatMap.tsx:80-81`) must split: **venue selection →
`STAGE_ZOOM.building` (15.5) directly**, **cluster centroid → `STAGE_ZOOM.city` (11)** — today both
call `nextFlyZoom(mapZoom)`. Carry a `duration` (and target zoom) on `MapFocus`, or set them as
constants in the effect. `nextFlyZoom` may remain for manual step-zoom but selection stops using it.

**I2 — §A: decouple detail *fetch* from *render* to kill latency and avoid world-tier glyphs.**
Today `buildingVenueId = mapTier(mapZoom) === "building" ? selectedVenueId : null`
(`FlatMap.tsx:55`) gates *both* the fetch and (via `building!=null`) the render. Verified the zoom
event fires continuously during flyTo (`FlatMapCanvas.tsx:84-88` → `setMapZoom`), so the fetch
*does* start mid-flight — good, not on settle — **but** zoom 14 is only crossed late in an ease to
15.5, so glyphs still pop in near the end. **Fix:** fetch eagerly on `selectedVenueId` (start at
click), but compute `building` only when `mapTier==="building"` (keep render zoom-gated). This
preloads detail during the fly and renders the instant tier flips, without ever drawing tiny
building glyphs at world tier. Answer to the risk-3 question: keep the observed-zoom gate for
*render*; use selection intent for *fetch*. No need for a separate explicit "building intent" flag.

**I3 — §E: the right-panel "collapse" is largely a solved problem; scope the real new work.**
Verified: both pages already close the right panel via `onClose={() => setPanel(null)}`
(`FlatMap.tsx:128,130`; `Globe.tsx:142,144`) and re-open it on selection via `setPanel(...)`
(`FlatMap.tsx:86,105`; `Globe.tsx:99,109`). So "close/collapse, reopens on selection" is **already
implemented** if collapse == `setPanel(null)`. Confirming the spec's claim: yes, "selection →
setPanel" is already true and there is no force-hide on select. The genuinely new work is only:
(a) **left-rail collapse** on both pages (page-level `grid-cols-[280px_…]` → `[40px_…]`/`[0_…]`
swap — the grid template lives on the page div `FlatMap.tsx:101` / `Globe.tsx:119`, so collapse
state must live at page level), and (b) a **positioning wrapper for FlatMap's right panel**, which
is currently mounted **bare** (`FlatMap.tsx:127-130`, no wrapper) vs Globe's `venue-panel-wrap`
(`Globe.tsx:138-140`). **Smallest shared surface:** a tiny `useRailCollapse()` hook (boolean +
toggle) + a shared `<CollapseToggle>` button + a shared panel wrapper component. **Do not** build a
monolithic shared `CollapsibleRail` that renders the grid — the two rails differ materially (Globe's
is `hidden lg:block` + `OrgChips` + a mobile bottom-sheet `railOpen`; FlatMap's is always-visible +
`VenueRail` only), so a single component leaks. **Caveat:** if you model panel-collapse as a
*separate* boolean (not `setPanel(null)`), the select handlers must also `setPanelCollapsed(false)`,
or selection won't reopen it — simplest is to keep close == `setPanel(null)`.

**I4 — Risk 6: fix the pre-existing per-frame `setData` churn (#30) before layering more on it, and
manage cross-layer symbol collision.** Verified the churn: `anchor` (`FlatMap.tsx:57`) is a fresh
object literal each render, so `nodes` (`useMemo … [anchor, detail]`) and `building` recompute every
render; the mini-globe's autorotate emits `onPovChange` → `setPov` → FlatMap re-renders
continuously → building-glyph `setData` (`FlatMapCanvas.tsx:174-179`) re-parses GeoJSON every frame
while the globe spins. Memoize `anchor` on the `lat`/`lng` primitives. Separately, once venues are a
symbol layer, you'll have **venue labels + building-glyph labels** colliding globally (Mapbox
collides across all symbol layers), plus the existing `building-glyphs-symbol` text
(`FlatMapCanvas.tsx:104-111`). Add `symbol-sort-key` (worst_status severity, then system count per
§B) and decide z-order; at building tier consider suppressing venue labels so building nodes win.

### MINOR

**M1 — §F: expose the globe zoom as a token-bumped prop, not a ref handle.** Verified globe.gl
`2.46.1` has both `pointOfView(): GeoCoords` (getter) and
`pointOfView({lat?,lng?,altitude?}, transitionMs?)` (setter) (`globe.gl.d.ts:113-114`) — already
used at `GlobeCanvas.tsx:479`. So an additive altitude-zoom is feasible: read current altitude, set
`altitude ± step`. **Cleanest seam:** a new `zoomCmd: {delta, token} | null` prop consumed in an
effect — this mirrors the existing token-bumped `focus` one-shot pattern (`GlobeCanvas.tsx:23`,
`475-480`). A `forwardRef` imperative handle would be a *new* pattern (no ref-based imperative
handles exist in this codebase). It's purely additive: doesn't touch dispose, `paused`, or
`onPovChange`, and `/globe` (which never passes it) stays byte-identical. **Caveat:** the corner
globe runs `paused={cameraBusy}` (`FlatMap.tsx:122`) — `pauseAnimation` stops the render loop, so a
zoom-button press *while the main map is flying* won't visibly animate until the fly ends. Acceptable;
note it.

**M2 — §5 open-choice #5:** resolve to **non-SDF pre-tinted rasters** (per B1), not "SDF-tinted."
The spec's stated default is the least reliable option; flip it.

**M3 — §G: the default `+/-` position (bottom-right) collides with the Mapbox attribution.**
Verified `attributionControl:true` (`mapboxImpl.ts:16`) with no positioning override, so the
attribution sits **bottom-right** by default — exactly where §G wants the zoom buttons. Move the
map `+/-` to **top-right** (globe is top-left, legend bottom-left per §D) or offset it above the
attribution, and/or set the attribution to `compact`. As-specified they overlap.

---

## Answers to the 7 scrutinized risks (summary)

1. **DOM→symbol migration (§B/§C).** Feasible; nothing clicks the venue marker today (grep-clean),
   so no click path breaks. But it's under-specified and orphans `venueMarkers.ts` + its test →
   **B2**. Rollup badge = second text-field or drop at world tier; org-halo/status-ring =
   `icon-halo` + optional under-circle. It is substantive (BLOCKING-scope), not a footnote; the
   cheap fallback that closes the label bug alone is world-tier badge suppression. The
   `tier`-keyed markers effect (`FlatMapCanvas.tsx:136,141-170`) is replaced wholesale by a
   `setData` on the venue source — simpler, not harder.
2. **SDF in-browser (§C).** Not realistic as the default — lucide `__iconNode` is stroke geometry
   (`fill:none`, verified), rasterizes to a poor SDF. Use **non-SDF pre-tinted (kind×status)
   images** (`sdf:false`), reliable + per-status color + the pure `__iconNode→SVG string` seam is
   jsdom-testable while the canvas raster stays behind the dynamic-import guard → **B1**.
3. **One-hop flyTo (§A).** A single `flyTo({center,zoom:15.5})` is correct; the `zoom` event fires
   continuously during the fly (`FlatMapCanvas.tsx:84-88`) so the tier gate opens mid-flight and the
   fetch starts mid-flight (not on settle). Two fixes: honor duration + `essential:true` and split
   `flyToVenue` (**I1**); and decouple eager fetch (on `selectedVenueId`) from zoom-gated render so
   glyphs preload without appearing at world tier (**I2**). No separate "building intent" flag
   needed — keep the observed-zoom gate for render only.
4. **GlobeCanvas zoom API (§F).** Feasible additively via a token-bumped `zoomCmd` prop (mirrors
   `focus`); `pointOfView({altitude},ms)` confirmed on the pinned globe.gl `2.46.1`. Doesn't break
   the dispose/island/`paused`/`onPovChange` model. Prop > ref here (**M1**).
5. **Shared panel-collapse (§E).** The pages differ enough that a monolithic shared rail leaks;
   right-panel collapse is already implemented (`setPanel(null)` + selection→setPanel — confirmed).
   Real new work = left-rail collapse + a FlatMap panel wrapper; smallest surface = `useRailCollapse`
   hook + `CollapseToggle` + shared wrapper (**I3**).
6. **Layer order / collision / setData thrash.** Real: fix the `anchor`-memo per-frame `setData`
   churn (#30) and add `symbol-sort-key` + z-order across venue vs building symbol layers (**I4**).
7. **Scope realism.** 8 areas is two coherent lanes, not one — split into Plan I (map: A/B/C/H) and
   Plan J (chrome: D/E/F/G) with the GlobeCanvas zoom prop as the only shared contract (see top).

## Other flags
- **Solved-problem-stated-as-new:** §E right-panel collapse (already `onClose`+selection→setPanel).
- **Reuse-surface violation risk:** §7 omits `venueMarkers.ts`; migrating without listing it as
  *replaced* leaves an orphan module + test (**B2**).
- **Success criteria:** all are verifiable via the live E2E except "recognizable line icons," which
  is subjective — that's precisely what the added design-review gate is for; acceptable.
- **§5 choices resolved differently:** #5 → non-SDF (M2); #4 map `+/-` default bottom-right →
  reposition off the attribution (M3).
