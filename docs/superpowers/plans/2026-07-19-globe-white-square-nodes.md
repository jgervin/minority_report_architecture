# /globe White-Square Nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `/globe` nodes (world venue/cluster + drill-in system/camera/display) into the same white rounded-square icon markers `/map` uses, recolor the drill-in connectors to green/gray, and keep the world org arcs.

**Architecture:** `/globe` is a globe.gl (three-globe) imperative island (`GlobeCanvas.tsx`). It already has a DOM-overlay layer (`htmlElementsData`, today holding drill-in labels) — the same mechanism `/map` uses for `mapboxgl.Marker`. We move node BODIES from in-canvas meshes (points layer for venues, objects-layer sphere beads for drill-in nodes) onto that DOM layer, mounting `MapNodeMarker` React roots reconciled by id (the `FlatMapCanvas.tsx` `syncVenueMarkers`/`syncDeviceMarkers` pattern). Pure helpers (marker data, connector color, label gating) are decided in the selector files and unit-tested; the canvas wiring is E2E-only (globe.gl can't run in jsdom).

**Tech Stack:** React 19, globe.gl 2.46 + three 0.185 (dynamic-imported), lucide-react, Tailwind (custom `ok/warn/off/crit/bg` palette), vitest + @testing-library/react, Playwright MCP live E2E.

## Global Constraints

- **`/map` must not change behavior.** `MapNodeMarker.tsx` may only gain **optional, backward-compatible** props (`count`, `ring`); markers that pass neither must render byte-identically to today. `/map` (`FlatMapCanvas.tsx`) is not touched.
- **Status→tone union is exactly** `"ok" | "warn" | "off" | "crit"` (the `HealthTone` type / `MapNodeMarker` `status` prop). Tone→color mapping is the existing `TONE_HEX` (`ok #34d399`, `warn #f5b942`, `off #5b6472`, `crit #f2545b`).
- **Node body is always white; health is on the corner dot** (and, for clusters, the ring). This is the whole point of "instead of the green nodes."
- **Connectors are two-state green(active)/gray(idle)** like `/map` — active `#34d399`, idle `#3a4150`. No amber/off third state on the edge.
- **World org arcs, the gray hull, and traveling pulses are unchanged.**
- **Tailwind classes must be literal strings** (the theme is purged) — no runtime-interpolated class fragments. Use lookup maps of complete class names.
- **HTML-marker React roots must defer `root.unmount()`** via `queueMicrotask` (React 19 "synchronously unmount a root while rendering" guard under marker churn — the `/map` lesson).
- jsdom can't run globe.gl → the `GlobeCanvas` wiring (Tasks 4–5) is **E2E-only**; TDD covers only the pure helpers (Tasks 1–3). Live E2E needs the Mapbox/globe assets + a real browser.
- Work in the assigned worktree only; never edit the bare checkout. Two commits per TDD task (failing test, then impl) so red→green shows in git history.

---

### Task 1: `MapNodeMarker` — optional `count` badge + status `ring`

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/MapNodeMarker.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/flatmap/MapNodeMarker.test.tsx`

**Interfaces:**
- Produces: `MapNodeMarker` now accepts optional `count?: number` and `ring?: boolean`. When `ring` is true, a bright status-colored ring is drawn around the white square (color from the existing `status` prop). When `count != null`, a small count badge is drawn on the square. Omitting both reproduces today's DOM exactly. Consumed by Task 4 (cluster markers pass `count` + `ring`).

- [ ] **Step 1: Write the failing tests**

Add to `/Users/jn/code/godview-prototype/src/components/flatmap/MapNodeMarker.test.tsx` (if the file has no existing render helper, use `render` from `@testing-library/react` as the other tests in this repo do):

```tsx
import { render } from "@testing-library/react";
import { MapNodeMarker } from "./MapNodeMarker";

describe("MapNodeMarker cluster extras (issue: /globe white-square nodes)", () => {
  it("omitting count and ring renders no badge and no ring (byte-compatible with /map)", () => {
    const { queryByTestId } = render(
      <MapNodeMarker kind="venue" label="Aventura" status="ok" showLabel={false} />,
    );
    expect(queryByTestId("node-count")).toBeNull();
    const node = queryByTestId("map-node")!;
    expect(node.getAttribute("data-ring")).toBeNull();
    expect(node.style.boxShadow).toBe("");   // no glow when ring is unset
  });

  it("count renders a badge with the number", () => {
    const { getByTestId } = render(
      <MapNodeMarker kind="venue" label="Miami" status="warn" showLabel count={7} />,
    );
    expect(getByTestId("node-count").textContent).toBe("7");
  });

  it("ring adds a guaranteed-visible status-colored glow keyed to the status", () => {
    const { getByTestId } = render(
      <MapNodeMarker kind="venue" label="Miami" status="crit" showLabel ring count={3} />,
    );
    const node = getByTestId("map-node");
    expect(node.getAttribute("data-ring")).toBe("crit");   // testable marker
    expect(node.style.boxShadow).toContain("#f2545b");     // crit hex — a real, visible ring
  });
});
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `cd <worktree> && npx vitest run src/components/flatmap/MapNodeMarker.test.tsx`
Expected: FAIL — `node-count` not found; `ring-crit` not present.

- [ ] **Step 3: Implement the optional props**

Replace `/Users/jn/code/godview-prototype/src/components/flatmap/MapNodeMarker.tsx` with:

```tsx
import { Building2, Server, Video, MonitorPlay } from "lucide-react";

const ICON = { venue: Building2, system: Server, camera: Video, display: MonitorPlay } as const;
const DOT: Record<"ok" | "warn" | "off" | "crit", string> = {
  ok: "bg-ok", warn: "bg-warn", off: "bg-off", crit: "bg-crit",
};
// Ring glow color per tone — inline hex (not a Tailwind class) so the bright ring is GUARANTEED to
// render regardless of theme purge. Values mirror TONE_HEX; kept local to keep this shared /map
// component free of a globe-selectors dependency. Only cluster markers on /globe pass `ring`.
const RING_HEX: Record<"ok" | "warn" | "off" | "crit", string> = {
  ok: "#34d399", warn: "#f5b942", off: "#5b6472", crit: "#f2545b",
};

export function MapNodeMarker({ kind, label, status, showLabel, dim, count, ring }: {
  kind: "venue" | "system" | "camera" | "display";
  label: string; status: "ok" | "warn" | "off" | "crit"; showLabel: boolean; dim?: boolean;
  count?: number; ring?: boolean;
}) {
  const Icon = ICON[kind];
  return (
    <div className="flex flex-col items-center select-none">
      <div data-testid="map-node" {...(ring ? { "data-ring": status } : {})}
        className={`relative flex h-9 w-9 items-center justify-center rounded-[9px] bg-white shadow-md cursor-pointer ${dim ? "opacity-60" : ""}`}
        style={ring ? { boxShadow: `0 0 0 3px ${RING_HEX[status]}, 0 0 10px 1px ${RING_HEX[status]}` } : undefined}>
        <Icon className="h-4 w-4 text-[#1a2029]" strokeWidth={1.8} />
        <span data-testid="node-status-dot"
          className={`absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full ring-2 ring-bg ${DOT[status]}`} />
        {count != null && (
          <span data-testid="node-count"
            className="absolute -bottom-1 -right-1 min-w-[15px] rounded-full bg-elev px-1 text-center text-[9px] font-semibold leading-[15px] text-text ring-1 ring-bg">
            {count}
          </span>
        )}
      </div>
      {showLabel && (
        <span className="mt-1 max-w-[120px] truncate rounded px-1 text-[10.5px] text-text"
          style={{ textShadow: "0 1px 3px #0a0d12, 0 0 2px #0a0d12" }}>{label}</span>
      )}
    </div>
  );
}
```

Note: the default marker (no `ring`) keeps `style={undefined}` and no `data-ring` attribute, so `/map`'s existing DOM/snapshot is unchanged.

- [ ] **Step 4: Run the tests, verify they pass + full suite**

Run: `cd <worktree> && npx vitest run src/components/flatmap/MapNodeMarker.test.tsx && npm run test`
Expected: new tests PASS; full suite green (existing `/map` MapNodeMarker tests unaffected — no props changed for them).

- [ ] **Step 5: Commit** — first the failing test, then the implementation (two commits, red→green in history).

---

### Task 2: `explodeSelectors` — connector two-state color, `statusTone`, `nodeShowLabel`

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/explodeSelectors.test.ts`

**Interfaces:**
- Consumes: `MapMode`, `TONE_HEX`, `HealthTone` from `./globeSelectors`; existing `ExplodedConnector`, `ExplodedNodeType`.
- Produces:
  - `connectorColor(c, mode, live)` — CHANGED to two-state: green (`TONE_HEX.ok`) when the branch is active, gray (`#3a4150`) otherwise. Consumed by `GlobeCanvas` (Task 5).
  - `statusTone(status: string): HealthTone` — maps a raw node status to the marker tone union: `"active"→"ok"`, `"degraded"→"warn"`, everything else (`offline`/`retired`/unknown) → `"off"`. Consumed by Task 5.
  - `DEVICE_LABEL_ALTITUDE = 0.2` and `nodeShowLabel(type: ExplodedNodeType, altitude: number): boolean` — `type === "system"` → always true; camera/display leaf → true only when `altitude <= DEVICE_LABEL_ALTITUDE` (zoomed in). Consumed by Task 5. (Smaller altitude = more zoomed in on globe.gl.)

- [ ] **Step 1: Write the failing tests**

Add to `/Users/jn/code/godview-prototype/src/data/explodeSelectors.test.ts`:

```ts
import { connectorColor, statusTone, nodeShowLabel, DEVICE_LABEL_ALTITUDE } from "./explodeSelectors";
import { TONE_HEX } from "./globeSelectors";
import type { ExplodedConnector } from "./explodeSelectors";

const conn = (status: string, systemId = "s1"): ExplodedConnector => ({
  key: "k", from: { lat: 0, lng: 0, altitude: 0 }, to: { lat: 0, lng: 0, altitude: 0 },
  systemId, status,
});

describe("connectorColor — two-state green/gray (issue: /globe restyle)", () => {
  it("health mode: active → green, anything else → gray", () => {
    expect(connectorColor(conn("active"), "health", new Set())).toBe(TONE_HEX.ok);
    expect(connectorColor(conn("degraded"), "health", new Set())).toBe("#3a4150");
    expect(connectorColor(conn("offline"), "health", new Set())).toBe("#3a4150");
  });
  it("live mode: system in live set → green, else gray", () => {
    expect(connectorColor(conn("active", "s1"), "live", new Set(["s1"]))).toBe(TONE_HEX.ok);
    expect(connectorColor(conn("active", "s1"), "live", new Set())).toBe("#3a4150");
  });
});

describe("statusTone", () => {
  it("maps raw status to the marker tone union", () => {
    expect(statusTone("active")).toBe("ok");
    expect(statusTone("degraded")).toBe("warn");
    expect(statusTone("offline")).toBe("off");
    expect(statusTone("retired")).toBe("off");
    expect(statusTone("anything")).toBe("off");
  });
});

describe("nodeShowLabel — leaf labels appear as you zoom in", () => {
  it("system labels always show", () => {
    expect(nodeShowLabel("system", 1.0)).toBe(true);
    expect(nodeShowLabel("system", 0.05)).toBe(true);
  });
  it("camera/display labels show only at/under DEVICE_LABEL_ALTITUDE", () => {
    expect(nodeShowLabel("camera", DEVICE_LABEL_ALTITUDE + 0.01)).toBe(false);
    expect(nodeShowLabel("camera", DEVICE_LABEL_ALTITUDE)).toBe(true);
    expect(nodeShowLabel("display", 0.1)).toBe(true);
    expect(nodeShowLabel("display", 0.3)).toBe(false);
  });
});
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `cd <worktree> && npx vitest run src/data/explodeSelectors.test.ts`
Expected: FAIL — `statusTone`/`nodeShowLabel`/`DEVICE_LABEL_ALTITUDE` not exported; `connectorColor` still returns amber for degraded in health mode.

- [ ] **Step 3: Implement**

In `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts`:

(a) Add `HealthTone` to the existing globeSelectors import (line 4):
```ts
import { TONE_HEX, type MapMode, type HealthTone } from "./globeSelectors";
```

(b) Replace the existing `connectorColor` (lines 193–196) with the two-state version, and add the new helpers directly below it:
```ts
export function connectorColor(c: ExplodedConnector, mode: MapMode, live: Set<string>): string {
  const active = mode === "health" ? c.status === "active" : live.has(c.systemId);
  return active ? TONE_HEX.ok : "#3a4150";   // green (active) / gray (idle) — matches /map edges
}

/** Raw node status -> the marker tone union (nodes have no failure count, so never "crit"). */
export function statusTone(status: string): HealthTone {
  if (status === "active") return "ok";
  if (status === "degraded") return "warn";
  return "off";
}

/** Globe altitude below which drill-in leaf (camera/display) labels appear. System labels always
 * show (they orient the tree). Smaller altitude = more zoomed in. Mirrors /map's deviceShowLabel. */
export const DEVICE_LABEL_ALTITUDE = 0.2;
export function nodeShowLabel(type: ExplodedNodeType, altitude: number): boolean {
  return type === "system" || altitude <= DEVICE_LABEL_ALTITUDE;
}
```

Note: the existing `DIM = "#3a4150"` constant (line 26) is the same gray — you may reference `DIM` instead of the literal in `connectorColor` for consistency; either is acceptable.

- [ ] **Step 4: Run the tests, verify they pass + full suite**

Run: `cd <worktree> && npx vitest run src/data/explodeSelectors.test.ts && npm run test`
Expected: PASS. (If a pre-existing `connectorColor` test asserted the old amber/off behavior, update it to the two-state expectation — this is an intended behavior change per the spec; note it in your report.)

- [ ] **Step 5: Commit** (failing test, then impl — two commits).

---

### Task 3: `globeSelectors` — `dotMarker` (venue/cluster → marker props)

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`

**Interfaces:**
- Consumes: existing `GlobeDot` (`VenueDot | ClusterDot`), `healthTone`, `HealthTone`.
- Produces: `dotMarker(dot: GlobeDot): { kind: "venue"; label: string; status: HealthTone; count: number | null; ring: boolean }` — venue → `{ kind:"venue", label: venue name, status: healthTone(rollup), count: null, ring: false }`; cluster → `{ kind:"venue", label: city, status: healthTone(rollup), count: venues.length, ring: true }`. Both use the venue (`Building2`) icon. Consumed by `GlobeCanvas` (Task 4).

- [ ] **Step 1: Write the failing test**

Add to `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`:

```ts
import { dotMarker } from "./globeSelectors";
import type { VenueDot, ClusterDot } from "./globeSelectors";
import type { MapVenue, MapVenueRollup } from "./apiTypes";

const rollup = (over: Partial<MapVenueRollup> = {}): MapVenueRollup => ({
  systems: 1, cameras: 0, displays: 0, worst_status: "active",
  active_ad_runs: 0, runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null, ...over,
});
const venue = (over: Partial<MapVenue> = {}): MapVenue => ({
  location_id: "v1", name: "Aventura Mall", location_type: "mall", city: "Aventura",
  country: "US", lat: 25.9, lng: -80.1, rollup: rollup(), ...over,
} as MapVenue);

describe("dotMarker", () => {
  it("venue dot -> plain white-square venue marker, no count, no ring", () => {
    const d: VenueDot = { kind: "venue", id: "v1", lat: 25.9, lng: -80.1, venue: venue() };
    expect(dotMarker(d)).toEqual({ kind: "venue", label: "Aventura Mall", status: "ok", count: null, ring: false });
  });
  it("cluster dot -> venue marker with count = venue tally, ring = true, worst-status tone", () => {
    const d: ClusterDot = {
      kind: "cluster", id: "c1", lat: 25.9, lng: -80.1, city: "Miami", country: "US",
      venues: [venue(), venue({ location_id: "v2" })],
      rollup: rollup({ worst_status: "degraded" }),
    };
    expect(dotMarker(d)).toEqual({ kind: "venue", label: "Miami", status: "warn", count: 2, ring: true });
  });
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd <worktree> && npx vitest run src/data/globeSelectors.test.ts`
Expected: FAIL — `dotMarker` is not exported.

- [ ] **Step 3: Implement**

Add to `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` (e.g. directly after `dotRadius`, ~line 196):

```ts
/** Venue/cluster dot -> MapNodeMarker props for the /globe white-square markers (Task 4).
 * Clusters carry a venue count + a bright status ring; individual venues are plain squares.
 * Both use the venue icon; health lives on the dot (and ring), so the body stays white. */
export function dotMarker(dot: GlobeDot): {
  kind: "venue"; label: string; status: HealthTone; count: number | null; ring: boolean;
} {
  if (dot.kind === "cluster") {
    return { kind: "venue", label: dot.city, status: healthTone(dot.rollup), count: dot.venues.length, ring: true };
  }
  return { kind: "venue", label: dot.venue.name, status: healthTone(dot.venue.rollup), count: null, ring: false };
}
```

- [ ] **Step 4: Run the test, verify it passes + full suite**

Run: `cd <worktree> && npx vitest run src/data/globeSelectors.test.ts && npm run test`
Expected: PASS; full suite green.

- [ ] **Step 5: Commit** (failing test, then impl — two commits).

---

### Task 4: `GlobeCanvas` — world venue/cluster nodes as white-square HTML markers

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`

**Interfaces:**
- Consumes: `dotMarker` (Task 3), `MapNodeMarker` (Task 1), the existing `dots` prop + `onDotClick` callback, globe.gl's `htmlElementsData`/`htmlLat`/`htmlLng`/`htmlAltitude`/`htmlElement` API.
- Produces: world venue/cluster nodes rendered as `MapNodeMarker` DOM markers on the globe's html layer, reconciled by `dot:<id>`; the points-layer meshes and the mid-zoom label-sprite layer for those nodes are removed. Establishes the shared `syncHtmlMarkers()` + unified marker-datum shape that Task 5 extends with drill-in node markers.

**This task is E2E-verified (globe.gl cannot run in jsdom). Do NOT add a jsdom render test for `GlobeCanvas`.** Follow the `/map` `FlatMapCanvas.tsx` `syncVenueMarkers` pattern exactly (createRoot per marker, reconcile by id, deferred `root.unmount()` via `queueMicrotask`, DOM `click`/`dblclick` listeners).

- [ ] **Step 1: Establish the unified HTML-marker datum + shared sync**

Context (existing code): the html layer today carries drill-in *labels* via `HtmlLabelDatum { key; label: NodeLabel; el }` with accessors reading `d.label.lat/lng/altitude` (GlobeCanvas.tsx:38, 226–234). We generalize it to a marker datum carrying its own coords + a React root.

(a) Add imports at the top of `GlobeCanvas.tsx`:
```ts
import { createRoot, type Root } from "react-dom/client";
import { MapNodeMarker } from "../flatmap/MapNodeMarker";
import { dotMarker } from "../../data/globeSelectors";   // add to the existing globeSelectors import instead of a second line if preferred
```
Also add to the existing `explodeSelectors` import (GlobeCanvas.tsx:9-12): `statusTone, nodeShowLabel`.

(b) Replace the `HtmlLabelDatum` interface (line 38) with a unified marker datum:
```ts
interface HtmlMarkerDatum { key: string; lat: number; lng: number; altitude: number; el: HTMLDivElement; root: Root; }
```

(c) Add refs near the other data caches (after line 121) — one map per node source, plus an altitude tracker for label gating:
```ts
const venueMarkersRef = useRef(new Map<string, HtmlMarkerDatum>());   // key `dot:<id>`
const nodeMarkersRef = useRef(new Map<string, HtmlMarkerDatum>());    // key `node:<key>` (Task 5)
const altitudeRef = useRef(2.5);                                      // last pov.altitude, for label gating
```

(d) Add the shared feed helper (next to `syncCustomLayer`, ~line 364):
```ts
// One html layer, two marker sources (venue/cluster world markers + drill-in node markers) —
// mirrors syncCustomLayer combining line + deep-pulse datums into one customLayerData array.
const syncHtmlMarkers = () => {
  const globe = globeRef.current;
  if (!globe) return;
  globe.htmlElementsData([...venueMarkersRef.current.values(), ...nodeMarkersRef.current.values()]);
};
```

- [ ] **Step 2: Point the html accessors at the unified datum**

Replace the html accessors in the init chain (lines 226–234) with:
```ts
        // White-square node markers (venue/cluster + drill-in) — one DOM layer, MapNodeMarker
        // roots reconciled by id (syncVenueMarkers/syncNodeMarkers). Replaces the point meshes
        // and the object-layer beads.
        .htmlLat((d: HtmlMarkerDatum) => d.lat)
        .htmlLng((d: HtmlMarkerDatum) => d.lng)
        .htmlAltitude((d: HtmlMarkerDatum) => d.altitude)
        .htmlElement((d: HtmlMarkerDatum) => d.el)
        .htmlElementVisibilityModifier((el: HTMLElement, visible: boolean) => {
          el.style.opacity = visible ? "1" : "0";   // globe.gl hides back-of-globe markers
        })
        .htmlTransitionDuration(0);
```

- [ ] **Step 3: Add `syncVenueMarkers` and remove the point-mesh + venue label-sprite layers**

(a) Add the venue-marker reconciler as a function inside the component (mirror `FlatMapCanvas.syncVenueMarkers`), reading `dotsRef.current`:
```ts
// Reconcile the `dot:*` html markers against dotsRef.current (world venue/cluster nodes).
// Reads only refs, so the onZoom handler (set up once) can call it too. Cluster markers carry a
// count + bright status ring; venues are plain squares. showLabel: labels on for now (bounded by
// clustering + back-of-globe occlusion) — leaf-label gating is a Task-5 concern for drill-in nodes.
const syncVenueMarkers = () => {
  const globe = globeRef.current;
  if (!globe) return;
  const seen = new Set<string>();
  for (const dot of dotsRef.current) {
    const id = `dot:${dot.id}`;
    seen.add(id);
    const m = dotMarker(dot);
    let entry = venueMarkersRef.current.get(id);
    if (!entry) {
      const el = document.createElement("div");
      const root = createRoot(el);
      const captured = dot;   // stable per-marker closure for the click handler
      el.addEventListener("click", (e) => { e.stopPropagation(); clickRef.current(captured); });
      el.addEventListener("dblclick", (e) => e.stopPropagation());
      entry = { key: id, lat: dot.lat, lng: dot.lng, altitude: 0.02, el, root };
      venueMarkersRef.current.set(id, entry);
    } else {
      entry.lat = dot.lat; entry.lng = dot.lng;
    }
    entry.root.render(
      <MapNodeMarker kind="venue" label={m.label} status={m.status} showLabel
        count={m.count ?? undefined} ring={m.ring} />,
    );
  }
  for (const [id, entry] of venueMarkersRef.current) {
    if (seen.has(id)) continue;
    const r = entry.root;
    queueMicrotask(() => r.unmount());   // deferred unmount — React 19 churn guard (the /map lesson)
    venueMarkersRef.current.delete(id);
  }
  syncHtmlMarkers();
};
```
Note: a click handler captured on first create can go stale if a `dot:<id>` is reused for a different underlying dot. Ids are content-stable (`venue.location_id` / `cluster:<city>|<country>`), so reuse implies the same place; passing the *latest* dot is still safer — if you prefer, store the dot on `entry` and read `entry.dot` in the handler. Either is acceptable; call out your choice in the report.

(b) In the DATA effect (lines 273–283), stop feeding the point meshes and drive the markers instead. Replace the effect body with:
```ts
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe) return;
    syncVenueMarkers();
    syncRings();
  }, [dots, mode, ready]);
