# Design — `/globe`: white-square icon nodes, neutral-restyled drill-in edges

**Date:** 2026-07-19 · **Status:** design, approved by owner · **Scope:** `godview-prototype` `/globe` view only

## Problem

`/globe` (the 3D globe view) renders its nodes as green 3D sphere meshes, visually
inconsistent with the `/map` view, which the owner just rebuilt to use small **white
rounded-square icon nodes** (`src/components/flatmap/MapNodeMarker.tsx`). The owner wants the
globe's nodes to match that white-square aesthetic "instead of the green nodes," and the
drill-in device-tree edges recolored away from always-green.

Today (`godview-prototype`, per code survey):
- **Venue / cluster world nodes** are globe.gl's built-in **Points layer** — 3D meshes colored by
  status via `dotColor` (`src/data/globeSelectors.ts`), green (`#34d399`) for ok/playing.
- **Drill-in system / camera / display nodes** ("explode" fan when zoomed into a venue) are
  globe.gl **Objects-layer** `THREE.SphereGeometry` beads, colored via `nodeColor`
  (`src/data/explodeSelectors.ts`), green for active.
- **Edges:** (a) world **org arcs** — globe.gl Arc layer, per-org palette
  (`src/data/topologySelectors.ts`, `ORG_PALETTE`, *not* green); (b) drill-in **connectors** —
  custom `THREE.Line` objects, green when active (`connectorColor`, `explodeSelectors.ts`); plus a
  gray hull outline and animated "traveling pulse" dashes.
- **Labels:** native globe.gl label **sprites** for mid-zoom venue/cluster names
  (`labelsFor`, `topologySelectors.ts`) and globe.gl **`htmlElementsData`** DOM `<div>`s for
  drill-in node names (`GlobeCanvas.tsx`, `data-testid="globe-node-label"`).

Key enabling fact: globe.gl's **`htmlElementsData`** DOM-overlay layer already exists and is in
active use for drill-in labels — the same mechanism `/map` uses for `mapboxgl.Marker` HTML
markers. So `MapNodeMarker` can be mounted as a globe HTML overlay with no new projection math.

## Goals

1. Render globe nodes (both tiers) as **white rounded-square icon nodes** (lucide icon + status
   dot), matching `/map`'s `MapNodeMarker` — health moves from the body color onto the corner dot;
   the square body is always white.
2. **Cluster** world nodes additionally get a **bright status-colored ring** around the square and
   a **count** of venues in the cluster (so clusters pop at a distance and read aggregate health).
3. Recolor the drill-in **device-tree connectors** to the same **green (active) / gray (idle)**
   two-state as `/map`, instead of always-green.
4. Keep the world **org arcs** unchanged (they are the globe's signature and are org-colored, not
   the "green" the owner flagged). Keep the gray hull and traveling pulses unchanged.
5. Preserve all existing interaction: clicking any node opens its right-docked panel; drill-in /
   explode tiers, clustering, pov/zoom gating, back-of-globe occlusion all keep working.

## Non-goals (explicitly out of scope)

- `/map` view — untouched. `MapNodeMarker` may only be **extended with optional, backward-compatible
  props** (`count`, `ring`); its existing `/map` behavior and tests must not change.
- World **org arcs** — kept as-is (color, dash, highlight). Not restyled.
- **Traveling pulses** (deep-zoom animated dashes, `pulseLayer.ts`) and the **gray hull** outline —
  unchanged.
- No change to the data model, `fetchMap` polling, clustering thresholds, explode ring geometry, or
  the panel components.

## Approach

**Move node bodies from in-canvas meshes to globe.gl `htmlElementsData` DOM markers**, reusing
`MapNodeMarker` exactly as `/map` does with `mapboxgl.Marker`. Each marker is a React root
(`createRoot`) mounted into a `<div>` positioned by globe.gl's `htmlLat`/`htmlLng`/`htmlAltitude`
accessors (the same accessors already feeding the drill-in label layer). This lets venue, cluster,
system, camera, and display nodes all reuse the white-square component and gives DOM
`cursor:pointer` + click/dblclick handling for free (mirrors `FlatMapCanvas.tsx`).

