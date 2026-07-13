# Globe v2 — Plan E: anchored explosion (godview-prototype, Lane 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lane 2 of the Globe v2 "Living Topology" spec (`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md` §4): below a new `EXPLODE_ALTITUDE` the ONE relevant venue dot explodes into a radial ring of system nodes, and below a second threshold each system fans its cameras + displays in an outer arc segment — all anchored at the venue's real geo position. Connectors (venue→system, system→device) render as a custom three.js line layer, an octagon hull frames the exploded group, DOM labels name every node, and clicking any node swaps the right panel to that node's details, mounted keyed `${type}:${id}`.

**Architecture:** All geometry, layout, label content, and color decisions are pure deterministic functions in a new selector module (`/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts`) — unit-tested in jsdom with zero WebGL. `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` remains the ONLY imperative island: it gains three identity-diffed layers (globe.gl `objectsData` for nodes, `customLayerData` for connectors + hull, `htmlElementsData` for DOM labels) and a widened `onPovChange` callback; `three` is dynamically imported inside the ref-mount effect alongside `globe.gl`, so jsdom never touches it. The Globe page (`/Users/jn/code/godview-prototype/src/pages/Globe.tsx`) owns the exploded venue's detail poll (spec §4 detail-poll-ownership amendment) and composes the per-node panel.

**Tech Stack:** unchanged from v1 (React 19 + Vite 8 + Tailwind 3 + vitest 4 / Testing Library, `globe.gl@2.46.1`), plus `three` promoted from transitive to direct pinned dependency (installed transitively today at `0.185.1`; globe.gl declares `"three": ">=0.179 <1"`).

## Global Constraints