```
Delete the now-unused `datumsRef`/`diffDatums` venue-point plumbing for this effect and the `globe.pointsData(...)` call. (Leave `diffDatums`/`upsertDatums` imports if still used by rings/arcs; remove the `datumsRef` declaration if nothing else references it — the reviewer will check for orphans.)

(c) Remove the point-layer accessors from the init chain (lines 172–177: `.pointAltitude/.pointColor/.pointRadius/.pointLabel/.onPointClick`). The points layer is no longer fed. (`dotColor`/`dotRadius`/`dotSummary`/`escapeHtml` imports become unused **for the points layer** — remove any that nothing else references; `dotMarker` replaces them.)

(d) Remove the mid-zoom label-sprite layer for venues (it now double-draws with the marker labels):
  - Delete the LABELS effect (lines 302–314) and the label accessors in the init chain (lines 198–206).
  - Remove the `labels` prop from `GlobeCanvas`'s props (lines 57, 66) and its `labelDatumsRef` (line 109).
  - In `Globe.tsx`: stop passing `labels` to `<GlobeCanvas>` (line 129) and remove the now-unused `labels` memo (lines 92–95) plus the `labelsFor`/`suppressExplodedLabel` imports (lines 9, 13) **if nothing else uses them**. Do NOT delete the `labelsFor`/`suppressExplodedLabel` functions themselves (pre-existing code, may retain tests) — only remove their now-dead usage here (CLAUDE.md §3).

- [ ] **Step 4: Live E2E — world tier**

Start the dev server in the worktree (see the runbook the controller provides), open `/globe`, and via Playwright:
- At the default/zoomed-out pov: assert white-square markers exist (`[data-testid="map-node"]`), that **cluster** markers show a `[data-testid="node-count"]` badge and a `ring-*` class, and that the org **arcs** are still present (globe.gl `.arcsData` unchanged).
- Zoom in until clusters split into individual venues → plain white-square venue markers (no count/ring), labels visible.
- Click a venue marker → its `VenuePanel` opens (right-docked). Click a cluster marker → camera flies in / de-clusters (existing `onDotClick` behavior).
- Rotate the globe → markers on the back hemisphere fade to `opacity:0` (no floating over the far side).
- 0 console errors across rotate/zoom churn (attach a fresh console listener; the `queueMicrotask` unmount must keep React quiet).

Report the E2E findings (the controller runs this gate).

- [ ] **Step 5: Commit** — the canvas + page changes for the world-tier markers.

---

### Task 5: `GlobeCanvas` — drill-in system/camera/display nodes as white-square HTML markers

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`

