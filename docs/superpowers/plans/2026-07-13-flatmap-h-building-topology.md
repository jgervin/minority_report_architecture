# Flat Map v3 — Plan H: building-level 2D topology + detail cards + pulses (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the building tier of the Flat Map v3 "Command Map" spec
(`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md` §5 "Plan H scope").
When `mapTier(zoom) === 'building'` for the selected venue, render that venue's topology inside Plan G's
`<FlatMapCanvas>` as **2D Mapbox graphics** — systems as group/card glyphs, cameras and displays as glyph
markers with a status ring + name label, connectors as thin styled lines (NOT the globe's 3D tubes) — laid out
by Plan G's deterministic-fallback `buildingLayout` (there are NO real per-device coordinates; building layout is
fallback-ONLY, per outside-review Amendment 1 — BLOCKING). Detail is **panels-first** (reuse `VenuePanel` +
`NodePanel`; anchored floating cards are an explicit follow-on, NOT a Plan H gate — Amendment 6). Pulses reuse the
**pure delta engines verbatim** and drive a **NEW Mapbox pulse renderer** — a venue-marker pulse at far zoom and a
camera→system→display animated line pulse at building zoom, candy-cane pacing as an aesthetic goal (Amendment 5).

**Architecture:** Every decision that is testable in jsdom is a **pure function** in new selector modules
(`/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts`,
`/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.ts`) — they build plain GeoJSON-shaped objects and
carry no Mapbox/WebGL import. Plan G's `<FlatMapCanvas>` remains the **only Mapbox imperative island**: Plan H
adds building sources/layers and pulse-layer wiring to it (behind Plan G's `hasWebGL() && VITE_MAPBOX_TOKEN`
guard), and the actual animated Mapbox render code lives in a dynamically-imported
`/Users/jn/code/godview-prototype/src/components/flatmap/mapPulseLayer.ts` that jsdom can never reach (the
`pulseLayer.ts` discipline, ported to Mapbox). The existing `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
(Plan G's page) is extended to run `useVenueDetailPoll` for the building venue, feed `buildingLayout` output through
the pure engines, and mount `VenuePanel`/`NodePanel`. **Frontend-only (godview-prototype). No backend changes.**

**Tech Stack:** React 19 + Vite + Tailwind 3 + react-router-dom v7 + vitest 4 / Testing Library (jsdom);
`mapbox-gl` (added by Plan G, proprietary Mapbox TOS — do NOT strip the attribution/logo control);
`globe.gl@2.46.1` + `three@0.185.1` (corner globe, unchanged by this plan). **No new runtime dependencies added by
Plan H** — the pure feature modules use local structural GeoJSON types (plain objects Mapbox `setData` accepts at
runtime), so they need neither `@types/geojson` nor `mapbox-gl` imports and stay jsdom-testable.

## Global Constraints

- **Sequencing (LOCKED): Plan H branches from `main` AFTER Plan G is merged.** Plan H consumes Plan G's
  `mapSelectors.mapTier`, `mapLayout.buildingLayout`, `<FlatMapCanvas>` (incl. the `paused` prop on `GlobeCanvas`
  and the `hasWebGL() && VITE_MAPBOX_TOKEN` fallback seam), and the `/map` route + `FlatMap.tsx` page shell — all
  authored by Plan G (spec §5 "Plan G scope … it OWNS the shared contracts Plan H consumes"). Task 1 is a contract
  preflight against the "Contract (consumes — produced by Plan G)" section below; on any mismatch, reconcile the
  contract first (scoped commit / name-substitution across this plan) or STOP and report — do NOT improvise against a
  divergent Plan G surface.
- **Building layout is deterministic-fallback ONLY (Amendment 1 — BLOCKING).** The `/god-view/map/locations/{id}`
  endpoint returns NO per-device coordinates: `MapSystemDevice` has no `lat`/`lng`
  (`/Users/jn/code/godview-prototype/src/data/apiTypes.ts:143`), `map.py` selects none, and the
  `cameras`/`displays` tables carry no lat/lng columns. There is **no real-coords branch to build**. Glyphs are
  ALWAYS positioned by `buildingLayout(anchor, systems)` around the venue anchor. Real per-device positioning is a
  future additive backend lane — explicitly OUT OF SCOPE for v3. Do NOT read `device.lat`/`device.lng` anywhere.
- **Reuse the pure delta ENGINES verbatim; write NEW Mapbox render (Amendment 5).** Reused unchanged (do NOT modify):
  `diffFarPulses`, `diffDeepPulses`, `attributionCamera`, `deepPulsePath`
  (`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts:21,60,48,93`), `usePollDelta`
  (`/Users/jn/code/godview-prototype/src/hooks/usePollDelta.ts`), `useVenueDetailPoll`
  (`/Users/jn/code/godview-prototype/src/hooks/useVenueDetailPoll.ts`), `liveSystemIds`
  (`/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts:182`). NOT reused (globe.gl/three-render-specific —
  Plan H writes Mapbox equivalents): `pulseRingDatum`, `sweepArcDatum`
  (`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts:127,144` — globe.gl ring/arc-dash units) and the whole of
  `/Users/jn/code/godview-prototype/src/components/globe/pulseLayer.ts` (three `Line2`/`LineMaterial`, consumes
  `globe.getCoords` output `{x,y,z}` — 100% globe-coupled; verified read).
- **Panels FIRST; anchored cards are a follow-on, NOT a gate (Amendment 6).** Reuse `VenuePanel`
  (`/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.tsx:12` — self-polls
  `fetchMapLocation(locationId)`, drop-in `{ locationId, onClose }`) and `NodePanel`
  (`/Users/jn/code/godview-prototype/src/components/globe/NodePanel.tsx:14` — `{ type, id, detail, onClose }`, fed by
  the page's `useVenueDetailPoll` `detail`). Both are right-slide-in framed. Anchored-to-marker floating cards
  (positioning against a moving Mapbox marker + collision/z-order) are net-new surface and are **explicitly out of
  Plan H scope**; do not build them.
- **Mapbox pulse-renderer testability (Amendment 11 + memory `feedback-subagent-workspace-discipline`).** The
  animated renderer is Mapbox-coupled: it lives in `mapPulseLayer.ts`, reached ONLY via dynamic
  `import("./mapPulseLayer")` inside `FlatMapCanvas` AFTER Plan G's guard — same rule as Plan G's `import("mapbox-gl")`.
  The `FlatMapCanvas` jsdom test adds a throwing `vi.mock("./mapPulseLayer", …)` (the `pulseLayer.ts` tripwire
  pattern). **Delta computation stays in the PURE reused engines (already tested); only the Mapbox render layer is
  imperative.** The pure GeoJSON/lifecycle helpers (`mapPulseGeometry.ts`) carry Plan H's pulse unit tests.
- **Discriminates-proof for every invariant/lifecycle test (memory: v2 caught a VACUOUS StrictMode test).** Any test
  asserting an animation/lifecycle invariant (candy-cane stepper cycles, pulse dies after its window, the tripwire
  never fires on the fallback path) MUST be accompanied in the same step by a one-line note stating the concrete
  mutation that makes it fail (e.g. "remove the `elapsedMs < DURATION` guard → the `pulseAlive` test goes red").
  A test with no such mutation is vacuous — do not ship it.
- **Mapbox-gl gotchas Plan H must honor (Amendment 11), all already handled by Plan G's island — Plan H must not
  regress them:** `mapboxgl.accessToken` set before `new Map`; `import "mapbox-gl/dist/mapbox-gl.css"` lives INSIDE
  the dynamically-imported island; the token check is a synchronous `import.meta.env.VITE_MAPBOX_TOKEN` read gating
  the dynamic import; rely on `hasWebGL()` + try/catch, never the deprecated `mapboxgl.supported()`. Plan H adds
  layers to the already-constructed map instance — it introduces no second `new Map` and imports `mapbox-gl` nowhere
  outside the island.
- **Do NOT strip the Mapbox attribution/logo control (Amendment 12 — TOS).** Plan H touches no attribution control.
- **Subagent workspace discipline (4 drift incidents in v2 — memory `feedback-subagent-workspace-discipline`):**
  (1) Step 1 of EVERY implementer dispatch is `cd <worktree path> && pwd` to lock the workspace and echo it back;
  (2) the bare repo path `/Users/jn/code/godview-prototype` is a READ-ONLY reference — all edits happen in the
  worktree checkout; (3) the controller runs an existence-check (`ls` the files the task creates/modifies in the
  worktree) BEFORE dispatching each commit. Never commit from the bare path.
- **All git via the git-flow-manager subagent**
  (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers NEVER run raw
  `git`/`gh`. Work on branch `feat/flatmap-h-building-topology` in a DEDICATED worktree of
  `/Users/jn/code/godview-prototype`. **Commit each failing test separately from the implementation that greens it**
  (red→green pairs must show in history; watch the test fail first). Merge commits (not squash) on PR merge.
- **Verify commands** (confirmed against `/Users/jn/code/godview-prototype/package.json`): `npx vitest run [files]`
  (script `test` = `vitest run`), `npx tsc -b` (build runs `tsc -b && vite build`), `npm run lint` (oxlint),
  `npm run build`.
- Reference every file by ABSOLUTE path.

---

## Contract (consumes — produced by Plan G)

**LOCKED — verbatim. A gate-check diffs Plan G and Plan H against this block; the names/signatures must match Plan G
exactly.**

A. **`GlobeCanvas` `paused` prop** — exists after Plan G (`paused?: boolean` → `pauseAnimation`/`resumeAnimation`).
Plan H does not touch it.

B. **Pure tier selector** — `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`:
```ts
export type MapTier = 'world' | 'city' | 'building';
export function mapTier(zoom: number): MapTier;
```
Plan H renders the building layer iff `mapTier(zoom) === 'building'` for the selected venue.

C. **Deterministic fallback building-layout** — `/Users/jn/code/godview-prototype/src/data/mapLayout.ts` (Plan G
authors):
```ts
export interface MapNode {
  key: string;               // `${type}:${id}`
  type: 'system' | 'camera' | 'display';
  id: string; name: string | null; status: string;
  systemId: string | null;   // parent system for camera/display; null for systems
  lat: number; lng: number; altitude: 0;
}
export function buildingLayout(anchor: { lat: number; lng: number }, systems: MapSystem[]): MapNode[];
```
Plan H renders `MapNode[]` as glyphs AND feeds them directly to `deepPulsePath` (MapNode satisfies its
`Pick<ExplodedNode,'key'|'type'|'id'|'lat'|'lng'|'altitude'>` input — verified against
`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts:93-95`: MapNode has `key`=`${type}:${id}`, `type`, `id`,
`lat`, `lng`, `altitude:0`, exactly the six picked fields).

D. **Token/WebGL fallback seam** — Plan G's `<FlatMapCanvas>` only mounts when
`hasWebGL() && import.meta.env.VITE_MAPBOX_TOKEN`. Plan H's layers mount INSIDE it; do NOT re-implement the guard.

E. **Reused-verbatim pure engines** (do NOT modify): `diffFarPulses`, `diffDeepPulses`, `attributionCamera`,
`deepPulsePath`, `usePollDelta`. NOT reused (globe-only — write NEW Mapbox equivalents): `pulseRingDatum`,
`sweepArcDatum`, `pulseLayer.ts`.

**Additional Plan-G surface Plan H reads (Task 1 confirms exact names; substitute mechanically if they differ):**
- `<FlatMapCanvas>` is the single Mapbox imperative island holding the constructed `mapboxgl.Map` instance, mounted
  behind seam D, with a jsdom fallback branch rendering `data-testid="map-unavailable"`. Plan H adds sources/layers
  and pulse wiring INSIDE it (props + effects), exactly as Plan F added `farPulses`/`deepPulses` to `GlobeCanvas`.
- `FlatMap.tsx` (Plan G's page at the `/map` route) owns the Mapbox camera **zoom** state (surfaced from the island,
  e.g. via an `onMove`/`onZoom` callback — Plan G's analog of `GlobeCanvas.onPovChange`,
  `/Users/jn/code/godview-prototype/src/pages/Globe.tsx:128`) and a **selected-venue** id (rail/marker click). Plan H
  reads both to gate the building tier. The page also owns the independent mini-globe `pov` state (Amendment 10).
- These types/functions are ALREADY in the repo and reused as-is: `MapSystem`, `MapSystemDevice`, `MapLocationDetail`
  (`/Users/jn/code/godview-prototype/src/data/apiTypes.ts:143-154`); `TONE_HEX`, `type MapMode`
  (`/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`); `liveSystemIds`, `statusGlyph`
  (`/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts:182,221`); `type GeoPoint`, `type FarPulse`
  (`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts:88,15`).

---

## File structure (created / modified by Plan H)

**Created:**
- `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts` — pure: `MapNode[]` → connector lines + glyph
  markers + labels as GeoJSON-shaped FeatureCollections; glyph color/icon per node+mode. jsdom-tested.
- `/Users/jn/code/godview-prototype/src/data/buildingFeatures.test.ts`
- `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.ts` — pure: pulse GeoJSON feature builders (venue point,
  camera→system→display line) + candy-cane dash stepper + pulse lifecycle helpers. jsdom-tested.
- `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.test.ts`
- `/Users/jn/code/godview-prototype/src/components/flatmap/mapPulseLayer.ts` — imperative Mapbox pulse renderer;
  dynamic-import-only (jsdom never reaches it). No unit test (WebGL/Mapbox) — covered by the E2E + the tripwire.

**Modified (Plan G's files):**
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx` — add building sources/layers + pulse
  props/effects; add the dynamic `import("./mapPulseLayer")` behind Plan G's guard.
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx` — new props threaded through fallback
  renders + the `mapPulseLayer` throwing-mock tripwire.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` — building-tier gate, `useVenueDetailPoll`,
  `buildingLayout`→`buildingFeatures`, pulse batches via `usePollDelta`+`deepPulsePath`, `VenuePanel`/`NodePanel`.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx` — building-tier + panel wiring assertions.

(Island directory CONFIRMED `src/components/flatmap/` by the G/H gate-check — Plan G authors
`src/components/flatmap/FlatMapCanvas.tsx` + `mapboxImpl.ts`, so this plan's `mapPulseLayer.ts` and every
modified island/page file live under `src/components/flatmap/` for the `import("./mapPulseLayer")`
co-location to resolve. Task 1 still re-verifies the exact Plan-G file names + prop set on the merged
branch before any edit.)

---

## Task 1 — Worktree + Plan G contract preflight

**Files** — none modified (read-only verification; no TDD pair).

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/flatmap-h-building-topology` from `main` for
  `/Users/jn/code/godview-prototype` (**Plan G must already be merged to `main`; if not, STOP and report**). Record
  the worktree checkout path; **Step 1 of every later dispatch is `cd <that path> && pwd`.** The bare
  `/Users/jn/code/godview-prototype` is a READ-ONLY reference only.
