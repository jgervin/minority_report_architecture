# Flat Map venue clustering (#37) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `/map`, collapse co-located (same-city) venue markers into a single count+label cluster marker at world zoom, de-clustering when zoomed in.

**Architecture:** Add a pure `clusterMapVenues(venues, mapZoom)` selector that reuses the existing `clusterVenues()` city-grouping, gated on Mapbox zoom tier. `FlatMapCanvas.syncVenueMarkers` renders the resulting `GlobeDot[]` (venue vs cluster) live from `map.getZoom()`. A cluster click flies to city zoom to de-cluster.

**Tech Stack:** React 19, TypeScript, Mapbox GL (HTML markers), Vitest (jsdom), Playwright (live E2E).

**Repo:** `godview-prototype` (base `main` @ `c4ceb11`). Spec: `docs/superpowers/specs/2026-07-23-flatmap-venue-clustering-design.md`.

## Global Constraints

- jsdom cannot run mapbox-gl → `FlatMapCanvas` rendering/click behavior is **E2E-only**; unit-test only the pure selector.
- Keep the existing marker reconciliation hygiene: deferred `root.unmount()` via `queueMicrotask`, `marker.remove()` on drop.
- `mapTier` thresholds (from `mapSelectors.ts`): world `< CITY_ZOOM(5)`, city `[5,14)`, building `>= 14`.
- Follow existing style; touch only the three files named. `noop`-omittable optional prop (`onClusterClick?`) so the `FlatMapCanvas.test.tsx` mocks need no change.

---

### Task 1: `clusterMapVenues` pure selector

**Files:**
- Modify: `src/data/mapSelectors.ts`
- Test: `src/data/mapSelectors.test.ts`

**Interfaces:**
- Consumes: `clusterVenues(venues, altitude, threshold?)` and `type GlobeDot` from `./globeSelectors`; `type MapVenue` from `./apiTypes`; `mapTier` (already in this file).
- Produces: `clusterMapVenues(venues: MapVenue[], mapZoom: number): GlobeDot[]`.

- [ ] **Step 1: Write the failing tests**

Add to `src/data/mapSelectors.test.ts` (add imports `clusterMapVenues` from `./mapSelectors`; `type MapVenue` from `./apiTypes`):

```ts
const venue = (id: string, city: string, country: string, lat: number, lng: number): MapVenue => ({
  location_id: id, name: id.toUpperCase(), location_type: "mall", city, country, lat, lng,
  rollup: { systems: 1, cameras: 1, displays: 1, worst_status: "active", active_ad_runs: 0,
    runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null },
  org: { id: "o1", name: "Acme" },
});
const dubaiA = venue("d1", "Dubai", "AE", 25.12, 55.20);
const dubaiB = venue("d2", "Dubai", "AE", 25.20, 55.28);
const bangkok = venue("b1", "Bangkok", "TH", 13.75, 100.53);

describe("clusterMapVenues (#37)", () => {
  it("world zoom groups same-city venues into one cluster with the right count + centroid", () => {
    const dots = clusterMapVenues([dubaiA, dubaiB, bangkok], 2); // zoom 2 = world (< CITY_ZOOM 5)
    const cluster = dots.find((d) => d.kind === "cluster");
    expect(cluster && cluster.kind === "cluster" && cluster.venues.length).toBe(2);
    expect(cluster && cluster.kind === "cluster" && cluster.lat).toBeCloseTo((25.12 + 25.20) / 2, 5);
    expect(dots.filter((d) => d.kind === "venue")).toHaveLength(1); // Bangkok singleton stays a venue dot
  });

  it("city zoom returns every venue individually (no clustering)", () => {
    const dots = clusterMapVenues([dubaiA, dubaiB, bangkok], 8); // zoom 8 = city
    expect(dots).toHaveLength(3);
    expect(dots.every((d) => d.kind === "venue")).toBe(true);
  });

  it("building zoom also returns individuals", () => {
    const dots = clusterMapVenues([dubaiA, dubaiB], 15);
    expect(dots.every((d) => d.kind === "venue")).toBe(true);
  });

  it("empty input -> empty output", () => {
    expect(clusterMapVenues([], 2)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `npx vitest run src/data/mapSelectors.test.ts`
Expected: FAIL — `clusterMapVenues` is not exported / undefined.

- [ ] **Step 3: Implement the selector**

In `src/data/mapSelectors.ts`, add near the top import block and after `mapTier`:

```ts
import { clusterVenues, type GlobeDot } from "./globeSelectors";
import type { MapVenue } from "./apiTypes";