- **Sequencing:** Plan E starts from `main` AFTER Plans C + D (Lane 1) are merged — Plan D also edits `GlobeCanvas.tsx`/`Globe.tsx` (org arcs, chips, labels), and the final E2E asserts org arcs stay visible through the hull. The unit-level tasks do not consume any Plan C additive field (see Contract), so if Lane 1 slips, Tasks 1–9 can proceed on a rebase-later basis — but do NOT open the PR until it's rebased onto merged Lane 1.
- **Exactly ONE venue exploded at a time** (spec §4): the selected venue, or the venue nearest the camera center when none is selected — which is why `onZoom` must surface the full `{lat, lng, altitude}` (globe.gl already delivers `GeoCoords` — `/Users/jn/code/godview-prototype/node_modules/globe.gl/dist/globe.gl.d.ts:21-25,125`); today GlobeCanvas discards all but `pov.altitude` (`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx:66`).
- **Identity-diff EVERY new layer datum** (spec §3/§4 amendment): node datums, connector/hull datums, and html-label datums are all keyed and cached across polls exactly like v1's point datums (`GlobeCanvas.tsx:93-105`) — never mint fresh datum objects per poll, never re-init the globe. A shared pure helper (`diffDatums`, Task 4) enforces the pattern.
- **three/globe.gl must never load in jsdom:** both stay behind the WebGL guard + dynamic import inside the ref-mount effect (`GlobeCanvas.tsx:34-89`); the GlobeCanvas test adds a throwing `vi.mock("three", ...)` next to the existing throwing `globe.gl` mock.
- **Relationships come ONLY from `GET /god-view/map/locations/{id}`** (`/Users/jn/code/mras-ops/api/src/godview/map.py:133-176`) — nothing invented client-side. Per-node extras (camera duty, display screen group) come from the existing fleet detail fetcher `fetchObjectDetail` (`/Users/jn/code/godview-prototype/src/data/api.ts:61-62`). **No new backend.**
- **Detail-poll ownership (spec §4 amendment):** the exploded venue owns its own `/god-view/map/locations/{id}` poll (new `useVenueDetailPoll` hook, Task 6), independent of any panel. `VenuePanel`'s own poll (`/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.tsx:13`) is left untouched (surgical); the accepted cost is a duplicate 5 s poll of the same endpoint while the exploded venue's own VenuePanel is open.
- **Panel keying (fleet lesson):** every panel mounts keyed `${type}:${id}` — established at `/Users/jn/code/godview-prototype/src/pages/Fleet.tsx:58` (`<ObjectDrawer key={`${panel.sel.type}:${panel.sel.id}`} …>`) and `/Users/jn/code/godview-prototype/src/pages/Globe.tsx:62` (`<VenuePanel key={`venue:${panelId}`} …>`).
- **Do not touch Plan D's layers:** `arcsData` (org arcs) and `labelsData` (venue/cluster labels) belong to Lane 1; explosion code adds `objectsData`/`customLayerData`/`htmlElementsData` only. Do not touch `ringsData` phase behavior either — the ring-identity fix is Lane 3 (godview #14).
- **All git via the git-flow-manager subagent** (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers never run raw `git`/`gh`. Work on branch `feat/globe-e-anchored-explosion` in a dedicated worktree of `/Users/jn/code/godview-prototype`. **Commit each failing test separately from the implementation that greens it** (red→green pairs in history); merge commits (not squash) on PR merge.
- Verify commands (confirmed against `/Users/jn/code/godview-prototype/package.json`): `npx vitest run [files]` (script `test` = `vitest run`), `npx tsc -b` (build script runs `tsc -b && vite build`), `npm run lint` (oxlint), `npm run build`.
- Reference every file by absolute path.

## Contract (consumes)

Verbatim field names Plan E reads. Gate-check: diff this against Plan C and the live payload.

**`GET /god-view/map/locations/{id}`** (produced by `/Users/jn/code/mras-ops/api/src/godview/map.py:133-176`):

```
location:  { id, name, location_type, city, country, lat, lng, timezone, status }   (map.py:137-140)
systems[]: { id, name, zone, status, system_type, cameras[], displays[] }           (map.py:144-146,165-167)
systems[].cameras[]:  { id, name, status, screen_id, last_seen_at }                 (map.py:149-152)
systems[].displays[]: { id, name, status, screen_id, last_seen_at }                 (map.py:153-156)
ad_runs[]: { id, status, system_id, system_name, started_at, ended_at, created_at } (map.py:169-174; + display_id once Plan C merges — not consumed here)
```

Plan E consumes: `location.id`, `location.name`, `location.lat`, `location.lng`; `systems[].id/name/zone/status/system_type`; device `id/name/status/screen_id/last_seen_at`; `ad_runs[].status` + `ad_runs[].system_id` (live-mode styling only — a system is "live" when it has an ad_run with status `dispatched` or `playing`, same predicate as `panelRollupLine` at `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts:142-143`).

**NEW frontend type fields (server already sends both — additive typing only, no backend change):**
- `MapSystemDevice.screen_id: string | null` — server sends it on cameras AND displays (map.py:150,154); the frontend type at `/Users/jn/code/godview-prototype/src/data/apiTypes.ts:137` currently omits it (spec §3 API amendment names this exact gap). Typed nullable because `cameras.screen_id` is nullable in the registry (cf. `FleetCameraItem.screen_id: string | null`, apiTypes.ts:76) while displays' is not (apiTypes.ts:80) — the shared device type takes the union.
- `MapSystem.system_type: string` — server sends it (map.py:145); frontend type at apiTypes.ts:138 omits it; the system panel promises `zone/status/system_type` (spec §4).

**`fetchObjectDetail(type, id)`** (`/Users/jn/code/godview-prototype/src/data/api.ts:61-62` → `ObjectDetail` at apiTypes.ts:84-89; server shapes at `/Users/jn/code/mras-ops/api/src/registry/reads.py:190-215`):
- camera → `state.effective_duty` (reads.py:195-198,203 — COALESCEd to `'unknown'`), `state.last_seen_at`
- display → `config.screen_group_id` (reads.py:212)

**`GET /god-view/map`** (v1, unchanged consumption): `venues[].location_id/name/lat/lng/city/country/rollup`. Plan E does **NOT** consume Plan C's additive fields (`org`, `last_run_created_at`, `ad_runs[].display_id`) — those are Lanes 1/3.

**globe.gl / three-globe API consumed** (verified in the installed d.ts):
- `objectsData` / `objectLat` / `objectLng` / `objectAltitude` / `objectThreeObject` — `/Users/jn/code/godview-prototype/node_modules/three-globe/dist/three-globe.d.ts:346-359`; `onObjectClick` — `globe.gl.d.ts:105`.
- `customLayerData` / `customThreeObject` / `customThreeObjectUpdate` — `three-globe.d.ts:362-367`.
- `htmlElementsData` / `htmlLat` / `htmlLng` / `htmlAltitude` / `htmlElement` / `htmlElementVisibilityModifier` / `htmlTransitionDuration` — `three-globe.d.ts:330-343`.
- `getCoords(lat, lng, altitude?)` → `{x,y,z}` — `three-globe.d.ts:371` (exposed on the globe.gl instance, which extends `ThreeGlobeGeneric` — `globe.gl.d.ts:32-33`).
- `pointOfView` / `onZoom(callback: (pov: GeoCoords) => void)` with `GeoCoords = { lat, lng, altitude }` — `globe.gl.d.ts:21-25,113-114,125`.

---

## Task 1 — Worktree + `three` direct dependency

**Files**
- Modify: `/Users/jn/code/godview-prototype/package.json` (+ lockfile) — add `"three"` (exact pin to the installed transitive version) to `dependencies`.

**Interfaces** — none (infra task; no TDD pair — verified by install + build commands).

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/globe-e-anchored-explosion` from `main` for `/Users/jn/code/godview-prototype` (after confirming Plans C + D are merged to `main`; if not, flag it and proceed rebase-later per Global Constraints). All subsequent paths refer to that worktree's checkout (written as the repo's canonical absolute paths).
- [ ] Confirm the transitively installed three version: `node -e "console.log(require('three/package.json').version)"` — expected `0.185.1` (globe.gl allows `>=0.179 <1`). Pin exactly what is installed: `npm install --save-exact three@<that version>` so Vite/vitest resolve the same copy globe.gl bundles against (no dual-three).
- [ ] Verify: `node -e "console.log(require('./package.json').dependencies.three)"` prints the pinned version; `npm run build` still succeeds.
- [ ] Commit via git-flow-manager: `chore(globe): promote three to a direct pinned dependency (explosion layers build Line/Mesh objects directly)`

---

## Task 2 — Type widening: `MapSystemDevice.screen_id`, `MapSystem.system_type`

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts:137-138` (two fields)
- Modify: `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (fixtures gain the fields — every later test leans on them)
- Test: `/Users/jn/code/godview-prototype/src/data/api.test.ts` (append to the existing `globe map api` describe block)

**Interfaces**

```ts
// apiTypes.ts:137 becomes:
export interface MapSystemDevice { id: string; name: string | null; status: string; screen_id: string | null; last_seen_at: string | null; }
// apiTypes.ts:138 becomes:
export interface MapSystem { id: string; name: string; zone: string | null; status: string; system_type: string; cameras: MapSystemDevice[]; displays: MapSystemDevice[]; }
```

**Steps**

- [ ] Write the failing test — append inside `api.test.ts`'s `globe map api` block:

```ts
it("fetchMapLocation surfaces screen_id on devices and system_type on systems (server already sends both)", async () => {
  const payload = { location: { id: "l1", name: "Mall", location_type: "mall", city: null,
    country: null, lat: null, lng: null }, systems: [
      { id: "s1", name: "Wall A", zone: "entrance", status: "active", system_type: "advertising_wall",
        cameras: [{ id: "c1", name: "Cam", status: "active", screen_id: "demo-cam-1", last_seen_at: null }],
        displays: [{ id: "d1", name: "Panel", status: "active", screen_id: "demo-disp-1", last_seen_at: null }] },
    ], ad_runs: [] };
  vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(payload), { status: 200 }));
  const out = await fetchMapLocation("l1");
  expect(out.systems[0].system_type).toBe("advertising_wall");
  expect(out.systems[0].cameras[0].screen_id).toBe("demo-cam-1");
  expect(out.systems[0].displays[0].screen_id).toBe("demo-disp-1");
});
```

- [ ] **Red is a TYPECHECK failure, not a runtime one** (vitest transpiles via esbuild without typechecking; the JSON round-trips the fields regardless). Run: `npx tsc -b` — expect FAIL: `TS2339: Property 'screen_id' does not exist on type 'MapSystemDevice'` (and `system_type` on `MapSystem`) in `api.test.ts`. Record the exact errors.
- [ ] Commit (red): `test(globe-e): map detail devices carry screen_id, systems carry system_type (red — tsc)`
- [ ] Implement: apply the two-field Interfaces change to `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`. Then update `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` `locationDetail` (lines 41-53): add `system_type: "advertising_wall"` to both systems and `screen_id` to every device (`"demo-cam-a"`, `"demo-cam-b"`, `"demo-cam-c"`, `"demo-disp-a"`, `"demo-disp-b"`, `"demo-disp-c"` — matching the `demo-` screen_id namespace of the seed).
- [ ] Run: `npx tsc -b` — clean; `npx vitest run src/data/api.test.ts src/data/globeSelectors.test.ts src/components/globe/VenuePanel.test.tsx` — PASS (fixture change must not break v1 tests; VenuePanel renders devices but reads no `screen_id`).
- [ ] Commit (green): `feat(globe-e): type MapSystemDevice.screen_id + MapSystem.system_type (additive; server already sends them)`

---

## Task 3 — Explosion layout selectors (pure, WebGL-free)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/explodeSelectors.test.ts`

**Interfaces**

```ts
export interface Pov { lat: number; lng: number; altitude: number; }
export const EXPLODE_ALTITUDE = 0.8;    // below v1's CLUSTER_ALTITUDE (1.2, globeSelectors.ts:68);
                                        // v1's venue fly-to lands at CLUSTER_ALTITUDE*0.6 = 0.72
                                        // (GlobeCanvas.tsx:114) — i.e. INSIDE the explode band, so
                                        // selecting a venue explodes it. Provisional; tuned in Task 10.
export const DEVICE_ALTITUDE = 0.35;    // second threshold: device fan appears
export const NODE_ALTITUDE = 0.015;     // node hover height (v1 points sit at 0.02)

export type ExplodedNodeType = "system" | "camera" | "display";
export interface ExplodedNode {
  key: string;                          // `${type}:${id}` — stable datum identity AND panel key
  type: ExplodedNodeType;
  id: string;
  venueId: string;
  systemId: string | null;              // parent system for devices; null for system nodes
  name: string | null;
  status: string;
  screen_id: string | null;             // devices only ("" never sent; systems get null)
  last_seen_at: string | null;
  lat: number; lng: number; altitude: number;
}
export interface GeoPoint { lat: number; lng: number; altitude: number; }
export interface ExplodedConnector { key: string; from: GeoPoint; to: GeoPoint; systemId: string; status: string; }
export interface HullDatum { key: string; points: GeoPoint[]; }      // 9 points — octagon closed loop
export interface NodeLabel { key: string; kind: "venue" | "system" | "device"; lat: number; lng: number; altitude: number; text: string; glyph: string | null; }
export interface ExplosionLayout {
  venueId: string; tier: 1 | 2;
  nodes: ExplodedNode[]; connectors: ExplodedConnector[]; hull: HullDatum; labels: NodeLabel[];
}

export function explosionTier(altitude: number): 0 | 1 | 2;
export function explodedVenueId(venues: MapVenue[], pov: Pov, selectedVenueId: string | null): string | null;
export function explodeVenue(detail: MapLocationDetail, tier: 1 | 2): ExplosionLayout;
export function liveSystemIds(detail: MapLocationDetail): Set<string>;
export function nodeColor(node: ExplodedNode, mode: MapMode, live: Set<string>): string;
export function connectorColor(c: ExplodedConnector, mode: MapMode, live: Set<string>): string;
export function statusGlyph(status: string): string;   // "●" active, "◐" degraded, "○" otherwise
```