- [ ] Confirm Contract B: `grep -n "export function mapTier\|export type MapTier" src/data/mapSelectors.ts` — record
  the exact signature and the world/city/building zoom thresholds `mapTier` uses (Plan H's building gate and the E2E
  target zoom depend on them).
- [ ] Confirm Contract C: `grep -n "export interface MapNode\|export function buildingLayout" src/data/mapLayout.ts`
  — verify `MapNode` has exactly `{ key, type, id, name, status, systemId, lat, lng, altitude }` and
  `buildingLayout(anchor, systems)` returns `MapNode[]`. **Verify MapNode satisfies
  `Pick<ExplodedNode,'key'|'type'|'id'|'lat'|'lng'|'altitude'>`** (key convention `${type}:${id}`, `altitude` is `0`).
  If `altitude` is typed as `number` rather than the literal `0`, that still satisfies the Pick — record it.
- [ ] Confirm Contract A + D + island structure: locate `FlatMapCanvas` (expected
  `src/components/flatmap/FlatMapCanvas.tsx`). Confirm (a) it mounts behind `hasWebGL() && import.meta.env.VITE_MAPBOX_TOKEN`
  and renders `data-testid="map-unavailable"` on the fallback path; (b) it is the single island holding the
  `mapboxgl.Map` instance with the CSS import + dynamic `import("mapbox-gl")` INSIDE it; (c) how it surfaces the
  Mapbox **zoom** to the page (callback name — the `onPovChange` analog) and how the page holds selected-venue.
  Confirm `GlobeCanvas` has a `paused?: boolean` prop. **Record actual prop/callback names.**