**Why HTML overlay over rasterized sprites:** the `htmlElementsData` infrastructure already exists
and is proven in this file (drill-in labels), `/map` already committed to this exact DOM-marker
pattern (consistency + literal `MapNodeMarker` reuse), and node counts are modest (dozens of
venues, reduced further by clustering; a handful of devices per drilled-in venue). A rasterized
`CanvasTexture`/`THREE.Sprite` path would be cheaper at hundreds of nodes and get depth-occlusion
for free, but cannot reuse `MapNodeMarker` and needs a new icon→texture rasterizer — not worth it
at these counts. Back-of-globe occlusion is handled by globe.gl's
`htmlElementVisibilityModifier` (already used here to fade the label layer).

## Node visual

Reuse `MapNodeMarker` (`{ kind, label, status, showLabel, dim }`), extended with two **optional**
props (defaulted so `/map` is byte-unaffected):

- `count?: number` — when present (cluster case), render a small **count badge** on the square.
- `ring?: boolean` — when `true` (cluster case), render a **bright ring/glow** around the white
  square, colored by the marker's existing `status` prop via the same tone→hex mapping as the
  status dot (`ok #34d399`, `warn #f5b942`, `off #5b6472`, `crit #f2545b`). Defaults to `false`, so
  `/map` markers (which pass neither `count` nor `ring`) render exactly as today.

Node treatment:
- **Individual venue:** white square + venue icon (`Building2`) + small status corner dot. No ring,
  no count.
- **Cluster:** white square + icon + **bright status ring** + **count** of venues.
- **System / camera / display (drill-in):** white square + `Server`/`Video`/`MonitorPlay` icon +
  status corner dot. No ring, no count.
- Status→color lives on the **dot** (and, for clusters, the ring); body is always white — matching
  `/map`.

## Edges

- **World org arcs:** unchanged.
- **Drill-in connectors:** `connectorColor` (`explodeSelectors.ts`) becomes two-state — **green
  (`#34d399`) when active**, **gray (`#3a4150`) when idle** — matching `/map`'s
  `buildingFeatures.edgeActive` scheme. "Active" keeps the current definition (`mode==="health"` →
  `status==="active"`; live mode → parent system in the live set). This is a recolor of an
  existing function; no geometry change. Hull outline stays gray; pulses unchanged.

## Labels & layer consolidation

