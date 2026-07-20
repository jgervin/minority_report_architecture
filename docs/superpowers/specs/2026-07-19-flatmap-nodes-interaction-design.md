# Design — Flat Map: white-square nodes, green/gray edges, standard map interaction

**Date:** 2026-07-19 · **Status:** design, pending user review · **Scope:** `godview-prototype` `/map` only (`/globe` deferred)

## Problem

The `/map` flat map's building tier and its interaction model don't match a standard mapping app, and the visuals are wrong. Six issues (owner, 2026-07-19):

1. **Green status circles** are drawn under the device/venue icons (`venue-ring`, `building-glyphs-circle` layers). Owner wants no circles — just nodes and edges.
2. **Double-click a location does nothing.** It should fly all the way in and expand that location's devices.
3. **Cursor stays the drag/grab hand** over location icons (no pointer) — because only device glyphs have a hover handler; venue markers have none.
4. **Manually zooming into a location doesn't expand it,** and clicking/double-clicking it does nothing — device rendering is gated on a venue pre-selected via the rail *and* building zoom, so zoom-in alone expands nothing and venue markers have no click handler.
5. **The map should behave like standard mapping apps** (hover cursor, click/double-click to select/zoom/expand) — not bespoke per-event handling.
6. **Floating icons are wrong.** Owner wants small **white rounded-square nodes with an icon + label** and **green/gray edges** between them (per reference images), not the current Mapbox symbol glyphs.

## Goals

- Replace the floating symbol glyphs (venues + devices) with **small white rounded-square icon nodes** (icon + label + status dot), flat.
- Replace the connector styling with **green (active) / gray (idle) edges with directional arrows**.
- Delete the two status-circle layers.
- Give the map a **standard interaction model**: hover→pointer, single-click→select+center+partial-zoom, double-click→toggle expand (zoom all-in + device tree / collapse), chevron→collapse, and **zoom-driven** expand/collapse.

## Non-goals (explicitly out of scope)

- `/globe` view (deferred; will get the same white-square treatment — devices/nodes as white icon-squares instead of green nodes/edges — in a later pass).
- The **group boundary box** (the rounded rectangle around a cluster in the reference images) — skipped per owner.
- **On-edge pill labels** (the "HTTPS" badges in the reference images) — skipped per owner; our connections have no equivalent label.
- No change to the data model, the `buildingLayout` tree geometry, the rail, panels, corner globe, or pulses (they keep working as-is).

## Approach