- [ ] Confirm the reused surface is byte-unchanged on `main`: `grep -n "diffFarPulses\|diffDeepPulses\|attributionCamera\|deepPulsePath" src/data/pulseDelta.ts`;
  `grep -n "export function usePollDelta" src/hooks/usePollDelta.ts`;
  `grep -n "export function useVenueDetailPoll" src/hooks/useVenueDetailPoll.ts`;
  `grep -n "export function liveSystemIds\|export function statusGlyph" src/data/explodeSelectors.ts`;
  `grep -n "export function VenuePanel" src/components/globe/VenuePanel.tsx` and `NodePanel` in
  `.../NodePanel.tsx`. Record the exact `VenuePanel`/`NodePanel` prop shapes.
- [ ] **If any assumed name/shape differs from this Contract section:** update THIS plan's remaining tasks
  mechanically (name/path substitution only) and note the deltas in the PR description. If a shape differs
  STRUCTURALLY (e.g. `FlatMapCanvas` is not a single island with a reachable map instance, or the page does not own
  zoom/selected-venue), STOP and report — that is a Plan G gap, not a Plan H improvisation.
- [ ] Sanity: `npx vitest run` and `npx tsc -b` green on the fresh branch before any change.

---

## Task 2 — Pure building-topology features (`buildingFeatures.ts`)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/buildingFeatures.test.ts`

**Interfaces**
- Consumes: `MapNode` from `/Users/jn/code/godview-prototype/src/data/mapLayout.ts` (Plan G, Contract C);
  `TONE_HEX`, `type MapMode` from `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`; `statusGlyph` from
  `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts:221`.
- Produces (later tasks rely on these EXACT names):
```ts
// buildingFeatures.ts — pure. No mapbox, no react, no three. Local structural GeoJSON types (plain
// objects that mapbox-gl `source.setData` accepts at runtime) keep this jsdom-testable and dependency-free.
export interface LngLat { 0: number; 1: number; }                 // [lng, lat] — GeoJSON order
export interface PointFeature { type: "Feature"; geometry: { type: "Point"; coordinates: [number, number] };
  properties: { key: string; kind: MapNode["type"]; icon: string; color: string; label: string; glyph: string }; }
export interface LineFeature { type: "Feature"; geometry: { type: "LineString"; coordinates: [number, number][] };
  properties: { key: string; systemId: string; color: string }; }
export interface FeatureCollection<F> { type: "FeatureCollection"; features: F[]; }

export interface BuildingFeatures {
  connectors: FeatureCollection<LineFeature>;   // one line per camera/display, from its parent system node
  glyphs: FeatureCollection<PointFeature>;       // one marker per node (system/camera/display)
}
export function glyphIcon(type: MapNode["type"]): string;         // "system"→"▣", "camera"→"◉", "display"→"▤"
export function glyphColor(node: MapNode, mode: MapMode, live: Set<string>): string;
export function buildingFeatures(nodes: MapNode[], mode: MapMode, live: Set<string>): BuildingFeatures;
```

Rules (each encoded as a test):
- **`glyphIcon`:** `system → "▣"`, `camera → "◉"`, `display → "▤"` (distinct 2D glyphs per type — reference-3
  iconography intent; exact glyphs are visual-tune candidates flagged for the E2E task, the TESTED contract is
  "one distinct non-empty glyph per type").
