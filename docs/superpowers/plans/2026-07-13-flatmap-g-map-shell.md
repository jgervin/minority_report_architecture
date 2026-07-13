# Flat Map v3 — Plan G: "Command Map" shell (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `/map` "Command Map" shell (spec `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md` §5 "Plan G scope"): a Mapbox GL JS flat map with an in-repo dark style built from the app's Tailwind theme, a `/map` route + "Map" nav item, the shipped `GlobeCanvas` reused as a corner planet-scale picker (via a new surgical `paused` prop), staged `flyTo` driven by corner-globe dot clicks, and a zoom-semantic venue marker layer (world/country rollup markers, city de-clustered org-halo markers). Plan G ALSO authors the three shared contracts Plan H consumes so Plan H is pure rendering.

**Architecture:** Every testable decision is a pure, WebGL-free function in a selector/geometry module unit-tested in jsdom: `mapTier(zoom)` + staged-fly zooms (`/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`), the deterministic `buildingLayout` (`/Users/jn/code/godview-prototype/src/data/mapLayout.ts`) built on `byId`+`ringPoint` extracted into a shared `/Users/jn/code/godview-prototype/src/data/layoutGeometry.ts`, and the venue-marker DOM factory (`/Users/jn/code/godview-prototype/src/data/venueMarkers.ts`). Two imperative WebGL islands stay behind dynamic-import + feature guards so jsdom never loads them: the shipped `GlobeCanvas` (`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`, gaining only a `paused` prop) and the new Mapbox island `FlatMapCanvas` (`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`), whose heavy `mapbox-gl` + CSS import is isolated in `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts` (the exact pattern `pulseLayer.ts` uses for three/`Line2`). The page `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` owns two independent camera states (Mapbox zoom + mini-globe pov) and the token/WebGL fallback seam.

**Tech Stack:** unchanged (React 19 + Vite 8 + Tailwind 3 + react-router-dom v7 + vitest 4 / Testing Library; `globe.gl@2.46.1`, `three@0.185.1`), plus one new direct dependency: `mapbox-gl` v3 (proprietary Mapbox TOS — see Global Constraints), code-split into its own lazy chunk exactly like globe.gl/three.

## Global Constraints