Because each white-square marker renders **its own label** (via `MapNodeMarker`'s `showLabel`), the
pre-existing label layers that duplicated those names are retired **for the nodes now drawn as
markers**:
- The drill-in **`globe-node-label`** HTML label layer is replaced by the markers' own labels
  (the markers ARE the new `htmlElementsData` content).
- The native **label-sprite** layer for venue/cluster names is dropped where it would double up with
  the marker labels. (If mid-zoom name legibility regresses, the marker's own `showLabel` zoom
  gate — mirroring `/map`'s `mapTier`/`deviceShowLabel` — covers it.)

Label visibility is **zoom/altitude-gated** like `/map`: cluster/venue labels show at the
appropriate tier; drill-in **leaf** (camera/display) labels appear only when zoomed in past a
threshold, while **system** labels stay on (reuse the `/map` rule via a globe-altitude→tier
adapter). Icons + status dots are always visible.

## Interaction

- **Click** any node marker → open its right-docked panel (venue/cluster → `VenuePanel`; device →
  `NodePanel`), via DOM `click` listeners on the marker element — replacing the globe.gl
  `onPointClick`/`onObjectClick` raycasting for these nodes. `dblclick` stops propagation (mirrors
  `/map`) so it does not also trigger globe.gl camera interactions.
- **Hover** → pointer cursor (native to the marker div).
- Clustering, explode tiers, pov/zoom gating, arc highlight-on-select, pulses — all unchanged; they
  key off the same `pov`/selection state as today.

## Components / files affected (godview-prototype)

- **`src/components/flatmap/MapNodeMarker.tsx`** — add optional `count` + `ring` props
  (backward-compatible; `/map` passes neither). Unit-tested.
- **`src/components/globe/GlobeCanvas.tsx`** — the core change: feed venue/cluster + exploded
  system/device nodes into `htmlElementsData` as `MapNodeMarker` React roots (reconciled by id, the
  `FlatMapCanvas.tsx` `syncVenueMarkers`/`syncDeviceMarkers` pattern — `createRoot`, deferred
  `root.unmount()` via `queueMicrotask`); remove the Points-layer venue meshes, the Objects-layer
  sphere beads, and the redundant label layers for these nodes; wire DOM click/dblclick →
  panel callbacks; keep arcs/hull/pulses.
- **`src/data/explodeSelectors.ts`** — `connectorColor` → two-state green/gray; add a small
  `status`(hex)→`HealthTone` adapter if needed so `ExplodedNode.status` maps to the `ok/warn/off/crit`
  union `MapNodeMarker` expects.
- **`src/data/globeSelectors.ts`** — a helper to expose a cluster's **venue count** and its
  **rollup status tone** for the marker `count`/`ring` (data already present on `ClusterDot`).
- **`src/pages/Globe.tsx`** — pass the node→marker data + click callbacks into `GlobeCanvas`
  (mirrors how `/map`'s `FlatMap.tsx` wires `FlatMapCanvas`); retire props feeding the removed
  layers.
- Tests: `MapNodeMarker.test.tsx` (new count/ring cases), `explodeSelectors.test.ts` (connector
  two-state), `globeSelectors.test.ts` (cluster count/tone helper). `GlobeCanvas` behavior is
  E2E-only (WebGL/globe.gl can't run in jsdom — same constraint as `/map`'s Mapbox).

## Testing

- **Unit (vitest/jsdom):** `MapNodeMarker` count badge + status ring rendering (and that omitting
  the props reproduces the current `/map` DOM exactly); `connectorColor` two-state; cluster
  count/tone helper. Pure logic only — jsdom can't run globe.gl.
- **Live E2E (Playwright MCP, real WebGL globe):** world tier shows white-square venue nodes +
  cluster nodes with a bright status ring + count; org arcs still present; drill into a venue →
  white-square system/camera/display nodes with green(active)/gray(idle) connectors, no green
  sphere beads; click a node (world + drill-in) opens the right panel; labels zoom-gate (leaf
  labels appear only when zoomed in; system/venue labels on); back-of-globe markers occlude/fade;
  0 console errors across rotate/zoom churn. Verify at desktop and a mobile width.

## Risks / considerations

- **React-root churn on the globe:** rotating/zooming re-runs marker reconcile; reuse `/map`'s
  deferred-`unmount()` (`queueMicrotask`) fix to avoid React 19 "synchronously unmount a root while
  rendering" errors. Flag for the implementer.
- **Back-of-globe occlusion:** verify `htmlElementVisibilityModifier` hides markers on the far
  hemisphere (it already does for labels) — markers must not "float" over the globe's back.
- **Marker vs. label-sprite overlap during transition:** ensure the old label-sprite / node-label
  layers are fully removed for marker-drawn nodes, or names double-draw.
- **Perf at world tier:** dozens of DOM markers is fine; clustering keeps counts down. If a future
  dataset has hundreds of un-clustered venues, revisit the rasterized-sprite path (documented above)
  — not needed now.

## Build order (for the plan — each step verified)

1. Extend `MapNodeMarker` with optional `count` + `ring` (TDD; prove `/map` DOM unchanged).
2. `connectorColor` two-state green/gray + `status`→tone adapter (TDD).
3. Cluster count/tone helper in `globeSelectors` (TDD).
4. `GlobeCanvas`: swap venue/cluster + exploded nodes onto `htmlElementsData` `MapNodeMarker`
   roots (reconcile-by-id, deferred unmount), remove old node meshes + redundant label layers, wire
   click/dblclick → panel. (E2E-verified.)
5. Live E2E pass (world + drill-in + clusters + connectors + click→panel + occlusion + mobile).