- **`glyphColor`:** same discipline as `explodeSelectors.nodeColor`
  (`/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts:198-202`): `mode === "health"` → `TONE_HEX.ok`
  for `active`, `TONE_HEX.warn` for `degraded`, `TONE_HEX.off` otherwise; `mode === "live"` →
  `TONE_HEX.ok` when the node's system (`node.systemId ?? node.id`) is in `live`, else the dim `#3a4150`
  (the same `DIM` constant explodeSelectors uses — define a module-local `const DIM = "#3a4150"`; do not export
  globeSelectors' private one).
- **`buildingFeatures.connectors`:** for each node with `type !== "system"`, emit ONE `LineFeature` from its parent
  system node (matched by `node.systemId`) to itself; `properties.key = `conn:${node.key}``,
  `properties.systemId = node.systemId`, `properties.color = glyphColor(node, mode, live)`. Coordinates are
  `[lng, lat]` (GeoJSON order — NOT `[lat, lng]`). A device whose parent system node is absent from `nodes` is
  skipped (no dangling line). Systems emit no connector.
- **`buildingFeatures.glyphs`:** one `PointFeature` per node; `properties.label = node.name ?? node.id`;
  `properties.glyph = statusGlyph(node.status)`; `properties.icon = glyphIcon(node.type)`;
  `properties.color = glyphColor(node, mode, live)`; coordinates `[node.lng, node.lat]`.
- Pure: same input → deep-equal output. Empty `nodes` → both collections have `features: []`.

**Steps**

- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/data/buildingFeatures.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { buildingFeatures, glyphColor, glyphIcon } from "./buildingFeatures";
import { TONE_HEX } from "./globeSelectors";
import type { MapNode } from "./mapLayout";

const sys = (id: string, status = "active"): MapNode =>
  ({ key: `system:${id}`, type: "system", id, name: id, status, systemId: null, lat: 30, lng: -97, altitude: 0 });
const cam = (id: string, systemId: string, status = "active"): MapNode =>
  ({ key: `camera:${id}`, type: "camera", id, name: id, status, systemId, lat: 30.001, lng: -97, altitude: 0 });
const disp = (id: string, systemId: string): MapNode =>
  ({ key: `display:${id}`, type: "display", id, name: null, status: "active", systemId, lat: 29.999, lng: -97, altitude: 0 });

const nodes = [sys("s1"), cam("c1", "s1"), disp("d1", "s1"), sys("s2", "degraded"), cam("c2", "s2")];

describe("glyphIcon — one distinct non-empty glyph per node type", () => {
  it("gives system/camera/display distinct icons", () => {
    const icons = new Set([glyphIcon("system"), glyphIcon("camera"), glyphIcon("display")]);
    expect(icons.size).toBe(3);
    for (const g of icons) expect(g.length).toBeGreaterThan(0);
  });
});

describe("glyphColor — health tones; live green/dim by parent system", () => {
  const live = new Set(["s1"]);
  it("health mode uses status tones", () => {
    expect(glyphColor(sys("s1"), "health", live)).toBe(TONE_HEX.ok);
    expect(glyphColor(sys("s2", "degraded"), "health", live)).toBe(TONE_HEX.warn);
  });
  it("live mode: green when the node's system is live, dim otherwise", () => {
    expect(glyphColor(cam("c1", "s1"), "live", live)).toBe(TONE_HEX.ok);   // parent s1 live
    expect(glyphColor(cam("c2", "s2"), "live", live)).toBe("#3a4150");     // parent s2 not live
    expect(glyphColor(sys("s1"), "live", live)).toBe(TONE_HEX.ok);         // system keyed on its own id
  });
});

describe("buildingFeatures — connectors + glyph markers as GeoJSON [lng,lat]", () => {
  const fc = buildingFeatures(nodes, "health", new Set());
  it("emits one glyph per node", () => {
    expect(fc.glyphs.features).toHaveLength(5);
    const c1 = fc.glyphs.features.find((f) => f.properties.key === "camera:c1")!;
    expect(c1.geometry.coordinates).toEqual([-97, 30.001]);              // [lng, lat] order
    expect(c1.properties.label).toBe("c1");
    const d1 = fc.glyphs.features.find((f) => f.properties.key === "display:d1")!;
    expect(d1.properties.label).toBe("d1");                              // name null -> id fallback
  });
  it("emits one connector per device from its parent system, none for systems", () => {
    const keys = fc.connectors.features.map((f) => f.properties.key).sort();
    expect(keys).toEqual(["conn:camera:c1", "conn:camera:c2", "conn:display:d1"]);
    const conn = fc.connectors.features.find((f) => f.properties.key === "conn:camera:c1")!;
    expect(conn.geometry.coordinates).toEqual([[-97, 30], [-97, 30.001]]);  // system -> device, [lng,lat]
  });
  it("skips a device whose parent system node is absent (no dangling line)", () => {
    const orphan = buildingFeatures([cam("cx", "missing")], "health", new Set());
    expect(orphan.connectors.features).toEqual([]);
    expect(orphan.glyphs.features).toHaveLength(1);
  });
  it("is pure and empty-safe", () => {
    expect(buildingFeatures([], "health", new Set())).toEqual(buildingFeatures([], "health", new Set()));
    expect(buildingFeatures([], "health", new Set()).glyphs.features).toEqual([]);
  });
});
```

- [ ] **Run to verify it fails:** `npx vitest run src/data/buildingFeatures.test.ts`
  Expected: FAIL — `Cannot find module './buildingFeatures'`.
- [ ] **Commit (red):** `test(flatmap): pure building features — connectors + glyph markers + colors (red)`
- [ ] **Implement** `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts` per the Interfaces + Rules.
  Notes: import `TONE_HEX`, `type MapMode` from `./globeSelectors`, `statusGlyph` from `./explodeSelectors`,
  `type MapNode` from `./mapLayout`; `const DIM = "#3a4150"`; build a `Map<string, MapNode>` keyed on `node.key`
  for parent-system lookup (`byKey.get(`system:${node.systemId}`)`). No mapbox/three/react imports.
- [ ] **Run to verify it passes:** `npx vitest run src/data/buildingFeatures.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): pure building-topology features from MapNode[] (glyphs + connectors + colors)`

---

## Task 3 — Pure Mapbox pulse geometry (`mapPulseGeometry.ts`)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.test.ts`

**Interfaces**
- Consumes: `type GeoPoint`, `type FarPulse`, `pulseColor` from
  `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts:88,15,11`.
- Produces:
```ts
// mapPulseGeometry.ts — pure GeoJSON feature builders + candy-cane dash frame math + pulse lifecycle.
// No mapbox/three/react. Local structural GeoJSON types (mapbox `setData` accepts them at runtime).
export interface PulsePointFeature { type: "Feature"; geometry: { type: "Point"; coordinates: [number, number] };
  properties: { color: string }; }
export interface PulseLineFeature { type: "Feature"; geometry: { type: "LineString"; coordinates: [number, number][] };
  properties: { color: string }; }

export const FAR_PULSE_MS = 1500;        // venue marker pulse lifetime (matches globe PULSE_RING_MS intent)
export const BUILDING_PULSE_MS = 1800;   // camera->system->display travel lifetime (matches globe TRAVEL_MS)

/** Far-zoom venue marker pulse: a point at the venue, GeoJSON [lng,lat]. */
export function pulsePointFeature(p: FarPulse, color: string): PulsePointFeature;
/** Building path (camera->system->display) as a LineString; altitude dropped (Mapbox is 2D).
 * Fewer than 2 points -> null (nothing to draw). */
export function pulseLineFeature(path: GeoPoint[], color: string): PulseLineFeature | null;
/** true while the pulse is still animating; false once elapsed >= duration (removal signal). */
export function pulseAlive(elapsedMs: number, durationMs: number): boolean;
/** Candy-cane crawl: the mapbox `line-dasharray` value for this frame. Cycles a fixed multi-stripe
 * pattern set so the stripes appear to crawl (Mapbox cannot tween dasharray; it is stepped per frame).
 * Returns a 2-element [dash, gap] pattern rotated by the frame index derived from elapsedMs. */
export function candyCaneDash(elapsedMs: number): [number, number];
```

Rules (each a test):
- `pulsePointFeature(p, color)` → `{ type:"Feature", geometry:{ type:"Point", coordinates:[p.lng, p.lat] }, properties:{ color } }`.
- `pulseLineFeature(path, color)`: maps each `GeoPoint` to `[lng, lat]` (drops `altitude`); `< 2` points → `null`.
- `pulseAlive(elapsedMs, durationMs)` → `elapsedMs < durationMs`. **Discriminates-proof:** deleting the `<` guard
  (returning constant `true`) makes the "dies after its window" assertion below go red.