Geometry rules (spec §4 amendments, encoded as tests):
- Angle convention: measured from north, clockwise. Offset from the venue anchor: `lat += r·cos(θ)`, `lng += r·sin(θ) / cos(anchorLat·π/180)` — **the cos(lat) division is mandatory** or rings render as ellipses (a 51.5°N venue squashes 38%).
- Ring radii are fixed geo-degree constants sized for the `EXPLODE_ALTITUDE` band (on-screen size scales ~1/altitude): `SYSTEM_RING_DEG = 1.8`, `DEVICE_RING_DEG = 3.2`, `HULL_RING_DEG = 4.2` (module-private consts; provisional — Task 10 tunes them live).
- Determinism: systems sorted by `id` ascending; within a system, cameras sorted by `id` then displays sorted by `id`. System i of n sits at `θ = 2πi/n` (first due north). Tier 2: system i's devices fan across an outer arc segment centered on `θᵢ`, width `(2π/n)·0.8`, device j of m at `θᵢ + segWidth·(m === 1 ? 0 : j/(m-1) − 1/2)`.
- Hull: 8 vertices at `θ = 22.5° + k·45°`, radius `HULL_RING_DEG`, closed by repeating the first point (9 points), altitude `NODE_ALTITUDE / 2`.
- Labels: venue name at north of the hull (`HULL_RING_DEG + 0.5`, θ=0, glyph null); system name just outside each ring node (`SYSTEM_RING_DEG + 0.5`, same θ); device `name ?? screen_id ?? id` + `statusGlyph(status)` just outside each device node (`DEVICE_RING_DEG + 0.45`).
- `explodedVenueId`: `null` when `explosionTier(pov.altitude) === 0` or no venue has coords; the selected venue when it exists and has coords; otherwise the plottable venue nearest the camera center by equirectangular distance `Δlat² + (Δlng·cos(pov.lat·π/180))²`.
- Colors: health mode → `TONE_HEX` by status (`active`→ok, `degraded`→warn, else off — device rows carry no failure counts, so no crit at node level). live mode → `TONE_HEX.ok` when the node's system (`systemId ?? id`) is in `liveSystemIds(detail)` (`ad_runs` rows with status `dispatched`/`playing`), else dim `#3a4150`. Connectors take the child endpoint's system/status the same way.

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/data/explodeSelectors.test.ts`. Cover, using `locationDetail`/`venues` from `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` plus a synthetic 51.5°N detail:

```ts
import { describe, expect, it } from "vitest";
import {
  DEVICE_ALTITUDE, EXPLODE_ALTITUDE, NODE_ALTITUDE,
  explodeVenue, explodedVenueId, explosionTier, liveSystemIds,
  nodeColor, connectorColor, statusGlyph, type Pov,
} from "./explodeSelectors";
import { locationDetail, venues } from "./globeFixtures";
import type { MapLocationDetail } from "./apiTypes";

const pov = (lat: number, lng: number, altitude: number): Pov => ({ lat, lng, altitude });

describe("explosionTier (spec §4 thresholds)", () => {
  it("0 at/above EXPLODE_ALTITUDE, 1 in the band, 2 below DEVICE_ALTITUDE", () => {
    expect(explosionTier(EXPLODE_ALTITUDE)).toBe(0);
    expect(explosionTier(1.2)).toBe(0);
    expect(explosionTier(0.5)).toBe(1);
    expect(explosionTier(DEVICE_ALTITUDE - 0.01)).toBe(2);
  });
  it("EXPLODE_ALTITUDE sits below v1's CLUSTER_ALTITUDE and above the v1 fly-to landing (0.72)", () => {
    expect(EXPLODE_ALTITUDE).toBeLessThan(1.2);
    expect(EXPLODE_ALTITUDE).toBeGreaterThan(0.72);
  });
});

describe("explodedVenueId — exactly one venue, selected or nearest camera center", () => {
  it("null above the threshold regardless of selection", () => {
    expect(explodedVenueId(venues, pov(32.9, -96.8, 1.0), "loc_dal_north")).toBeNull();
  });
  it("the selected venue wins when it has coords", () => {
    expect(explodedVenueId(venues, pov(52, 13, 0.5), "loc_dal_north")).toBe("loc_dal_north");
  });
  it("no selection -> nearest plottable venue to the camera center", () => {
    expect(explodedVenueId(venues, pov(52.4, 13.3, 0.5), null)).toBe("loc_berlin");
    // [ERRATUM 2026-07-12: original expected loc_dal_north — planner arithmetic error; the formula is the spec and loc_dal_gal is strictly nearer (0.00518 vs 0.01). Shipped code follows the formula.]
    expect(explodedVenueId(venues, pov(33.0, -96.8, 0.5), null)).toBe("loc_dal_gal");
  });
  it("a selected venue without coords falls back to nearest", () => {
    expect(explodedVenueId(venues, pov(52.4, 13.3, 0.5), "loc_nocoords")).toBe("loc_berlin");
  });
  it("longitude distance is cos(lat)-weighted", () => {
    // At 52°N a 2° lng gap shrinks to ~1.23° effective; construct a pov where naive
    // (unweighted) distance would pick the wrong venue and assert the weighted winner.
    // (Concrete fixture pair chosen at implementation time; assert the weighted choice.)
  });
});

