# Flat Map — white-square nodes, green/gray edges, standard interaction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `/map` floating symbol glyphs + green status circles with small white rounded-square icon nodes (venues + devices) connected by green/gray arrowed edges, and give the map a standard interaction model (hover→pointer, single-click→select+center+partial-zoom, double-click→toggle expand, chevron→collapse, zoom-driven expand/collapse) — while every node click still opens the right-docked side panel.

**Architecture:** Nodes render as Mapbox HTML markers (`mapboxgl.Marker` wrapping a container `<div>` into which a React `MapNodeMarker` is mounted via `createRoot`), reconciled from the existing venue/building feature data. Edges stay Mapbox GeoJSON line layers, recolored to a two-state green/gray with a direction-arrow symbol layer. The two circle layers are deleted. Interaction logic is extracted into pure, unit-tested helpers; the imperative marker/map wiring is verified by live Playwright E2E (the map never initializes in jsdom).

**Tech Stack:** React 19, mapbox-gl (dynamic-imported), lucide-react icons, Tailwind (custom palette), vitest + @testing-library/react, Playwright MCP for live E2E.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-19-flatmap-nodes-interaction-design.md`

## Global Constraints

- Work in a dedicated `godview-prototype` worktree under `.claude/worktrees/` (branch e.g. `feat/flatmap-nodes`). Implementers start every session with `cd <worktree> && pwd`; the bare checkout `/Users/jn/code/godview-prototype` is READ-ONLY reference.
- **Implementers never run git.** Each failing test and its implementation are committed as SEPARATE commits by `git-flow-manager` (red test first, then impl), per task. Merge commits, not squash.
- **jsdom cannot test the live map** — the Mapbox map only initializes with WebGL+token, which jsdom lacks, so FlatMapCanvas's map/marker wiring early-returns. Unit tests cover ONLY pure logic + React DOM (`MapNodeMarker`, `buildingFeatures`, extracted interaction helpers). The map/marker/edge rendering + all click/hover/zoom behavior is verified by **live Playwright E2E** (real Chrome, Mapbox token in the worktree's gitignored `.env`).
- **Mapbox token for E2E:** copy the token from the main checkout's `.env` into the worktree's gitignored `.env` (`VITE_MAPBOX_TOKEN=...`). NEVER commit/log/PR the token; discard the `.env` at close-out.
- **Full-literal Tailwind classes** (arbitrary values as complete strings selected by ternary — JIT can't see interpolated fragments).
- **Status → color** (Tailwind palette, hex): `ok #34d399`, `warn #f5b942`, `crit #f2545b`, `off #5b6472`. Edge green = `#34d399`; edge gray = `#3a4150`.
- Zoom constants (from `src/data/mapSelectors.ts`): `CITY_ZOOM = 5`, `BUILDING_ZOOM = 14`, `STAGE_ZOOM = { country: 4, city: 11, building: 15.5 }`. `mapTier(zoom)` → `"world"|"city"|"building"`.
- Do NOT change: the data model, `buildingLayout` tree geometry, the rail, panels, corner globe, or pulses.
- Run tests from the worktree root: `npx vitest run <file>`; full suite `npm test`; `npm run lint`; `npx tsc --noEmit`.

## File structure

- **New** `src/components/flatmap/MapNodeMarker.tsx` — the React white-square node (icon + label + status dot). Pure/presentational; RTL-testable.
- **New** `src/data/mapInteraction.ts` — pure interaction helpers (`expandedVenueId`, `nearestVenueId`, click-intent). Unit-tested.
- **Modify** `src/data/buildingFeatures.ts` — edge two-state color (green/gray) + expose an `active` flag.
- **Modify** `src/components/flatmap/FlatMapCanvas.tsx` — delete circle layers; swap symbol glyphs → HTML markers; restyle connectors + add arrow layer; wire hover/click/dblclick; new callbacks.
- **Modify** `src/pages/FlatMap.tsx` — interaction wiring (single/double-click routing, zoom-driven expand/collapse, chevron, nearest-center focus).
- **Tests:** `MapNodeMarker.test.tsx`, `mapInteraction.test.ts`, `buildingFeatures.test.ts` (extend), plus E2E driven by the controller.