- `candyCaneDash(elapsedMs)`: derive a frame index `Math.floor(elapsedMs / STEP_MS) % CYCLE` from a small set of
  offset patterns so consecutive frames differ (the crawl). **Discriminates-proof:** the test asserts two elapsed
  values one full `STEP_MS` apart yield DIFFERENT patterns — a constant return makes it red.

**Steps**

- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  BUILDING_PULSE_MS, candyCaneDash, FAR_PULSE_MS, pulseAlive, pulseLineFeature, pulsePointFeature,
} from "./mapPulseGeometry";
import { pulseColor } from "./pulseDelta";

describe("pulsePointFeature — venue far pulse, GeoJSON [lng,lat]", () => {
  it("places the point at the venue with the pulse color", () => {
    const f = pulsePointFeature({ venueId: "v", lat: 30.27, lng: -97.74, orgId: null }, pulseColor(0));
    expect(f.geometry.coordinates).toEqual([-97.74, 30.27]);
    expect(f.properties.color).toBe(pulseColor(0));
  });
});

describe("pulseLineFeature — camera->system->display path, altitude dropped", () => {
  const path = [
    { lat: 30.01, lng: -97, altitude: 0 },
    { lat: 30, lng: -97, altitude: 0 },
    { lat: 29.99, lng: -97, altitude: 0 },
  ];
  it("maps to [lng,lat] pairs in order", () => {
    expect(pulseLineFeature(path, "#34d399")!.geometry.coordinates)
      .toEqual([[-97, 30.01], [-97, 30], [-97, 29.99]]);
  });
  it("returns null for fewer than 2 points (nothing to draw)", () => {
    expect(pulseLineFeature([path[0]], "#34d399")).toBeNull();
    expect(pulseLineFeature([], "#34d399")).toBeNull();
  });
});

describe("pulseAlive — one-shot lifecycle", () => {
  it("is alive inside the window and dead at/after the duration", () => {
    // Discriminates-proof: removing the `elapsedMs < durationMs` guard makes the second assertion fail.
    expect(pulseAlive(0, BUILDING_PULSE_MS)).toBe(true);
    expect(pulseAlive(BUILDING_PULSE_MS, BUILDING_PULSE_MS)).toBe(false);
    expect(pulseAlive(FAR_PULSE_MS + 1, FAR_PULSE_MS)).toBe(false);
  });
});

describe("candyCaneDash — the stripe pattern crawls (steps) over time", () => {
  it("returns different patterns for frames one full step apart", () => {
    // Discriminates-proof: a constant return makes this fail. Find the step by scanning until a change.
    const first = candyCaneDash(0);
    let changedAt = -1;
    for (let t = 1; t <= 2000; t += 10) {
      if (candyCaneDash(t).join(",") !== first.join(",")) { changedAt = t; break; }
    }
    expect(changedAt).toBeGreaterThan(0);                       // it DOES change over time
    expect(first).toHaveLength(2);                              // [dash, gap]
    expect(first.every((n) => n > 0)).toBe(true);
  });
});
```

- [ ] **Run to verify it fails:** `npx vitest run src/data/mapPulseGeometry.test.ts`
  Expected: FAIL — `Cannot find module './mapPulseGeometry'`.
- [ ] **Commit (red):** `test(flatmap): pure mapbox pulse geometry — features + candy-cane stepper + lifecycle (red)`
- [ ] **Implement** `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.ts` per the Interfaces + Rules.
  `candyCaneDash`: `const STEP_MS = 120; const PATTERNS: [number,number][] = [[0.5,0.5],[0.25,0.75],[0.75,0.25]]`
  (or similar multi-stripe set); return `PATTERNS[Math.floor(elapsedMs / STEP_MS) % PATTERNS.length]`. No
  mapbox/three/react imports.
- [ ] **Run to verify it passes:** `npx vitest run src/data/mapPulseGeometry.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): pure mapbox pulse geometry + candy-cane dash stepper + one-shot lifecycle`

---

## Task 4 — FlatMapCanvas building layers (glyphs + connectors + labels)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`