describe("explodeVenue — deterministic two-tier layout", () => {
  const l1 = explodeVenue(locationDetail, 1);
  it("tier 1: one node per system on the ring, keys `${'system'}:${id}`, sorted by id", () => {
    expect(l1.nodes.map((n) => n.key)).toEqual(["system:sys_entrance_a", "system:sys_food_court"]);
    expect(l1.nodes.every((n) => n.type === "system")).toBe(true);
    expect(l1.nodes[0].altitude).toBe(NODE_ALTITUDE);
  });
  it("tier 1: venue->system connectors only, one per system", () => {
    expect(l1.connectors).toHaveLength(2);
    expect(l1.connectors.map((c) => c.key)).toEqual(
      ["conn:venue>system:sys_entrance_a", "conn:venue>system:sys_food_court"]);
  });
  it("first system sits due north of the anchor (lat + R, lng unchanged)", () => {
    const anchor = locationDetail.location;
    expect(l1.nodes[0].lng).toBeCloseTo(anchor.lng!, 6);
    expect(l1.nodes[0].lat).toBeGreaterThan(anchor.lat!);
  });
  it("is a pure function: same input -> deep-equal output", () => {
    expect(explodeVenue(locationDetail, 2)).toEqual(explodeVenue(locationDetail, 2));
  });
  const l2 = explodeVenue(locationDetail, 2);
  it("tier 2 adds device nodes in the outer arc segment of their parent system", () => {
    const devices = l2.nodes.filter((n) => n.type !== "system");
    expect(devices).toHaveLength(6);                        // 3 cameras + 3 displays
    expect(devices.map((n) => n.key)).toContain("camera:cam_a");
    expect(devices.map((n) => n.key)).toContain("display:disp_c");
    const camA = devices.find((n) => n.id === "cam_a")!;
    expect(camA.systemId).toBe("sys_entrance_a");
    expect(camA.screen_id).toBe("demo-cam-a");              // Task 2 fixture field flows through
  });
  it("tier 2 adds system->device connectors carrying the device's system + status", () => {
    const sysDev = l2.connectors.filter((c) => c.key.startsWith("conn:system:"));
    expect(sysDev).toHaveLength(6);
  });
  it("octagon hull: 9 points (closed loop) around the group", () => {
    expect(l2.hull.points).toHaveLength(9);
    expect(l2.hull.points[0]).toEqual(l2.hull.points[8]);
    expect(l2.hull.key).toBe("hull:loc_dal_north");
  });
  it("labels: venue name on the hull, system names on ring nodes, device name + status glyph", () => {
    const byKind = (k: string) => l2.labels.filter((l) => l.kind === k);
    expect(byKind("venue")[0].text).toBe("Dallas North Mall");
    expect(byKind("system").map((l) => l.text)).toEqual(["Entrance Wall A", "Food Court Wall"]);
    const camB = l2.labels.find((l) => l.text.includes("Entrance Cam B"))!;
    expect(camB.glyph).toBe("◐");                           // degraded fixture camera
  });
});

describe("cos(lat) correction (spec §4 amendment: 51.5N squashes 38% uncorrected)", () => {
  const northDetail: MapLocationDetail = {
    ...locationDetail,
    location: { ...locationDetail.location, id: "loc_london", name: "London", lat: 51.5, lng: 0 },
  };
  it("east-pointing offsets divide lng by cos(lat)", () => {
    // With 4 systems, system index 1 sits due east (θ=90°): lat offset ~0, lng offset = R / cos(51.5°).
    const four = { ...northDetail, systems: [0, 1, 2, 3].map((i) => ({
      ...northDetail.systems[0], id: `sys_${i}`, name: `S${i}`, cameras: [], displays: [] })) };
    const nodes = explodeVenue(four, 1).nodes;
    const east = nodes[1];
    const latRadius = nodes[0].lat - 51.5;                  // R in degrees, read off the north node
    expect(east.lat).toBeCloseTo(51.5, 5);
    expect(east.lng).toBeCloseTo(latRadius / Math.cos((51.5 * Math.PI) / 180), 5);
    expect(east.lng / latRadius).toBeGreaterThan(1.55);     // ~1.606 — the anti-squash factor
  });
});

describe("mode styling", () => {
  it("liveSystemIds: systems with dispatched/playing ad_runs", () => {
    expect(liveSystemIds(locationDetail)).toEqual(new Set(["sys_entrance_a"]));   // ar_1 playing
  });
  it("nodeColor health: status tones; live: green for live systems, dim otherwise", () => {
    const l2 = explodeVenue(locationDetail, 2);
    const camB = l2.nodes.find((n) => n.id === "cam_b")!;   // degraded
    const live = liveSystemIds(locationDetail);
    expect(nodeColor(camB, "health", live)).toBe("#f5b942");
    expect(nodeColor(camB, "live", live)).toBe("#34d399");  // parent sys_entrance_a is live
    const foodCam = l2.nodes.find((n) => n.id === "cam_c")!;
    expect(nodeColor(foodCam, "live", live)).toBe("#3a4150");
  });
  it("connectorColor follows the same rule via the connector's systemId/status", () => {
    const l1 = explodeVenue(locationDetail, 1);
    const live = liveSystemIds(locationDetail);
    expect(connectorColor(l1.connectors[0], "live", live)).toBe("#34d399");
    expect(connectorColor(l1.connectors[1], "live", live)).toBe("#3a4150");
  });
  it("statusGlyph", () => {
    expect(statusGlyph("active")).toBe("●");
    expect(statusGlyph("degraded")).toBe("◐");
    expect(statusGlyph("offline")).toBe("○");
    expect(statusGlyph("retired")).toBe("○");
  });
});
```

- [ ] Fill in the cos(lat)-weighted `explodedVenueId` test with a concrete two-venue fixture where weighted and unweighted nearest disagree (compute at implementation time; the assertion must pick the weighted winner).
- [ ] Run: `npx vitest run src/data/explodeSelectors.test.ts` — expect FAIL: `Cannot find module './explodeSelectors'`.
- [ ] Commit (red): `test(globe-e): explosion tiers, one-venue rule, deterministic ring/fan/hull layout, cos(lat) correction, mode colors (red)`
- [ ] Implement `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts` per Interfaces + Geometry rules. Notes:
  - Import `TONE_HEX`, `type MapMode` from `./globeSelectors`; import types from `./apiTypes`. Define local `const DIM = "#3a4150"` (globeSelectors' `DIM_IDLE` is module-private — do not export it; keep the change surgical).
  - `explodeVenue` returns `null`-free data ONLY when `detail.location.lat/lng` are non-null; guard with a thrown-free contract: callers (`Globe.tsx`) check coords first — document this in the JSDoc rather than widening the return type.
  - Everything is plain math + array ops — no three, no globe.gl, no React.
- [ ] Run: `npx vitest run src/data/explodeSelectors.test.ts` — expect PASS. `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe-e): pure explosion layout selectors — tiers, nearest-venue rule, ring/fan/hull geometry, labels, mode colors`

---

## Task 4 — `diffDatums` helper + `onPovChange` widening

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/datumCache.ts` (pure, jsdom-testable)
- Test: `/Users/jn/code/godview-prototype/src/components/globe/datumCache.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` (prop `onAltitudeChange: (altitude) => void` → `onPovChange: (pov: {lat,lng,altitude}) => void`; `onZoom` forwards the whole `GeoCoords` it already receives — today line 66 discards lat/lng)
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` (altitude state → pov state)
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` (prop rename in existing tests)

**Interfaces**

```ts
// datumCache.ts — the identity-diff discipline (spec amendment) as a reusable pure helper.
// Reuses cached datum objects by key so globe.gl updates known objects in place (same pattern
// as v1's point datums, GlobeCanvas.tsx:93-105); `update` mutates the cached datum from the
// fresh source item. Returns the new cache Map; callers spread .values() into the layer setter.
export function diffDatums<S, D>(
  prev: Map<string, D>,
  items: S[],
  key: (item: S) => string,
  create: (item: S) => D,
  update: (datum: D, item: S) => void,
): Map<string, D>;
```

```ts
// GlobeCanvas prop change (breaking within the repo; all three call sites updated in this task):
onPovChange: (pov: { lat: number; lng: number; altitude: number }) => void;   // was onAltitudeChange
```

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/components/globe/datumCache.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { diffDatums } from "./datumCache";

interface Item { id: string; v: number; }
interface Datum { id: string; v: number; }