**Interfaces:**
- Consumes: Task 4's `syncHtmlMarkers`/`nodeMarkersRef`/`altitudeRef`; `MapNodeMarker`, `statusTone`, `nodeShowLabel`, the changed `connectorColor` (Task 2); the existing `explosion` prop + `onNodeClick` callback.
- Produces: drill-in system/camera/display nodes rendered as `MapNodeMarker` DOM markers (reconciled by `node:<key>`), replacing the object-layer sphere beads and the `globe-node-label` divs. Connectors already recolor green/gray via Task 2's `connectorColor`. Leaf labels gate on altitude via `nodeShowLabel`.

**E2E-only (globe.gl not in jsdom).** Reuse the Task 4 marker pattern.

- [ ] **Step 1: Add `syncNodeMarkers` and drive it from the EXPLOSION effect**

(a) Add the node-marker reconciler (mirror `syncVenueMarkers`, reading the current explosion's nodes — pass them in, since explosion is a prop, not a ref; keep a small `explosionRef` if the onZoom handler must re-sync on altitude crossing):
```ts
const explosionRef = useRef<ExplosionLayout | null>(null);   // near the other refs
// ...
const syncNodeMarkers = () => {
  const globe = globeRef.current;
  if (!globe) return;
  const nodes = explosionRef.current?.nodes ?? [];
  const alt = altitudeRef.current;
  const seen = new Set<string>();
  for (const node of nodes) {
    const id = `node:${node.key}`;
    seen.add(id);
    let entry = nodeMarkersRef.current.get(id);
    if (!entry) {
      const el = document.createElement("div");
      const root = createRoot(el);
      const captured = node;
      el.addEventListener("click", (e) => { e.stopPropagation(); nodeClickRef.current?.(captured); });
      el.addEventListener("dblclick", (e) => e.stopPropagation());
      entry = { key: id, lat: node.lat, lng: node.lng, altitude: node.altitude, el, root };
      nodeMarkersRef.current.set(id, entry);
    } else {
      entry.lat = node.lat; entry.lng = node.lng; entry.altitude = node.altitude;
    }
    entry.root.render(
      <MapNodeMarker kind={node.type} label={node.name ?? node.id}
        status={statusTone(node.status)} showLabel={nodeShowLabel(node.type, alt)} />,
    );
  }
  for (const [id, entry] of nodeMarkersRef.current) {
    if (seen.has(id)) continue;
    const r = entry.root;
    queueMicrotask(() => r.unmount());
    nodeMarkersRef.current.delete(id);
  }
  syncHtmlMarkers();
};
```
(Note: if a marker with the same `node:<key>` is reused for a different underlying node, pass the latest via `entry` as in Task 4 — same tradeoff, same acceptable choices.)

(b) In the EXPLOSION effect (lines 369–436), keep the connector/hull custom-layer sync (it already uses the changed `connectorColor`), but **replace the objects-layer beads and the label divs** with the node markers:
- Set `explosionRef.current = explosion;` at the top of the effect.
- Delete the `nodeDatumsRef` sphere-mesh reconcile + recolor loop + `globe.objectsData(...)` (lines 384–399) and call `syncNodeMarkers()` instead.
- Delete the `explosionLabelDatumsRef` html-label reconcile + `globe.htmlElementsData(...)` (lines 419–435) — the node markers carry their own labels now; the html layer is fed by `syncHtmlMarkers`.
- On `explosion === null`, `syncNodeMarkers()` naturally clears (empty nodes → all `node:*` markers unmount) — keep the existing deep-pulse dispose block.

(c) Remove the object-layer accessors from the init chain (lines 210–214: `.objectLat/.objectLng/.objectAltitude/.objectThreeObject/.onObjectClick`) and the `HtmlLabelDatum`/`NodeDatum` types + `nodeColor` import if now unused. Keep `customThreeObject*` (connectors/hull/pulses) untouched.

- [ ] **Step 2: Gate leaf labels on altitude crossing (onZoom)**

Extend the existing `.onZoom` accessor (line 185) so it tracks altitude and re-syncs node labels when crossing the leaf-label threshold (mirrors `/map`'s `deviceLabelRef` crossing):
```ts
        .onZoom((pov: { lat: number; lng: number; altitude: number }) => {
          altitudeRef.current = pov.altitude;
          povRef.current(pov);
          const show = pov.altitude <= DEVICE_LABEL_ALTITUDE;
          if (show !== leafLabelRef.current) { leafLabelRef.current = show; syncNodeMarkers(); }
        })
```
Add `const leafLabelRef = useRef(false);` with the other refs, and import `DEVICE_LABEL_ALTITUDE` from `explodeSelectors`. (`syncNodeMarkers` reads only refs, so calling it from this once-set handler is safe.)

- [ ] **Step 3: Dispose markers on unmount**

In the DISPOSE cleanup (lines 250–268), unmount both marker maps' roots so long-lived TV sessions don't leak React roots:
```ts
      for (const e of venueMarkersRef.current.values()) { const r = e.root; queueMicrotask(() => r.unmount()); }
      venueMarkersRef.current.clear();
      for (const e of nodeMarkersRef.current.values()) { const r = e.root; queueMicrotask(() => r.unmount()); }
      nodeMarkersRef.current.clear();
```

- [ ] **Step 4: Live E2E — drill-in tier**

Open `/globe`, drill into a venue (click a venue marker → it flies in; keep zooming until the explosion tier), and via Playwright:
- Assert drill-in **system/camera/display** nodes render as white-square markers (Server/Video/MonitorPlay icons via `[data-testid="map-node"]`), NOT green sphere beads.
- Assert the connector lines are green when active / gray when idle (inspect the custom-layer line materials or visually confirm no always-green tree).
- **Leaf-label gating:** at the shallow explosion band, camera/display markers show icon+dot but **no label**, while **system** labels show; zoom in past `DEVICE_LABEL_ALTITUDE` (0.2) → leaf labels appear; zoom back out → they hide.
- Click a system and a device marker → the correct `NodePanel` opens.
- Zoom back out → node markers unmount (only world markers remain); back-of-globe occlusion still holds; 0 console errors.
- Verify at a mobile width too (the `/globe` mobile drawer layout is unchanged, but confirm markers render).

Report the E2E findings.

- [ ] **Step 5: Commit** — the drill-in node markers + label gating + dispose hygiene.

---

## Notes for the executor

- **Order matters:** Tasks 1–3 (pure, TDD) must land before Task 4/5 (they consume `count`/`ring`, `dotMarker`, `statusTone`/`nodeShowLabel`/two-state `connectorColor`). Task 5 builds on Task 4's shared `syncHtmlMarkers`/`nodeMarkersRef`/`altitudeRef`.
- **Do not touch** the arcs, rings, far/deep pulse, focus, zoom, background-color, or pause effects — they are orthogonal and must keep working.
- After Task 5, run `npm run test` (full suite), `npm run lint`, `npx tsc --noEmit` — all must pass — and remove any imports/types/refs your changes orphaned (`datumsRef`, `dotColor`, `dotRadius`, `dotSummary`, `escapeHtml`, `nodeColor`, `NodeDatum`, `HtmlLabelDatum`, `labelsFor`/`suppressExplodedLabel` usage) that nothing else references. Do not delete pre-existing exported functions, only your own orphans.