**Interfaces**
- Consumes: `BuildingFeatures` from `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts` (Task 2).
- Produces (page-facing prop; Plan G's existing props carry through unchanged):
```ts
// FlatMapCanvas gains ONE new prop for this task (the page precomputes the pure features):
building: BuildingFeatures | null;   // null => building layer empty (world/city tier, or no venue)
```

**Island wiring decisions** (all inside FlatMapCanvas's existing Mapbox-guarded island — Plan G's structure; mapbox
is NEVER imported at module top):
- On map `load` (Plan G's init), add three GeoJSON sources — `"building-connectors"`, `"building-glyphs"` — each
  `{ type: "geojson", data: EMPTY_FC }` where `EMPTY_FC = { type: "FeatureCollection", features: [] }`; and their
  layers: a `line` layer for connectors (`paint: { "line-color": ["get","color"], "line-width": 1.5, "line-opacity": 0.7 }`),
  a `circle` layer for glyph status rings (`paint: { "circle-color": ["get","color"], "circle-radius": 6, "circle-stroke-width": 1.5, "circle-stroke-color": ["get","color"] }`),
  and a `symbol` layer for the icon glyph + name label (`layout: { "text-field": ["concat", ["get","glyph"], " ", ["get","label"]], "text-size": 10, "text-offset": [0, 1.2] }`,
  `paint: { "text-color": ["get","color"] }`). Data-driven `["get","color"]` reads the feature `properties.color`
  Task 2 wrote — no per-node imperative styling.
- A `building` data effect (deps `[building, ready]`): `map.getSource("building-connectors").setData(building?.connectors ?? EMPTY_FC)`
  and `...("building-glyphs").setData(building?.glyphs ?? EMPTY_FC)`. `building === null` → both get `EMPTY_FC`
  (layer clears). Guard on the map instance existing + `map.isStyleLoaded()` exactly as Plan G guards its venue-layer
  setData (mirror Plan G's existing pattern; if Plan G queues setData behind a `load`/`styledata` handler, reuse that
  helper — do NOT add a second load handler).
- No new dispose logic needed beyond Plan G's map `remove()` (sources/layers die with the map).
- **Do not touch** Plan G's venue-marker layer or the corner globe.

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`.
  Thread `building={null}` through every existing `render(<FlatMapCanvas … />)`, and add one jsdom fallback test
  (jsdom has no WebGL, so `hasWebGL()` is false → the `map-unavailable` fallback path; the building props must be
  accepted and the layer wiring must never run):

```tsx
import { buildingFeatures } from "../../data/buildingFeatures";
import type { MapNode } from "../../data/mapLayout";

const bNode: MapNode = { key: "system:s1", type: "system", id: "s1", name: "S1",
  status: "active", systemId: null, lat: 30, lng: -97, altitude: 0 };

test("building props are accepted on the fallback path without constructing a map", () => {
  const { rerender } = render(<FlatMapCanvas /* + Plan G required props */ building={null} />);
  rerender(<FlatMapCanvas /* + Plan G required props */
    building={buildingFeatures([bNode], "health", new Set())} />);
  expect(screen.getByTestId("map-unavailable")).toBeInTheDocument();
});
```

  (Fill `/* + Plan G required props */` with the exact required-prop set Task 1 recorded from Plan G's
  `FlatMapCanvas` signature — mirror an existing render in this test file.)

- [ ] **Run to verify it fails:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx`
  Expected: FAIL — TS: unknown prop `building` (and/or the new import path resolves but the prop is untyped).
  Record the exact error.
- [ ] **Commit (red):** `test(flatmap): FlatMapCanvas accepts building features on the fallback path (red)`
- [ ] **Implement** the `building` prop + the three sources/layers + the data effect per the wiring decisions.
  Keep every mapbox reference inside the island's guarded effects (no-op until the map exists), reusing Plan G's
  style-loaded guard helper.
- [ ] **Run to verify it passes:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx` → PASS (fallback path
  untouched by the new layer code); `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): building layers — connector lines + glyph markers + labels via geojson sources`

---

## Task 5 — FlatMapCanvas pulse layers + `mapPulseLayer.ts` (far venue pulse + building path pulse)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/flatmap/mapPulseLayer.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`

**Interfaces**
- Consumes: `pulsePointFeature`, `pulseLineFeature`, `pulseAlive`, `candyCaneDash`, `FAR_PULSE_MS`,
  `BUILDING_PULSE_MS` from `/Users/jn/code/godview-prototype/src/data/mapPulseGeometry.ts` (Task 3);
  `type FarPulse`, `type GeoPoint`, `pulseColor` from `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts`.
- Produces (page-facing props; the page precomputes both batches from the reused engines):
```ts
// FlatMapCanvas gains two pulse props:
farPulses: { seq: number; venues: FarPulse[] } | null;                                  // far zoom
buildingPulses: { seq: number; paths: { key: string; color: string; path: GeoPoint[] }[] } | null;  // building zoom

// mapPulseLayer.ts — the ONLY module reaching imperative Mapbox pulse code. Reached exclusively via
// dynamic import("./mapPulseLayer") inside FlatMapCanvas AFTER Plan G's hasWebGL()+token guard (the
// pulseLayer.ts rule). `map` is typed `any` (mapbox-gl's Map — this repo already treats globe/three
// instances as any; do not add a mapbox type import here that jsdom would load).
export interface MapPulse { tick(elapsedMs: number): boolean; dispose(): void; }
/** A far venue-marker pulse: a growing/fading circle at the venue point. */
export function buildFarPulse(map: any, id: string, p: FarPulse, color: string): MapPulse;
/** A building camera->system->display candy-cane line pulse (line-dasharray stepped per frame). */
export function buildBuildingPulse(map: any, id: string, path: GeoPoint[], color: string): MapPulse;
```

**Mechanism** (mirrors GlobeCanvas owning the rAF while `pulseLayer.ts` builds per-pulse objects,
`/Users/jn/code/godview-prototype/src/components/globe/pulseLayer.ts:31,58-75`):
- `buildFarPulse`: `map.addSource(id, { type:"geojson", data: pulsePointFeature(p, color) })` + a `circle` layer
  (`circle-radius` grown per frame in `tick`, `circle-opacity` faded); `tick(elapsedMs)` sets the paint props via
  `map.setPaintProperty` and returns `pulseAlive(elapsedMs, FAR_PULSE_MS)`; `dispose()` removes the layer + source.
- `buildBuildingPulse`: `pulseLineFeature(path, color)` → `null` guard (caller skips); else `addSource` + a `line`
  layer; `tick(elapsedMs)` sets `line-dasharray` = `candyCaneDash(elapsedMs)` (the crawl) and returns
  `pulseAlive(elapsedMs, BUILDING_PULSE_MS)`; `dispose()` removes layer + source.
- **FlatMapCanvas owns ONE rAF loop + a `handledFar`/`handledBuilding` seq guard + active-pulse array + timers:** two
  effects (`[farPulses]`, `[buildingPulses]`), each skips if `!mapReady || batch == null || batch.seq === handledRef`;
  marks handled; lazily `const layer = pulseLayerRef.current ??= await import("./mapPulseLayer")`; builds a `MapPulse`
  per pulse; pushes to the active array; starts the rAF if idle. Each frame ticks every active pulse with
  `performance.now() - startedAt`; a pulse returning `false` is `dispose()`d and removed; the loop stops when the
  array empties. **On unmount: cancel the rAF and `dispose()` every active pulse** (extend Plan G's map-remove
  cleanup). Far and building pulses share this loop.

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`.
  Add the throwing tripwire mock next to any Plan-G `mapbox-gl` mock, thread `farPulses={null} buildingPulses={null}`
  through existing renders, and add the tripwire test:

```tsx
vi.mock("./mapPulseLayer", () => { throw new Error("mapPulseLayer (mapbox) must not load in jsdom"); });

test("fallback path ignores pulse batches and never imports the mapbox pulse layer", () => {
  // Discriminates-proof: if the pulse effect imported ./mapPulseLayer unconditionally (no map/guard
  // check), the throwing mock fires and this test goes red. It stays green only because the dynamic
  // import sits behind the map-exists guard, which never passes on the jsdom fallback path.
  const { rerender } = render(<FlatMapCanvas /* + Plan G required props */
    building={null} farPulses={null} buildingPulses={null} />);
  rerender(<FlatMapCanvas /* + Plan G required props */ building={null}
    farPulses={{ seq: 1, venues: [{ venueId: "v", lat: 1, lng: 2, orgId: null }] }}
    buildingPulses={{ seq: 1, paths: [{ key: "system:s1", color: "#34d399",
      path: [{ lat: 1, lng: 2, altitude: 0 }, { lat: 1.1, lng: 2, altitude: 0 }] }] }} />);
  expect(screen.getByTestId("map-unavailable")).toBeInTheDocument();
});
```

- [ ] **Run to verify it fails:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx`
  Expected: FAIL — TS: unknown props `farPulses`/`buildingPulses`.
- [ ] **Commit (red):** `test(flatmap): FlatMapCanvas pulse props + mapPulseLayer never loads in jsdom (red)`
- [ ] **Implement** `/Users/jn/code/godview-prototype/src/components/flatmap/mapPulseLayer.ts` and the two FlatMapCanvas
  pulse effects + the shared rAF loop + unmount cleanup per the Mechanism. `mapPulseLayer.ts` imports ONLY from
  `../../data/mapPulseGeometry` (pure) — no `mapbox-gl` import (the `map` instance is passed in), so the tripwire
  proves the DYNAMIC-IMPORT boundary holds, not a heavy dependency.
- [ ] **Run to verify it passes:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx` → PASS (jsdom never
  reaches the throwing mock); `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): mapbox pulse renderer — far venue pulse + building candy-cane line pulse (rAF)`

---

## Task 6 — FlatMap page wiring (building tier + panels + pulse batches)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` (Plan G's page)
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Interfaces**
- Consumes: `mapTier` (`/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`); `buildingLayout`
  (`/Users/jn/code/godview-prototype/src/data/mapLayout.ts`); `buildingFeatures`
  (`/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts`); `mapPulseGeometry` types; `useVenueDetailPoll`
  (`/Users/jn/code/godview-prototype/src/hooks/useVenueDetailPoll.ts`); `usePollDelta`
  (`/Users/jn/code/godview-prototype/src/hooks/usePollDelta.ts`); `diffFarPulses`, `diffDeepPulses`, `deepPulsePath`,
  `pulseColor` (`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts`); `liveSystemIds`
  (`/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts`); `VenuePanel`, `NodePanel`
  (`/Users/jn/code/godview-prototype/src/components/globe/`); Plan G's zoom + selected-venue state.

**Wiring** (mirror `/Users/jn/code/godview-prototype/src/pages/Globe.tsx:42-110` — the proven analog):
- The page already owns (Plan G) the Mapbox `zoom`, the map data poll (`usePolling(fetchMap, 5000)` → `data`), and
  the selected-venue id. Derive `buildingVenueId = mapTier(zoom) === "building" ? selectedVenueId : null`.
- `const { detail } = useVenueDetailPoll(buildingVenueId);` — page-owned building-venue detail poll (self-resets to
  null on id change; keeps last-good on error — verified `useVenueDetailPoll.ts:13-32`).
- `const anchor = detail && detail.location.lat != null && detail.location.lng != null
    ? { lat: detail.location.lat, lng: detail.location.lng } : null;`
- `const nodes = useMemo(() => (anchor && detail) ? buildingLayout(anchor, detail.systems) : null, [anchor, detail]);`
- `const live = useMemo(() => (detail ? liveSystemIds(detail) : new Set<string>()), [detail]);`
- `const building = useMemo(() => nodes ? buildingFeatures(nodes, mode, live) : null, [nodes, mode, live]);`
- **Far pulses (reused engine):** `const farBatch = usePollDelta(data, diffFarPulses);`
  `const farPulses = useMemo(() => farBatch && { seq: farBatch.seq, venues: farBatch.pulses }, [farBatch]);`
  (No org-arc sweep on the flat map — that was globe-only; the far pulse is the venue marker only, spec §3.)
- **Building pulses (reused engines over MapNode[]):**
  `const deepBatch = usePollDelta(detail, diffDeepPulses);`
  ```ts
  const buildingPulses = useMemo(() => {
    if (!deepBatch || !nodes) return null;
    const paths = deepBatch.pulses
      .map((p, i) => ({ key: `${p.systemId}|${p.cameraId ?? ""}|${p.displayId ?? ""}`,
        color: pulseColor(deepBatch.seq + i), path: deepPulsePath(nodes, p) }))
      .filter((x) => x.path.length >= 2);
    return paths.length ? { seq: deepBatch.seq, paths } : null;
  }, [deepBatch, nodes]);
  ```
  (`deepPulsePath(nodes, p)` consumes `MapNode[]` directly — MapNode satisfies its `Pick<ExplodedNode,…>` input,
  Contract C.)
- Pass `building`, `farPulses`, `buildingPulses` to `<FlatMapCanvas>` alongside Plan G's props.
- **Panels-first (Amendment 6):** on glyph click Plan G surfaces the clicked node (or the page maps a marker click to
  `{ type, id }`); the page holds `panel: { type: "venue"|"system"|"camera"|"display"; id; venueId } | null` and
  renders, EXACTLY as `Globe.tsx:141-144`:
  ```tsx
  {panel && (panel.type === "venue"
    ? <VenuePanel key={`venue:${panel.id}`} locationId={panel.id} onClose={() => setPanel(null)} />
    : <NodePanel key={`${panel.type}:${panel.id}`} type={panel.type} id={panel.id}
        detail={detail} onClose={() => setPanel(null)} />)}
  ```
  No anchored floating cards (explicitly out of scope).

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`. Because the
  page mounts `<FlatMapCanvas>` (WebGL) the existing Plan-G page tests already mock it; extend that mock to capture
  the new props, and add assertions. If Plan G's test mocks `FlatMapCanvas` as a prop-capturing stub, reuse it;
  otherwise add `vi.mock("../components/flatmap/FlatMapCanvas", …)` capturing props into a ref. Cover:

```tsx
// (1) Below building zoom / no selected venue -> building + buildingPulses are null.
it("passes null building layer at world/city tier", async () => {
  // render FlatMap with mocked fetchMap data + Plan G zoom stubbed to a city zoom, no venue selected
  // expect the captured FlatMapCanvas props: building === null
});
// (2) At building tier with a selected venue whose detail resolves -> building features are passed.
it("builds the building layer at building tier for the selected venue", async () => {
  // stub mapTier boundary (zoom at building), select a venue, mock fetchMapLocation -> a detail with 1 system + 1 cam
  // expect captured props: building.glyphs.features length === 2 (system + camera)
});
// (3) NodePanel mounts keyed `${type}:${id}` fed by the page detail when a non-venue node is selected.
it("mounts NodePanel with the page detail for a device selection", async () => {
  // set panel = { type:"camera", id:"c1", venueId } ; expect a node-panel testid rendered
});
```

  (Flesh each stub from the concrete Plan-G page-test harness Task 1 recorded — mirror `Globe.test.tsx`'s approach to
  stubbing `usePolling`/`fetchMapLocation` and the canvas mock. The three assertions above are the required contract;
  the exact mock plumbing follows Plan G's existing `FlatMap.test.tsx`.)

- [ ] **Run to verify it fails:** `npx vitest run src/pages/FlatMap.test.tsx`
  Expected: FAIL — captured `building`/`buildingPulses` props undefined (page not yet wired).
- [ ] **Commit (red):** `test(flatmap): page passes building layer + pulses at building tier, mounts panels (red)`
- [ ] **Implement** the page wiring per the Wiring block. Import order/grouping to match the existing file. Do not
  touch Plan G's world/city venue-marker path, fly-to, corner globe, rail, or `map-unavailable` seam.
- [ ] **Run to verify it passes:** `npx vitest run src/pages/FlatMap.test.tsx` → PASS; `npx tsc -b` → clean.
  Quick headed smoke: `npm run dev`, open `http://localhost:5173/map` with the backend down — page renders the
  `map-unavailable` seam (no token in a fresh env) or the map with an empty building layer, no console errors.
- [ ] **Commit (green):** `feat(flatmap): building-tier wiring — layout->features, reused pulse engines, panels-first`

---

## Task 7 — Full suite, typecheck, build, lint, bundle sanity, PR

**Files** — none new; fixes only if something below fails (each fix scoped + committed with its reason).

**Steps**

- [ ] `cd <worktree> && pwd` (workspace lock). `npx vitest run` — full suite green (all pre-existing v1/Plan-G tests
  too; jsdom never hits the `mapPulseLayer` throwing mock).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. **Bundle guardrail:** the ENTRY chunk must not grow from Plan H —
  `mapPulseLayer.ts` must land in a lazy chunk (reached only by dynamic import), and `buildingFeatures.ts` /
  `mapPulseGeometry.ts` are pure and small. `ls -lS dist/assets | head`; record chunk sizes in the commit message.
- [ ] **Contract gate-check:** re-read this plan's "Contract (consumes — produced by Plan G)" block against the merged
  Plan G. Confirm every consumed name/signature (A `paused`, B `mapTier`/`MapTier`, C `MapNode`/`buildingLayout`,
  D `hasWebGL()&&VITE_MAPBOX_TOKEN` seam, E engine names) matches Plan G verbatim. Note any Task-1 substitutions in
  the PR.
- [ ] Controller existence-check (workspace discipline): `ls src/data/buildingFeatures.ts src/data/mapPulseGeometry.ts
  src/components/flatmap/mapPulseLayer.ts` in the worktree before the final commit.
- [ ] Commit: `chore(flatmap): full suite + tsc + build + lint green; pulse layer in lazy chunk (sizes noted)`
- [ ] Ask git-flow-manager to push the branch and open a PR titled
  `feat(flatmap): building-level topology + detail panels + pulses (Plan H)` against `main` with the structured
  description (Summary / Motivation / Implementation / Tests / Risks / rollout), noting: building layout is
  fallback-only (Amendment 1); pulses reuse the pure engines + a new Mapbox renderer (Amendment 5); panels-first,
  anchored cards deferred (Amendment 6); Mapbox attribution kept (Amendment 12); any Task-1 contract reconciliations.
  Request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings
  before Task 8.

---

## Task 8 — Live Playwright E2E: demo_traffic → building topology + pulses on the real stack

**DEPENDENCY:** Plan G + Plan H merged-or-branch-live; dev stack up (ops-api `:8080`, projector running, seed v2
applied — **17 venues, 4 retailer orgs**); `VITE_MAPBOX_TOKEN` set in the worktree env; frontend `npm run dev`.
Findings become scoped fix commits on this branch or follow-up GitHub issues.

**Files** — none (live drill).

**Steps**

- [ ] Preconditions: confirm `/god-view/map` returns venues and `/god-view/map/locations/{id}` returns
  systems/cameras/displays for a seeded venue. Confirm the token is present so `<FlatMapCanvas>` mounts the map
  (not `map-unavailable`).
- [ ] Headless WebGL note: if driving via Playwright MCP and WebGL is unavailable in the headless context, cover the
  visual checks with a headed/real-browser pass — the pulse and glyph checks are intrinsically visual.
- [ ] Start the generator from `/Users/jn/code/mras-ops`:
  `python3 -m scripts.demo_traffic --rate 10 --duration 600`
  (dev `DATABASE_URL` default `postgresql://mras:mras@localhost:5432/mras`).
- [ ] **Building tier renders:** on `/map`, select a seeded venue (rail/marker), zoom to `mapTier === 'building'`.
  Observe the venue's systems as group/card glyphs, cameras + displays as glyph markers with a status ring + name
  label, and thin connector lines system→device. No 3D tubes. Screenshot.
- [ ] **Far-zoom venue pulse:** zoom back out to world/city tier. Within ~2–7 s of a generator
  `ad_run/planned→playing` line (5 s poll + projector settle — accepted lag, NOT a bug), the emitting venue's marker
  pulses once and does NOT keep looping. Screenshot mid-pulse.
- [ ] **Building-zoom path pulse:** with an actively-emitting venue at building tier, within ~one poll of the
  generator printing `ad_run/dispatched` for that venue, observe the candy-cane line pulse traveling
  camera→system→display along the connectors, terminating (no loop) after ~2 s; the camera end is the system's FIRST
  camera by `screen_id` (`attributionCamera` ground truth) and the display end matches the run's `display_id` when
  present. Screenshot mid-travel.
- [ ] **Panels:** click a system glyph → `NodePanel` (system) with `zone/status/system_type`; click a camera → camera
  panel with `screen_id`/`duty`; click a display → display panel with screen group; click the venue → `VenuePanel`
  (self-polling). Each mounts keyed `${type}:${id}` (no stale content on switch).
- [ ] **Two-WebGL hygiene (spec §7 risk):** with the corner globe present, confirm smooth interaction on the target
  hardware; verify the mini globe pauses during a Mapbox `flyTo` (Plan G's `paused` prop, Amendment 2) and resumes
  after — Plan H does not regress it.
- [ ] **Longevity:** leave `/map` 10+ minutes under generator load — no console errors, no unbounded source/layer
  growth (pulse sources/layers must be added AND removed by `dispose()`), interaction stays smooth; navigate away and
  back — no leaked rAF/timer warnings.
- [ ] Tune flagged visual constants (glyph icons, marker/ring sizes, `candyCaneDash` step/pattern, `FAR_PULSE_MS`,
  `BUILDING_PULSE_MS`, dash direction) as scoped commits if the live look demands it.
- [ ] Fix anything found (red→green where code changes), then ask git-flow-manager to merge the PR (merge commit)
  after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with
  `repo@sha`, E2E evidence + screenshots, gotchas); file any deferred follow-ups (anchored floating cards refinement;
  real per-device coords backend lane) as GitHub issues so nothing falls off the plan.

---

## Self-review notes (spec §5 "Plan H scope" coverage check, done at plan time)

- **Building tier = 2D glyphs by fallback layout only (Amendment 1):** Task 6 gates on `mapTier(zoom)==='building'` +
  selected venue, feeds `buildingLayout(anchor, detail.systems)` (no device coords read anywhere) into Task 2's pure
  `buildingFeatures` → connector lines + glyph markers + labels; Task 4 renders them as Mapbox geojson sources/layers.
  ✓
- **Panels-first, anchored cards deferred (Amendment 6):** Task 6 reuses `VenuePanel` (self-poll) + `NodePanel` (page
  `detail`), mounted keyed `${type}:${id}`; anchored floating cards are explicitly out of scope. ✓
- **Pulses = reused pure engines + NEW Mapbox renderer (Amendment 5):** far venue-marker pulse (`diffFarPulses`) and
  building camera→system→display line pulse (`diffDeepPulses` + `deepPulsePath` over `MapNode[]`); globe-only
  `pulseRingDatum`/`sweepArcDatum`/`pulseLayer.ts` NOT reused — Task 3 (pure geometry) + Task 5 (`mapPulseLayer.ts`
  imperative, dynamic-import + tripwire). Candy-cane pacing is the aesthetic goal (`candyCaneDash`), not code reuse. ✓
- **Mounts inside Plan G's `<FlatMapCanvas>` behind the guard (Contract D):** Tasks 4/5 add sources/layers + pulse
  wiring inside the island; Task 6 passes props; no second guard, no second `new Map`, attribution untouched
  (Amendment 12). ✓
- **Testability (Amendment 11):** all decisions pure + jsdom-tested (Tasks 2/3); the Mapbox render layer is
  dynamic-imported behind the guard with a throwing tripwire (Task 5); mapbox never loads in jsdom. ✓
- **Sequencing after merged Plan G; Contract consumed verbatim (Global Constraints + Contract block):** Task 1
  preflight + Task 7 gate-check. ✓
- **Discriminates-proofs on invariant tests (memory):** `pulseAlive` window + `candyCaneDash` crawl + the tripwire
  each carry a stated mutation that reddens them. ✓
- **Subagent workspace discipline (memory):** cd+pwd lock step 1, bare-path read-only, existence-check before commit
  — Global Constraints + Tasks 1/7. ✓
- **Frontend-only, no backend changes (spec §4/§6):** no `map.py`/schema edits; real per-device coords are a future
  additive lane, filed as an issue in Task 8. ✓
- **Process:** worktree branch, no raw git for implementers, red→green pairs watched failing, exact verify commands
  from `/Users/jn/code/godview-prototype/package.json`, PR + strongest-model review, live E2E with
  `demo_traffic --rate 10 --duration 600` and the accepted 2–7 s lag, SESSION_LOG close-out — Tasks 1/7/8. ✓