// #37: co-located venue clustering for the flat map. At world tier, reuse clusterVenues' by-city
// grouping (pass altitude=Infinity to force the grouped branch) so overlapping same-city markers
// collapse to one count marker; at city tier and beyond, pass altitude=0 so every venue is its own
// dot. Pure — the only #37 piece jsdom can test (FlatMapCanvas rendering is E2E-only).
export function clusterMapVenues(venues: MapVenue[], mapZoom: number): GlobeDot[] {
  return clusterVenues(venues, mapTier(mapZoom) === "world" ? Infinity : 0);
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `npx vitest run src/data/mapSelectors.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```
test: red — clusterMapVenues world-groups by city / city-splits (#37)
```
then
```
feat: clusterMapVenues selector — city-cluster map venues at world zoom (#37)
```
(Two commits: stage the test first with the stub absent to show red in history, then the impl. If done together, one `feat:` commit is acceptable but prefer red→green.)

---

### Task 2: Render clusters in FlatMapCanvas + wire cluster click

**Files:**
- Modify: `src/components/flatmap/FlatMapCanvas.tsx` (`syncVenueMarkers`, props type, refs)
- Modify: `src/pages/FlatMap.tsx` (pass `onClusterClick`)

**Interfaces:**
- Consumes: `clusterMapVenues` (Task 1); `MapNodeMarker` `count`/`ring` props (existing); `healthTone(rollup)` (already imported in FlatMapCanvas); `flyTo`, `STAGE_ZOOM.city`, `panel` (existing in FlatMap).
- Produces: new optional prop `onClusterClick?: (lat: number, lng: number) => void` on `FlatMapCanvas`.

No jsdom unit test (mapbox can't load in jsdom — see Global Constraints); verified by Task 3 live E2E. The gate here is: existing suite stays green + typecheck + lint clean.

- [ ] **Step 1: Add the `onClusterClick` prop + ref (FlatMapCanvas.tsx)**

Add `onClusterClick` to the destructured params (line ~55) and to the props type (after `onVenueDblClick`, ~line 70):

```ts
  onClusterClick?: (lat: number, lng: number) => void;   // #37: cluster marker click → fly in to de-cluster
```

Add a ref alongside `onVenueClickRef`/`onVenueDblClickRef` (~line 105):

```ts
  const onClusterClickRef = useRef(onClusterClick); onClusterClickRef.current = onClusterClick;
```

Add the import (top of file, with the other `../../data` imports):

```ts
import { clusterMapVenues } from "../../data/mapSelectors";
import type { GlobeDot } from "../../data/globeSelectors";  // only if a type annotation is needed; else omit
```

- [ ] **Step 2: Rewrite `syncVenueMarkers` to iterate clustered dots**

Replace the body of `syncVenueMarkers` (lines 113–162) with:

```tsx
  function syncVenueMarkers() {
    const map = mapRef.current;
    const MBX = mbxRef.current;
    if (!map || !MBX) return;
    const dots = clusterMapVenues(venuesRef.current, map.getZoom());
    const venueLabel = mapTier(map.getZoom()) === "city"; // individual-venue label gating (#26) unchanged
    const seen = new Set<string>();
    for (const dot of dots) {
      const id = dot.kind === "cluster" ? dot.id : `venue:${dot.venue.location_id}`; // cluster dot.id already = "cluster:<city>|<cc>"
      seen.add(id);
      let entry = markersRef.current.get(id);
      if (!entry) {
        const el = document.createElement("div");
        const root = createRoot(el);
        const marker = new MBX.Marker({ element: el, anchor: "top" })
          .setLngLat([dot.lng, dot.lat]).addTo(map);
        if (dot.kind === "cluster") {
          const lat = dot.lat, lng = dot.lng;                       // capture centroid for the closure
          el.addEventListener("click", (e) => { e.stopPropagation(); onClusterClickRef.current?.(lat, lng); });
          el.addEventListener("dblclick", (e) => e.stopPropagation());
        } else {
          const locationId = dot.venue.location_id;
          let clickTimer: ReturnType<typeof setTimeout> | null = null;
          el.addEventListener("click", (e) => {
            e.stopPropagation();
            if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
            clickTimer = setTimeout(() => { clickTimer = null; onVenueClickRef.current(locationId); }, 250);
          });
          el.addEventListener("dblclick", (e) => {
            e.stopPropagation();
            if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
            onVenueDblClickRef.current(locationId);
          });
        }
        entry = { marker, root, el };
        markersRef.current.set(id, entry);
      } else {
        entry.marker.setLngLat([dot.lng, dot.lat]);
      }
      if (dot.kind === "cluster") {
        entry.root.render(
          <MapNodeMarker kind="venue" label={dot.city} status={healthTone(dot.rollup)}
            showLabel count={dot.venues.length} ring />,
        );
      } else {
        entry.root.render(
          <MapNodeMarker kind="venue" label={dot.venue.name} status={healthTone(dot.venue.rollup)}
            showLabel={venueLabel} />,
        );
      }
    }
    for (const [id, entry] of markersRef.current) {
      if (!(id.startsWith("venue:") || id.startsWith("cluster:")) || seen.has(id)) continue;
      const rootToUnmount = entry.root;
      queueMicrotask(() => rootToUnmount.unmount());
      entry.marker.remove();
      markersRef.current.delete(id);
    }
  }
```

(Note: `dot.lat`/`dot.lng` exist on both `VenueDot` and `ClusterDot`; `dot.kind === "cluster"` narrows for `.city`/`.venues`/`.rollup` vs `.venue`.)

- [ ] **Step 3: Wire the cluster click in FlatMap.tsx**

Add to the `<FlatMapCanvas ...>` props (near `onVenueClick`, ~line 213):

```tsx
            onClusterClick={(lat, lng) => flyTo(lat, lng, STAGE_ZOOM.city, !!panel)}
```

- [ ] **Step 4: Typecheck, lint, and run the full unit suite**

Run: `npm run build` (tsc -b + vite build) → expect exit 0, 0 tsc errors.
Run: `npm run lint` → expect exit 0.
Run: `npx vitest run` → expect all green (no regressions; Task 1 tests included).

- [ ] **Step 5: Commit**

```
feat: render same-city venue clusters on /map + cluster-click de-cluster (#37)
```

---

### Task 3: Live E2E verification (real Mapbox)

**Files:** none (verification only). Requires a `VITE_MAPBOX_TOKEN` in a gitignored worktree `.env` (copy from `/Users/jn/code/godview-prototype/.env`; discard at close-out) and ops-api up on :8080. Run the dev server on a NON-5173 port.

- [ ] **Step 1:** Start the worktree dev server (`npm run dev -- --port 5198 --strictPort`); confirm `/map` returns 200.
- [ ] **Step 2:** Playwright: navigate to `http://localhost:5198/map`, wait for the map to load, ensure zoom is at world tier (default ~1.4). Query the DOM for `[data-testid="map-node"]` markers and their `[data-testid="node-count"]` badges.
  - Expect: exactly 3 markers carry a count badge of `2` (Dubai, London, New York), with a visible city label; total venue-marker count = raw 17 − 3 = 14.
- [ ] **Step 3:** Click a cluster marker (e.g. Dubai). Expect: the map flies in (`map.getZoom()` rises past `CITY_ZOOM` 5) and the cluster splits into 2 individual venue markers (`node-count` badge gone; two `map-node` markers near Dubai).
- [ ] **Step 4:** Confirm 0 console errors. Kill the dev server (by port); confirm it's down.

**Definition of done for the branch:** Task 1 unit tests green; `npm run build`/lint clean; full suite green; live E2E Steps 2–4 all pass with 0 console errors.