**Render nodes as Mapbox HTML markers** (`mapboxgl.Marker` wrapping a styled `<div>`), not the current GPU symbol layers. Each marker is a white rounded-square with an icon, a label beneath, and a status dot. Mapbox positions and reprojects each marker as the map pans/zooms; markers are **fixed screen-size** (they don't grow/shrink with zoom — matching the fixed-size cards in the reference images). Edges remain Mapbox GeoJSON **line layers**, restyled, with an **arrow symbol layer** for direction.

*Why HTML markers over the current rasterized symbol icons:* HTML/CSS gives the exact white-square look, the status dot, hover states, `cursor: pointer` for free, and real DOM click/dblclick handling per node — which is what makes the interaction model straightforward and the visuals match the images. The alternative (pre-rasterized card images in a symbol layer) is more GPU-efficient but cannot reproduce the card look, the status dot, or hover cleanly, and would need many pre-rendered variants; not worth it at our node counts (a venue has a handful of systems/devices; venues are dozens, and are clustered at low zoom).

## Node visual

A reusable node marker (one component, used for both venue and device nodes):

- **Square:** white background, rounded corners (~9px radius), soft drop shadow, ~40×40px, centered icon (line-art, monochrome dark — matching the reference).
- **Icon:** per node kind — venue (building/home), system, camera, display. Reuse existing lucide/icon set where possible.
- **Label:** small text centered **below** the square (with a subtle halo/background for legibility over the map). Venue label visibility is **gated by zoom** (as today: hidden at world tier, shown at city tier) to control overlap; device labels show at building tier.
- **Status dot:** small colored dot on the square's corner — green (ok/active) · amber (warn/degraded) · gray (off/idle) · red (failure). Health lives on the **dot**, so edges can stay a clean green/gray.
- **Cursor:** the marker `<div>` is `cursor: pointer` (fixes the drag-hand issue for nodes).

Both `venue-symbol`/`venue-ring` and `building-glyphs-symbol`/`building-glyphs-circle` are replaced by these markers. **The `venue-ring` and `building-glyphs-circle` circle layers are removed.**

## Edges

- **Line layer** (existing `building-connectors`), recolored to a **two-state** scheme: **green** when the connection is *active* — defined as the parent system being healthy (status `ok`) or in the live set (`liveSystemIds`, in live-ad-runs mode) — and **gray** (`#3a4150`) otherwise. (Node health is on the dot, not the edge; a degraded/offline branch reads gray on the edge with the precise status shown by each node's dot.)
- **Direction arrows:** a symbol layer along each line (`symbol-placement: "line"`, an arrowhead icon) pointing **system → device** (the tree's parent→child direction).
- No pill labels.

## Interaction model (standard map behavior)

Expansion is **zoom-driven**: a location's device tree is shown when that location is *focused* **and** the map is at/above the building zoom threshold. All triggers below manipulate focus/zoom; the display derives from that (this is why it stays consistent with "detail appears as you zoom," like standard maps).

- **Hover** a node → pointer cursor (native to the marker div).
- **Single-click** a location → **select it → open its right-docked side panel** (`VenuePanel` via `PanelWrapper`), gently **center** it, and **partial zoom-in** to city level. Does not expand.
- **Double-click** a location → **select it → open its right-docked panel** *and* **fly all the way in** to building zoom (→ its device tree expands). **Double-click the expanded location again → collapse** (fly back out to city zoom).
- **Chevron** on the expanded location (a small ▾ affordance on/near the focused venue node) → collapse (fly back out to city zoom) — the second way to close, per owner.
- **Single-click a device node** → **open its right-docked panel** (`NodePanel` via `PanelWrapper`) for that system/camera/display (its existing behavior, preserved).
- **Manual zoom** past the building threshold → **auto-expand**: if a location is already selected, expand it; if none is selected, focus + expand the location **nearest the viewport center**. Zooming back out below the threshold **collapses**.
- **Single-vs-double disambiguation:** a short (~250 ms) timer on single-click, cancelled if a second click arrives (double-click). Marker dblclick stops propagation so it doesn't also trigger Mapbox's native double-click-zoom.

### Panel behavior (FIRM requirement, owner 2026-07-19)

Clicking **any** node must open the **right-docked side panel** for that node — locations → `VenuePanel`, devices → `NodePanel`, both via the existing `PanelWrapper` (right slide-in on desktop, bottom sheet on mobile). This must be preserved through the click-disambiguation and expand/collapse rework: single-click and double-click on a location both open its panel (they differ only in zoom/expand depth), and a device single-click opens its panel. E2E must assert the panel opens on click for both a location and a device.

## Components / files affected (godview-prototype)

- **New:** `src/components/flatmap/MapNodeMarker.tsx` (or a marker factory) — builds the white-square marker DOM for a node (venue or device) given `{ kind, label, status, showLabel }`; returns the element + wires `cursor: pointer`.
- **`src/components/flatmap/FlatMapCanvas.tsx`** — the core change: remove `venue-ring` + `building-glyphs-circle` circle layers and the `venue-symbol`/`building-glyphs-symbol` icon rendering; drive HTML markers off the venue + building feature data (add/reconcile markers on `setData`-equivalent effects); restyle `building-connectors-line` to green/gray + add the arrow symbol layer; add hover/click/dblclick handling; emit venue single-click, venue double-click (toggle-expand), and device click via callbacks.
- **`src/pages/FlatMap.tsx`** — interaction wiring: single-click venue (select + center + partial zoom), double-click venue (toggle: fly to building zoom / fly out), chevron collapse, and the zoom-driven expand/collapse + nearest-to-center focus on manual zoom. The existing `selectVenue`/`flyTo`/`atBuilding` logic is extended, not replaced.
- **`src/data/buildingFeatures.ts`** — edge color becomes two-state (green/gray by activity); node features carry `status` for the dot (already present). Possibly a small `activity` flag on connectors.
- Icon assets: reuse the existing icon set; add device/venue line-art icons if missing.
- Tests: `FlatMapCanvas.test.tsx`, `FlatMap.test.tsx`, `buildingFeatures.test.ts` updated/added.

## Testing

- **Unit (vitest/jsdom):** `buildingFeatures` edge two-state coloring + node status; `FlatMap` interaction logic (single vs double click routing, zoom-threshold expand/collapse state, nearest-to-center focus selection) with the mapbox layer mocked as today. Marker DOM structure (white square, label gating, status dot, `cursor: pointer`) via a unit test of `MapNodeMarker`. (jsdom can't verify real map layout — layout/visual is covered by live E2E.)
- **Live E2E (Playwright MCP, real Chrome, Mapbox token from `.env`):** hover→pointer; single-click→center+partial-zoom+panel; double-click→zoom-in+expanded device tree of white-square nodes + green/gray arrowed edges, no circles; double-click again→collapse; chevron→collapse; manual zoom-in→auto-expand nearest location, zoom-out→collapse; verify at desktop + a mobile width.

## Risks / considerations

- **Venue-label overlap at world/city zoom:** the current symbol layer used Mapbox's collision engine. HTML markers don't auto-collide, so venue labels are gated by zoom (hidden at world tier) and venues are clustered at low zoom (existing `clusterVenues`) to keep counts/overlap manageable. If overlap is still bad at city zoom, the plan can add a simple "label only for hovered/selected" rule. Flag for the implementer.
- **Marker count/perf:** dozens of venue markers at city zoom + a handful of device markers at building zoom is well within HTML-marker budgets. Markers must be disposed on unmount (mirror the existing GL-context disposal hygiene).
- **Single/double-click timing** can feel laggy if the disambiguation delay is too long; keep it ~250 ms and make single-click's visible effect (panel open) feel immediate.

## Build order (for the plan — each step verified live)

1. Remove the two circle layers + add `cursor: pointer` / hover + venue click handlers (kills the "circles / drag-hand / venue not clickable" bugs on the current glyphs).
2. `MapNodeMarker` + swap venue and device rendering to HTML markers (the white-square visual).
3. Edge restyle: green/gray two-state + direction arrows.
4. Interaction model: single-click (center+partial-zoom), double-click toggle-expand, chevron collapse, zoom-driven expand/collapse + nearest-to-center focus.