describe("diffDatums (identity-diff discipline — spec §3/§4 amendment)", () => {
  const mk = (i: Item): Datum => ({ id: i.id, v: i.v });
  const up = (d: Datum, i: Item) => { d.v = i.v; };
  it("reuses the SAME datum object across polls for a stable key", () => {
    const m1 = diffDatums(new Map(), [{ id: "a", v: 1 }], (i) => i.id, mk, up);
    const m2 = diffDatums(m1, [{ id: "a", v: 2 }], (i) => i.id, mk, up);
    expect(m2.get("a")).toBe(m1.get("a"));          // identity preserved
    expect(m2.get("a")!.v).toBe(2);                 // content updated in place
  });
  it("drops vanished keys and creates new ones", () => {
    const m1 = diffDatums(new Map(), [{ id: "a", v: 1 }], (i) => i.id, mk, up);
    const m2 = diffDatums(m1, [{ id: "b", v: 9 }], (i) => i.id, mk, up);
    expect(m2.has("a")).toBe(false);
    expect(m2.get("b")!.v).toBe(9);
  });
});
```

- [ ] Also append the failing prop-shape test to `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` (jsdom fallback path — proves the component compiles and survives with the new prop; the live forwarding is asserted in Task 10):

```tsx
test("GlobeCanvas accepts onPovChange and explosion props on the fallback path", () => {
  render(<GlobeCanvas dots={[]} mode="health" focus={null} explosion={null}
    arcs={[]} labels={[]} highlightOrgId={null}   // Plan D's required props (merged before this plan)
    onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});
```

(`explosion`/`onNodeClick` land in Task 5 — declare them in this red test now so ONE red covers the full new prop surface; Task 5's implementation greens the remainder. If preferred, split: this task's red only renames `onAltitudeChange`→`onPovChange`.)

- [ ] Run: `npx vitest run src/components/globe/datumCache.test.ts` — FAIL (module not found); `npx tsc -b` — FAIL (unknown props).
- [ ] Commit (red): `test(globe-e): diffDatums identity contract + widened GlobeCanvas prop surface (red)`
- [ ] Implement `datumCache.ts` (≤15 lines). In `GlobeCanvas.tsx`: rename the prop and ref (`altRef` → `povRef`), change line 66 to `.onZoom((pov: { lat: number; lng: number; altitude: number }) => povRef.current(pov))` — globe.gl's callback already receives full `GeoCoords` (globe.gl.d.ts:125). Refactor the existing point-datum diff effect (lines 93-105) to use `diffDatums` (behavior-identical — this is the "generalize the discipline" refactor, done while tests are green). In `Globe.tsx`: `const [pov, setPov] = useState({ lat: 0, lng: 0, altitude: 2.5 })`, replace `altitude` reads with `pov.altitude` (`clusterVenues(venues, pov.altitude)`), pass `onPovChange={setPov}`. Update the three existing `onAltitudeChange={noop}` usages in `GlobeCanvas.test.tsx`.
- [ ] Run: `npx vitest run src/components/globe src/pages/Globe.test.tsx src/data` and `npx tsc -b` — all green (Task 5's props may stay red if you split the red test; note which).
- [ ] Commit (green): `feat(globe-e): onZoom -> full {lat,lng,altitude} pov (onPovChange); diffDatums helper; point layer refactored onto it`

---

## Task 5 — GlobeCanvas explosion layers (objects + custom lines + DOM labels)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` (append)

**Interfaces**

```ts
// New props (final surface, with Task 4's rename — Plan D's Lane-1 props carry through unchanged):
export function GlobeCanvas(props: {
  dots: GlobeDot[];
  mode: MapMode;
  focus: Focus | null;
  arcs: OrgArcDatum[];                          // Plan D (Lane 1) — unchanged by this plan
  labels: LabelDatum[];                         // Plan D (Lane 1) — unchanged by this plan
  highlightOrgId: string | null;                // Plan D (Lane 1) — unchanged by this plan
  explosion: ExplosionLayout | null;            // NEW — pure layout from explodeSelectors; null = no explosion
  liveSystems: Set<string>;                     // NEW — liveSystemIds(detail) — pure, page-computed
  onDotClick: (dot: GlobeDot) => void;
  onNodeClick: (node: ExplodedNode) => void;    // NEW
  onPovChange: (pov: { lat: number; lng: number; altitude: number }) => void;  // Task 4 rename of onAltitudeChange
  onBackgroundClick?: () => void;               // Plan D (Lane 1) — unchanged by this plan
}): JSX.Element;
```

Island wiring decisions (all inside the ref-mount effect / data effects — three NEVER at module top):

- **Import:** `Promise.all([import("globe.gl"), import("three")])` after the WebGL guard; keep the three module namespace in a local captured by the closures (`threeMod`).
- **Init chain additions** (once, at init):
  - `.objectLat((d) => d.node.lat).objectLng((d) => d.node.lng).objectAltitude((d) => d.node.altitude)` and `.objectThreeObject((d) => d.mesh)` — the mesh is created per-datum at datum-create time (`new threeMod.Mesh(new threeMod.SphereGeometry(node.type === "system" ? 0.55 : 0.35, 12, 12), new threeMod.MeshBasicMaterial())`; globe radius is 100 units, so these read as small beads). `objectsData`/`objectThreeObject` per three-globe.d.ts:346-359.
  - `.onObjectClick((d) => nodeClickRef.current(d.node))` (globe.gl.d.ts:105); latest-callback ref like `clickRef`.
  - `.customThreeObject((d) => d.line)` + `.customThreeObjectUpdate((obj, d) => { setLinePoints(obj, d); obj.material.color.set(d.color); })` (three-globe.d.ts:362-367). Line objects: `new threeMod.Line(new threeMod.BufferGeometry(), new threeMod.LineBasicMaterial())`; `setLinePoints` maps the datum's geo points through `globe.getCoords(lat, lng, altitude)` (three-globe.d.ts:371) via `geometry.setFromPoints(...)`. Connector datums carry 2 points; the hull datum carries its 9 — one code path.
  - `.htmlLat((d) => d.label.lat).htmlLng((d) => d.label.lng).htmlAltitude((d) => d.label.altitude)`, `.htmlElement((d) => d.el)`, `.htmlElementVisibilityModifier((el, visible) => { el.style.opacity = visible ? "1" : "0"; })`, `.htmlTransitionDuration(0)` (three-globe.d.ts:330-343). Label elements are created per-datum with `document.createElement("div")` + `textContent` (no innerHTML — venue/device names are operator-editable; textContent needs no escaping), `style.pointerEvents = "none"` so labels never eat node clicks, monospace 10px, `data-testid="globe-node-label"`.
- **Explosion data effect** (`[explosion, mode, liveSystems, ready]`), mirroring the v1 point effect:
  - `nodeDatumsRef = diffDatums(prev, explosion?.nodes ?? [], n => n.key, create, update)`; after diffing, restyle every cached mesh directly (`d.mesh.material.color.set(nodeColor(d.node, modeRef.current, liveSystems))`) — the objects layer has no update callback, so recolor by mutating the cached mesh. Then `globe.objectsData([...map.values()])` (fresh array, stable datums).
  - `lineDatumsRef` = connectors + hull as one keyed list (`c.key`, `hull.key`); each datum's `color` is recomputed via `connectorColor` (hull gets a fixed faint `#5b6472`); `globe.customLayerData([...])` — `customThreeObjectUpdate` then repositions/recolors existing lines in place.
  - `labelDatumsRef` = `explosion?.labels ?? []` keyed `l.key`; update mutates `d.el.textContent = glyph ? `${glyph} ${text}` : text` and the datum's lat/lng/alt; `globe.htmlElementsData([...])`.
  - `explosion === null` → all three setters get `[]` (layers empty, caches cleared).
- **Dispose:** no change needed beyond v1's `_destructor()` (it tears down layers); label divs are owned by globe.gl's DOM container inside `el`, cleared by `el.replaceChildren()` (GlobeCanvas.tsx:87).
- **Do not touch** `arcsData`/`labelsData` (Plan D's) or `ringsData` behavior.

**Steps**

- [ ] Append failing tests to `GlobeCanvas.test.tsx` (jsdom-only — the real rendering is Task 10's E2E):

```tsx
// Guardrail extension: three must never load in jsdom either (spec §4: three imports stay
// inside the ref-mount effect).
vi.mock("three", () => { throw new Error("three must not load in jsdom"); });

test("explosion props render on the fallback path without loading three", () => {
  const layout = explodeVenue(locationDetail, 2);           // pure — no WebGL involved
  render(<GlobeCanvas dots={[]} mode="live" focus={null} explosion={layout}
    arcs={[]} labels={[]} highlightOrgId={null}             // Plan D's required props
    liveSystems={liveSystemIds(locationDetail)}
    onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});

test("explosion updates across rerenders don't crash the fallback path", () => {
  const { rerender } = render(<GlobeCanvas dots={[]} mode="health" focus={null} explosion={null}
    arcs={[]} labels={[]} highlightOrgId={null}
    liveSystems={new Set()} onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  rerender(<GlobeCanvas dots={[]} mode="health" focus={null}
    arcs={[]} labels={[]} highlightOrgId={null}
    explosion={explodeVenue(locationDetail, 1)} liveSystems={new Set()}
    onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx` + `npx tsc -b` — FAIL (unknown props / missing wiring).
- [ ] Commit (red): `test(globe-e): GlobeCanvas explosion props; three joins globe.gl behind the jsdom guard (red)`
- [ ] Implement per the wiring decisions above. Keep every three/globe.gl reference inside the mount effect and the data effects (which no-op until `globeRef.current` exists — same guard as v1 line 96).
- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx`, `npx tsc -b` — PASS/clean. Quick headed smoke: `npm run dev`, open `/globe`, confirm the v1 globe still renders and no console errors with the explosion path idle (explosion stays `null` until Task 8 wires the page).
- [ ] Commit (green): `feat(globe-e): objects/customLayer/htmlElements explosion layers — identity-diffed nodes, connector+hull lines via getCoords, DOM labels`

---

## Task 6 — `useVenueDetailPoll` (exploded venue owns its detail poll)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/hooks/useVenueDetailPoll.ts`
- Test: `/Users/jn/code/godview-prototype/src/hooks/useVenueDetailPoll.test.ts`

**Interfaces**

```ts
// Spec §4 amendment: the explosion can be proximity-triggered with no panel open, and Lane 3
// needs consecutive payloads regardless of panel state — so this poll belongs to the PAGE,
// keyed on the exploded venue id, not to VenuePanel (whose own poll is untouched).
export function useVenueDetailPoll(locationId: string | null, intervalMs?: number): {
  detail: MapLocationDetail | null;    // null while no venue exploded, while switching, or on first load
};
```

Behavior: `useEffect` keyed `[locationId, intervalMs]` — on id change: reset `detail` to null (never show venue A's topology at venue B's anchor), fetch immediately, then `setInterval`; a `cancelled` flag drops stale in-flight responses on cleanup; errors keep last-good (matching `usePolling`'s philosophy, `/Users/jn/code/godview-prototype/src/hooks/usePolling.ts:12-20`) EXCEPT across an id change, where reset wins. `null` id → no fetching, `detail` null.

**Steps**

- [ ] Write the failing test (fake timers + mocked `fetchMapLocation`):

```ts
import { renderHook, act, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("../data/api", () => ({ fetchMapLocation: vi.fn() }));
import { fetchMapLocation } from "../data/api";
import { useVenueDetailPoll } from "./useVenueDetailPoll";
import { locationDetail } from "../data/globeFixtures";

describe("useVenueDetailPoll", () => {
  beforeEach(() => { vi.useFakeTimers(); vi.mocked(fetchMapLocation).mockResolvedValue(locationDetail); });
  afterEach(() => { vi.useRealTimers(); vi.clearAllMocks(); });

  it("null id: no fetch, null detail", () => {
    const { result } = renderHook(() => useVenueDetailPoll(null, 5000));
    expect(fetchMapLocation).not.toHaveBeenCalled();
    expect(result.current.detail).toBeNull();
  });
  it("fetches immediately on explode and repolls on the interval", async () => {
    const { result } = renderHook(() => useVenueDetailPoll("loc_dal_north", 5000));
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(fetchMapLocation).toHaveBeenCalledWith("loc_dal_north");
    expect(result.current.detail).toEqual(locationDetail);
    await act(() => vi.advanceTimersByTimeAsync(5000));
    expect(fetchMapLocation).toHaveBeenCalledTimes(2);
  });
  it("switching venue resets detail to null before the new payload lands", async () => {
    const { result, rerender } = renderHook(({ id }) => useVenueDetailPoll(id, 5000),
      { initialProps: { id: "loc_dal_north" as string | null } });
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(result.current.detail).not.toBeNull();
    vi.mocked(fetchMapLocation).mockReturnValue(new Promise(() => {}));   // never resolves
    rerender({ id: "loc_berlin" });
    expect(result.current.detail).toBeNull();
  });
  it("a stale in-flight response from the previous venue is dropped", async () => {
    let resolveA!: (v: typeof locationDetail) => void;
    vi.mocked(fetchMapLocation).mockReturnValueOnce(new Promise((r) => { resolveA = r; }));
    const { result, rerender } = renderHook(({ id }) => useVenueDetailPoll(id, 5000),
      { initialProps: { id: "loc_dal_north" as string | null } });
    rerender({ id: null });
    await act(async () => { resolveA(locationDetail); });
    expect(result.current.detail).toBeNull();
  });
});
```

- [ ] Run: `npx vitest run src/hooks/useVenueDetailPoll.test.ts` — FAIL (module not found).
- [ ] Commit (red): `test(globe-e): exploded-venue detail poll — immediate fetch, interval, reset + stale-drop on switch (red)`
- [ ] Implement (≈30 lines). Run the test — PASS; `npx tsc -b` clean.
- [ ] Commit (green): `feat(globe-e): useVenueDetailPoll — page-owned /god-view/map/locations/{id} poll keyed on the exploded venue`

---

## Task 7 — NodePanel (system / camera / display right panel)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/NodePanel.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/NodePanel.test.tsx`

**Interfaces**

```ts
// Mounted keyed `${type}:${id}` by the page (fleet keying lesson — Fleet.tsx:58). Venue nodes
// do NOT come here — the page keeps mounting v1's VenuePanel for those.
export function NodePanel(props: {
  type: "system" | "camera" | "display";
  id: string;
  detail: MapLocationDetail | null;    // the page-owned exploded-venue payload (Task 6)
  onClose: () => void;
}): JSX.Element;
```

Content per spec §4 (data = panel payload + `fetchObjectDetail`; no new backend):
- **system** (from `detail.systems` row): name, `StatusDot` (kind `lifecycle`), `zone`, `system_type`, `status`, then the device list reusing the same compact row treatment as VenuePanel's `DeviceRow` (NodePanel keeps its own private copy — `DeviceRow` is module-private in VenuePanel.tsx:99; do NOT export it, surgical rule).
- **camera** (device row found across `detail.systems[].cameras`): name, `status` + StatusDot (kind `device`), `last_seen_at` via `timeAgo`, **`screen_id`** (from the map payload — Task 2 field), and **current duty** = `state.effective_duty` from a keyed-mount `usePolling(() => fetchObjectDetail("camera", id), 5000)` (server COALESCEs to `'unknown'` — render verbatim; `"—"` only while loading).
- **display**: name, `status` + StatusDot, `last_seen_at`, `screen_id`, and **screen group** = `config.screen_group_id` from `usePolling(() => fetchObjectDetail("display", id), 5000)` (rendered as the monospace id, `"—"` when null — group NAME would need an extra scoped fetch; out of scope, no new backend and no speculative fetches).
- If `detail` is null or the node id is absent from it (venue de-exploded mid-view, device deleted): render a quiet `data-testid="node-gone"` note ("Node not in the current venue payload") + the close button — never crash.
- Frame: reuse VenuePanel's visual frame markup (scroll container, close button `data-testid="panel-close"`, `bg-sidebar/95 border-l border-border p-3` — VenuePanel.tsx:64-72); private copy, same reasoning as DeviceRow.

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/components/globe/NodePanel.test.tsx` — mock `../../data/api`'s `fetchObjectDetail`; use `locationDetail`:

```tsx
vi.mock("../../data/api", () => ({ fetchObjectDetail: vi.fn() }));
```

Cases:
  - system panel: renders "Entrance Wall A", "entrance", "advertising_wall", status dot; lists its 2 cameras + 2 displays; `fetchObjectDetail` NOT called (system content is fully in the payload).
  - camera panel (`type="camera" id="cam_b"` with `fetchObjectDetail` resolving `{ object_type: "camera", identity: {}, config: {}, state: { effective_duty: "recognize", last_seen_at: "2026-07-12T11:40:00Z" } }`): shows "Entrance Cam B", degraded status, `screen_id` "demo-cam-b", and `await waitFor` → duty "recognize"; `expect(fetchObjectDetail).toHaveBeenCalledWith("camera", "cam_b")`.
  - display panel (`id="disp_a"`, mock config `{ screen_group_id: "sg-uuid-1" }`): shows "Panel 1", screen_id "demo-disp-a", and screen group "sg-uuid-1".
  - `detail={null}` → `node-gone` note renders, close button works, no crash; unknown id likewise.
- [ ] Run: `npx vitest run src/components/globe/NodePanel.test.tsx` — FAIL (module not found).
- [ ] Commit (red): `test(globe-e): per-node panel — system detail, camera duty via fetchObjectDetail, display screen group, gone-node fallback (red)`
- [ ] Implement `NodePanel.tsx`. Camera/display extra fetch uses `usePolling` — safe because the page mounts NodePanel keyed `${type}:${id}` (closure-per-mount, fleet lesson).
- [ ] Run: `npx vitest run src/components/globe/NodePanel.test.tsx` — PASS; `npx tsc -b` clean.
- [ ] Commit (green): `feat(globe-e): NodePanel — system/camera/display right panel (payload + fleet detail fetchers, keyed mounts)`

---

## Task 8 — Globe page integration (explode state, panel-by-type, close-on-unexplode)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`
- Test: `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx` (append)

**Interfaces** (page-internal state, documented for the reviewer):

```ts
type PanelSel = { type: "venue" | "system" | "camera" | "display"; id: string; venueId: string };
// pov: { lat, lng, altitude } — from onPovChange (Task 4)
// selectedVenueId = panel?.venueId ?? null           (any open panel pins its venue as "selected")
// explodedId = explodedVenueId(venues, pov, selectedVenueId)     — memoized
// { detail } = useVenueDetailPoll(explodedId)
// [ERRATUM 2026-07-12: guard must check lat AND lng (final-review I1); lat-only feeds NaN geometry. Shipped code checks both.]
// explosion = useMemo: explodedId && detail?.location.id === explodedId && detail.location.lat != null && detail.location.lng != null
//   ? explodeVenue(detail, explosionTier(pov.altitude) === 2 ? 2 : 1) : null
// liveSystems = useMemo(() => detail ? liveSystemIds(detail) : new Set(), [detail])
```

Wiring decisions:
- `selectVenue` sets `panel = { type: "venue", id, venueId: id }` (v1 behavior preserved; the fly-to lands at 0.72 < EXPLODE_ALTITUDE → the selected venue explodes).
- `onNodeClick(node)` sets `panel = { type: node.type, id: node.id, venueId: node.venueId }`.
- **Close-on-unexplode:** an effect closes a non-venue panel whose `venueId !== explodedId` (its data source is gone; a stale camera panel over a different venue would lie). Venue panels stay open regardless (v1 semantics).
- Panel mount: `panel.type === "venue"` → `<VenuePanel key={`venue:${panel.id}`} locationId={panel.id} …/>` (unchanged); else `<NodePanel key={`${panel.type}:${panel.id}`} type id detail={detail} …/>` — same wrapper div/testids as today (Globe.tsx:56-65).
- The exploded venue's dot stays in `dots` (it is the anchor the ring surrounds).

**Steps**

- [ ] Append failing tests to `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx`, following its existing `vi.mock("../data/api", …)` setup (extend the mock module with `fetchMapLocation` — already mocked for VenuePanel tests — and add `fetchObjectDetail`). jsdom renders the GlobeCanvas fallback, so drive the explosion via the page's props/state seams:
  - "selecting a venue below EXPLODE_ALTITUDE starts the venue detail poll even with the panel closed": select a venue (rail click), close the panel — assert `fetchMapLocation` keeps getting called (fake timers advance) — the detail-poll-ownership amendment, testable because the poll now lives in the page. NOTE: with the panel closed there is no selected venue (`panel === null`) — assert via the nearest-camera path instead if simpler: mock `onPovChange` is internal, so instead render, then simulate deep pov by clicking a venue (fly-to sets focus but pov comes from onZoom which never fires in jsdom fallback). **Decision:** jsdom can't move the camera; test the seam directly — assert `explodedVenueId`+`useVenueDetailPoll` composition by exporting nothing new; instead the page test asserts: clicking a rail venue opens the VENUE panel (existing behavior), and NodePanel rendering is covered by mounting the page with a preset panel through a node-click simulation is impossible in fallback. Therefore the page tests assert the two things jsdom CAN see: (a) close-on-unexplode effect — not reachable either without pov. **Scope the page unit tests to what is real in jsdom:** (a) v1 flows still pass untouched (regression), (b) the page compiles with the new wiring (tsc), (c) a direct unit test of the tiny pure helper the page uses for close-on-unexplode if extracted (`shouldClosePanel(panel, explodedId): boolean` — put it in explodeSelectors.ts, 3 lines, test it there). Everything pov-driven is Task 10's live E2E — this is exactly why the layout/one-venue rules were pushed into pure selectors in Task 3.
- [ ] So: add `shouldClosePanel` red test to `explodeSelectors.test.ts` (non-venue panel + mismatched/null explodedId → true; venue panel → false; matching → false), plus a Globe.test.tsx regression run.
- [ ] Run: `npx vitest run src/data/explodeSelectors.test.ts src/pages/Globe.test.tsx` — expect FAIL on `shouldClosePanel`.
- [ ] Commit (red): `test(globe-e): shouldClosePanel rule — non-venue panels close when their venue de-explodes (red)`
- [ ] Implement: `shouldClosePanel` in explodeSelectors.ts; rewire `Globe.tsx` per the decisions above (panelId → PanelSel, pov, explodedId, useVenueDetailPoll, explosion memo, liveSystems, onNodeClick, close effect, NodePanel mount).
- [ ] Run: `npx vitest run src/pages/Globe.test.tsx src/data/explodeSelectors.test.ts src/components/globe` and `npx tsc -b` — all PASS (all four pre-existing Globe page tests must stay green).
- [ ] Commit (green): `feat(globe-e): page owns explode state + detail poll; per-node panel keyed type:id; close-on-unexplode`

---

## Task 9 — Full suite, typecheck, build, lint; PR + review

**Files** — none new; fixes only if something below fails (each fix scoped + committed with reason).

**Steps**

- [ ] `npx vitest run` — full suite green (all pre-existing tests too).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds; confirm three/globe.gl still land in the lazy chunk (dynamic import preserved), entry chunk did not grow by ~1 MB: `ls -lS dist/assets | head`.
- [ ] Headed smoke: `npm run dev`, open `http://localhost:5173/globe` against whatever backend is up — page must not crash with explosion features present but backend absent (AsyncState error path).
- [ ] Commit: `chore(globe-e): full suite + tsc + build + lint green`
- [ ] Ask git-flow-manager to push the branch and open a PR titled `feat(globe): anchored explosion — venue ring, device fan, connectors, hull, node panels (Plan E)` against `main` with the structured description (Summary / Motivation / Implementation / Tests / Risks). Request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings before Task 10.

---

## Task 10 — Live Playwright E2E vs the seeded v2 stack + label-density tuning

**DEPENDENCY:** Lane 1 merged (Plans C + D: seed v2 applied to the dev DB, org arcs live) and the dev stack up (ops-api `:8080`, projector running). Optionally `scripts/demo_traffic.py` running gently so live-mode styling has signal.

**Files** — none (live drill; findings become scoped fix commits on this branch or follow-up issues).

**Steps**

- [ ] Preconditions: seed v2 applied; `npm run dev` in the worktree (`http://localhost:5173`, `VITE_OPS_API_URL` unset → `http://localhost:8080`). Headless-WebGL note as in Plan B Task 10 (`--enable-unsafe-swiftshader --use-angle=swiftshader --ignore-gpu-blocklist`); if headless GL is flaky, run DOM assertions headless and the visual pass headed.
- [ ] Navigate to `/globe`; confirm v1 baseline (dots, rail, org arcs from Plan D).
- [ ] **Explosion tier 1:** click a seeded venue in the rail (fly-to lands at 0.72 < EXPLODE_ALTITUDE) → assert the systems ring appears: node meshes present (scene objects — assert via `[data-testid="globe-node-label"]` count ≥ the venue's system count and label texts match its system names).
- [ ] **Exactly one venue:** zoom/pan near a DIFFERENT venue with no selection (close the panel first) → labels/nodes swap to that venue's systems; at no point do two venues' labels coexist.
- [ ] **Tier 2:** zoom below DEVICE_ALTITUDE → device labels appear with status glyphs (●/◐/○) fanned outside the ring; count matches the venue's cameras + displays.
- [ ] **Hull + org arcs:** octagon hull line visible around the group; the venue's org arcs (Plan D) remain visible entering/leaving the hull — screenshot.
- [ ] **Node click → panel:** click a camera node → right panel shows camera name, status, last_seen, **screen_id**, and **current duty** (`effective_duty`); network tab shows `GET /cameras/{id}`. Click a display node → status/last_seen/**screen group**. Click a system node → zone/status/system_type + device list. Click the venue dot → v1 VenuePanel. Each swap is a fresh keyed mount (no stale content flash of the previous node).
- [ ] **Detail-poll ownership:** with NO panel open and a venue exploded, assert `GET /god-view/map/locations/{id}` keeps firing every ~5 s (network log).
- [ ] **No re-init:** capture the canvas element reference, wait 2 poll ticks, assert same element; also assert label DIVs for unchanged nodes are the SAME DOM nodes across a poll (identity-diff proof: `browser_evaluate` tag an element property, re-check after 6 s).
- [ ] **Label-density tuning pass (budgeted — spec §8 risk):** judge readability on a real venue at both tiers; tune `SYSTEM_RING_DEG`/`DEVICE_RING_DEG`/`HULL_RING_DEG`, `EXPLODE_ALTITUDE`/`DEVICE_ALTITUDE`, label font size, and (if needed) suppress device labels at tier-2-entry altitude. Each tune = scoped commit with a before/after screenshot; update the Task 3 constants' tests if thresholds move (green suite after).
- [ ] Screenshots for the session log: tier 1 ring, tier 2 fan + hull + org arcs, camera panel with duty.
- [ ] Fix anything found (red→green where code changes), then ask git-flow-manager to merge the PR (merge commit) after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with `repo@sha`, E2E evidence, tuned constants, gotchas) and file any remaining follow-ups as GitHub issues (e.g. screen-group NAME resolution in the display panel; explosion at cluster level is spec §7 out-of-scope — do not file it).

---

## Self-review notes (spec §4 coverage check, done at plan time)

- `EXPLODE_ALTITUDE` below v1's `CLUSTER_ALTITUDE` (0.8 < 1.2), above the v1 fly-to landing so selection explodes — Task 3, tested. ✓
- Exactly ONE venue exploded: selected, else nearest camera center — `explodedVenueId` (Task 3) fed by the widened `onPovChange` (Task 4). ✓
- Two tiers: radial system ring, then per-system device fan in outer arc segments — `explodeVenue` (Task 3). ✓
- Layout pure + deterministic (sorted ids + counts), lng offsets ÷ cos(lat) with an explicit 51.5°N test, radii sized as fixed geo-degrees for the band (tuned live, Task 10) — Task 3, zero WebGL. ✓
- Connectors venue→system, system→device as custom three.js lines (`customLayerData` + `customThreeObject`/`customThreeObjectUpdate`, positions via `getCoords`), styled by active mode (health tone / live state from `ad_runs`) — Tasks 3/5; relationships ONLY from `/god-view/map/locations/{id}`. ✓
- Octagon hull as a three.js line loop; org arcs (Plan D's `arcsData`) untouched and asserted visible through the hull in E2E — Tasks 3/5/10. ✓
- DOM labels via `htmlElementsData`: venue name on hull, system names on ring, device names + status glyph; density tuning budgeted in Task 10. ✓
- Detail-poll ownership: page-owned `useVenueDetailPoll` keyed on the exploded venue, independent of panels; VenuePanel untouched (accepted duplicate poll) — Task 6. ✓
- Per-node right panel keyed `${type}:${id}` (Fleet.tsx:58 pattern): venue → v1 panel; system → zone/status/system_type + devices; camera → status/last_seen/screen_id/duty (`fetchObjectDetail` → `state.effective_duty`); display → status/last_seen/screen group (`config.screen_group_id`). No new backend — Tasks 7/8. ✓
- Identity-diff ALL new layer datums via shared `diffDatums` (v1 point layer refactored onto it); three + globe.gl both dynamically imported inside the ref-mount effect; throwing jsdom mocks for BOTH — Tasks 4/5. ✓
- GlobeCanvas stays the only imperative island; all geometry/labels/colors from pure selectors — Tasks 3/5. ✓
- Out of scope honored (spec §7): one exploded venue only, no cluster-level explosion, no SSE, no editing from the globe, no Lane 3 animation (rings-identity fix explicitly deferred to Plan F).