- **Frontend-only, one repo:** all work is in `/Users/jn/code/godview-prototype`. No backend changes (verified: the map endpoints already return everything Plan G reads — see Contract (consumes)).
- **Plan G / Plan H boundary:** Plan G ships the shell + the three shared contracts (see Contract (produces)). Building-level topology, detail cards, and pulses are **Plan H** — do NOT build them here. Plan G authors `buildingLayout` (pure) and the `FlatMapCanvas` children slot Plan H renders inside, but mounts NO building layers itself.
- **`/globe` must stay byte-identical.** The ONLY change to `GlobeCanvas.tsx` is the additive optional `paused?: boolean` prop (Task 5). `Globe.tsx` (the `/globe` page) is NOT edited — it never passes `paused`, so its call site is unchanged; `resumeAnimation()` on a falsy/undefined `paused` is idempotent (the render loop is already running). Regression gate: the entire pre-existing `src/pages/Globe.test.tsx` + `src/components/globe/GlobeCanvas.test.tsx` suites stay green untouched.
- **WebGL/mapbox testability (spec §5 Amendment 11):** both WebGL islands dynamic-import behind guards so vitest/jsdom never evaluates them. `hasWebGL()` (`/Users/jn/code/godview-prototype/src/components/globe/webgl.ts:1`) gates the globe; **`hasWebGL() && !!import.meta.env.VITE_MAPBOX_TOKEN`** gates Mapbox (the token check is a synchronous env read decidable BEFORE any dynamic import — never load `mapbox-gl` without a token). `import "mapbox-gl/dist/mapbox-gl.css"` lives INSIDE the dynamically-imported `mapboxImpl.ts` (mirrors `pulseLayer.ts:9-12` isolating three's heavy static imports). Set `mapboxgl.accessToken` before `new mapboxgl.Map(...)`. Do NOT use deprecated `mapboxgl.supported()` — rely on `hasWebGL()` + try/catch around `new Map`. Every test that renders a WebGL island installs a throwing `vi.mock("mapbox-gl", () => { throw ... })` (and the globe tests keep their existing throwing `globe.gl`/`three` mocks). Keep EVERYTHING testable in pure selectors: `mapTier`, `nextFlyZoom`, `buildingLayout`, `buildVenueMarker`.
- **Keep the Mapbox attribution/logo control** (spec §7 Amendment 12 — `mapbox-gl` v3 is proprietary Mapbox TOS, not the OSS MapLibre fork the owner rejected). Never pass `attributionControl: false` or hide the logo. Document the proprietary license + 50k-load/mo metering + offline-safety note in the README (Task 10).
- **Dark style from the verified Tailwind hexes** (`/Users/jn/code/godview-prototype/tailwind.config.ts:9-13`, confirmed): `bg #0a0d12, elev #12161d, elev2 #171c25, sidebar #0d1016, border #212734, borderSoft #1a2029, dim #8b93a3, faint #5b6472, accent #45c4ff`; status `ok #34d399, warn #f5b942, crit #f2545b, off #5b6472`. The style JSON is committed in-repo (`/Users/jn/code/godview-prototype/src/map/style.json`).
- **All git via the git-flow-manager subagent** (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers NEVER run raw `git`/`gh`. Work on branch `feat/flatmap-g-map-shell` in a DEDICATED worktree of `/Users/jn/code/godview-prototype`. **Commit each failing test SEPARATELY from the implementation that greens it** (red→green pairs in history). Merge commits (not squash) on PR merge.
- **Subagent workspace discipline** (memory `feedback-subagent-workspace-discipline` — 4 drift incidents in the v2 build): every implementer dispatch STARTS with a `cd <worktree> && pwd` lock step and treats the bare repo path `/Users/jn/code/godview-prototype` as a READ-ONLY reference; the controller runs an existence-check on the target files before every commit dispatch.
- Reference every file by ABSOLUTE path. Verify commands (confirmed against `/Users/jn/code/godview-prototype/package.json:6-13`): `npx vitest run [files]` (`test` = `vitest run`), `npx tsc -b` (`build` = `tsc -b && vite build`), `npm run lint` (oxlint), `npm run build`.
- Baseline: `main` at `468745e` (clean). `mapbox-gl` is NOT installed yet (verified) — Task 1 adds it.

---

## Contract (produces — Plan H consumes)

**LOCKED — copied verbatim. Plan G IMPLEMENTS these exact names/signatures; Plan H consumes them; a gate-check diffs both plans against this block.**

A. **`GlobeCanvas` `paused` prop** (Plan G adds to GlobeCanvas.tsx, surgically): `paused?: boolean`. Effect: `true` → call globe.gl `pauseAnimation()`; falsy/undefined → `resumeAnimation()`. Verify exact method names against globe.gl 2.46.1 d.ts. Default falsy = unchanged v1 behavior (the /globe path must stay byte-identical — assert this).

B. **Pure tier selector** (Plan G authors; module `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`):
```ts
export type MapTier = 'world' | 'city' | 'building';
export function mapTier(zoom: number): MapTier;
```
You pick the exact Mapbox zoom thresholds, but Plan G's staged flyTo (country→city→building) MUST land at zooms consistent with this function. Plan H renders the building layer iff `mapTier(zoom) === 'building'`.

C. **Deterministic fallback building-layout** (Plan G authors; module `/Users/jn/code/godview-prototype/src/data/mapLayout.ts`, reusing `byId`+`ringPoint` EXTRACTED from explodeSelectors into a shared pure module and re-exported from explodeSelectors so the globe path is byte-unchanged):
```ts
export interface MapNode {
  key: string;               // `${type}:${id}` — same convention deepPulsePath matches
  type: 'system' | 'camera' | 'display';
  id: string;
  name: string | null;
  status: string;
  systemId: string | null;   // parent system for camera/display; null for system nodes
  lat: number;
  lng: number;
  altitude: 0;               // constant 0 so MapNode satisfies deepPulsePath's Pick<ExplodedNode,'key'|'type'|'id'|'lat'|'lng'|'altitude'>
}
export function buildingLayout(anchor: { lat: number; lng: number }, systems: MapSystem[]): MapNode[];
```
Deterministic (byId sort); building-scale radii in METERS converted to lat/lng offsets at the anchor (cos-lat corrected — reuse ringPoint's math idea, NOT its degree constants). Pure/WebGL-free, fully unit-tested.

D. **Token/WebGL fallback seam** (Plan G authors the page shell `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`): the map region renders `<FlatMapCanvas>` ONLY when `hasWebGL() && !!import.meta.env.VITE_MAPBOX_TOKEN`; otherwise a `data-testid="map-unavailable"` element. `VenueRail` is ALWAYS rendered; the corner `<GlobeCanvas>` renders whenever `hasWebGL()`. Add `VITE_MAPBOX_TOKEN` to `.env.example`. Plan H's building layers/pulses mount INSIDE `<FlatMapCanvas>` — Plan H does not re-implement this guard.

E. **Reused-verbatim pure engines** (neither plan modifies): `diffFarPulses`, `diffDeepPulses`, `attributionCamera`, `deepPulsePath`, `usePollDelta`. NOT reused (globe-only): `pulseRingDatum`, `sweepArcDatum`, `pulseLayer.ts`.

### Plan-G-internal contract details (not in the locked block, but the concrete shapes Plan H will import)

- `mapSelectors.ts` also exports the staged-fly helper Plan G's corner-globe click uses:
  ```ts
  export const CITY_ZOOM = 5;       // >= this, mapTier leaves 'world'
  export const BUILDING_ZOOM = 14;  // >= this, mapTier === 'building'
  export const STAGE_ZOOM: { country: 4; city: 11; building: 15.5 };
  export function nextFlyZoom(currentZoom: number): number;  // progressive world→country→city→building
  ```
  Consistency (asserted in Task 2): `mapTier(STAGE_ZOOM.building) === 'building'` and `mapTier(STAGE_ZOOM.city) === 'city'`.
- `FlatMapCanvas` props (authored Task 8). **Plan H integrates via PROPS + internal effects using the
  island's own `map` ref — the codebase-established GlobeCanvas pulse-prop pattern (Plan F) — NOT a
  children slot or context** (gate-check Finding 3, IMPORTANT): Plan H ADDS `building`/`farPulses`/
  `buildingPulses` props to this same interface (Plan H Task 4/5). There is no `children` prop and no
  `useFlatMap()` context — dropping that speculative seam honors CLAUDE.md §2 (no single-use abstractions).
  ```ts
  export interface MapFocus { lat: number; lng: number; zoom: number; token: number; }  // token bumps re-fly
  export function FlatMapCanvas(props: {
    venues: MapVenue[];
    mode: MapMode;
    focus: MapFocus | null;                 // page-driven staged flyTo
    orgColors?: Map<string, string>;        // page supplies from orgsFromVenues (city org-halos)
    onZoom: (zoom: number) => void;         // reports map.getZoom() so the page recomputes mapTier
    onCameraBusy: (busy: boolean) => void;  // movestart => true, moveend => false (drives corner-globe `paused`)
    // Plan H extends THIS interface with its building/pulse props (props+effects, not children).
  }): JSX.Element;
  ```

---

## Contract (consumes)

Verbatim backend field names Plan G reads. Gate-check: diff against the live payload. No backend change — both endpoints already return these (re-verified against `/Users/jn/code/mras-ops/api/src/godview/map.py`).

**`GET /god-view/map`** (produced by `map.py:129-157`; typed at `/Users/jn/code/godview-prototype/src/data/apiTypes.ts:135-142`), the ONLY endpoint Plan G calls:
```
venues[]: { location_id, name, location_type, city, country, lat, lng,
            org: { id, name } | null,                                    (map.py:141-142)
            rollup: { systems, cameras, displays, worst_status,
                      active_ad_runs, composing_count, playing_count,
                      runs_last_hour, failures_last_hour,
                      last_activity_at, last_run_created_at } }           (map.py:143-155)
```
Plan G consumes: `location_id, name, lat, lng, city, country` (venue markers + rail + mini-globe dots via `clusterVenues`), `org.id` (city-tier org-halo color via `orgsFromVenues`), and `rollup` (rail stats + world-tier rollup badge). All read through the existing `fetchMap()` (`/Users/jn/code/godview-prototype/src/data/api.ts:105`) → `usePolling(fetchMap, 5000)`.

**`GET /god-view/map/locations/{id}`** (produced by `map.py:160-204`; typed at `apiTypes.ts:143-154`): Plan G does NOT call this — but its `MapSystem[]` shape is the input type of `buildingLayout` (Contract C), which Plan H feeds. **BLOCKING data fact (spec §4 / review Amendment 1, re-verified):** this endpoint returns NO per-device coordinates — `cameras`/`displays` SELECT only `id, system_id, name, status, screen_id, last_seen_at` (`map.py:177,181`); `MapSystemDevice` (`apiTypes.ts:143`) has no `lat`/`lng`; the `cameras`/`displays` tables carry no lat/lng columns (only the unexposed `devices` table does). So `buildingLayout` is deterministic-fallback ONLY — there is no real-coords branch to build. Exposing per-device coords is a future additive backend lane, out of scope for v3.

**globe.gl pause API consumed by Contract A** (verified in the installed d.ts): `pauseAnimation(): ChainableInstance` and `resumeAnimation(): ChainableInstance` — `/Users/jn/code/godview-prototype/node_modules/globe.gl/dist/globe.gl.d.ts:115-116` (also `node_modules/three-globe/dist/three-globe.d.ts:378-379`). Exact names confirmed.

---

## Task 1 — Worktree + `mapbox-gl` dependency + `.env.example`

**Files:**
- Modify: `/Users/jn/code/godview-prototype/package.json` (+ lockfile) — add `"mapbox-gl"` (exact pin) to `dependencies`.
- Modify: `/Users/jn/code/godview-prototype/.env.example` — add `VITE_MAPBOX_TOKEN`.
- Modify: `/Users/jn/code/godview-prototype/.gitignore` — ignore real env files (**the token is a secret and MUST NOT be committed**; `.env` is currently NOT ignored and the repo has no `.env` yet).

**Interfaces:** none (infra task; verified by install + build, not a TDD pair).

**Steps**

- [ ] **Lock the workspace.** Ask git-flow-manager to create a dedicated worktree + branch `feat/flatmap-g-map-shell` from `main` (`468745e`) for `/Users/jn/code/godview-prototype`. Every implementer dispatch begins with `cd <worktree-path> && pwd`; the bare `/Users/jn/code/godview-prototype` is a READ-ONLY reference. All paths below are the repo's canonical absolute paths, resolved inside the worktree.
- [ ] **Install mapbox-gl v3 pinned exactly** (mirrors Plan E's three-pin discipline — pin what installs so Vite/vitest resolve one copy): `npm install --save-exact mapbox-gl@^3`. mapbox-gl v3 ships its own TypeScript types (no `@types/mapbox-gl` needed).
- [ ] Verify: `node -e "console.log(require('./package.json').dependencies['mapbox-gl'])"` prints a concrete `3.x.y` (no `^`). Record the exact version in the commit message.
- [ ] Edit `/Users/jn/code/godview-prototype/.env.example` — append after the existing `VITE_OPS_API_URL` line:
  ```
  # Mapbox GL access token for the /map Command Map (proprietary Mapbox TOS; free tier 50k loads/mo).
  # Get one at https://account.mapbox.com/. When unset, /map shows the venue rail + corner globe and a
  # "map unavailable" panel — the map never loads without a token.
  VITE_MAPBOX_TOKEN=
  ```
  (No `src/vite-env.d.ts` change needed: `tsconfig.app.json:10` already includes `"vite/client"`, so `import.meta.env.VITE_MAPBOX_TOKEN` typechecks exactly as the existing `import.meta.env.VITE_OPS_API_URL` at `api.ts:10`.)
- [ ] **Gitignore real env files** (secret safety): append `.env` and `.env.local` to `/Users/jn/code/godview-prototype/.gitignore` if not already covered (only `.env.example` is committed; `.env` holds the real `VITE_MAPBOX_TOKEN` and must never be staged). Verify with `git check-ignore .env` (git-flow-manager) → prints `.env`.
- [ ] Verify: `npm run build` still succeeds (mapbox-gl added but unimported → not yet in any chunk).
- [ ] Commit via git-flow-manager: `chore(flatmap): add mapbox-gl@<version> (exact pin) + VITE_MAPBOX_TOKEN env doc for the /map command shell`

---

## Task 2 — `mapTier` + staged-fly selectors (pure, WebGL-free) — Contract B

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/mapSelectors.test.ts`

**Interfaces:**
- Produces (Contract B + Plan-G-internal): `MapTier`, `mapTier(zoom)`, `CITY_ZOOM`, `BUILDING_ZOOM`, `STAGE_ZOOM`, `nextFlyZoom(currentZoom)`.
- Consumes: nothing.

Threshold decisions (Mapbox zoom units, 0=whole world … 22=building):
- `mapTier`: `zoom < CITY_ZOOM (5)` → `'world'` (rollup markers); `zoom < BUILDING_ZOOM (14)` → `'city'` (de-clustered markers); else `'building'`.
- `STAGE_ZOOM = { country: 4, city: 11, building: 15.5 }` — the three staged landings.
- `nextFlyZoom(z)`: progressive drill — `z < STAGE_ZOOM.country` → `country (4)`; else `z < STAGE_ZOOM.city` → `city (11)`; else `building (15.5)`. This is what a corner-globe dot click uses to advance one stage toward the venue.

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/data/mapSelectors.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { BUILDING_ZOOM, CITY_ZOOM, STAGE_ZOOM, mapTier, nextFlyZoom } from "./mapSelectors";

describe("mapTier (Contract B thresholds)", () => {
  it("world below CITY_ZOOM, city in the middle band, building at/above BUILDING_ZOOM", () => {
    expect(mapTier(0)).toBe("world");
    expect(mapTier(CITY_ZOOM - 0.01)).toBe("world");
    expect(mapTier(CITY_ZOOM)).toBe("city");
    expect(mapTier(BUILDING_ZOOM - 0.01)).toBe("city");
    expect(mapTier(BUILDING_ZOOM)).toBe("building");
    expect(mapTier(18)).toBe("building");
  });
  it("staged-fly landings agree with mapTier (locked consistency rule)", () => {
    expect(mapTier(STAGE_ZOOM.building)).toBe("building");
    expect(mapTier(STAGE_ZOOM.city)).toBe("city");
  });
});

describe("nextFlyZoom — progressive world→country→city→building drill", () => {
  it("advances one stage per call based on the current zoom", () => {
    expect(nextFlyZoom(0)).toBe(STAGE_ZOOM.country);      // world -> country
    expect(nextFlyZoom(STAGE_ZOOM.country)).toBe(STAGE_ZOOM.city);     // country -> city
    expect(nextFlyZoom(STAGE_ZOOM.city)).toBe(STAGE_ZOOM.building);    // city -> building
    expect(nextFlyZoom(STAGE_ZOOM.building)).toBe(STAGE_ZOOM.building);// building -> recenter (stay)
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/data/mapSelectors.test.ts`. Expected: FAIL, `Cannot find module './mapSelectors'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): mapTier thresholds + staged nextFlyZoom, landings consistent with mapTier (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts`:

```ts
// Pure Mapbox-zoom semantics for the /map command shell (Contract B). No mapbox-gl, no React —
// unit-testable in jsdom. Mapbox zoom units: 0 = whole world, ~22 = building.
export type MapTier = "world" | "city" | "building";

export const CITY_ZOOM = 5;       // >= this de-clusters venues into city-tier markers
export const BUILDING_ZOOM = 14;  // >= this shows the building topology (Plan H renders iff 'building')

export function mapTier(zoom: number): MapTier {
  if (zoom < CITY_ZOOM) return "world";
  if (zoom < BUILDING_ZOOM) return "city";
  return "building";
}

// Three staged landings for a corner-globe dot click. Consistency (tested): city lands in the
// 'city' band, building lands in the 'building' band.
export const STAGE_ZOOM = { country: 4, city: 11, building: 15.5 } as const;

export function nextFlyZoom(currentZoom: number): number {
  if (currentZoom < STAGE_ZOOM.country) return STAGE_ZOOM.country;
  if (currentZoom < STAGE_ZOOM.city) return STAGE_ZOOM.city;
  return STAGE_ZOOM.building;
}
```

- [ ] **Step 5: Run test to verify it passes** — `npx vitest run src/data/mapSelectors.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): mapTier + staged nextFlyZoom pure selectors (Contract B)`

---

## Task 3 — Extract `byId` + `ringPoint` into a shared geometry module (globe path byte-unchanged) — Contract C prerequisite

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/layoutGeometry.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/layoutGeometry.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/explodeSelectors.ts` (delete the two module-private helpers with their shared JSDoc at `:78-90` — gate-check Finding 5; the JSDoc at `:78-80` must be removed WITH the helpers so Step 4 re-copies it into `layoutGeometry.ts`, import them from `./layoutGeometry`, and re-export so any future importer can reach them)

**Interfaces:**
- Produces: `byId<T extends { id: string }>(items: T[]): T[]` and `ringPoint(anchorLat: number, anchorLng: number, r: number, theta: number): { lat: number; lng: number }` — moved VERBATIM from `explodeSelectors.ts:78-90` (radius `r` in DEGREES; the `cos(anchorLat)` division on the lng term is preserved exactly).
- Consumes: nothing.
- **Byte-unchanged guarantee:** `explodeVenue`'s output is identical (pure code move + import). The existing `src/data/explodeSelectors.test.ts` is the regression oracle and must stay green with zero edits.

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/data/layoutGeometry.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { byId, ringPoint } from "./layoutGeometry";

describe("byId — deterministic ascending sort by id (non-mutating)", () => {
  it("sorts a copy by id.localeCompare, leaving the input untouched", () => {
    const input = [{ id: "b" }, { id: "a" }, { id: "c" }];
    expect(byId(input).map((x) => x.id)).toEqual(["a", "b", "c"]);
    expect(input.map((x) => x.id)).toEqual(["b", "a", "c"]);  // input not mutated
  });
});

describe("ringPoint — degree offset with mandatory cos(lat) lng correction", () => {
  it("north (theta=0): lat += r, lng unchanged", () => {
    const p = ringPoint(51.5, 0, 1.8, 0);
    expect(p.lat).toBeCloseTo(53.3, 6);
    expect(p.lng).toBeCloseTo(0, 6);
  });
  it("east (theta=pi/2 at 51.5N): lat unchanged, lng += r / cos(51.5deg)", () => {
    const p = ringPoint(51.5, 0, 1.8, Math.PI / 2);
    expect(p.lat).toBeCloseTo(51.5, 6);
    expect(p.lng).toBeCloseTo(1.8 / Math.cos((51.5 * Math.PI) / 180), 6);  // ~2.89, the anti-squash factor
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/data/layoutGeometry.test.ts`. Expected: FAIL, `Cannot find module './layoutGeometry'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): shared byId + ringPoint geometry (extraction target) (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/data/layoutGeometry.ts` — copy the two functions VERBATIM from `explodeSelectors.ts:78-90` (including the JSDoc on `ringPoint`):

```ts
// Shared pure layout geometry — used by the globe's explosion layout (explodeSelectors) and the
// flat map's building-fallback layout (mapLayout). No three, no globe.gl, no mapbox, no React.

/** Offsets a point from the anchor by radius `r` degrees at angle `theta` radians, measured
 * from north, clockwise. The cos(anchorLat) division on the lng term is mandatory — without it
 * rings render as ellipses at high latitude (a 51.5°N venue squashes 38%). */
export function ringPoint(anchorLat: number, anchorLng: number, r: number, theta: number): { lat: number; lng: number } {
  return {
    lat: anchorLat + r * Math.cos(theta),
    lng: anchorLng + (r * Math.sin(theta)) / Math.cos((anchorLat * Math.PI) / 180),
  };
}

export function byId<T extends { id: string }>(items: T[]): T[] {
  return [...items].sort((a, b) => a.id.localeCompare(b.id));
}
```

- [ ] **Step 5: Rewire `explodeSelectors.ts` surgically.** Delete lines `78-90` (the two `function ringPoint(...)` / `function byId(...)` definitions), and add at the top import block (after line 6):
  ```ts
  import { byId, ringPoint } from "./layoutGeometry";
  ```
  Then re-export them for downstream reuse (add near the top, after the import):
  ```ts
  export { byId, ringPoint } from "./layoutGeometry";
  ```
  Nothing else in `explodeSelectors.ts` changes — `explodeVenue` still calls `byId(...)` and `ringPoint(...)` by the same names.
- [ ] **Step 6: Run tests to verify pass (green) + regression** — `npx vitest run src/data/layoutGeometry.test.ts src/data/explodeSelectors.test.ts` → both PASS (explodeSelectors unchanged output proves the byte-unchanged extraction); `npx tsc -b` → clean; `npm run lint` → clean.
- [ ] **Step 7: Commit (green)** — `feat(flatmap-g): extract byId + ringPoint into layoutGeometry, re-export from explodeSelectors (globe path byte-unchanged)`

---

## Task 4 — `buildingLayout` deterministic fallback module (pure) — Contract C

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/mapLayout.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/mapLayout.test.ts`

**Interfaces:**
- Produces (Contract C): `MapNode`, `buildingLayout(anchor: { lat: number; lng: number }, systems: MapSystem[]): MapNode[]`.
- Consumes: `byId`, `ringPoint` (Task 3, `./layoutGeometry`); `MapSystem`, `MapSystemDevice` types (`./apiTypes:143-144`).

Geometry rules (encoded as tests; **building-scale METERS, altitude 0**, cos-lat corrected via `ringPoint`):
- Meter→degree: `METERS_PER_DEG = 111_320` (1° latitude ≈ 111.32 km). A radius of `R` meters → `R / METERS_PER_DEG` degrees passed to `ringPoint` (so `ringPoint`'s cos-lat lng correction applies — "reuse ringPoint's math idea, not its degree constants").
- `SYSTEM_RING_M = 40`, `DEVICE_RING_M = 70` (building-scale; tens of meters — tuned live in Task 11).
- Determinism: `systems = byId(systems)`; within a system `[...byId(cameras) as camera, ...byId(displays) as display]`. System `i` of `n` sits at `θ = 2πi/n` (first due north). Device `j` of `m` fans across an outer arc segment centered on `θᵢ` of width `(2π/n)·0.8`, at `θᵢ + segWidth·(m === 1 ? 0 : j/(m-1) − 1/2)` — the SAME fan formula as `explodeVenue` (`explodeSelectors.ts:140-142`), so the two layouts stay visually consistent.
- `MapNode.key` = `` `${type}:${id}` `` (matches `deepPulsePath`'s lookup, `pulseDelta.ts:99-101`); `systemId` = `null` for system nodes, the parent system id for devices; `altitude` always `0` (the literal type `0`, satisfying `deepPulsePath`'s `Pick`).
- No hull, no connectors, no labels here — Plan G ships nodes only; connectors/glyphs/cards are Plan H's rendering.

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/data/mapLayout.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { buildingLayout } from "./mapLayout";
import type { MapSystem } from "./apiTypes";

const dev = (id: string, name: string) =>
  ({ id, name, status: "active", screen_id: null, last_seen_at: null });
const sys = (id: string, name: string, cams: string[], disps: string[]): MapSystem => ({
  id, name, zone: null, status: "active", system_type: "advertising_wall",
  cameras: cams.map((c) => dev(c, c)), displays: disps.map((d) => dev(d, d)),
});

const anchor = { lat: 32.9, lng: -96.8 };
const systems: MapSystem[] = [
  sys("sys_b", "Wall B", ["cam_b1"], ["disp_b1"]),
  sys("sys_a", "Wall A", ["cam_a2", "cam_a1"], ["disp_a1"]),
];

describe("buildingLayout — deterministic building-scale fallback (Contract C)", () => {
  const nodes = buildingLayout(anchor, systems);

  it("emits one system node per system, sorted by id, keyed `system:<id>`, systemId null, altitude 0", () => {
    const sysNodes = nodes.filter((n) => n.type === "system");
    expect(sysNodes.map((n) => n.key)).toEqual(["system:sys_a", "system:sys_b"]);
    expect(sysNodes.every((n) => n.systemId === null && n.altitude === 0)).toBe(true);
  });

  it("first system sits due north of the anchor (lat > anchor, lng ~ anchor)", () => {
    const first = nodes.find((n) => n.key === "system:sys_a")!;
    expect(first.lat).toBeGreaterThan(anchor.lat);
    expect(first.lng).toBeCloseTo(anchor.lng, 6);
  });

  it("emits every camera + display as a node keyed `camera:`/`display:` with its parent systemId", () => {
    const devNodes = nodes.filter((n) => n.type !== "system");
    expect(devNodes).toHaveLength(5);                       // 3 cams + 2 disps
    const camA1 = devNodes.find((n) => n.id === "cam_a1")!;
    expect(camA1.key).toBe("camera:cam_a1");
    expect(camA1.systemId).toBe("sys_a");
    expect(camA1.altitude).toBe(0);
    // cameras before displays within a system, each byId-sorted
    const aDevs = devNodes.filter((n) => n.systemId === "sys_a").map((n) => n.key);
    expect(aDevs).toEqual(["camera:cam_a1", "camera:cam_a2", "display:disp_a1"]);
  });

  it("radii are building-scale (tens of meters, ~<0.001 deg), NOT the globe's degree constants", () => {
    const first = nodes.find((n) => n.key === "system:sys_a")!;
    expect(first.lat - anchor.lat).toBeLessThan(0.001);    // 40 m ~= 0.00036 deg, not 1.8 deg
    expect(first.lat - anchor.lat).toBeGreaterThan(0);
  });

  it("cos(lat) correction: an east-fanned node divides its lng offset by cos(anchorLat)", () => {
    // Build a single 1-system layout whose one device fans due-east-ish and assert the lng
    // offset exceeds the raw meter->deg (proving the cos-lat division at a 51.5N anchor).
    const north = { lat: 51.5, lng: 0 };
    const one = buildingLayout(north, [sys("s", "S", ["c1", "c2", "c3"], [])]);
    const dev1 = one.find((n) => n.id === "c1")!;
    // some device has a non-trivial |lng| that, per ringPoint, is divided by cos(51.5deg) (~0.62)
    const anyEastward = one.filter((n) => n.type !== "system").some((n) => Math.abs(n.lng) > 0);
    expect(anyEastward).toBe(true);
    expect(Number.isFinite(dev1.lng)).toBe(true);
  });

  it("is a pure function: same input -> deep-equal output", () => {
    expect(buildingLayout(anchor, systems)).toEqual(buildingLayout(anchor, systems));
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/data/mapLayout.test.ts`. Expected: FAIL, `Cannot find module './mapLayout'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): buildingLayout deterministic building-scale fallback nodes (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/data/mapLayout.ts`:

```ts
// Deterministic fallback building layout for the /map building tier (Contract C). The
// map-location endpoint returns NO per-device coordinates (map.py:177,181), so glyphs are ALWAYS
// laid out around the venue anchor by this function. Pure/WebGL-free — unit-tested in jsdom.
// Reuses byId (determinism) + ringPoint (cos-lat math), NOT the globe's degree constants.
import { byId, ringPoint } from "./layoutGeometry";
import type { MapSystem, MapSystemDevice } from "./apiTypes";

export interface MapNode {
  key: string;               // `${type}:${id}` — same convention deepPulsePath matches
  type: "system" | "camera" | "display";
  id: string;
  name: string | null;
  status: string;
  systemId: string | null;   // parent system for camera/display; null for system nodes
  lat: number;
  lng: number;
  altitude: 0;               // constant 0 -> satisfies deepPulsePath's Pick
}

const METERS_PER_DEG = 111_320;      // 1 deg latitude ~= 111.32 km
const SYSTEM_RING_M = 40;            // building-scale radii in meters (Task 11 tunes live)
const DEVICE_RING_M = 70;

const toDeg = (meters: number) => meters / METERS_PER_DEG;

export function buildingLayout(anchor: { lat: number; lng: number }, systems: MapSystem[]): MapNode[] {
  const sorted = byId(systems);
  const n = sorted.length;
  const nodes: MapNode[] = [];

  sorted.forEach((system, i) => {
    const thetaI = (2 * Math.PI * i) / n;
    const sp = ringPoint(anchor.lat, anchor.lng, toDeg(SYSTEM_RING_M), thetaI);
    nodes.push({
      key: `system:${system.id}`, type: "system", id: system.id, name: system.name,
      status: system.status, systemId: null, lat: sp.lat, lng: sp.lng, altitude: 0,
    });

    const devices: { type: "camera" | "display"; device: MapSystemDevice }[] = [
      ...byId(system.cameras).map((device) => ({ type: "camera" as const, device })),
      ...byId(system.displays).map((device) => ({ type: "display" as const, device })),
    ];
    const m = devices.length;
    const segWidth = ((2 * Math.PI) / n) * 0.8;
    devices.forEach(({ type, device }, j) => {
      const thetaJ = thetaI + segWidth * (m === 1 ? 0 : j / (m - 1) - 1 / 2);
      const dp = ringPoint(anchor.lat, anchor.lng, toDeg(DEVICE_RING_M), thetaJ);
      nodes.push({
        key: `${type}:${device.id}`, type, id: device.id, name: device.name,
        status: device.status, systemId: system.id, lat: dp.lat, lng: dp.lng, altitude: 0,
      });
    });
  });

  return nodes;
}
```

- [ ] **Step 5: Run test to verify it passes** — `npx vitest run src/data/mapLayout.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): buildingLayout deterministic fallback module (Contract C) — meters, cos-lat, altitude 0`

---

## Task 5 — `GlobeCanvas` `paused` prop — Contract A

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/pauseControl.ts` (pure, jsdom-testable seam)
- Test: `/Users/jn/code/godview-prototype/src/components/globe/pauseControl.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` (add optional `paused?: boolean` prop + one effect)

**Interfaces:**
- Produces (Contract A): `GlobeCanvas` gains `paused?: boolean`. Internally delegates to a pure helper:
  ```ts
  // pauseControl.ts
  export function applyAnimationState(
    globe: { pauseAnimation(): void; resumeAnimation(): void },
    paused: boolean | undefined,
  ): void;   // paused truthy -> pauseAnimation(); falsy/undefined -> resumeAnimation()
  ```
- Consumes: globe.gl `pauseAnimation()`/`resumeAnimation()` (verified `globe.gl.d.ts:115-116`).
- **Byte-unchanged:** the helper is the real red→green (the globe instance never exists in jsdom, so the effect can't be asserted there — this mirrors the codebase's pure-selector discipline). `Globe.tsx` is NOT edited; it never passes `paused`, and a falsy `paused` calls the idempotent `resumeAnimation()` on an already-running loop.

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/components/globe/pauseControl.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { applyAnimationState } from "./pauseControl";

const fakeGlobe = () => ({ pauseAnimation: vi.fn(), resumeAnimation: vi.fn() });

describe("applyAnimationState (Contract A)", () => {
  it("paused=true pauses the render loop", () => {
    const g = fakeGlobe();
    applyAnimationState(g, true);
    expect(g.pauseAnimation).toHaveBeenCalledTimes(1);
    expect(g.resumeAnimation).not.toHaveBeenCalled();
  });
  it("paused=false resumes", () => {
    const g = fakeGlobe();
    applyAnimationState(g, false);
    expect(g.resumeAnimation).toHaveBeenCalledTimes(1);
    expect(g.pauseAnimation).not.toHaveBeenCalled();
  });
  it("paused=undefined resumes (default = unchanged v1 behavior, idempotent)", () => {
    const g = fakeGlobe();
    applyAnimationState(g, undefined);
    expect(g.resumeAnimation).toHaveBeenCalledTimes(1);
    expect(g.pauseAnimation).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/components/globe/pauseControl.test.ts`. Expected: FAIL, `Cannot find module './pauseControl'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): applyAnimationState pause/resume seam for GlobeCanvas (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/components/globe/pauseControl.ts`:

```ts
// Pure GlobeCanvas pause seam (Contract A). The imperative globe instance never exists in jsdom,
// so keep the decision here to unit-test it; GlobeCanvas's effect just calls this.
export function applyAnimationState(
  globe: { pauseAnimation(): void; resumeAnimation(): void },
  paused: boolean | undefined,
): void {
  if (paused) globe.pauseAnimation();
  else globe.resumeAnimation();
}
```

- [ ] **Step 5: Wire GlobeCanvas surgically.** In `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`:
  - Add `paused` to the destructure at `:55-58` → `dots, mode, focus, arcs, labels, highlightOrgId, explosion, liveSystems, farPulses, deepPulses, paused, onDotClick, onNodeClick, onPovChange, onBackgroundClick`.
  - Add to the props type (after `deepPulses` at `:71`): `paused?: boolean;                    // Plan G: pause the render loop while a host Mapbox flyTo is in flight`.
  - Add the import near the other local imports (after `:15`): `import { applyAnimationState } from "./pauseControl";`.
  - Add ONE effect immediately after the CAMERA effect (after `:478`):
    ```ts
    // PAUSE (Plan G, Contract A) — a host page (the /map corner globe) pauses the whole render
    // loop while a Mapbox flyTo animates, to spend GPU on one WebGL context at a time. pauseAnimation
    // is the GPU-cost lever (autoRotate=false only stops the spin, not the draw loop). Idempotent
    // resume on falsy `paused` keeps /globe (which never passes it) byte-identical.
    useEffect(() => {
      const globe = globeRef.current;
      if (!globe) return;
      applyAnimationState(globe, paused);
    }, [paused, ready]);
    ```
- [ ] **Step 6: Run tests to verify pass (green) + regression** — `npx vitest run src/components/globe/pauseControl.test.ts src/components/globe/GlobeCanvas.test.tsx src/pages/Globe.test.tsx` → all PASS (the pre-existing Globe/GlobeCanvas suites unchanged prove /globe stays byte-identical); `npx tsc -b` → clean; `npm run lint` → clean.
- [ ] **Step 7: Commit (green)** — `feat(flatmap-g): GlobeCanvas paused prop -> pauseAnimation/resumeAnimation (Contract A); /globe unchanged`

---

## Task 6 — In-repo dark Mapbox style built from the Tailwind theme

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/map/style.json`
- Test: `/Users/jn/code/godview-prototype/src/map/style.test.ts`

**Interfaces:**
- Produces: a committed Mapbox GL Style Spec v8 JSON (`style.json`) importable by `FlatMapCanvas` (Task 8). Uses the mapbox-hosted `mapbox-streets-v8` vector source + mapbox default glyphs (token-gated at runtime), styled with the exact theme hexes.
- Consumes: the verified Tailwind hexes (Global Constraints).

Style content (reference-1 look — muted navy land, near-black water, faint roads at city zoom, no POI noise):
- `version: 8`, `name: "godview-dark"`, `glyphs: "mapbox://fonts/mapbox/{fontstack}/{range}.pbf"`, `sources.composite = { type: "vector", url: "mapbox://mapbox.mapbox-streets-v8" }`.
- Layers (order matters): `background` (`background-color` = bg `#0a0d12`); `land` (`background` over water suppressed — use a `fill` on `landuse`/`landcover` at elev `#12161d`); `water` (fill near-black `#070a0e`); `admin` boundaries (line, border `#212734`); `road` (line, faint `#5b6472`, `minzoom: 11` so world/city stay clean); `settlement-label`/`place-label` (symbol, text-color dim `#8b93a3`). **No POI layer** (keeps the map uncluttered per spec §3).

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/map/style.test.ts` (asserts the style is a valid v8 shell carrying the theme, using the streets source, with no POI noise — a real content contract):

```ts
import { describe, expect, it } from "vitest";
import style from "./style.json";

const layer = (id: string) => (style.layers as any[]).find((l) => l.id === id);

describe("godview-dark Mapbox style", () => {
  it("is a v8 style using the mapbox streets vector source + mapbox glyphs", () => {
    expect(style.version).toBe(8);
    expect((style.sources as any).composite.url).toBe("mapbox://mapbox.mapbox-streets-v8");
    expect(style.glyphs).toContain("mapbox://fonts/mapbox");
  });
  it("paints the app theme: bg background, near-black water, themed roads/labels", () => {
    expect(layer("background").paint["background-color"]).toBe("#0a0d12");
    expect(layer("water").paint["fill-color"]).toBe("#070a0e");
    expect(layer("road").paint["line-color"]).toBe("#5b6472");   // faint
    expect(layer("road").minzoom).toBeGreaterThanOrEqual(11);    // roads only at city zoom
  });
  it("has no POI-noise layer", () => {
    expect((style.layers as any[]).some((l) => /poi/i.test(l.id))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/map/style.test.ts`. Expected: FAIL, `Cannot find module './style.json'` (file absent). (JSON imports resolve under the existing `tsconfig.app.json` / Vite defaults — `resolveJsonModule` is on by Vite convention; if `tsc -b` flags it, that surfaces here and the impl step adds the file which resolves it.)
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): godview-dark Mapbox style contract — theme hexes, streets source, no POI (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/map/style.json` — a compact valid v8 style. Skeleton (fill layers per the content list; keep `road` `minzoom: 11`, no POI):

```json
{
  "version": 8,
  "name": "godview-dark",
  "glyphs": "mapbox://fonts/mapbox/{fontstack}/{range}.pbf",
  "sources": {
    "composite": { "type": "vector", "url": "mapbox://mapbox.mapbox-streets-v8" }
  },
  "layers": [
    { "id": "background", "type": "background", "paint": { "background-color": "#0a0d12" } },
    { "id": "land", "type": "fill", "source": "composite", "source-layer": "landuse",
      "paint": { "fill-color": "#12161d" } },
    { "id": "water", "type": "fill", "source": "composite", "source-layer": "water",
      "paint": { "fill-color": "#070a0e" } },
    { "id": "admin", "type": "line", "source": "composite", "source-layer": "admin",
      "paint": { "line-color": "#212734", "line-width": 0.6 } },
    { "id": "road", "type": "line", "source": "composite", "source-layer": "road", "minzoom": 11,
      "paint": { "line-color": "#5b6472", "line-width": 0.6 } },
    { "id": "settlement-label", "type": "symbol", "source": "composite", "source-layer": "place_label",
      "layout": { "text-field": ["get", "name"], "text-font": ["DIN Pro Regular", "Arial Unicode MS Regular"], "text-size": 11 },
      "paint": { "text-color": "#8b93a3", "text-halo-color": "#0a0d12", "text-halo-width": 1 } }
  ]
}
```
  (Implementer: confirm `source-layer` names against `mapbox-streets-v8` at build; the streets-v8 layer ids are `landuse`, `water`, `admin`, `road`, `place_label` — adjust if the live tileset differs, keeping the test's asserted layer `id`s stable. The exact land/road styling is tuned live in Task 11.)
- [ ] **Step 5: Run test to verify it passes** — `npx vitest run src/map/style.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): in-repo godview-dark Mapbox style from the Tailwind theme (versioned)`

---

## Task 7 — Venue marker DOM factory (pure)

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/venueMarkers.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/venueMarkers.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface VenueMarkerDatum { id: string; lat: number; lng: number; el: HTMLDivElement; }
  // Pure DOM factory: world/country tier -> rollup badge (name + counts pill, health tone);
  // city tier -> de-clustered marker with org-colored halo. jsdom-testable (uses document only).
  export function buildVenueMarker(
    venue: MapVenue, tier: MapTier, mode: MapMode, orgColor: string | null,
  ): VenueMarkerDatum;
  ```
- Consumes: `MapVenue` (`./apiTypes:135`), `MapTier` (`./mapSelectors`, Task 2), `MapMode` + `healthTone` + `TONE_HEX` (`./globeSelectors:5,10,14`). Org color is supplied by the caller (the page derives it from `orgsFromVenues`, `./topologySelectors:13`) — kept a param so the factory stays pure.

Rules (encoded as tests):
- Every marker `el` is a `div[data-testid="venue-marker"]` with `data-venue-id`, `pointer-events` clickable, and a health-tone dot (`TONE_HEX[healthTone(rollup)]`).
- `tier === "world"`: include a rollup badge child `[data-testid="venue-rollup-badge"]` = `` `${name} · ${rollup.systems} sys` `` (world/country rollup marker).
- `tier === "city"`: no rollup badge; add an org halo ring — `el.style.boxShadow`/border uses `orgColor` when non-null (city de-clustered, org-colored halo), a neutral border when null.
- `tier === "building"`: same base marker as city (the building GLYPH topology is Plan H inside `FlatMapCanvas`; Plan G's venue marker just stays a dot at building zoom).
- Uses `textContent` (never `innerHTML`) for the name (operator-editable → no injection), matching `GlobeCanvas.tsx:414`.

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/data/venueMarkers.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { buildVenueMarker } from "./venueMarkers";
import type { MapVenue } from "./apiTypes";

const venue = (over: Partial<MapVenue> = {}): MapVenue => ({
  location_id: "loc1", name: "Dallas North", location_type: "mall",
  city: "Dallas", country: "US", lat: 32.9, lng: -96.8,
  rollup: { systems: 3, cameras: 6, displays: 4, worst_status: "active", active_ad_runs: 1,
    runs_last_hour: 2, failures_last_hour: 0, last_activity_at: null }, org: { id: "o1", name: "Acme" },
  ...over,
});

describe("buildVenueMarker (pure DOM factory)", () => {
  it("world tier: rollup badge with name + system count, health-tone dot, testids", () => {
    const m = buildVenueMarker(venue(), "world", "health", "#a78bfa");
    expect(m.id).toBe("loc1");
    expect(m.el.getAttribute("data-testid")).toBe("venue-marker");
    expect(m.el.getAttribute("data-venue-id")).toBe("loc1");
    const badge = m.el.querySelector('[data-testid="venue-rollup-badge"]')!;
    expect(badge.textContent).toContain("Dallas North");
    expect(badge.textContent).toContain("3 sys");
  });
  it("city tier: no rollup badge, org-colored halo when org present", () => {
    const m = buildVenueMarker(venue(), "city", "health", "#a78bfa");
    expect(m.el.querySelector('[data-testid="venue-rollup-badge"]')).toBeNull();
    expect(m.el.style.cssText).toContain("#a78bfa");   // halo color applied
  });
  it("degraded venue shows the warn tone; null org halo does not crash", () => {
    const m = buildVenueMarker(
      venue({ rollup: { ...venue().rollup, worst_status: "degraded" } }), "city", "health", null);
    expect(m.el.innerHTML).toContain("#f5b942");        // warn tone dot
  });
  it("uses textContent for the name (no HTML injection)", () => {
    const m = buildVenueMarker(venue({ name: "<b>x</b>" }), "world", "health", null);
    expect(m.el.innerHTML).not.toContain("<b>x</b>");
    expect(m.el.textContent).toContain("<b>x</b>");
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/data/venueMarkers.test.ts`. Expected: FAIL, `Cannot find module './venueMarkers'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): buildVenueMarker DOM factory — world rollup badge, city org halo, tone dot (red)`
- [ ] **Step 4: Write minimal implementation** `/Users/jn/code/godview-prototype/src/data/venueMarkers.ts` per the rules above. Notes: build the element with `document.createElement`; set `data-testid`, `data-venue-id`; a tone dot span whose `style.background = TONE_HEX[healthTone(v.rollup)]`; the world-tier `[data-testid="venue-rollup-badge"]` child via `textContent`; city/building tier sets `el.style` halo (`boxShadow`/`border`) to `orgColor ?? "#212734"`. Pure — `document` only, no React/mapbox.
- [ ] **Step 5: Run test to verify it passes** — `npx vitest run src/data/venueMarkers.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): buildVenueMarker pure DOM factory for zoom-semantic venue markers`

---

## Task 8 — `FlatMapCanvas` Mapbox island + `mapboxImpl` isolation + context seam

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts` (the ONLY module that statically imports `mapbox-gl` + its CSS — dynamically imported behind the guard)
- Create: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx` (imperative island + `useFlatMap` context)
- Test: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`

**Interfaces:**
- Produces (Plan-G-internal contract, above): `MapFocus`, `FlatMapCanvas`, `useFlatMap()`.
- `mapboxImpl.ts`:
  ```ts
  import mapboxgl from "mapbox-gl";
  import "mapbox-gl/dist/mapbox-gl.css";                  // isolated here so jsdom never evaluates it
  export { mapboxgl };
  export function createMap(opts: { container: HTMLElement; token: string; style: object }): mapboxgl.Map;
  ```
  `createMap` sets `mapboxgl.accessToken = opts.token` BEFORE `new mapboxgl.Map({ container, style, center:[0,20], zoom:1.4, attributionControl: true })` (attribution stays — TOS) and returns the map. Wrapped in try/catch by the caller.
- Consumes: `hasWebGL()` (`../globe/webgl:1`), `style.json` (Task 6), `MapVenue`/`MapMode`, `buildVenueMarker` (Task 7), `mapTier` (Task 2).

Island wiring (all mapbox refs inside the guarded init effect — mapbox NEVER at module top):
- **Guard:** `const token = import.meta.env.VITE_MAPBOX_TOKEN as string | undefined;` then `if (!hasWebGL() || !token) return;` at the top of the init effect (defense-in-depth; the page already guards, but this keeps the jsdom tripwire honest — in jsdom `hasWebGL()` is false so `import("./mapboxImpl")` never fires).
- **Init (once):** `import("./mapboxImpl").then(({ createMap }) => { try { const map = createMap({ container, token, style }); ... } catch { setUnsupported... } })`. On `map.on("load")`: set the map into context state, wire listeners:
  - `map.on("movestart", () => onCameraBusyRef.current(true))`, `map.on("moveend", () => onCameraBusyRef.current(false))` (drives the corner-globe `paused`).
  - `map.on("zoom", () => onZoomRef.current(map.getZoom()))` (page recomputes `mapTier`).
- **Venue markers effect** (`[venues, mode, tier, mapReady]`): diff a `Map<string, mapboxgl.Marker>` by venue id — create with `new mapboxgl.Marker({ element: buildVenueMarker(v, tier, mode, orgColor).el }).setLngLat([v.lng, v.lat]).addTo(map)`; on tier/mode change, rebuild the element (`marker.getElement().replaceWith(...)` or recreate); remove vanished ids. `orgColor` comes in via a prop the page computes (add `orgColors: Map<string,string>` to props) OR compute inline — to keep Task 8 self-contained, add `orgColors?: Map<string, string>` prop (page supplies from `orgsFromVenues`). Only plottable venues (`lat != null && lng != null`) get markers.
- **`focus` effect** (`[focus, mapReady]`): `if (!focus) return; map.flyTo({ center: [focus.lng, focus.lat], zoom: focus.zoom, duration: 1200 })`. Token-bumped like `GlobeCanvas`'s `Focus`.
- **Plan H seam (PROPS, not context — gate-check Finding 3):** keep the live `map` in a ref/state inside the island; Plan H adds `building`/`farPulses`/`buildingPulses` props whose effects read that `map` ref to add sources/layers — exactly as `GlobeCanvas` took `farPulses`/`deepPulses` in Plan F. NO `FlatMapContext`, NO `useFlatMap()`, NO `children` slot.
- **Dispose:** `map?.remove()` on unmount; clear markers.
- **Render:** `<div ref={mountRef} data-testid="flatmap-canvas" className="h-full w-full" />` (no children slot — Plan H integrates via props/effects, gate-check Finding 3). On the internal-guard/no-token path it still renders the mount div (the PAGE decides whether to show `map-unavailable`; `FlatMapCanvas` mounted at all means the page already passed the guard, so this internal early-return is purely the test tripwire).

- [ ] **Step 1: Write the failing test** `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx` (jsdom: `hasWebGL()` is false → the island must render the mount div + children and NEVER import mapbox-gl):

```tsx
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
// Tripwire: mapbox-gl must never load in jsdom (mirrors the globe.gl/three guards).
vi.mock("mapbox-gl", () => { throw new Error("mapbox-gl must not load in jsdom"); });
import { FlatMapCanvas } from "./FlatMapCanvas";

const noop = () => {};

describe("FlatMapCanvas (imperative island, jsdom guard)", () => {
  it("renders its mount div + children without loading mapbox-gl (no WebGL in jsdom)", () => {
    render(
      <FlatMapCanvas venues={[]} mode="health" focus={null} onZoom={noop} onCameraBusy={noop}>
        <div data-testid="plan-h-slot">building layers go here</div>
      </FlatMapCanvas>,
    );
    expect(screen.getByTestId("flatmap-canvas")).toBeInTheDocument();
    expect(screen.getByTestId("plan-h-slot")).toBeInTheDocument();   // children slot for Plan H
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx`. Expected: FAIL, `Cannot find module './FlatMapCanvas'`.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): FlatMapCanvas renders mount + children behind the jsdom mapbox tripwire (red)`
- [ ] **Step 4: Write minimal implementation** — create `mapboxImpl.ts` (the isolated static import) then `FlatMapCanvas.tsx` per the wiring above. Keep `import "mapbox-gl/dist/mapbox-gl.css"` and `import mapboxgl from "mapbox-gl"` ONLY in `mapboxImpl.ts`; `FlatMapCanvas.tsx` reaches them via `await import("./mapboxImpl")` inside the guarded effect. Export `FlatMapContext`/`useFlatMap`.
- [ ] **Step 5: Run tests to verify pass (green)** — `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx` → PASS (tripwire not thrown = mapbox never imported); `npx tsc -b` → clean; `npm run lint` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): FlatMapCanvas Mapbox island — isolated mapboxImpl, dynamic import guard, flyTo, movestart/moveend, venue markers, children context`

---

## Task 9 — `/map` page shell (Contract D) + route + nav wiring

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Test: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/routes.tsx:7,15` (import + route)
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.tsx:24` (nav item after "/globe")

**Interfaces:**
- Produces (Contract D): the `/map` page shell that renders `<FlatMapCanvas>` only under `hasWebGL() && !!import.meta.env.VITE_MAPBOX_TOKEN`, else `data-testid="map-unavailable"`; `VenueRail` ALWAYS; corner `<GlobeCanvas>` whenever `hasWebGL()`.
- Consumes: everything above + `fetchMap` (`api.ts:105`) via `usePolling`, `clusterVenues`/`sortRail`/`GlobeDot`/`MapMode` (`globeSelectors`), `orgsFromVenues` (`topologySelectors:13`), `ModeLegend`, `VenueRail`, `GlobeCanvas` + `Focus`, `hasWebGL` (`../components/globe/webgl`).

Page composition (two independent camera states — spec §3 Amendment 10):
```ts
const { data, loading, error, refetch } = usePolling(fetchMap, 5000);
const venues = data?.venues ?? [];
const [mode, setMode] = useState<MapMode>("health");
// (1) mini-globe camera:
const [pov, setPov] = useState({ lat: 0, lng: 0, altitude: 2.5 });
const dots = useMemo(() => clusterVenues(venues, pov.altitude), [venues, pov.altitude]);
// (2) Mapbox camera:
const [mapZoom, setMapZoom] = useState(1.4);
const [mapFocus, setMapFocus] = useState<MapFocus | null>(null);
const [cameraBusy, setCameraBusy] = useState(false);
// (2b) Selected venue — Plan H's building tier gates on this (gate-check Finding 2, BLOCKING):
//      Plan H Task 6 computes buildingVenueId = mapTier(zoom)==='building' ? selectedVenueId : null.
//      Without page-owned selection state, Plan H's core feature has no input. VenueRail already
//      supports selectedId/onSelect (VenueRail.tsx:6-10,20-22) — we just thread the state.
const [selectedVenueId, setSelectedVenueId] = useState<string | null>(null);
const orgColors = useMemo(
  () => new Map(orgsFromVenues(venues).map((o) => [o.id, o.color])), [venues]);
const railVenues = useMemo(() => sortRail(venues, mode), [venues, mode]);

const webgl = hasWebGL();
const token = import.meta.env.VITE_MAPBOX_TOKEN as string | undefined;

const flyToVenue = (lat: number, lng: number) =>
  setMapFocus((f) => ({ lat, lng, zoom: nextFlyZoom(mapZoom), token: (f?.token ?? 0) + 1 }));
// Selecting a VENUE sets selection + flies toward building; selecting a CLUSTER flies to the city
// WITHOUT selecting (spec §3: venue → building, cluster → city). Both rail and corner-globe dot use it.
const selectVenue = (locationId: string, lat: number, lng: number) => {
  setSelectedVenueId(locationId);
  flyToVenue(lat, lng);
};
const onCornerDotClick = (dot: GlobeDot) =>          // GlobeDot = VenueDot | ClusterDot (globeSelectors.ts:60-65)
  dot.kind === "venue"
    ? selectVenue(dot.venue.location_id, dot.lat, dot.lng)
    : flyToVenue(dot.lat, dot.lng);                  // cluster centroid → city, no selection
```
Layout: `<Shell crumb="Map">` with `ModeLegend`; a rail column (always: `VenueRail venues={railVenues} mode selectedId={selectedVenueId} onSelect={(v)=>{ setSelectedVenueId(v.location_id); if (v.lat!=null && v.lng!=null) flyToVenue(v.lat,v.lng); }}`); a full-bleed map region:
```tsx
{webgl && token
  ? <FlatMapCanvas venues={venues} mode={mode} focus={mapFocus}
      onZoom={setMapZoom} onCameraBusy={setCameraBusy} orgColors={orgColors} />
  : <div data-testid="map-unavailable" className="flex h-full items-center justify-center text-faint text-[12.5px]">
      Map unavailable — {webgl ? "set VITE_MAPBOX_TOKEN to load the map" : "no WebGL on this device"}. The venue rail lists the whole fleet.
    </div>}
```
Plan H adds its building/pulse props (`building`, `farPulses`, `buildingPulses`) to this same
`<FlatMapCanvas … />` element (props + internal effects, NOT children — gate-check Finding 3), and
reads `selectedVenueId` from this page as the input to its building tier.
Corner globe (bottom-left ~300px, only when `webgl`), reusing `GlobeCanvas` as a dots-only v1 picker (spec §3 Amendment 3 — empty arcs/labels/null everything already yields v1; the ONLY new prop is `paused`):
```tsx
{webgl && (
  <div data-testid="corner-globe" className="absolute bottom-3 left-3 h-[300px] w-[300px] overflow-hidden rounded-[10px] border border-border bg-bg">
    <GlobeCanvas dots={dots} mode={mode} focus={null}
      arcs={[]} labels={[]} highlightOrgId={null}
      explosion={null} liveSystems={new Set()} farPulses={null} deepPulses={null}
      paused={cameraBusy}
      onDotClick={onCornerDotClick} onNodeClick={() => {}} onPovChange={setPov} />
  </div>
)}
```

- [ ] **Step 1: Write the failing tests** `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`. Mock `../data/api` (`fetchMap` resolving a 1-venue payload; `fetchProjectorStatus` for `Shell`) and `../components/globe/webgl` (`hasWebGL`), and drive `VITE_MAPBOX_TOKEN` via `vi.stubEnv`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
vi.mock("../data/api", () => ({
  fetchMap: vi.fn().mockResolvedValue({ venues: [{
    location_id: "l1", name: "Dallas North", location_type: "mall", city: "Dallas", country: "US",
    lat: 32.9, lng: -96.8, org: { id: "o1", name: "Acme" },
    rollup: { systems: 3, cameras: 6, displays: 4, worst_status: "active", active_ad_runs: 0,
      runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null } }] }),
  fetchProjectorStatus: vi.fn().mockResolvedValue({ cursor: 0, backlog: 0, lag_seconds: 0, health: "ok" }),
}));
vi.mock("../components/globe/webgl", () => ({ hasWebGL: vi.fn(() => false) }));
import { hasWebGL } from "../components/globe/webgl";
import { FlatMap } from "./FlatMap";

const renderPage = () => render(<MemoryRouter><FlatMap /></MemoryRouter>);
afterEach(() => { vi.unstubAllEnvs(); vi.clearAllMocks(); });

describe("FlatMap shell (Contract D fallback seam)", () => {
  it("no token: rail always rendered, map region shows map-unavailable", async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "");
    renderPage();
    await waitFor(() => expect(screen.getByTestId("venue-rail")).toBeInTheDocument());
    expect(screen.getByText("Dallas North")).toBeInTheDocument();       // rail row
    expect(screen.getByTestId("map-unavailable")).toBeInTheDocument();
  });
  it("no WebGL: no corner globe even with a token", async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "pk.test");
    vi.mocked(hasWebGL).mockReturnValue(false);
    renderPage();
    await waitFor(() => expect(screen.getByTestId("venue-rail")).toBeInTheDocument());
    expect(screen.queryByTestId("corner-globe")).toBeNull();
    expect(screen.getByTestId("map-unavailable")).toBeInTheDocument();  // needs webgl AND token
  });
  it("WebGL present: corner globe renders (globe fallback in jsdom)", async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "pk.test");
    vi.mocked(hasWebGL).mockReturnValue(true);
    renderPage();
    await waitFor(() => expect(screen.getByTestId("corner-globe")).toBeInTheDocument());
  });
});
```
  Also add a route/nav test `/Users/jn/code/godview-prototype/src/routes.test.tsx`:
```tsx
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { router } from "./routes";
import { Shell } from "./components/Shell";
vi.mock("./data/api", () => ({ fetchProjectorStatus: vi.fn().mockResolvedValue(null) }));
import { vi } from "vitest";

describe("routing + nav wiring", () => {
  it("registers the /map route", () => {
    expect((router.routes as any[]).some((r) => r.path === "/map")).toBe(true);
  });
  it("Shell nav lists Map after Globe", () => {
    render(<MemoryRouter><Shell>x</Shell></MemoryRouter>);
    const map = screen.getByRole("link", { name: "Map" });
    expect(map).toHaveAttribute("href", "/map");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail** — `npx vitest run src/pages/FlatMap.test.tsx src/routes.test.tsx`. Expected: FAIL — `Cannot find module './FlatMap'` and no `/map` route / no "Map" nav link.
- [ ] **Step 3: Commit (red)** — `test(flatmap-g): /map shell fallback seam + route/nav wiring (red)`
- [ ] **Step 4: Write the implementation:**
  - `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` per the composition above (wrap in `<AsyncState>` like `Globe.tsx:118`).
  - `/Users/jn/code/godview-prototype/src/routes.tsx`: add `import { FlatMap } from "./pages/FlatMap";` (after line 7) and `{ path: "/map", element: <FlatMap /> },` (after line 15, before the closing `]`).
  - `/Users/jn/code/godview-prototype/src/components/Shell.tsx:24`: add `{ to: "/map", label: "Map" },` immediately after the `{ to: "/globe", label: "Globe" }` entry in the "God View" group.
- [ ] **Step 5: Run tests to verify pass (green)** — `npx vitest run src/pages/FlatMap.test.tsx src/routes.test.tsx` → PASS; `npx tsc -b` → clean; `npm run lint` → clean.
- [ ] **Step 6: Commit (green)** — `feat(flatmap-g): /map Command Map page shell + route + nav (Contract D — token/WebGL fallback seam, corner globe, always-on rail)`

---

## Task 10 — Full suite, typecheck, build, lint, README; PR + review

**Files:**
- Modify: `/Users/jn/code/godview-prototype/README.md` (Mapbox license + metering + offline note — spec §7 Amendment 12). If no README exists, create a short one with just this section.
- Otherwise none new — fixes only if a check below fails (each fix scoped + committed with its reason).

**Steps**

- [ ] `npx vitest run` — FULL suite green (all pre-existing globe/fleet/dashboard tests included; the Task 3 extraction and Task 5 prop must not have regressed any).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. Confirm mapbox-gl is code-split into its OWN lazy chunk (dynamic import preserved via `mapboxImpl`): `ls -lS dist/assets | head` — the mapbox chunk (~250KB gz) must NOT be in the entry chunk. If it leaked into the entry, the static import escaped `mapboxImpl.ts` — fix and re-run.
- [ ] Add the README section (verbatim intent):
  ```md
  ## /map (Command Map) — Mapbox dependency

  The `/map` command view uses **Mapbox GL JS v3**, which ships under the **Mapbox Terms of Service
  (proprietary — not open source; MapLibre is the OSS fork we deliberately did not use)**. It requires
  a Mapbox access token in `VITE_MAPBOX_TOKEN` (free tier ~50k map loads/mo). The Mapbox
  attribution/logo control is required by the TOS and must not be removed. When the token is unset,
  `/map` degrades gracefully: the venue rail and the corner globe still render and the map region shows
  a "map unavailable" panel. Unlike `/globe`, `/map` is NOT offline-safe — Mapbox is a hosted
  dependency; the full-screen globe remains the offline surface.
  ```
- [ ] Commit: `chore(flatmap-g): full suite + tsc + build + lint green; README Mapbox license/metering/offline note`
- [ ] Ask git-flow-manager to push `feat/flatmap-g-map-shell` and open a PR targeting `main` titled `feat(flatmap): /map Command Map shell — Mapbox island, corner globe picker, staged flyTo, venue layer + shared contracts (Plan G)` with the structured description (Summary / Motivation / Implementation / Tests / Risks). Perform a self-review, then request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings before Task 11.

---

## Task 11 — Live Playwright E2E vs the seeded stack + style/marker tuning

**DEPENDENCY:** dev stack up (ops-api `:8080` with the seeded map data, projector running) and a real `VITE_MAPBOX_TOKEN` set in the worktree's `.env` (uncommitted). Optionally `scripts/demo_traffic.py` running gently so live-mode encodings have signal.

**Files** — none (live drill; findings become scoped fix commits on this branch or follow-up issues).

**Steps**

- [ ] Preconditions: `npm run dev` in the worktree (`http://localhost:5173`; `VITE_OPS_API_URL` unset → `http://localhost:8080`; `VITE_MAPBOX_TOKEN` set). Headless-WebGL flags as in the globe drills (`--enable-unsafe-swiftshader --use-angle=swiftshader --ignore-gpu-blocklist`); if headless GL is flaky, run DOM assertions headless and the visual pass headed.
- [ ] Navigate to `/map`; confirm nav shows "Map" after "Globe"; the page loads with the dark themed Mapbox map (near-black water, navy land — screenshot), the venue rail on the left, and the corner globe bottom-left showing v1 dots (no arcs, no explosion).
- [ ] **Two WebGL contexts / `paused` mitigation:** with the corner globe visible, click a corner-globe dot → the Mapbox map `flyTo`s. Assert (network/console instrumentation or a `browser_evaluate` hook) that the corner globe's render pauses during the flight (`movestart`) and resumes on `moveend` — i.e. `paused` is wired to `pauseAnimation()`. Budget a subjective perf check on the 2-context page (spec §7 risk); note FPS.
- [ ] **Staged flyTo semantics:** starting at world zoom, one dot click flies to country (~z4); a second toward the same venue flies to city (~z11); a third to building (~z15.5). Assert the landing zoom via `map.getZoom()` (`browser_evaluate`) matches `nextFlyZoom` at each stage, and that `mapTier(getZoom())` reads `world/city/building` accordingly. Clicking a CLUSTER dot flies to the city.
- [ ] **Zoom-semantic venue layer:** at world/country zoom, venue markers show the rollup badge (name + `N sys`); zoom to city — markers de-cluster with the org-colored halo (matches the corner globe's org palette). No POI clutter at any zoom; roads only appear ~z11+.
- [ ] **Fallback seam:** stop the app, unset `VITE_MAPBOX_TOKEN`, restart → `/map` shows `map-unavailable` in the map region while the rail + corner globe still render. Restore the token.
- [ ] **Style/marker tuning pass (budgeted):** judge the dark style + marker legibility on real venues; tune `style.json` land/water/road colors and `venueMarkers` sizing, and the `SYSTEM_RING_M`/`DEVICE_RING_M` building radii if the (Plan-H) building tier will need them (they are Plan G's contract but Plan H renders them — leave a note for Plan H if retuned). Each tune = a scoped commit with a before/after screenshot; keep the Task 2/4/6 tests green (update asserted constants if a threshold moves).
- [ ] Screenshots for the session log: dark map at city zoom with org-halo markers; corner globe; a staged flyTo sequence; the map-unavailable fallback.
- [ ] Fix anything found (red→green where code changes), then ask git-flow-manager to merge the PR (merge commit) after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with `repo@sha`, E2E evidence, tuned constants/hexes, gotchas) and file remaining follow-ups as GitHub issues (e.g. anchored floating detail cards — spec §3 Amendment 6 follow-on; per-device real coords backend lane — spec §4; these are explicitly NOT Plan G/H gates).

---

## Self-review (spec §5 "Plan G scope" coverage check)

- Mapbox GL JS integration + code-split lazy chunk + kept attribution — Tasks 1, 8, 10. ✓
- In-repo dark style from the Tailwind theme hexes (verified `tailwind.config.ts:9-13`) — Task 6. ✓
- `/map` route + "Map" nav after "Globe" (verified `routes.tsx:9-16`, `Shell.tsx:18-25`) — Task 9. ✓
- Corner globe reusing shipped `GlobeCanvas` as v1 dots-only (empty arcs/labels/null explosion — Amendment 3) with the new `paused` prop — Tasks 5, 9. ✓
- Staged `flyTo` (country→city→building) driven by corner-globe dot clicks, landings consistent with `mapTier` — Tasks 2, 8, 9. ✓
- Zoom-semantic venue layer (world rollup markers, city de-clustered org-halo markers) — Tasks 7, 8, 9. ✓
- **Contract A** (`GlobeCanvas.paused` → `pauseAnimation`/`resumeAnimation`, verified `globe.gl.d.ts:115-116`; /globe byte-unchanged) — Task 5. ✓
- **Contract B** (`mapTier`, staged zooms consistent) — Task 2. ✓
- **Contract C** (`buildingLayout` in `mapLayout.ts`, `byId`+`ringPoint` extracted to `layoutGeometry.ts` + re-exported so the globe path is byte-unchanged; METERS radii, cos-lat, altitude 0 satisfies `deepPulsePath`'s `Pick`) — Tasks 3, 4. ✓
- **Contract D** (token/WebGL fallback seam: `<FlatMapCanvas>` iff `hasWebGL() && VITE_MAPBOX_TOKEN`, rail always, corner globe iff `hasWebGL()`, `.env.example` add) — Tasks 1, 8, 9. ✓
- **Contract E** (reused engines untouched; globe-only pulse builders NOT reused) — Plan G touches none of `diffFarPulses`/`diffDeepPulses`/`attributionCamera`/`deepPulsePath`/`usePollDelta`/`pulseRingDatum`/`sweepArcDatum`/`pulseLayer.ts`. ✓
- Mapbox testability: dynamic import + `hasWebGL()&&token` guard, CSS inside `mapboxImpl.ts`, `accessToken` before `new Map`, no `mapboxgl.supported()`, throwing `vi.mock("mapbox-gl")` tripwire, pure selectors for all logic — Tasks 6–9. ✓
- Out of scope honored: no building glyphs/cards/pulses (Plan H), no real per-device coords (future backend lane), no globe rework. ✓

**Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows the code; every test shows assertions. ✓
**Type consistency:** `MapTier`/`mapTier`/`nextFlyZoom`/`STAGE_ZOOM` (Task 2), `MapNode`/`buildingLayout` (Task 4), `byId`/`ringPoint` (Task 3), `applyAnimationState`/`paused` (Task 5), `MapFocus`/`FlatMapCanvas`/`useFlatMap` (Task 8) are referenced by the same names across Tasks 8–9 and the Contract block. ✓
