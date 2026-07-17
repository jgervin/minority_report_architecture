# Flat Map v4 — UX/UI Polish Spec (AMENDED per outside review)

**Date:** 2026-07-14
**Repo:** `godview-prototype` (builds on Flat Map v3 = PR #24 Plan G + PR #27 Plan H, `main@3bc3ff7`)
**Grounding:** `.../2026-07-14-flatmap-v4-investigation.md` · **Outside review (folded below):** `.../2026-07-14-flatmap-v4-outside-review.md` (verdict PROCEED-WITH-AMENDMENTS: 2 BLOCKING · 4 IMPORTANT · 3 MINOR — all folded in).
**Owner decisions locked (2026-07-14):** spec'd-lane process WITH a dedicated design-review pass · line-icon set (lucide) · compact collapsible corner legend.

## 1. Why

Flat Map v3 shipped functionally correct but with **no design-review pass**. Live owner review surfaced 2 hard bugs + interaction/visual gaps. This lane fixes them and adds a design-review gate. Scope: the `/map` page plus a shared panel-collapse on `/globe`.

## 2. Root causes (from the investigation — verified)

- **"Teal square" on venue click.** `nextFlyZoom` (`mapSelectors.ts:14-22`) is a **3-stage ladder** (country 4 → city 11 → building 15.5) advancing **one stage per click**. From `mapZoom=1.4` one click reaches only zoom 4 = `world` (`CITY_ZOOM=5`), so the building gate (`BUILDING_ZOOM=14`) never opens → no detail → empty building sources. The visible "teal square" is the **venue DOM marker** (bordered ring, no fill; `venueMarkers.ts:32-36`) tinted by the org halo (`ORG_PALETTE` includes teal `#2dd4bf`).
- **Stacked labels.** Venues are DOM `mapboxgl.Marker`s (`FlatMapCanvas.tsx:164-166`), not a symbol layer → Mapbox collision never applies.
- **No icons.** `glyphIcon` ▣/◉/▤ computed, never rendered; no `map.addImage`; `lucide-react@1.23.0` installed but unused.
- **Corner globe / panels / zoom:** globe `absolute bottom-3 left-3`, 300×300, no zoom API; both pages `grid-cols-[280px_minmax(0,1fr)]`, no desktop collapse; no `NavigationControl`.

## 3. Changes

### A — Fix: one-hop flyTo to building tier (bug) [amended: I1, I2]
Selecting a venue flies **directly to building zoom in one animated `flyTo`**, so `mapTier` crosses `BUILDING_ZOOM` and building glyphs populate.
- **Split `flyToVenue`** (`FlatMap.tsx:80-81`): venue selection → `STAGE_ZOOM.building` (15.5); cluster centroid → `STAGE_ZOOM.city` (11). Selection stops calling `nextFlyZoom` (which may remain for manual step-zoom only).
- **Change the camera effect** (`FlatMapCanvas.tsx:247-251`): currently `flyTo({center,zoom,duration:1200})` with no `essential:true`. Use **duration ~1800–2200ms, `essential:true`**, and a moderate `curve`/`speed`. Carry `duration`+target `zoom` on `MapFocus` (or constants in the effect). (Closes #31 — snappy one hop, not the 30–45s crawl.)
- **Decouple fetch from render (I2):** fetch venue detail **eagerly on `selectedVenueId`** (starts at click, preloads during the fly), but compute the rendered `building` features **only when `mapTier==="building"`** (keep render zoom-gated). Net: detail is ready the instant tier flips; no tiny building glyphs ever drawn at world tier; no settle-latency. No separate "building intent" flag needed — observed-zoom gate for render, selection intent for fetch.

### B — Fix: world-tier label declutter via venue symbol layer (bug) [amended: B2, I4]
Migrate venues from DOM markers to a **GeoJSON `symbol` layer** so Mapbox collision applies. This is a **module replacement, not an orphan**:
- **New pure module `src/data/venueFeatures.ts`** (direct parallel to `buildingFeatures.ts`) emits venue GeoJSON (`properties`: `kind:"venue"`, `status` = worst_status tier, `name`, `sys` count, `id`). **Retire `src/data/venueMarkers.ts` + migrate its test** to `venueFeatures.test.ts` (the 4 assertions become feature-shape assertions). The `tier`-keyed DOM-markers effect (`FlatMapCanvas.tsx:136,141-170`) is replaced by a `setData` on the `venues` source.
- **Layer paint/layout:** `icon-image` (§C) always visible (`icon-allow-overlap:true`); `text-field` = `name` (+ optional `· N sys`) with `text-allow-overlap:false`, `text-optional:true` (drop label on collision, keep icon), `symbol-sort-key` by importance (worst_status severity, then `sys` count). Suppress labels below city tier (icons only at world); reveal on hover/selected.
- **Rollup badge:** keep as the venue label text (`name · N sys`), collision-managed (no more stacking). **Org-halo dropped** on the flat map (it caused the teal-square confusion; status color now carries meaning); **status-ring** via `icon-halo-color`/`icon-halo-width` if desired.
- **Cross-layer collision (I4):** venue labels + building-glyph labels collide globally in Mapbox. Add `symbol-sort-key` and **suppress venue labels at building tier** so building nodes win; set z-order (venues under building glyphs at building tier).
- **Descope fallback (if scope must trim):** the label-stack bug alone is killed by **not emitting the world-tier text badge** (icon/dot only, name on hover) — ~10 lines, no migration. Noted; the full migration is preferred because §C needs the icon layer anyway.

### C — Line-icon set as non-SDF pre-tinted rasters (venues + building nodes) [amended: B1, M2]
Adopt `lucide-react@1.23.0` icons, rendered as **non-SDF pre-tinted raster images** (NOT SDF — lucide icons are stroke SVGs `fill:none` that make degenerate SDFs).
- **Pre-render N kinds × M statuses** images: kinds = {venue, system, camera, display} × statuses = {active, degraded, offline, failures} ≈ 16 small rasters, each stroked in its status color (`TONE_HEX`), registered once on map `load` via `map.addImage(name, bitmap, { sdf:false })`.
- Symbol layers select with `"icon-image": ["concat", ["get","kind"], "-", ["get","status"]]`. **No `icon-color`** (only tints SDF) — status color is baked into the raster.
- Icons: venue = `Building2`, system = `Server`, camera = `Video`/`Cctv`, display = `MonitorPlay`/`Tv` (defaults; §5).
- Building tier: replace ▣/◉/▤ + status-glyph text with the pre-tinted icon per node type; keep name label + connector lines from Plan H.
- **Test isolation:** the pure, jsdom-testable seam is **`__iconNode → SVG string`** (string assembly, no canvas) — unit-test that. The raster step (SVG → `ImageBitmap`) needs a canvas jsdom lacks → put it in a module reached only via `import(...)` behind the existing WebGL/`ready` guard (same discipline as `mapboxImpl.ts`); it runs only in the live E2E.

### D — Compact collapsible corner legend [locked]
Small legend in a map corner **clear of the globe** (globe → top-left in §F ⇒ legend **bottom-left**). Rows: one per element type (venue/system/camera/display) with its icon + short label, plus status color key (active/degraded/offline/failures). Collapsible via a header chevron to a single "Legend" pill. Compact.

### E — Collapsible panels (both `/globe` and `/map`) [amended: I3]
Verified: **right-panel close+reopen already works** (`onClose={()=>setPanel(null)}` + selection→`setPanel(...)` on both pages). So the genuinely new work is scoped to:
- **Left-rail collapse (both pages):** the grid template lives on the page div (`FlatMap.tsx:101` / `Globe.tsx:119`), so collapse state lives at **page level** — swap `grid-cols-[280px_…]` → `[40px_…]` (thin strip w/ reopen handle) or `[0_…]`; animate width.
- **FlatMap right-panel wrapper:** FlatMap's panel is mounted **bare** (`FlatMap.tsx:127-130`) vs Globe's `venue-panel-wrap` — add the parallel positioning wrapper so it participates.
- **Smallest shared surface:** a `useRailCollapse()` hook (boolean+toggle) + a shared `<CollapseToggle>` button + a shared panel wrapper. **Do NOT** build a monolithic `CollapsibleRail` (the two rails differ: Globe = `hidden lg:block` + `OrgChips` + mobile `railOpen`; FlatMap = always-visible + `VenueRail`). Keep close == `setPanel(null)` so selection reopens for free.

### F — Corner globe nav window (`/map`) [amended: M1]
- **Reposition** bottom-left → **top-left** (`absolute top-3 left-3`).
- **Size toggle:** button at the window's **top-right** toggles 300px ↔ **¾ (225px)**; persist (state, optional `localStorage`).
- **Globe +/- zoom:** drive globe.gl point-of-view **altitude** via a **new additive `zoomCmd:{delta,token}|null` prop** on `GlobeCanvas` (mirrors the existing token-bumped `focus` one-shot at `GlobeCanvas.tsx:23,475-480`; `pointOfView({altitude},ms)` confirmed on pinned `2.46.1`). NOT a ref handle (no imperative-ref pattern exists here). Additive — doesn't touch dispose/`paused`/`onPovChange`; `/globe` (never passes it) stays byte-identical. Step = **2× a pinch step**. Caveat: while `paused={cameraBusy}` during a main-map fly, a zoom press won't visibly animate until the fly ends (acceptable).

### G — Flat map +/- zoom buttons [amended: M3]
On-screen **+/- controls** (custom, themed — not `NavigationControl`) calling `map.easeTo({ zoom: current ± step })`, step **2× default**. **Position top-right** (globe top-left, legend bottom-left) — NOT bottom-right, which collides with the Mapbox attribution (`attributionControl:true`, `mapboxImpl.ts:16`, default bottom-right); optionally set attribution `compact`.

### H — Fold-in: building node click → device NodePanel (was #28)
Add `map.on("click", "building-glyphs", …)` reading feature `type`/`id` → page `setPanel({type,id,venueId})`, which (per §E) shows the right panel. Closes the Plan H known gap.

### Cross-cutting fix — anchor memo churn (#30) [I4]
`anchor` (`FlatMap.tsx:57`) is a fresh object literal each render; the mini-globe's autorotate emits `onPovChange`→`setPov`→continuous re-render → building `setData` re-parses GeoJSON every frame. **Memoize `anchor` on the `lat`/`lng` primitives** (part of this lane, before layering a venue symbol layer on top). Closes #30.

## 4. Non-goals
Real per-device lat/lng (building layout stays ring-fallback) · changing the globe's 3D explosion/pulses on `/globe` (only shared panel-collapse touches `/globe`) · mobile redesign (collapse targets desktop).

## 5. Open design choices (defaults; confirm with owner)
1. **lucide icons:** venue `Building2`, system `Server`, camera `Video`, display `MonitorPlay` (owner may swap).
2. **Legend corner:** bottom-left (globe top-left).
3. **Collapsed-rail style:** thin icon strip w/ reopen handle (default) vs fully hidden.
4. **Map +/- position:** top-right (resolved off the attribution per M3).
5. **Icon rendering:** **non-SDF pre-tinted rasters** (resolved per B1/M2; SDF rejected).

## 6. Plan decomposition (sequence I → J)
- **Plan I — Map data/visual (risky, coupled):** §A one-hop flyTo (I1/I2) · §B venue declutter/symbol migration (B2) · §C non-SDF icons (B1) · §H node-click · + the #30 anchor-memo fix + cross-layer collision (I4). **Shared contract** = the icon-image registry (`kind-status` names) + the symbol-layer feature schema (`venueFeatures`/`buildingFeatures` `properties.kind/status/id`). Closes both hard bugs. Do first.
- **Plan J — Chrome/controls (lower-risk React/CSS):** §D legend · §E panel collapse (I3) · §F corner globe reposition+size+zoom (M1) · §G map +/- (M3). **Shared contract** = the additive `GlobeCanvas` `zoomCmd` prop (§F only). Touches no map data.

## 7. Success criteria (live E2E + design-review must verify)
Venue click flies **one hop** to building tier; camera/system/display **icons** render (no teal square) · world-tier labels **don't stack** · building nodes show **recognizable line icons** tinted by status; **clicking a node opens its NodePanel** · compact legend renders + **collapses** · left rail + right panel **collapse**; right panel **reopens on selection** — both pages · corner globe **top-left**, **size toggle** (300↔225), working **+/- globe zoom** · map **+/- zoom** (~2× step) · no WebGL/rAF leak; 0 app console errors · **design-review pass** signs off visual/interaction quality (the gate missed in v3).

## 8. Reuse surface (do not fork)
Extend, don't fork: `buildingFeatures.ts` (add icon-image `kind` per type), `mapPulseGeometry.ts`, `mapLayout.ts`, `mapSelectors.ts` (`mapTier` unchanged; selection stops using `nextFlyZoom`), `pulseDelta` engines, `useVenueDetailPoll`, `usePollDelta`, `TONE_HEX`/status coloring. **`src/data/venueMarkers.ts` is REPLACED by the new `src/data/venueFeatures.ts`** (+ test migrated) — explicit replacement, not an orphan. `GlobeCanvas` gains only the additive `zoomCmd` prop.