---

### Task 1: Kill the green circles, fix the cursor, make venues clickable (on the current glyphs)

Quick bug-fixes on the existing symbol/circle rendering, before the marker rewrite — so the "circles / drag-hand / venue-not-clickable" complaints are gone early and independently verifiable. This task is imperative Mapbox code (E2E-verified); its "test" is the live E2E gate at the end.

**Files:**
- Modify: `src/components/flatmap/FlatMapCanvas.tsx` (remove circle layers; add venue hover + click)

**Interfaces:**
- Consumes: existing `onNodeClick` prop; the page's existing venue click path.
- Produces: a new `onVenueClick(id: string)` and `onVenueDblClick(id: string)` prop on `FlatMapCanvas` (Task 4 wires them; here they're added + called so the venue layer is interactive). Add both to the component's props type as `onVenueClick: (id: string) => void; onVenueDblClick: (id: string) => void;` and to the destructure, with matching latest-callback refs (`onVenueClickRef`, `onVenueDblClickRef`).

- [ ] **Step 1: Remove the two circle layers**

In `src/components/flatmap/FlatMapCanvas.tsx`, delete the `map.addLayer({ id: "venue-ring", ... })` block (currently ~lines 106-116) and the `map.addLayer({ id: "building-glyphs-circle", ... })` block (~lines 143-150). Also delete the `VENUE_STATUS_COLOR` const's use in the removed layers is gone, but it's still used by `venue-symbol` text/paint — leave `VENUE_STATUS_COLOR` for now (Task 2 removes the symbol layers).

- [ ] **Step 2: Add venue hover (pointer) + click + dblclick**

Immediately after the existing `building-glyphs-symbol` click/hover handlers (~line 173), add venue interactivity on the `venue-symbol` layer. Also add the two refs near the other callback refs (top of component):

```tsx
  const onVenueClickRef = useRef(onVenueClick); onVenueClickRef.current = onVenueClick;
  const onVenueDblClickRef = useRef(onVenueDblClick); onVenueDblClickRef.current = onVenueDblClick;
```

Handlers (inside the `map.on("load", ...)` block, after the building-glyph handlers):

```tsx
        map.on("mouseenter", "venue-symbol", () => { map.getCanvas().style.cursor = "pointer"; });
        map.on("mouseleave", "venue-symbol", () => { map.getCanvas().style.cursor = ""; });
        // Single vs double click on a venue: defer the single-click ~250ms; a second click cancels it.
        let venueClickTimer: ReturnType<typeof setTimeout> | null = null;
        map.on("click", "venue-symbol", (e: any) => {
          const f = e.features?.[0]; if (!f) return;
          const id = f.properties.id;
          if (venueClickTimer) { clearTimeout(venueClickTimer); venueClickTimer = null; }
          venueClickTimer = setTimeout(() => { venueClickTimer = null; onVenueClickRef.current(id); }, 250);
        });
        map.on("dblclick", "venue-symbol", (e: any) => {
          const f = e.features?.[0]; if (!f) return;
          e.preventDefault();   // suppress Mapbox's native double-click zoom on the venue
          if (venueClickTimer) { clearTimeout(venueClickTimer); venueClickTimer = null; }
          onVenueDblClickRef.current(f.properties.id);
        });
```

Add the props to the destructure + type (top of `FlatMapCanvas`): `onVenueClick`, `onVenueDblClick` typed as above.

- [ ] **Step 3: Provide the new props from the page (no-op wiring for now)**

In `src/pages/FlatMap.tsx`, pass to `<FlatMapCanvas ... onVenueClick={selectVenueById} onVenueDblClick={selectVenueById} />` where `selectVenueById` is a thin adapter that resolves the venue by id and calls the existing `selectVenue(locationId, lat, lng)` (Task 4 differentiates single vs double). Add:

```tsx
  const selectVenueById = (id: string) => {
    const v = venues.find((x) => x.location_id === id);
    if (v && v.lat != null && v.lng != null) selectVenue(v.location_id, v.lat, v.lng);
    else if (v) { setSelectedVenueId(v.location_id); setPanel({ type: "venue", id: v.location_id, venueId: v.location_id }); }
  };
```

- [ ] **Step 4: Typecheck + suite**

Run: `npx tsc --noEmit` (clean), `npm test` (existing suite green — no unit test asserts the removed circle layers), `npm run lint` (exit 0).

- [ ] **Step 5: Commit (single commit — imperative map change, E2E-verified; no red→green unit pair)**

git-flow-manager commits `FlatMapCanvas.tsx` + `FlatMap.tsx`:
`fix: /map — remove green status circles, add venue hover-pointer + click/dblclick`

- [ ] **Step 6: CONTROLLER live E2E gate (not a subagent step)**

With the worktree `.env` token set and `npx vite --port <n>`: navigate `/map`, zoom to a venue. Verify: no green circles behind venue/device icons; hovering a venue shows a pointer cursor; single-clicking a venue opens its panel + selects it (existing behavior). This is the acceptance for Task 1.

---

### Task 2: `MapNodeMarker` component + swap venue & device rendering to HTML markers

**Files:**
- Create: `src/components/flatmap/MapNodeMarker.tsx`
- Create: `src/components/flatmap/MapNodeMarker.test.tsx`
- Modify: `src/components/flatmap/FlatMapCanvas.tsx` (replace symbol layers with reconciled HTML markers)

**Interfaces:**
- Produces: `MapNodeMarker({ kind, label, status, showLabel, dim }: { kind: "venue"|"system"|"camera"|"display"; label: string; status: "ok"|"warn"|"off"|"crit"; showLabel: boolean; dim?: boolean })` — a presentational React node (white square + lucide icon + optional label + status dot). Task 2's FlatMapCanvas mounts it into each marker container via `createRoot`.
- Consumes (FlatMapCanvas): `venueFeatures(venues)` and `building.glyphs` feature collections (unchanged shapes) for marker position/props.

- [ ] **Step 1: Write the failing test** — `src/components/flatmap/MapNodeMarker.test.tsx`

```tsx
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { MapNodeMarker } from "./MapNodeMarker";

describe("MapNodeMarker", () => {
  it("renders a white square with an icon, the label, and a status dot", () => {
    const { container } = render(
      <MapNodeMarker kind="camera" label="Cam 1" status="ok" showLabel={true} />);
    expect(screen.getByText("Cam 1")).toBeInTheDocument();
    expect(container.querySelector("svg")).toBeTruthy();              // lucide icon
    expect(container.querySelector('[data-testid="node-status-dot"]')).toBeTruthy();
    // node square is pointer-cursor + white
    expect(container.querySelector('[data-testid="map-node"]')!.className).toContain("cursor-pointer");
    expect(container.querySelector('[data-testid="map-node"]')!.className).toContain("bg-white");
  });
  it("hides the label when showLabel is false", () => {
    render(<MapNodeMarker kind="venue" label="HQ" status="warn" showLabel={false} />);
    expect(screen.queryByText("HQ")).toBeNull();
  });
  it("colors the status dot by status", () => {
    const { container, rerender } = render(
      <MapNodeMarker kind="display" label="D" status="crit" showLabel={false} />);
    expect(container.querySelector('[data-testid="node-status-dot"]')!.className).toContain("bg-crit");
    rerender(<MapNodeMarker kind="display" label="D" status="off" showLabel={false} />);
    expect(container.querySelector('[data-testid="node-status-dot"]')!.className).toContain("bg-off");
  });
});
```

- [ ] **Step 2: Run — RED**: `npx vitest run src/components/flatmap/MapNodeMarker.test.tsx` → fails (no module).

- [ ] **Step 3: Implement** — `src/components/flatmap/MapNodeMarker.tsx`

```tsx
import { Building2, Server, Video, MonitorPlay } from "lucide-react";

const ICON = { venue: Building2, system: Server, camera: Video, display: MonitorPlay } as const;
const DOT: Record<"ok" | "warn" | "off" | "crit", string> = {
  ok: "bg-ok", warn: "bg-warn", off: "bg-off", crit: "bg-crit",
};

export function MapNodeMarker({ kind, label, status, showLabel, dim }: {
  kind: "venue" | "system" | "camera" | "display";
  label: string; status: "ok" | "warn" | "off" | "crit"; showLabel: boolean; dim?: boolean;
}) {
  const Icon = ICON[kind];
  return (
    <div className="flex flex-col items-center select-none">
      <div data-testid="map-node"
        className={`relative flex h-9 w-9 items-center justify-center rounded-[9px] bg-white shadow-md cursor-pointer ${dim ? "opacity-60" : ""}`}>
        <Icon className="h-4 w-4 text-[#1a2029]" strokeWidth={1.8} />
        <span data-testid="node-status-dot"
          className={`absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full ring-2 ring-bg ${DOT[status]}`} />
      </div>
      {showLabel && (
        <span className="mt-1 max-w-[120px] truncate rounded px-1 text-[10.5px] text-text"
          style={{ textShadow: "0 1px 3px #0a0d12, 0 0 2px #0a0d12" }}>{label}</span>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run — GREEN**: `npx vitest run src/components/flatmap/MapNodeMarker.test.tsx` → 3/3 pass.

- [ ] **Step 5: Commit the red→green pair** (git-flow-manager): test file (`test: MapNodeMarker white-square node (red)`), then impl (`feat: MapNodeMarker — white-square icon node with label + status dot (green)`).

- [ ] **Step 6: Swap FlatMapCanvas to HTML markers (imperative — E2E-verified)**

In `FlatMapCanvas.tsx`:
1. Add imports at top: `import { createRoot, type Root } from "react-dom/client";` and `import { MapNodeMarker } from "./MapNodeMarker";` and `import { mapTier } from "../../data/mapSelectors";`. The `mapboxgl` marker constructor comes from `mapboxImpl` — extend `createMap`'s module: import `{ mapboxgl }` where markers are made. Simplest: in the init `import("./mapboxImpl").then(({ createMap, mapboxgl }) => {...})` (mapboxImpl already exports `mapboxgl`), and stash it: `const MBX = mapboxgl;` on a ref `mbxRef.current = mapboxgl;`.
2. **Delete** the `venue-symbol` layer add and the `building-glyphs-symbol` layer add (the symbol rendering). KEEP `venue-ring`/`building-glyphs-circle` already removed (Task 1). KEEP the sources (`venues`, `building-glyphs`, `building-connectors`) — markers read from the same feature data via the page props, but simplest is to drive markers directly from the `venues` prop and `building` prop (not the GeoJSON source). Remove the now-unused `venue-symbol`/`building-glyphs-symbol` click/hover handlers (Task 1's venue handlers were on `venue-symbol`; move that interactivity onto the markers — see below).
3. Add a marker registry ref: `const markersRef = useRef(new Map<string, { marker: any; root: Root; el: HTMLDivElement }>());`
4. Reconcile venue markers in the venues effect (replaces `setData("venues", ...)` for rendering; you may keep the source for nothing or remove it). For each venue with lat/lng, upsert a marker at `[lng, lat]`; render `<MapNodeMarker kind="venue" label={name} status={healthTone(rollup)} showLabel={mapTier(currentZoom)==="city"} />`; wire the container's `click`/`dblclick` (with the same 250ms single/double disambiguation as Task 1, calling `onVenueClickRef`/`onVenueDblClickRef` with the venue id) and `mouseenter`→ nothing needed (div is `cursor-pointer`). Remove markers whose venue disappeared. Because label visibility depends on zoom, also re-render venue markers' `showLabel` on the `zoom` event (cheap: update a class or re-render the root with new props).
5. Reconcile building (device) markers off the `building` prop's node list. The page currently passes `building: BuildingFeatures` (glyphs + connectors); ADD the raw `nodes: MapNode[]` to what the page passes (or derive kind/label/status/id from `building.glyphs.features[i].properties`, which already carry `kind,label,status,id`). Upsert a device marker per glyph feature at its coordinates; `<MapNodeMarker kind={kind} label={label} status={status} showLabel={true} />`; wire container `click` → `onNodeClickRef.current({ type: kind, id })`. Clear all device markers when `building` is null.
6. Marker disposal: on unmount AND when removing a marker, call `root.unmount()` then `marker.remove()`. Extend the existing dispose cleanup to unmount+remove every entry in `markersRef`.

(Provide the reconcile helper inline; keep it small. Because this is imperative and E2E-only, there is no unit test — the acceptance is the E2E gate.)

- [ ] **Step 7: Typecheck + suite + lint** — `npx tsc --noEmit`, `npm test`, `npm run lint` all clean. (Existing FlatMapCanvas tests only assert the mount div renders — still true.)

- [ ] **Step 8: Commit** (git-flow-manager, single commit — imperative): `feat: /map — render venue & device nodes as white-square HTML markers`

- [ ] **Step 9: CONTROLLER live E2E gate**

`/map`: venues render as white squares with icon + label + status dot (no circles, no old glyphs). Zoom into a selected venue → device nodes render as white squares. Hover → pointer. Clicking a venue opens its panel; clicking a device opens the device panel. Screenshot desktop + a 390px mobile width.

---

### Task 3: Edges — green/gray two-state + direction arrows

**Files:**
- Modify: `src/data/buildingFeatures.ts` (edge color two-state + `active` flag)
- Test: `src/data/buildingFeatures.test.ts` (extend)
- Modify: `src/components/flatmap/FlatMapCanvas.tsx` (connector paint + arrow symbol layer)

**Interfaces:**
- Consumes: `buildingFeatures(nodes, mode, live)` (existing signature).
- Produces: each connector `LineFeature.properties` gains `active: boolean` and `color` becomes green (`#34d399`) when active else gray (`#3a4150`). Active = parent system healthy (`status === "active"`) OR in the `live` set.

- [ ] **Step 1: Write the failing test** (append to `src/data/buildingFeatures.test.ts`)

```ts
import { buildingFeatures } from "./buildingFeatures";
import type { MapNode } from "./mapLayout";

const sysOk: MapNode = { key: "system:s1", type: "system", id: "s1", name: "S1", status: "active", systemId: null, lat: 0, lng: 0, altitude: 0 };
const sysDown: MapNode = { key: "system:s2", type: "system", id: "s2", name: "S2", status: "offline", systemId: null, lat: 0, lng: 0, altitude: 0 };
const cam1: MapNode = { key: "camera:c1", type: "camera", id: "c1", name: "C1", status: "active", systemId: "s1", lat: 0.001, lng: 0, altitude: 0 };
const cam2: MapNode = { key: "camera:c2", type: "camera", id: "c2", name: "C2", status: "offline", systemId: "s2", lat: 0.001, lng: 0.001, altitude: 0 };

it("edge is green + active when its parent system is healthy", () => {
  const f = buildingFeatures([sysOk, cam1], "health", new Set());
  const conn = f.connectors.features[0].properties;
  expect(conn.active).toBe(true);
  expect(conn.color).toBe("#34d399");
});
it("edge is gray + inactive when its parent system is down (and not live)", () => {
  const f = buildingFeatures([sysDown, cam2], "health", new Set());
  const conn = f.connectors.features[0].properties;
  expect(conn.active).toBe(false);
  expect(conn.color).toBe("#3a4150");
});
it("edge is green when the parent system is in the live set", () => {
  const f = buildingFeatures([sysDown, cam2], "live", new Set(["s2"]));
  expect(f.connectors.features[0].properties.active).toBe(true);
  expect(f.connectors.features[0].properties.color).toBe("#34d399");
});
```

- [ ] **Step 2: Run — RED**: `npx vitest run src/data/buildingFeatures.test.ts` → new cases fail (`active` undefined; color uses old glyphColor).

- [ ] **Step 3: Implement** — in `src/data/buildingFeatures.ts`, add:

```ts
const EDGE_GREEN = "#34d399";
const EDGE_GRAY = "#3a4150";
export function edgeActive(parent: MapNode, mode: MapMode, live: Set<string>): boolean {
  if (parent.status === "active") return true;
  return mode === "live" && live.has(parent.id);
}
```

and in `buildingFeatures`, replace the connector push's `color` computation:

```ts
    const parent = byKey.get(`system:${node.systemId}`);
    if (!parent) continue;
    const active = edgeActive(parent, mode, live);
    connectors.push({
      type: "Feature",
      geometry: { type: "LineString", coordinates: [[parent.lng, parent.lat], [node.lng, node.lat]] },
      properties: { key: `conn:${node.key}`, systemId: node.systemId!, active, color: active ? EDGE_GREEN : EDGE_GRAY },
    });
```

Extend `LineFeature.properties` type to include `active: boolean`.

- [ ] **Step 4: Run — GREEN**: `npx vitest run src/data/buildingFeatures.test.ts` → all pass.

- [ ] **Step 5: Commit the red→green pair** (git-flow-manager): test (`test: building edges are green(active)/gray(idle) two-state (red)`), then impl (`feat: building edges — green when parent system active/live, gray otherwise (green)`).

- [ ] **Step 6: Arrow direction layer + connector paint (imperative — E2E-verified)**

In `FlatMapCanvas.tsx`: the `building-connectors-line` paint already reads `["get","color"]` — keep it (now green/gray from Task 3). Add a `line-width` of 2 and `line-opacity` 0.9. Add a direction-arrow symbol layer on the same source:

```tsx
        map.addLayer({
          id: "building-connectors-arrow", type: "symbol", source: "building-connectors",
          layout: {
            "symbol-placement": "line", "symbol-spacing": 60,
            "icon-image": "edge-arrow", "icon-size": 0.5, "icon-allow-overlap": true, "icon-rotate": 90,
          },
          paint: { "icon-opacity": 0.9 },
        });
```

Register a small SDF arrow image `edge-arrow` in the `load` handler (draw a triangle to a canvas, `map.addImage("edge-arrow", {width,height,data}, { sdf: true })`, tinted via `icon-color` — add `"icon-color": ["get","color"]` to the arrow paint). Provide the arrow-canvas helper inline (a ~12×12 filled triangle). Arrows follow the line parent→child (the LineString goes parent→device, so line direction = flow direction).

- [ ] **Step 7: Suite + lint + tsc** clean.

- [ ] **Step 8: Commit** (single, imperative): `feat: /map — directional arrows on connector edges`

- [ ] **Step 9: CONTROLLER live E2E gate**

Expanded venue: edges between system and its devices are green when the system is active, gray when down; arrows point system→device. Screenshot.

---

### Task 4: Standard interaction model (single/double/chevron/zoom-driven expand)

**Files:**
- Create: `src/data/mapInteraction.ts`
- Create: `src/data/mapInteraction.test.ts`
- Modify: `src/pages/FlatMap.tsx` (wire single/double/chevron/zoom-driven expand + panel)
- Test: `src/pages/FlatMap.test.tsx` (extend for the routing logic that IS jsdom-testable)

**Interfaces:**
- Produces:
  - `nearestVenueId(center: {lat:number;lng:number}, venues: {location_id:string;lat:number|null;lng:number|null}[]): string | null` — nearest venue with coords to the map center (simple squared-degree distance).
  - `expandedVenueId(opts: {zoom:number; focusedId:string|null}): string | null` — returns `focusedId` when `zoom >= BUILDING_ZOOM` else `null` (the venue whose devices should show).
- Consumes: `BUILDING_ZOOM`, `STAGE_ZOOM` from `mapSelectors`.

- [ ] **Step 1: Write the failing test** — `src/data/mapInteraction.test.ts`

```ts
import { describe, expect, it } from "vitest";
import { nearestVenueId, expandedVenueId } from "./mapInteraction";

describe("nearestVenueId", () => {
  const vs = [
    { location_id: "a", lat: 0, lng: 0 },
    { location_id: "b", lat: 10, lng: 10 },
    { location_id: "c", lat: null, lng: null },  // no coords -> ignored
  ];
  it("returns the closest venue with coords to the center", () => {
    expect(nearestVenueId({ lat: 9, lng: 9 }, vs)).toBe("b");
    expect(nearestVenueId({ lat: 1, lng: 1 }, vs)).toBe("a");
  });
  it("returns null when no venue has coords", () => {
    expect(nearestVenueId({ lat: 0, lng: 0 }, [{ location_id: "c", lat: null, lng: null }])).toBeNull();
  });
});

describe("expandedVenueId", () => {
  it("expands the focused venue at/above building zoom", () => {
    expect(expandedVenueId({ zoom: 16, focusedId: "a" })).toBe("a");
  });
  it("does not expand below building zoom", () => {
    expect(expandedVenueId({ zoom: 8, focusedId: "a" })).toBeNull();
  });
  it("expands nothing when no venue is focused", () => {
    expect(expandedVenueId({ zoom: 16, focusedId: null })).toBeNull();
  });
});
```

- [ ] **Step 2: Run — RED**: `npx vitest run src/data/mapInteraction.test.ts` → fails (no module).

- [ ] **Step 3: Implement** — `src/data/mapInteraction.ts`

```ts
import { BUILDING_ZOOM } from "./mapSelectors";

export function nearestVenueId(
  center: { lat: number; lng: number },
  venues: { location_id: string; lat: number | null; lng: number | null }[],
): string | null {
  let best: string | null = null;
  let bestD = Infinity;
  for (const v of venues) {
    if (v.lat == null || v.lng == null) continue;
    const d = (v.lat - center.lat) ** 2 + (v.lng - center.lng) ** 2;
    if (d < bestD) { bestD = d; best = v.location_id; }
  }
  return best;
}

export function expandedVenueId(opts: { zoom: number; focusedId: string | null }): string | null {
  return opts.zoom >= BUILDING_ZOOM ? opts.focusedId : null;
}
```

- [ ] **Step 4: Run — GREEN**: `npx vitest run src/data/mapInteraction.test.ts` → all pass.

- [ ] **Step 5: Commit the red→green pair** (git-flow-manager): test (`test: map interaction helpers — nearestVenueId + expandedVenueId (red)`), then impl (`feat: mapInteraction — nearest-venue + zoom-driven expand helpers (green)`).

- [ ] **Step 6: Wire the interaction model in FlatMap.tsx (imperative page wiring — E2E-verified)**

In `src/pages/FlatMap.tsx`:
1. Track a `focusedVenueId` (the venue the map is centered on / interacting with) alongside `selectedVenueId`. Track observed `mapZoom` (already have `setMapZoom`). Compute `const expandId = expandedVenueId({ zoom: mapZoom, focusedId: focusedVenueId });` and use `expandId` (not `selectedVenueId`) to drive `selectedVenueId → useVenueDetailPoll` + `atBuilding` building rendering. I.e. the building tree shows for `expandId`.
2. **Single-click** (`onVenueClick`): set focused + selected + open panel + `flyTo(lat, lng, STAGE_ZOOM.city)` (partial zoom + center). This opens the `VenuePanel` (existing `setPanel({type:"venue",...})`).
3. **Double-click** (`onVenueDblClick`): set focused + selected + open panel; if currently expanded (`expandId === id`), collapse: `flyTo(lat, lng, STAGE_ZOOM.city)`; else expand: `flyTo(lat, lng, STAGE_ZOOM.building)`.
4. **Chevron collapse:** render a small ▾ button on the page (e.g. overlaid near the focused venue, or a floating "collapse" control shown only while `expandId` is set) that calls `flyTo(focus.lat, focus.lng, STAGE_ZOOM.city)` (zoom out → collapse). Use `data-testid="map-collapse"`.
5. **Manual zoom → focus nearest:** on `onZoom`, when crossing into building zoom with no `focusedVenueId`, set `focusedVenueId = nearestVenueId(mapCenter, venues)`. Track `mapCenter` from the canvas (add an `onCenter` callback to FlatMapCanvas emitting `map.getCenter()` on `moveend`, or compute from focus). Simplest: FlatMapCanvas emits center on `moveend` via a new `onCenter?: (c:{lat,lng})=>void` prop; the page stores it.
6. **Device single-click** (`onNodeClick`) already opens the NodePanel — keep.

- [ ] **Step 7: jsdom-testable routing test** (append to `src/pages/FlatMap.test.tsx`)

Since the map doesn't init in jsdom, assert the *page-level* wiring that doesn't need the map: that the page passes `onVenueClick`/`onVenueDblClick`/`onNodeClick` to `FlatMapCanvas`, and that invoking the passed `onVenueClick(id)` opens the venue panel. Mock `FlatMapCanvas` to capture + invoke props:

```tsx
vi.mock("../components/flatmap/FlatMapCanvas", () => ({
  FlatMapCanvas: (props: any) => { (globalThis as any).__fmc = props; return <div data-testid="flatmap-canvas" />; },
}));
// ... in a test (token+webgl set): after render, call (globalThis as any).__fmc.onVenueClick("<seeded venue id>")
// then expect the venue panel testid to appear (venue-panel-wrap).
```

Write one test: single-click opens the panel; one test: `onNodeClick({type,id})` opens the node panel. (These verify the panel-open FIRM requirement in jsdom without the live map.)

- [ ] **Step 8: RED → implement wiring → GREEN**; full suite + lint + tsc clean.

- [ ] **Step 9: Commit** (git-flow-manager): red test then impl — `test: FlatMap opens the side panel on venue/device click (red)` / `feat: /map standard interaction — single/double/chevron/zoom-driven expand + panel (green)`

- [ ] **Step 10: CONTROLLER live E2E gate (the acceptance for the whole feature)**

`/map`, token set, desktop + 390px mobile:
- Hover node → pointer.
- Single-click location → panel opens (right dock desktop / bottom sheet mobile), map centers + partial-zooms; NOT expanded.
- Double-click location → flies all the way in, device tree of white-square nodes + green/gray arrowed edges appears, no circles; panel open. Double-click again → collapses.
- Chevron → collapses.
- Manually zoom into a location (no prior select) → it auto-expands; zoom out → collapses.
- Click a device node → its NodePanel opens.
Screenshots of collapsed + expanded.

---

## Self-review notes

- **Spec coverage:** circles removed (T1), cursor+venue-click (T1), white-square nodes venues+devices (T2), green/gray edges + arrows (T3), single/double/chevron/zoom-driven expand (T4), panel-on-click firm requirement (T4 Step 7 unit + T1/T2/T4 E2E). `/globe`, group box, edge pills excluded per spec.
- **jsdom reality:** every map-imperative task carries a controller E2E gate; unit TDD is applied only to `MapNodeMarker`, `buildingFeatures`, `mapInteraction`, and the panel-routing mock test — the only jsdom-testable surfaces.
- **Types:** `MapNodeMarker` status is `"ok"|"warn"|"off"|"crit"` (matches `HealthTone`); `buildingFeatures` glyph `status` is `HealthTone` (from `nodeIconStatus`); edge `active:boolean`+`color` consistent across T3 test/impl; `expandedVenueId`/`nearestVenueId` signatures match T4 test.
- **Venue-label overlap risk** (spec): handled by `showLabel = mapTier==="city"` on venue markers (labels off at world tier) + existing clustering; if still noisy, a follow-up can add hovered/selected-only labels.
