# God View Globe — Plan B: globe page (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `/globe` page in godview-prototype — a globe.gl 3D fleet view with Health / Live Ad Run encodings, city clustering, a sorted venue rail, and a venue drill-in panel that routes into the existing detail pages — per the spec `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-11-globe-view-design.md` §3.

**Architecture:** All map logic lives in pure, jsdom-testable selectors (`/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`) fed by two new read fetchers; one imperative island (`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`) owns globe.gl behind a WebGL guard and a dynamic import, diffing poll data into a single long-lived instance. The page (`/Users/jn/code/godview-prototype/src/pages/Globe.tsx`) composes rail + canvas + panel declaratively via the existing `usePolling`/`AsyncState`/`Shell` patterns.

**Tech Stack:** React 19 + Vite 8 + Tailwind 3 + vitest 4 / Testing Library (jsdom); new dep `globe.gl@2.46.1` (verified published; bundles three ≥0.179 transitively); textures bundled locally from three-globe's example images (NASA-derived, public-domain source imagery, redistributed in the MIT-licensed three-globe package).

## Global Constraints

- **Plan A dependency:** live data comes from Plan A's `GET /god-view/map` + `GET /god-view/map/locations/{id}` on ops-api plus the seeded demo fleet. All unit tests in this plan run against fixtures/mocks — **no backend required until the final live E2E task**, which runs only after Plan A is merged and the seed is applied.
- **globe.gl / three must never load in jsdom.** Decision (stronger than "verify module-top import"): `GlobeCanvas` loads globe.gl via **dynamic `import("globe.gl")` inside the ref-mount effect, after the WebGL feature guard**. This guarantees jsdom never evaluates three, and code-splits the ~1 MB (≈600 KB gz) three/globe.gl chunk so it only downloads on `/globe`. The GlobeCanvas unit test additionally mocks `globe.gl` with a throwing factory so any accidental load fails loudly.
- **Never re-init the globe on poll** — data is diffed into the existing instance (identity-stable point datums); init happens exactly once per mount, dispose on unmount (hours-long TV sessions).
- **Textures are local Vite asset imports** (`import earthNight from "../../assets/globe/earth-night.jpg"`) — never absolute `/...` URLs. `/Users/jn/code/godview-prototype/vite.config.ts` sets no `base` (default `/`), but asset imports stay correct under any future base.
- Desktop/TV-first; keep the app's dark aesthetic (monospace data figures, sans headings, tailwind palette in `/Users/jn/code/godview-prototype/tailwind.config.ts`: ok `#34d399`, warn `#f5b942`, crit `#f2545b`, off/faint `#5b6472`, accent `#45c4ff`, bg `#0a0d12`).
- **All git via the git-flow-manager subagent** (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — the executor never runs raw `git`/`gh`. Work on branch `feat/globe-b-globe-page` in a dedicated worktree of `/Users/jn/code/godview-prototype`. **Commit each failing test separately from the implementation that greens it** (red→green pairs must show in history). Merge commits (not squash) on PR merge.
- Reference every file by absolute path.
- **Contract note (flagged recon finding):** spec §3's Live encodings distinguish "composing-ish" from "playing", but spec §4's rollup payload only carries `active_ad_runs`. This plan types two **optional additive rollup fields** `composing_count` / `playing_count` that Plan A should emit; every selector has a documented fallback (`playing = playing_count ?? active_ad_runs`, `composing = composing_count ?? 0`) so the page degrades gracefully (glow-only, no pulse) against a strict-§4 backend. Reconcile at E2E time; do not block on it.

---

## Task 1 — Worktree, dependency, textures

**Files**
- Modify: `/Users/jn/code/godview-prototype/package.json` (+ lockfile) — add `"globe.gl": "2.46.1"` (exact pin) to `dependencies`.
- Create: `/Users/jn/code/godview-prototype/src/assets/globe/earth-night.jpg` (~715 KB)
- Create: `/Users/jn/code/godview-prototype/src/assets/globe/earth-topology.png` (~378 KB)
- Create: `/Users/jn/code/godview-prototype/src/assets/globe/SOURCES.md` (provenance/license note)

**Interfaces** — none (infra task; no TDD pair — verified by install + build commands).

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/globe-b-globe-page` from `main` for `/Users/jn/code/godview-prototype`. All subsequent file paths in this plan refer to that worktree's checkout (written here as the repo's canonical absolute paths).
- [ ] Install the pinned dep: `npm install --save-exact globe.gl@2.46.1` (run in the worktree root). Verify: `node -e "console.log(require('./package.json').dependencies['globe.gl'])"` prints `2.46.1`.
- [ ] Download the two textures with python3 + urllib (curl/wget are blocked in planning sessions and may be elsewhere; this is also reproducible). PINNED URLs, verified live (HTTP 200) at plan time:

```bash
mkdir -p src/assets/globe
python3 - <<'EOF'
import urllib.request
for url, dest in [
    ("https://unpkg.com/three-globe@2.45.0/example/img/earth-night.jpg",
     "src/assets/globe/earth-night.jpg"),
    ("https://unpkg.com/three-globe@2.45.0/example/img/earth-topology.png",
     "src/assets/globe/earth-topology.png"),
]:
    urllib.request.urlretrieve(url, dest)
    print("saved", dest)
EOF
```

- [ ] Verify sizes are sane (earth-night.jpg ≈ 715000 bytes, earth-topology.png ≈ 378243 bytes): `ls -l src/assets/globe/`.
- [ ] Write `/Users/jn/code/godview-prototype/src/assets/globe/SOURCES.md`:

```markdown
# Globe texture provenance

- `earth-night.jpg`, `earth-topology.png` — copied from the `three-globe` npm package
  example images (pinned): https://unpkg.com/three-globe@2.45.0/example/img/
- Source imagery: NASA Visible Earth / Earth at Night ("Black Marble") and NASA
  topology maps — NASA imagery is public domain. The three-globe package that
  redistributes them is MIT-licensed (https://github.com/vasturiano/three-globe).
- Bundled locally so the globe renders with no internet at a venue (spec §3).
```

- [ ] Sanity check the build still passes with the new dep + assets present: `npm run build` (runs `tsc -b && vite build`) — expect success.
- [ ] Also confirm the installed globe.gl init signature before Task 5: `sed -n '1,60p' node_modules/globe.gl/README.md` — current API is `new Globe(<domElement>, { configOptions })`. If the README shows the legacy `Globe()(<el>)` kapsule call style instead, use that in Task 5 (single line change).
- [ ] Commit via git-flow-manager: `chore(globe): add globe.gl@2.46.1 + bundled NASA earth textures (three-globe example images, pinned)`

---

## Task 2 — Map API types + fetchers

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` (append Globe map section)
- Modify: `/Users/jn/code/godview-prototype/src/data/api.ts` (add `fetchMap`, `fetchMapLocation`)
- Test: `/Users/jn/code/godview-prototype/src/data/api.test.ts` (append a `globe map api` describe block)

**Interfaces**

Produces (in `apiTypes.ts`):

```ts
export interface MapVenueRollup {
  systems: number; cameras: number; displays: number;
  worst_status: string;
  active_ad_runs: number; runs_last_hour: number; failures_last_hour: number;
  last_activity_at: string | null;
  composing_count?: number; playing_count?: number;   // Plan-A additive (see Global Constraints)
}
export interface MapVenue {
  location_id: string; name: string; location_type: string;
  city: string | null; country: string | null;
  lat: number | null; lng: number | null;
  rollup: MapVenueRollup;
}
export interface MapPayload { venues: MapVenue[]; }
export interface MapSystemDevice { id: string; name: string | null; status: string; last_seen_at: string | null; }
export interface MapSystem { id: string; name: string; zone: string | null; status: string; cameras: MapSystemDevice[]; displays: MapSystemDevice[]; }
export interface MapAdRun { id: string; status: string; started_at: string | null; ended_at: string | null; system_id: string | null; system_name: string | null; }
export interface MapLocationDetail {
  location: { id: string; name: string; location_type: string; city: string | null; country: string | null; lat: number | null; lng: number | null; timezone?: string | null };
  systems: MapSystem[];
  ad_runs: MapAdRun[];
}
```

Produces (in `api.ts`):

```ts
export const fetchMap: () => Promise<MapPayload>;
export const fetchMapLocation: (id: string) => Promise<MapLocationDetail>;
```

**Steps**

- [ ] Write the failing test — append to `/Users/jn/code/godview-prototype/src/data/api.test.ts` (matches the file's existing fetch-spy idiom):

```ts
import { fetchMap, fetchMapLocation } from "./api";

describe("globe map api", () => {
  it("fetchMap hits /god-view/map and returns parsed json", async () => {
    const payload = { venues: [{ location_id: "l1", name: "Mall", location_type: "mall",
      city: "Dallas", country: "US", lat: 32.9, lng: -96.8,
      rollup: { systems: 2, cameras: 2, displays: 4, worst_status: "active",
        active_ad_runs: 1, runs_last_hour: 3, failures_last_hour: 0, last_activity_at: null } }] };
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200 }));
    const out = await fetchMap();
    expect(spy).toHaveBeenCalledWith("http://localhost:8080/god-view/map");
    expect(out.venues[0].rollup.systems).toBe(2);
    expect(out.venues[0].lat).toBe(32.9);
  });

  it("fetchMapLocation hits /god-view/map/locations/{id}", async () => {
    const payload = { location: { id: "l1", name: "Mall", location_type: "mall", city: null,
      country: null, lat: null, lng: null }, systems: [], ad_runs: [] };
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200 }));
    const out = await fetchMapLocation("l1");
    expect(spy).toHaveBeenCalledWith("http://localhost:8080/god-view/map/locations/l1");
    expect(out.systems).toEqual([]);
  });

  it("fetchMap throws on non-ok response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("nope", { status: 500 }));
    await expect(fetchMap()).rejects.toThrow();
  });
});
```

- [ ] Run: `npx vitest run src/data/api.test.ts` — expect FAIL: `api.ts` has no exported member `fetchMap` (module resolution / TS error surfaces as test failure).
- [ ] Commit (red) via git-flow-manager: `test(globe): map api fetchers hit /god-view/map endpoints (red)`
- [ ] Minimal implementation — append the Interfaces block above to `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` under a header comment `// --- Globe map (God View globe, spec §4). Read-only, snake_case.`, then append to `/Users/jn/code/godview-prototype/src/data/api.ts` (and add `MapPayload, MapLocationDetail` to the type import at the top):

```ts
export const fetchMap = () => getJson<MapPayload>("/god-view/map");
export const fetchMapLocation = (id: string) =>
  getJson<MapLocationDetail>(`/god-view/map/locations/${id}`);
```

- [ ] Run: `npx vitest run src/data/api.test.ts` — expect PASS (all pre-existing api tests still green).
- [ ] Commit (green): `feat(globe): fetchMap/fetchMapLocation + MapPayload/MapLocationDetail types (spec §4)`

---

## Task 3 — Shared globe fixtures + core encodings (healthTone, liveState, sortRail, timeAgo)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (shared realistic fixtures — used by every later test)
- Create: `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`

**Interfaces**

Consumes: `MapVenue`, `MapVenueRollup`, `MapLocationDetail` from `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`.

Produces (in `globeSelectors.ts`, this task's slice):

```ts
export type MapMode = "health" | "live";
export type HealthTone = "ok" | "warn" | "off" | "crit";
export function healthTone(r: MapVenueRollup): HealthTone;
export type LiveState = "failed" | "playing" | "composing" | "idle";
export function liveState(r: MapVenueRollup): LiveState;
export function sortRail(venues: MapVenue[], mode: MapMode): MapVenue[];
export function timeAgo(iso: string | null, now?: Date): string;
```

**Steps**

- [ ] Create the shared fixture module `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (test-support data; committed with the red test):

```ts
// Shared fixtures for globe selector/component tests. Realistic spec-§4 payloads:
// two Dallas venues (cluster case), a failing venue, an offline venue, a venue with
// coords but no city, and a venue with no coords (rail-only).
import type { MapLocationDetail, MapPayload, MapVenue, MapVenueRollup } from "./apiTypes";

export const NOW = new Date("2026-07-12T12:00:00Z");

const rollup = (over: Partial<MapVenueRollup> = {}): MapVenueRollup => ({
  systems: 2, cameras: 2, displays: 4, worst_status: "active",
  active_ad_runs: 0, runs_last_hour: 0, failures_last_hour: 0,
  last_activity_at: "2026-07-12T11:59:46Z",           // 14s before NOW
  ...over,
});

export const venues: MapVenue[] = [
  { location_id: "loc_dal_north", name: "Dallas North Mall", location_type: "mall",
    city: "Dallas", country: "US", lat: 32.9, lng: -96.8,
    rollup: rollup({ systems: 5, active_ad_runs: 2, playing_count: 2, runs_last_hour: 9 }) },
  { location_id: "loc_dal_gal", name: "Dallas Galleria", location_type: "mall",
    city: "Dallas", country: "US", lat: 32.93, lng: -96.82,
    rollup: rollup({ systems: 4, worst_status: "degraded", composing_count: 1, runs_last_hour: 3 }) },
  { location_id: "loc_sfo", name: "SFO Terminal 2", location_type: "airport",
    city: "San Francisco", country: "US", lat: 37.62, lng: -122.38,
    rollup: rollup({ systems: 3, failures_last_hour: 2, active_ad_runs: 1, playing_count: 1, runs_last_hour: 6 }) },
  { location_id: "loc_berlin", name: "Berlin Flagship", location_type: "store",
    city: "Berlin", country: "DE", lat: 52.52, lng: 13.4,
    rollup: rollup({ systems: 1, worst_status: "offline", last_activity_at: null }) },
  { location_id: "loc_billboard", name: "Roadside Billboard", location_type: "store",
    city: null, country: "US", lat: 40.7, lng: -74.0,
    rollup: rollup({ systems: 1 }) },
  { location_id: "loc_nocoords", name: "Uncharted Kiosk", location_type: "store",
    city: null, country: null, lat: null, lng: null,
    rollup: rollup({ systems: 1 }) },
];

export const mapPayload: MapPayload = { venues };

export const locationDetail: MapLocationDetail = {
  location: { id: "loc_dal_north", name: "Dallas North Mall", location_type: "mall",
    city: "Dallas", country: "US", lat: 32.9, lng: -96.8, timezone: "America/Chicago" },
  systems: [
    { id: "sys_entrance_a", name: "Entrance Wall A", zone: "entrance", status: "active",
      cameras: [
        { id: "cam_a", name: "Entrance Cam A", status: "active", last_seen_at: "2026-07-12T11:59:50Z" },
        { id: "cam_b", name: "Entrance Cam B", status: "degraded", last_seen_at: "2026-07-12T11:40:00Z" },
      ],
      displays: [
        { id: "disp_a", name: "Panel 1", status: "active", last_seen_at: "2026-07-12T11:59:50Z" },
        { id: "disp_b", name: "Panel 2", status: "active", last_seen_at: "2026-07-12T11:59:48Z" },
      ] },
    { id: "sys_food_court", name: "Food Court Wall", zone: "food_court", status: "active",
      cameras: [{ id: "cam_c", name: "Food Court Cam", status: "active", last_seen_at: "2026-07-12T11:59:30Z" }],
      displays: [{ id: "disp_c", name: "Food Court Panel", status: "active", last_seen_at: "2026-07-12T11:59:30Z" }] },
  ],
  ad_runs: [
    { id: "ar_1", status: "playing", started_at: "2026-07-12T11:59:46Z", ended_at: null,
      system_id: "sys_entrance_a", system_name: "Entrance Wall A" },
    { id: "ar_2", status: "completed", started_at: "2026-07-12T11:50:00Z", ended_at: "2026-07-12T11:50:20Z",
      system_id: "sys_food_court", system_name: "Food Court Wall" },
    { id: "ar_3", status: "failed", started_at: "2026-07-12T11:45:00Z", ended_at: "2026-07-12T11:45:05Z",
      system_id: "sys_entrance_a", system_name: "Entrance Wall A" },
  ],
};
```

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { healthTone, liveState, sortRail, timeAgo } from "./globeSelectors";
import { venues, NOW } from "./globeFixtures";
import type { MapVenueRollup } from "./apiTypes";

const r = (over: Partial<MapVenueRollup> = {}): MapVenueRollup => ({
  systems: 1, cameras: 1, displays: 1, worst_status: "active",
  active_ad_runs: 0, runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null,
  ...over,
});

describe("healthTone (spec §3: red reserved for failures, not a device status)", () => {
  it("maps device worst_status: active->ok, degraded->warn, offline/retired->off", () => {
    expect(healthTone(r({ worst_status: "active" }))).toBe("ok");
    expect(healthTone(r({ worst_status: "degraded" }))).toBe("warn");
    expect(healthTone(r({ worst_status: "offline" }))).toBe("off");
    expect(healthTone(r({ worst_status: "retired" }))).toBe("off");
  });
  it("failures_last_hour > 0 forces crit even when devices are all active", () => {
    expect(healthTone(r({ worst_status: "active", failures_last_hour: 1 }))).toBe("crit");
  });
});

describe("liveState (spec §3: failed > playing > composing > idle)", () => {
  it("failures in the last hour -> failed", () => {
    expect(liveState(r({ failures_last_hour: 2, playing_count: 3 }))).toBe("failed");
  });
  it("playing_count > 0 -> playing (wins over composing)", () => {
    expect(liveState(r({ playing_count: 1, composing_count: 1 }))).toBe("playing");
  });
  it("composing_count only -> composing", () => {
    expect(liveState(r({ composing_count: 1, playing_count: 0 }))).toBe("composing");
  });
  it("nothing open -> idle", () => {
    expect(liveState(r())).toBe("idle");
  });
  it("falls back to active_ad_runs glow when Plan-A counts are absent (strict §4 payload)", () => {
    expect(liveState(r({ active_ad_runs: 1 }))).toBe("playing");
  });
});

describe("sortRail", () => {
  it("health mode sorts worst-first: crit, offline, degraded, then healthy by name", () => {
    expect(sortRail(venues, "health").map((v) => v.location_id)).toEqual([
      "loc_sfo",        // crit (failures)
      "loc_berlin",     // off
      "loc_dal_gal",    // warn
      "loc_dal_north", "loc_billboard", "loc_nocoords",   // ok, name asc
    ]);
  });
  it("live mode sorts most-active-first: active runs desc, then runs/hour desc, then name", () => {
    expect(sortRail(venues, "live").map((v) => v.location_id)).toEqual([
      "loc_dal_north",  // 2 active
      "loc_sfo",        // 1 active
      "loc_dal_gal",    // 0 active, 3 runs/h
      "loc_berlin", "loc_billboard", "loc_nocoords",      // 0/0, name asc
    ]);
  });
  it("does not mutate its input", () => {
    const before = venues.map((v) => v.location_id);
    sortRail(venues, "health");
    expect(venues.map((v) => v.location_id)).toEqual(before);
  });
});

describe("timeAgo", () => {
  it("formats seconds / minutes / hours / days and null", () => {
    expect(timeAgo("2026-07-12T11:59:46Z", NOW)).toBe("14s ago");
    expect(timeAgo("2026-07-12T11:45:00Z", NOW)).toBe("15m ago");
    expect(timeAgo("2026-07-12T09:00:00Z", NOW)).toBe("3h ago");
    expect(timeAgo("2026-07-10T12:00:00Z", NOW)).toBe("2d ago");
    expect(timeAgo(null, NOW)).toBe("—");
  });
});
```

- [ ] Run: `npx vitest run src/data/globeSelectors.test.ts` — expect FAIL: `Cannot find module './globeSelectors'`.
- [ ] Commit (red): `test(globe): health/live encodings, rail sorting, timeAgo — fixtures + red selectors tests`
- [ ] Minimal implementation — create `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`:

```ts
// Pure map selectors — no WebGL, no React. Everything the globe encodes is decided here
// (unit-testable in jsdom); GlobeCanvas only wires these into globe.gl accessors.
import type { MapVenue, MapVenueRollup } from "./apiTypes";

export type MapMode = "health" | "live";

// ---- Health encoding (spec §3): worst device status per venue; red reserved for failures.
export type HealthTone = "ok" | "warn" | "off" | "crit";

export const TONE_HEX: Record<HealthTone, string> = {
  ok: "#34d399", warn: "#f5b942", off: "#5b6472", crit: "#f2545b",   // tailwind ok/warn/off/crit
};

export function healthTone(r: MapVenueRollup): HealthTone {
  if (r.failures_last_hour > 0) return "crit";
  if (r.worst_status === "active") return "ok";
  if (r.worst_status === "degraded") return "warn";
  return "off";                                    // offline | retired | anything unknown
}

// ---- Live encoding (spec §3): pulse=composing-ish, glow=playing, red ring=failed, dim=idle.
// playing_count/composing_count are Plan-A additive fields; when absent, any active run glows.
export type LiveState = "failed" | "playing" | "composing" | "idle";

export function liveState(r: MapVenueRollup): LiveState {
  if (r.failures_last_hour > 0) return "failed";
  if ((r.playing_count ?? r.active_ad_runs) > 0) return "playing";
  if ((r.composing_count ?? 0) > 0) return "composing";
  return "idle";
}

// ---- Rail sorting (spec §3): worst-first in Health, most-active-first in Live.
const HEALTH_ORDER: Record<HealthTone, number> = { crit: 0, off: 1, warn: 2, ok: 3 };

export function sortRail(venues: MapVenue[], mode: MapMode): MapVenue[] {
  const byName = (a: MapVenue, b: MapVenue) => a.name.localeCompare(b.name);
  if (mode === "health") {
    return [...venues].sort((a, b) =>
      HEALTH_ORDER[healthTone(a.rollup)] - HEALTH_ORDER[healthTone(b.rollup)]
      || b.rollup.failures_last_hour - a.rollup.failures_last_hour
      || byName(a, b));
  }
  return [...venues].sort((a, b) =>
    b.rollup.active_ad_runs - a.rollup.active_ad_runs
    || b.rollup.runs_last_hour - a.rollup.runs_last_hour
    || byName(a, b));
}

// ---- Relative time for rollup lines / device rows.
export function timeAgo(iso: string | null, now: Date = new Date()): string {
  if (!iso) return "—";
  const s = Math.max(0, Math.floor((now.getTime() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
```

- [ ] Run: `npx vitest run src/data/globeSelectors.test.ts` — expect PASS.
- [ ] Commit (green): `feat(globe): healthTone/liveState/sortRail/timeAgo pure selectors (spec §3 encodings)`

---

## Task 4 — Clustering, text builders, dot visual accessors

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` (append)
- Test: `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts` (append)

**Interfaces**

Produces (appended to `globeSelectors.ts`):

```ts
export interface VenueDot { kind: "venue"; id: string; lat: number; lng: number; venue: MapVenue; }
export interface ClusterDot { kind: "cluster"; id: string; lat: number; lng: number; city: string; country: string | null; venues: MapVenue[]; rollup: MapVenueRollup; }
export type GlobeDot = VenueDot | ClusterDot;
export const CLUSTER_ALTITUDE: number;   // 1.2 — camera altitude threshold (globe.gl pov units)
export function clusterVenues(venues: MapVenue[], altitude: number, threshold?: number): GlobeDot[];
export function clusterLabel(c: ClusterDot): string;               // "Dallas · 3 venues · 12 systems"
export function venueSummary(v: MapVenue, now?: Date): string;     // rollup-only summary (tooltip/rail)
export function dotSummary(dot: GlobeDot, now?: Date): string;     // tooltip text for any dot
export function panelRollupLine(detail: MapLocationDetail, now?: Date): string;  // "8 systems · 3 playing · 1 camera warning · last ad 14s ago"
export function dotColor(dot: GlobeDot, mode: MapMode): string;    // hex for globe.gl pointColor
export function dotRadius(dot: GlobeDot): number;                  // clusters scale with venue count
export interface RingDatum { id: string; lat: number; lng: number; color: string; repeatPeriod: number; }
export function ringsFor(dots: GlobeDot[], mode: MapMode): RingDatum[];  // pulse (composing) + red ring (failed), live mode only
```

**Steps**

- [ ] Write the failing tests — append to `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts` (extend the import from `./globeSelectors` with `clusterVenues, CLUSTER_ALTITUDE, clusterLabel, venueSummary, dotSummary, panelRollupLine, dotColor, dotRadius, ringsFor, type GlobeDot`; extend the fixture import with `locationDetail, mapPayload`):

```ts
describe("clusterVenues (spec §3 semantic aggregation)", () => {
  it("above the altitude threshold, same-city venues merge into one city dot with rolled-up counts", () => {
    const dots = clusterVenues(venues, 2.0);            // 2.0 >= CLUSTER_ALTITUDE
    // Dallas cluster + SFO + Berlin + Billboard (city:null -> own dot); nocoords excluded
    expect(dots).toHaveLength(4);
    const dallas = dots.find((d) => d.kind === "cluster");
    expect(dallas).toBeDefined();
    if (dallas?.kind !== "cluster") throw new Error("unreachable");
    expect(dallas.id).toBe("cluster:Dallas|US");
    expect(dallas.venues.map((v) => v.location_id).sort())
      .toEqual(["loc_dal_gal", "loc_dal_north"]);
    expect(dallas.rollup.systems).toBe(9);              // 5 + 4
    expect(dallas.rollup.worst_status).toBe("degraded");
    expect(dallas.rollup.playing_count).toBe(2);        // summed Plan-A counts
    expect(dallas.rollup.composing_count).toBe(1);
    expect(dallas.lat).toBeCloseTo((32.9 + 32.93) / 2, 5);
  });
  it("below the threshold, every plottable venue renders individually", () => {
    const dots = clusterVenues(venues, 0.8);
    expect(dots).toHaveLength(5);                       // all but loc_nocoords
    expect(dots.every((d) => d.kind === "venue")).toBe(true);
  });
  it("venues without lat/lng are never plotted (they stay rail-only)", () => {
    for (const alt of [0.5, 3]) {
      expect(clusterVenues(venues, alt).some((d) => d.id === "loc_nocoords")).toBe(false);
    }
  });
  it("a single-venue city renders as the venue dot, not a cluster of one", () => {
    const dots = clusterVenues(venues, 2.0);
    expect(dots.find((d) => d.id === "loc_sfo")?.kind).toBe("venue");
  });
});

describe("text builders (concept-doc dot summaries)", () => {
  it("clusterLabel: 'Dallas · 2 venues · 9 systems'", () => {
    const dallas = clusterVenues(venues, 2.0).find((d) => d.kind === "cluster");
    if (dallas?.kind !== "cluster") throw new Error("no cluster");
    expect(clusterLabel(dallas)).toBe("Dallas · 2 venues · 9 systems");
  });
  it("venueSummary from rollup only", () => {
    expect(venueSummary(venues[0], NOW)).toBe("5 systems · 2 playing · last ad 14s ago");
    expect(venueSummary(venues[2], NOW))
      .toBe("3 systems · 1 playing · 2 failures/h · last ad 14s ago");
    expect(venueSummary(venues[3], NOW)).toBe("1 systems · 0 playing · worst: offline · last ad —");
  });
  it("dotSummary prefixes venue name for venue dots and delegates for clusters", () => {
    const dots = clusterVenues(venues, 2.0);
    const sfo = dots.find((d) => d.id === "loc_sfo") as GlobeDot;
    expect(dotSummary(sfo, NOW)).toContain("SFO Terminal 2 · ");
    const dallas = dots.find((d) => d.kind === "cluster") as GlobeDot;
    expect(dotSummary(dallas, NOW)).toBe("Dallas · 2 venues · 9 systems");
  });
  it("panelRollupLine matches the concept-doc header line", () => {
    expect(panelRollupLine(locationDetail, NOW))
      .toBe("2 systems · 1 playing · 1 camera warning · last ad 14s ago");
  });
});

describe("dot visual accessors", () => {
  const dots = clusterVenues(venues, 0.8);
  const byId = (id: string) => dots.find((d) => d.id === id) as GlobeDot;
  it("health mode colors by healthTone; red only for failures", () => {
    expect(dotColor(byId("loc_sfo"), "health")).toBe("#f2545b");       // crit
    expect(dotColor(byId("loc_dal_gal"), "health")).toBe("#f5b942");   // warn
    expect(dotColor(byId("loc_berlin"), "health")).toBe("#5b6472");    // off
    expect(dotColor(byId("loc_dal_north"), "health")).toBe("#34d399"); // ok
  });
  it("live mode: playing glows green, composing accent, failed crit, idle dim", () => {
    expect(dotColor(byId("loc_dal_north"), "live")).toBe("#34d399");
    expect(dotColor(byId("loc_dal_gal"), "live")).toBe("#45c4ff");
    expect(dotColor(byId("loc_sfo"), "live")).toBe("#f2545b");
    expect(dotColor(byId("loc_billboard"), "live")).toBe("#3a4150");
  });
  it("clusters render larger than venues, scaled by member count", () => {
    const cluster = clusterVenues(venues, 2.0).find((d) => d.kind === "cluster") as GlobeDot;
    expect(dotRadius(cluster)).toBeGreaterThan(dotRadius(byId("loc_sfo")));
  });
  it("ringsFor emits pulse rings for composing and red rings for failed, live mode only", () => {
    const rings = ringsFor(dots, "live");
    expect(rings).toEqual([
      { id: "ring:loc_dal_gal", lat: 32.93, lng: -96.82, color: "#45c4ff", repeatPeriod: 900 },
      { id: "ring:loc_sfo", lat: 37.62, lng: -122.38, color: "#f2545b", repeatPeriod: 1400 },
    ]);
    expect(ringsFor(dots, "health")).toEqual([]);
  });
});
```

- [ ] Run: `npx vitest run src/data/globeSelectors.test.ts` — expect FAIL: `clusterVenues` (etc.) not exported.
- [ ] Commit (red): `test(globe): clustering, tooltip/rollup text builders, dot color/radius/rings (red)`
- [ ] Minimal implementation — append to `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` (also add `MapLocationDetail` to the type import at the top):

```ts
// ---- Semantic aggregation (spec §3): beyond CLUSTER_ALTITUDE, venues cluster per city.
export interface VenueDot { kind: "venue"; id: string; lat: number; lng: number; venue: MapVenue; }
export interface ClusterDot {
  kind: "cluster"; id: string; lat: number; lng: number;
  city: string; country: string | null; venues: MapVenue[]; rollup: MapVenueRollup;
}
export type GlobeDot = VenueDot | ClusterDot;

/** Camera altitude (globe.gl pov.altitude units) above which venues aggregate into city dots. */
export const CLUSTER_ALTITUDE = 1.2;

const STATUS_RANK: Record<string, number> = { active: 0, degraded: 1, offline: 2, retired: 2 };
const worstOf = (a: string, b: string) => ((STATUS_RANK[b] ?? 2) > (STATUS_RANK[a] ?? 2) ? b : a);

const venueDot = (v: MapVenue): VenueDot =>
  ({ kind: "venue", id: v.location_id, lat: v.lat!, lng: v.lng!, venue: v });

export function clusterVenues(
  venues: MapVenue[], altitude: number, threshold: number = CLUSTER_ALTITUDE,
): GlobeDot[] {
  const plotted = venues.filter((v) => v.lat != null && v.lng != null);
  if (altitude < threshold) return plotted.map(venueDot);

  const groups = new Map<string, MapVenue[]>();
  for (const v of plotted) {
    // No city -> the venue stays its own dot even when zoomed out.
    const key = v.city ? `${v.city}|${v.country ?? ""}` : `loc|${v.location_id}`;
    groups.set(key, [...(groups.get(key) ?? []), v]);
  }
  return [...groups.entries()].map(([key, members]) => {
    if (members.length === 1) return venueDot(members[0]);
    const sum = (f: (r: MapVenueRollup) => number) => members.reduce((s, v) => s + f(v.rollup), 0);
    // Only surface Plan-A live counts when at least one member carries them —
    // otherwise liveState() must keep its active_ad_runs fallback for the whole cluster.
    const hasLiveCounts = members.some(
      (v) => v.rollup.playing_count != null || v.rollup.composing_count != null);
    const rollup: MapVenueRollup = {
      systems: sum((r) => r.systems),
      cameras: sum((r) => r.cameras),
      displays: sum((r) => r.displays),
      worst_status: members.reduce((w, v) => worstOf(w, v.rollup.worst_status), "active"),
      active_ad_runs: sum((r) => r.active_ad_runs),
      runs_last_hour: sum((r) => r.runs_last_hour),
      failures_last_hour: sum((r) => r.failures_last_hour),
      last_activity_at: members.map((v) => v.rollup.last_activity_at)
        .filter((t): t is string => t != null).sort().pop() ?? null,
      ...(hasLiveCounts ? {
        composing_count: sum((r) => r.composing_count ?? 0),
        playing_count: sum((r) => r.playing_count ?? 0),
      } : {}),
    };
    return {
      kind: "cluster" as const,
      id: `cluster:${key}`,
      lat: members.reduce((s, v) => s + v.lat!, 0) / members.length,
      lng: members.reduce((s, v) => s + v.lng!, 0) / members.length,
      city: members[0].city!, country: members[0].country ?? null,
      venues: members, rollup,
    };
  });
}

// ---- Dot summary / tooltip / rollup-line text builders (concept doc via spec §3).
export function clusterLabel(c: ClusterDot): string {
  return `${c.city} · ${c.venues.length} venues · ${c.rollup.systems} systems`;
}

export function venueSummary(v: MapVenue, now: Date = new Date()): string {
  const r = v.rollup;
  const parts = [`${r.systems} systems`, `${r.playing_count ?? r.active_ad_runs} playing`];
  if (r.worst_status !== "active") parts.push(`worst: ${r.worst_status}`);
  if (r.failures_last_hour > 0) parts.push(`${r.failures_last_hour} failures/h`);
  parts.push(`last ad ${timeAgo(r.last_activity_at, now)}`);
  return parts.join(" · ");
}

export function dotSummary(dot: GlobeDot, now: Date = new Date()): string {
  return dot.kind === "cluster"
    ? clusterLabel(dot)
    : `${dot.venue.name} · ${venueSummary(dot.venue, now)}`;
}

export function panelRollupLine(detail: MapLocationDetail, now: Date = new Date()): string {
  const playing = detail.ad_runs
    .filter((r) => r.status === "dispatched" || r.status === "playing").length;
  const camWarn = detail.systems.flatMap((s) => s.cameras)
    .filter((c) => c.status !== "active").length;
  const dispWarn = detail.systems.flatMap((s) => s.displays)
    .filter((d) => d.status !== "active").length;
  const lastAd = detail.ad_runs.map((r) => r.started_at)
    .filter((t): t is string => t != null).sort().pop() ?? null;
  const parts = [`${detail.systems.length} systems`, `${playing} playing`];
  if (camWarn > 0) parts.push(`${camWarn} camera ${camWarn === 1 ? "warning" : "warnings"}`);
  if (dispWarn > 0) parts.push(`${dispWarn} display ${dispWarn === 1 ? "warning" : "warnings"}`);
  parts.push(`last ad ${timeAgo(lastAd, now)}`);
  return parts.join(" · ");
}

// ---- Visual accessors consumed by GlobeCanvas (kept pure so they're unit-tested here).
const DIM_IDLE = "#3a4150";
const ACCENT = "#45c4ff";

export function dotColor(dot: GlobeDot, mode: MapMode): string {
  const r = dot.kind === "cluster" ? dot.rollup : dot.venue.rollup;
  if (mode === "health") return TONE_HEX[healthTone(r)];
  const s = liveState(r);
  if (s === "failed") return TONE_HEX.crit;
  if (s === "playing") return TONE_HEX.ok;
  if (s === "composing") return ACCENT;
  return DIM_IDLE;
}

export function dotRadius(dot: GlobeDot): number {
  return dot.kind === "cluster" ? Math.min(1.6, 0.55 + 0.15 * dot.venues.length) : 0.45;
}

export interface RingDatum { id: string; lat: number; lng: number; color: string; repeatPeriod: number; }

/** Live-mode rings: pulse (composing) + red ring (failed). Health mode has no rings. */
export function ringsFor(dots: GlobeDot[], mode: MapMode): RingDatum[] {
  if (mode !== "live") return [];
  const out: RingDatum[] = [];
  for (const d of dots) {
    const r = d.kind === "cluster" ? d.rollup : d.venue.rollup;
    const s = liveState(r);
    if (s === "composing") out.push({ id: `ring:${d.id}`, lat: d.lat, lng: d.lng, color: ACCENT, repeatPeriod: 900 });
    if (s === "failed") out.push({ id: `ring:${d.id}`, lat: d.lat, lng: d.lng, color: TONE_HEX.crit, repeatPeriod: 1400 });
  }
  return out;
}
```

- [ ] Run: `npx vitest run src/data/globeSelectors.test.ts` — expect PASS.
- [ ] Commit (green): `feat(globe): city clustering, dot/tooltip/rollup text builders, color/radius/ring accessors`

---

## Task 5 — GlobeCanvas: guarded, disposed, diff-updating globe.gl wrapper

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`

**Interfaces**

Consumes: `GlobeDot`, `MapMode`, `dotColor`, `dotRadius`, `dotSummary`, `ringsFor`, `CLUSTER_ALTITUDE` from `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`; textures from `/Users/jn/code/godview-prototype/src/assets/globe/`.

Produces:

```ts
export interface Focus { lat: number; lng: number; token: number; }   // token bumps re-fly to the same venue
export function hasWebGL(): boolean;
export function GlobeCanvas(props: {
  dots: GlobeDot[];
  mode: MapMode;
  focus: Focus | null;
  onDotClick: (dot: GlobeDot) => void;
  onAltitudeChange: (altitude: number) => void;
}): JSX.Element;
```

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { vi } from "vitest";
import { GlobeCanvas } from "./GlobeCanvas";
import { venues, mapPayload } from "../../data/globeFixtures";
import { clusterVenues } from "../../data/globeSelectors";

// Guardrail (spec §3): globe.gl/three must never load in jsdom. If the WebGL guard ever
// lets the dynamic import through, this factory makes the test fail loudly.
vi.mock("globe.gl", () => { throw new Error("globe.gl must not load in jsdom"); });

const noop = () => {};

test("GlobeCanvas renders the graceful WebGL fallback in jsdom without touching globe.gl", () => {
  render(<GlobeCanvas dots={clusterVenues(mapPayload.venues, 2.0)} mode="health"
    focus={null} onDotClick={noop} onAltitudeChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
  expect(screen.getByTestId("globe-fallback").textContent).toMatch(/WebGL/);
  expect(screen.queryByTestId("globe-canvas")).not.toBeInTheDocument();
});

test("GlobeCanvas fallback survives data/mode updates (poll ticks) without crashing", () => {
  const { rerender } = render(<GlobeCanvas dots={[]} mode="health" focus={null}
    onDotClick={noop} onAltitudeChange={noop} />);
  rerender(<GlobeCanvas dots={clusterVenues(venues, 0.8)} mode="live"
    focus={{ lat: 32.9, lng: -96.8, token: 1 }} onDotClick={noop} onAltitudeChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx` — expect FAIL: `Cannot find module './GlobeCanvas'`.
- [ ] Commit (red): `test(globe): GlobeCanvas WebGL fallback in jsdom, globe.gl never imported (red)`
- [ ] Implementation — create `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`. This is the single imperative island (spec §3 rendering guardrails are annotated inline). If Task 1's README check showed the legacy kapsule call style, replace `new Globe(el)` with `Globe()(el)` — everything else is identical:

```tsx
import { useEffect, useRef, useState } from "react";
import {
  CLUSTER_ALTITUDE, dotColor, dotRadius, dotSummary, ringsFor,
  type GlobeDot, type MapMode,
} from "../../data/globeSelectors";
import earthNight from "../../assets/globe/earth-night.jpg";
import earthTopology from "../../assets/globe/earth-topology.png";

export interface Focus { lat: number; lng: number; token: number; }

export function hasWebGL(): boolean {
  try {
    const c = document.createElement("canvas");
    return !!(c.getContext("webgl2") || c.getContext("webgl"));
  } catch {
    return false;
  }
}

// globe.gl instance — dynamically imported; typed loosely on purpose (imperative island).
type GlobeInstance = any;
interface PointDatum { id: string; lat: number; lng: number; dot: GlobeDot; }

export function GlobeCanvas({ dots, mode, focus, onDotClick, onAltitudeChange }: {
  dots: GlobeDot[];
  mode: MapMode;
  focus: Focus | null;                 // token bumps re-fly even to the same coordinates
  onDotClick: (dot: GlobeDot) => void;
  onAltitudeChange: (altitude: number) => void;
}) {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const globeRef = useRef<GlobeInstance>(null);
  const [ready, setReady] = useState(false);
  const [unsupported, setUnsupported] = useState(false);
  // Latest-callback refs so imperative handlers never go stale across renders.
  const clickRef = useRef(onDotClick); clickRef.current = onDotClick;
  const altRef = useRef(onAltitudeChange); altRef.current = onAltitudeChange;
  const modeRef = useRef(mode); modeRef.current = mode;

  // INIT — only here, only once per mount (spec §3): WebGL feature-guarded, globe.gl
  // dynamically imported AFTER the guard so jsdom/tests and non-WebGL kiosks never load three.
  useEffect(() => {
    if (!hasWebGL()) { setUnsupported(true); return; }
    const el = mountRef.current;
    if (!el) return;
    let disposed = false;
    let globe: GlobeInstance = null;
    let ro: ResizeObserver | null = null;
    import("globe.gl").then(({ default: Globe }) => {
      if (disposed) return;
      globe = new Globe(el)
        .globeImageUrl(earthNight)          // bundled Vite asset imports — never absolute /... paths
        .bumpImageUrl(earthTopology)
        .backgroundColor("#0a0d12")
        .showAtmosphere(true)
        .atmosphereColor("#45c4ff")
        .atmosphereAltitude(0.18)
        .pointAltitude(0.02)
        .pointColor((d: PointDatum) => dotColor(d.dot, modeRef.current))
        .pointRadius((d: PointDatum) => dotRadius(d.dot))
        .pointLabel((d: PointDatum) =>
          `<div style="font-family:ui-monospace,monospace;font-size:11px;padding:2px 4px">${dotSummary(d.dot)}</div>`)
        .onPointClick((d: PointDatum) => clickRef.current(d.dot))
        .ringColor((r: { color: string }) => r.color)
        .ringMaxRadius(3)
        .ringPropagationSpeed(2)
        .ringRepeatPeriod((r: { repeatPeriod: number }) => r.repeatPeriod)
        .onZoom((pov: { altitude: number }) => altRef.current(pov.altitude));
      globe.width(el.clientWidth).height(el.clientHeight);
      globe.controls().autoRotate = true;                 // idle cinematic rotation (spec §3)
      globe.controls().autoRotateSpeed = 0.4;
      globe.controls().addEventListener("start", () => {  // user drag/zoom stops it
        globe.controls().autoRotate = false;
      });
      ro = new ResizeObserver(() => globe.width(el.clientWidth).height(el.clientHeight));
      ro.observe(el);
      globeRef.current = globe;
      setReady(true);
    });
    return () => {        // DISPOSE on unmount — long-lived TV sessions must not leak GL contexts
      disposed = true;
      ro?.disconnect();
      globeRef.current = null;
      globe?._destructor?.();
      el.replaceChildren();
    };
  }, []);

  // DATA — each poll diffs into the live instance, never re-inits (spec §3). Point datum
  // objects are identity-stable per dot id so globe.gl updates known objects in place.
  const datumsRef = useRef(new Map<string, PointDatum>());
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe) return;
    const prev = datumsRef.current;
    const next = new Map<string, PointDatum>();
    for (const dot of dots) {
      const d = prev.get(dot.id) ?? { id: dot.id, lat: dot.lat, lng: dot.lng, dot };
      d.lat = dot.lat; d.lng = dot.lng; d.dot = dot;
      next.set(dot.id, d);
    }
    datumsRef.current = next;
    globe.pointsData([...next.values()]);
    globe.ringsData(ringsFor(dots, mode));
  }, [dots, mode, ready]);

  // CAMERA — fly to the selected venue (rail click or dot click).
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe || !focus) return;
    globe.controls().autoRotate = false;
    globe.pointOfView({ lat: focus.lat, lng: focus.lng, altitude: CLUSTER_ALTITUDE * 0.6 }, 1200);
  }, [focus, ready]);

  if (unsupported) {
    // Graceful fallback (spec §3): the page's venue rail still lists the whole fleet.
    return (
      <div data-testid="globe-fallback"
        className="flex h-full items-center justify-center px-6 text-center text-faint text-[12.5px]">
        3D globe unavailable (no WebGL on this device) — the venue rail lists the whole fleet.
      </div>
    );
  }
  return <div ref={mountRef} data-testid="globe-canvas" className="h-full w-full" />;
}
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx` — expect PASS (fallback path; the throwing `globe.gl` mock proves three was never imported).
- [ ] Run `npx tsc -b` — expect clean (asset imports are typed by `vite/client` in `/Users/jn/code/godview-prototype/tsconfig.app.json`).
- [ ] Commit (green): `feat(globe): GlobeCanvas — guarded dynamic globe.gl init, diff-on-poll, flyTo, dispose`

---

## Task 6 — ModeLegend + VenueRail

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/globe/VenueRail.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.test.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/VenueRail.test.tsx`

**Interfaces**

```ts
export function ModeLegend(props: { mode: MapMode; onMode: (m: MapMode) => void }): JSX.Element;
export function VenueRail(props: {
  venues: MapVenue[];                 // pre-sorted by the page via sortRail
  mode: MapMode;
  selectedId: string | null;
  onSelect: (v: MapVenue) => void;
}): JSX.Element;
```

**Steps**

- [ ] Write the failing tests. `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.test.tsx`:

```tsx
import { render, screen, fireEvent } from "@testing-library/react";
import { vi } from "vitest";
import { ModeLegend } from "./ModeLegend";

test("health mode shows the health legend (red reserved for failures)", () => {
  render(<ModeLegend mode="health" onMode={() => {}} />);
  const legend = screen.getByTestId("globe-legend");
  expect(legend.textContent).toContain("Active");
  expect(legend.textContent).toContain("Degraded");
  expect(legend.textContent).toContain("Offline / Retired");
  expect(legend.textContent).toContain("Failures (last hour)");
  expect(legend.textContent).not.toContain("Composing");
});

test("live mode shows the live legend", () => {
  render(<ModeLegend mode="live" onMode={() => {}} />);
  const legend = screen.getByTestId("globe-legend");
  expect(legend.textContent).toContain("Playing");
  expect(legend.textContent).toContain("Composing");
  expect(legend.textContent).toContain("Failed (recent)");
  expect(legend.textContent).toContain("Idle");
});

test("clicking a mode button calls onMode", () => {
  const onMode = vi.fn();
  render(<ModeLegend mode="health" onMode={onMode} />);
  fireEvent.click(screen.getByTestId("mode-live"));
  expect(onMode).toHaveBeenCalledWith("live");
});
```

`/Users/jn/code/godview-prototype/src/components/globe/VenueRail.test.tsx`:

```tsx
import { render, screen, fireEvent } from "@testing-library/react";
import { vi } from "vitest";
import { VenueRail } from "./VenueRail";
import { venues } from "../../data/globeFixtures";
import { sortRail } from "../../data/globeSelectors";

test("renders one row per venue in the order given (page pre-sorts)", () => {
  render(<VenueRail venues={sortRail(venues, "health")} mode="health" selectedId={null} onSelect={() => {}} />);
  const rows = screen.getAllByTestId("venue-row");
  expect(rows).toHaveLength(6);
  expect(rows[0].textContent).toContain("SFO Terminal 2");       // worst-first
});

test("health mode rows show worst status + failures; live mode rows show activity", () => {
  const { rerender } = render(
    <VenueRail venues={venues} mode="health" selectedId={null} onSelect={() => {}} />);
  const sfo = screen.getAllByTestId("venue-row").find((r) => r.textContent?.includes("SFO"))!;
  expect(sfo.textContent).toContain("2 fail/h");
  rerender(<VenueRail venues={venues} mode="live" selectedId={null} onSelect={() => {}} />);
  const dal = screen.getAllByTestId("venue-row").find((r) => r.textContent?.includes("Dallas North"))!;
  expect(dal.textContent).toContain("2 active");
  expect(dal.textContent).toContain("9 runs/h");
});

test("a venue without coordinates is listed with a 'no coords' marker", () => {
  render(<VenueRail venues={venues} mode="health" selectedId={null} onSelect={() => {}} />);
  const row = screen.getAllByTestId("venue-row").find((r) => r.textContent?.includes("Uncharted Kiosk"))!;
  expect(row.textContent).toContain("no coords");
});

test("clicking a row calls onSelect with the venue", () => {
  const onSelect = vi.fn();
  render(<VenueRail venues={venues} mode="health" selectedId={null} onSelect={onSelect} />);
  fireEvent.click(screen.getAllByTestId("venue-row")[0]);
  expect(onSelect).toHaveBeenCalledWith(venues[0]);
});
```

- [ ] Run: `npx vitest run src/components/globe/ModeLegend.test.tsx src/components/globe/VenueRail.test.tsx` — expect FAIL: modules not found.
- [ ] Commit (red): `test(globe): mode switcher legend + venue rail rows/stats/no-coords marker (red)`
- [ ] Implementation — create `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.tsx`:

```tsx
import type { MapMode } from "../../data/globeSelectors";

const LEGEND: Record<MapMode, { swatch: string; label: string }[]> = {
  health: [
    { swatch: "bg-ok", label: "Active" },
    { swatch: "bg-warn", label: "Degraded" },
    { swatch: "bg-off", label: "Offline / Retired" },
    { swatch: "bg-crit", label: "Failures (last hour)" },
  ],
  live: [
    { swatch: "bg-ok shadow-[0_0_6px_#34d399]", label: "Playing" },
    { swatch: "bg-accent animate-pulse", label: "Composing" },
    { swatch: "bg-crit ring-1 ring-crit/60", label: "Failed (recent)" },
    { swatch: "bg-faint", label: "Idle" },
  ],
};

export function ModeLegend({ mode, onMode }: { mode: MapMode; onMode: (m: MapMode) => void }) {
  const btn = (m: MapMode, label: string) => (
    <button data-testid={`mode-${m}`} onClick={() => onMode(m)}
      className={`px-2.5 py-1 rounded-md text-[12px] border ${
        mode === m ? "bg-elev text-text border-accent/50" : "text-dim border-border hover:bg-elev"}`}>
      {label}
    </button>
  );
  return (
    <div className="flex items-center gap-3 flex-wrap">
      <div className="flex items-center gap-1.5">{btn("health", "Health")}{btn("live", "Live Ad Runs")}</div>
      <div data-testid="globe-legend" className="flex items-center gap-3 font-mono text-[11px] text-dim flex-wrap">
        {LEGEND[mode].map((e) => (
          <span key={e.label} className="flex items-center gap-1.5">
            <span className={`h-2 w-2 rounded-full ${e.swatch}`} />{e.label}
          </span>
        ))}
      </div>
    </div>
  );
}
```

Create `/Users/jn/code/godview-prototype/src/components/globe/VenueRail.tsx`:

```tsx
import type { MapVenue } from "../../data/apiTypes";
import { healthTone, type MapMode } from "../../data/globeSelectors";

const TONE_BG = { ok: "bg-ok", warn: "bg-warn", off: "bg-off", crit: "bg-crit" } as const;

export function VenueRail({ venues, mode, selectedId, onSelect }: {
  venues: MapVenue[];                 // pre-sorted by the page (sortRail)
  mode: MapMode;
  selectedId: string | null;
  onSelect: (v: MapVenue) => void;
}) {
  return (
    <div data-testid="venue-rail">
      {venues.map((v) => {
        const r = v.rollup;
        const stat = mode === "health"
          ? `${r.worst_status}${r.failures_last_hour > 0 ? ` · ${r.failures_last_hour} fail/h` : ""}`
          : `${r.active_ad_runs} active · ${r.runs_last_hour} runs/h`;
        return (
          <button key={v.location_id} data-testid="venue-row" onClick={() => onSelect(v)}
            className={`w-full text-left px-2 py-1.5 rounded-md mb-0.5 border ${
              selectedId === v.location_id ? "bg-elev border-accent/40" : "border-transparent hover:bg-elev"}`}>
            <div className="flex items-center gap-2">
              <span className={`h-2 w-2 rounded-full shrink-0 ${TONE_BG[healthTone(r)]}`} />
              <span className="text-[12.5px] truncate">{v.name}</span>
              {v.lat == null && (
                <span className="ml-auto shrink-0 font-mono text-[9px] text-faint border border-border px-1 rounded">
                  no coords
                </span>
              )}
            </div>
            <div className="pl-4 flex items-center justify-between gap-2 font-mono text-[10.5px] text-dim">
              <span className="truncate">{[v.city, v.country].filter(Boolean).join(", ") || "—"}</span>
              <span className="shrink-0">{stat}</span>
            </div>
          </button>
        );
      })}
      {venues.length === 0 && <div className="px-2 py-4 text-faint text-[12px]">No venues.</div>}
    </div>
  );
}
```

- [ ] Run: `npx vitest run src/components/globe/ModeLegend.test.tsx src/components/globe/VenueRail.test.tsx` — expect PASS.
- [ ] Commit (green): `feat(globe): ModeLegend (Health | Live Ad Runs) + VenueRail with monospace stats`

---

## Task 7 — VenuePanel (slide-in drill-down)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.test.tsx`

**Interfaces**

Consumes: `fetchMapLocation` (mocked in tests), `usePolling`, `panelRollupLine`, `timeAgo`, `StatusDot`, `MapSystem`.

```ts
export function VenuePanel(props: { locationId: string; onClose: () => void }): JSX.Element;
// USAGE RULE (fleet keying lesson): always mount as <VenuePanel key={`venue:${id}`} .../> —
// usePolling captures its fetch closure per mount; a key change is what swaps venues.
```

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.test.tsx`:

```tsx
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { vi } from "vitest";
import { VenuePanel } from "./VenuePanel";
import { locationDetail } from "../../data/globeFixtures";

vi.mock("../../data/api", () => ({
  fetchMapLocation: vi.fn().mockImplementation(() => Promise.resolve(locationDetail)),
}));
import { fetchMapLocation } from "../../data/api";

const renderPanel = () => render(
  <MemoryRouter>
    <VenuePanel key="venue:loc_dal_north" locationId="loc_dal_north" onClose={() => {}} />
  </MemoryRouter>);

test("fetches the venue payload and renders header + rollup line", async () => {
  renderPanel();
  await waitFor(() => expect(screen.getByTestId("venue-panel")).toBeInTheDocument());
  expect(fetchMapLocation).toHaveBeenCalledWith("loc_dal_north");
  expect(screen.getByText("Dallas North Mall")).toBeInTheDocument();
  expect(screen.getByText("Dallas, US")).toBeInTheDocument();
  const rollup = screen.getByTestId("panel-rollup").textContent!;
  expect(rollup).toContain("2 systems");
  expect(rollup).toContain("1 playing");
  expect(rollup).toContain("1 camera warning");
});

test("systems expand to cameras/displays with status dots and last_seen_at", async () => {
  renderPanel();
  await waitFor(() => screen.getByTestId("venue-panel"));
  expect(screen.getByText("Entrance Wall A")).toBeInTheDocument();
  expect(screen.getByText("Food Court Wall")).toBeInTheDocument();
  const devices = screen.getAllByTestId("device-row");
  expect(devices).toHaveLength(6);                                 // 3 cameras + 3 displays
  const camB = devices.find((d) => d.textContent?.includes("Entrance Cam B"))!;
  expect(camB.querySelector('[data-testid="status-dot"]')?.getAttribute("data-status")).toBe("degraded");
  expect(camB.textContent).toMatch(/ago/);                         // last_seen_at rendered

  // collapsing a system hides its devices
  fireEvent.click(screen.getAllByTestId("system-toggle")[0]);
  expect(screen.getAllByTestId("device-row")).toHaveLength(2);     // only Food Court's remain
});

test("links out: ad run -> /compositions/:id, system -> /systems/:id, Manage in Fleet -> /fleet", async () => {
  renderPanel();
  await waitFor(() => screen.getByTestId("venue-panel"));
  const adLinks = screen.getAllByTestId("panel-adrun");
  expect(adLinks[0]).toHaveAttribute("href", "/compositions/ar_1");
  expect(screen.getByText("Entrance Wall A").closest("a")).toHaveAttribute("href", "/systems/sys_entrance_a");
  expect(screen.getByText(/Manage in Fleet/).closest("a")).toHaveAttribute("href", "/fleet");
});

test("close button calls onClose", async () => {
  const onClose = vi.fn();
  render(<MemoryRouter><VenuePanel locationId="loc_dal_north" onClose={onClose} /></MemoryRouter>);
  await waitFor(() => screen.getByTestId("venue-panel"));
  fireEvent.click(screen.getByTestId("panel-close"));
  expect(onClose).toHaveBeenCalled();
});
```

- [ ] Run: `npx vitest run src/components/globe/VenuePanel.test.tsx` — expect FAIL: module not found.
- [ ] Commit (red): `test(globe): venue panel rollup line, systems->devices drilldown, outbound links (red)`
- [ ] Implementation — create `/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.tsx`:

```tsx
import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { fetchMapLocation } from "../../data/api";
import { usePolling } from "../../hooks/usePolling";
import { panelRollupLine, timeAgo } from "../../data/globeSelectors";
import { StatusDot } from "../StatusDot";
import type { MapSystem } from "../../data/apiTypes";

// Mounted keyed by `venue:${locationId}` (fleet keying lesson) — usePolling captures its
// fetch closure per mount, so a key change is what swaps venues. Polled while open (spec §4).
export function VenuePanel({ locationId, onClose }: { locationId: string; onClose: () => void }) {
  const { data, loading, error } = usePolling(() => fetchMapLocation(locationId), 5000);
  if (error && !data) {
    return (
      <PanelFrame onClose={onClose}>
        <div data-testid="panel-error" className="text-crit text-[12px]">
          couldn't load venue — {error.message}
        </div>
      </PanelFrame>
    );
  }
  if (loading && !data) {
    return (
      <PanelFrame onClose={onClose}>
        <div data-testid="panel-loading" className="text-faint text-[12px]">Loading…</div>
      </PanelFrame>
    );
  }
  if (!data) return null;
  const loc = data.location;
  return (
    <PanelFrame onClose={onClose}>
      <div data-testid="venue-panel">
        <div className="flex items-center gap-2">
          <h2 className="text-[15px] font-semibold truncate">{loc.name}</h2>
          <span className="font-mono text-[9.5px] text-faint border border-border px-1.5 rounded">
            {loc.location_type}
          </span>
        </div>
        <div className="text-[11.5px] text-dim mb-1">
          {[loc.city, loc.country].filter(Boolean).join(", ") || "—"}
        </div>
        <div data-testid="panel-rollup"
          className="font-mono text-[11px] text-dim border-b border-border pb-2 mb-3">
          {panelRollupLine(data)}
        </div>

        <div className="text-[10.5px] uppercase tracking-wider text-faint font-semibold mb-1">Systems</div>
        {data.systems.map((s) => <SystemRow key={s.id} system={s} />)}
        {data.systems.length === 0 && <div className="text-faint text-[12px]">No systems.</div>}

        <div className="text-[10.5px] uppercase tracking-wider text-faint font-semibold mt-4 mb-1">Ad runs</div>
        {data.ad_runs.map((r) => (
          <Link key={r.id} to={`/compositions/${r.id}`} data-testid="panel-adrun"
            className="flex items-center gap-2 px-1 py-1 rounded hover:bg-elev text-[11.5px]">
            <StatusDot status={r.status} kind="adrun" />
            <span className="font-mono truncate">{r.id}</span>
            <span className="text-dim">{r.status}</span>
            <span className="ml-auto shrink-0 font-mono text-[10px] text-faint">{timeAgo(r.started_at)}</span>
          </Link>
        ))}
        {data.ad_runs.length === 0 && <div className="text-faint text-[12px]">No recent ad runs.</div>}

        <div className="mt-4 border-t border-border pt-2">
          <Link to="/fleet" className="text-accent text-[12px] hover:underline">Manage in Fleet →</Link>
        </div>
      </div>
    </PanelFrame>
  );
}

function PanelFrame({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  return (
    <div className="h-full overflow-auto bg-sidebar/95 border-l border-border p-3">
      <button data-testid="panel-close" aria-label="close panel" onClick={onClose}
        className="float-right text-dim hover:text-text">✕</button>
      {children}
    </div>
  );
}

function SystemRow({ system }: { system: MapSystem }) {
  const [open, setOpen] = useState(true);
  return (
    <div className="mb-1.5">
      <div className="flex items-center gap-2">
        <button data-testid="system-toggle" onClick={() => setOpen((o) => !o)}
          className="w-3 text-faint">{open ? "▾" : "▸"}</button>
        <StatusDot status={system.status} kind="lifecycle" />
        <Link to={`/systems/${system.id}`} className="text-[12.5px] truncate hover:underline">
          {system.name}
        </Link>
        {system.zone && <span className="font-mono text-[9.5px] text-faint">{system.zone}</span>}
      </div>
      {open && (
        <div className="pl-7">
          {system.cameras.map((c) =>
            <DeviceRow key={c.id} label="cam" name={c.name} status={c.status} lastSeen={c.last_seen_at} />)}
          {system.displays.map((d) =>
            <DeviceRow key={d.id} label="disp" name={d.name} status={d.status} lastSeen={d.last_seen_at} />)}
        </div>
      )}
    </div>
  );
}

function DeviceRow({ label, name, status, lastSeen }: {
  label: string; name: string | null; status: string; lastSeen: string | null;
}) {
  return (
    <div data-testid="device-row" className="flex items-center gap-2 py-0.5 text-[11.5px]">
      <span className="w-7 font-mono text-[9px] text-faint">{label}</span>
      <StatusDot status={status} kind="device" />
      <span className="truncate">{name ?? "—"}</span>
      <span className="ml-auto shrink-0 font-mono text-[10px] text-faint">{timeAgo(lastSeen)}</span>
    </div>
  );
}
```

- [ ] Run: `npx vitest run src/components/globe/VenuePanel.test.tsx` — expect PASS.
- [ ] Commit (green): `feat(globe): VenuePanel — rollup header, systems->devices, ad runs, links to detail pages`

---

## Task 8 — Globe page, route, Shell nav, `/systems/:id` deep link

**Files**
- Create: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`
- Test: `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/routes.tsx` (add `/globe`; make `/systems` accept an optional `:systemId`)
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.tsx` (nav item after Fleet)
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.test.tsx` (nav assertion)
- Modify: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx` (initialize the drilldown from the route param — the panel's `/systems/:id` links need a landing target; ~2-line change)
- Modify: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx` (deep-link test)

**Interfaces**

```ts
export function Globe(): JSX.Element;    // route "/globe"
// routes.tsx: { path: "/globe", element: <Globe /> }
//             { path: "/systems/:systemId?", element: <SystemsLogs /> }  (replaces "/systems")
```

**Steps**

- [ ] Write the failing page test `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx` (GlobeCanvas needs no mock — jsdom has no WebGL, so it renders its tested fallback; `Shell` needs `fetchProjectorStatus`):

```tsx
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { vi } from "vitest";
import { Globe } from "./Globe";
import { mapPayload, locationDetail } from "../data/globeFixtures";

vi.mock("../data/api", () => ({
  fetchProjectorStatus: vi.fn().mockResolvedValue({ cursor: 1, backlog: 0, lag_seconds: 0.5, health: "ok" }),
  fetchMap: vi.fn().mockImplementation(() => Promise.resolve(mapPayload)),
  fetchMapLocation: vi.fn().mockImplementation(() => Promise.resolve(locationDetail)),
}));
import { fetchMapLocation } from "../data/api";

const renderGlobe = () => render(<MemoryRouter><Globe /></MemoryRouter>);

test("renders the rail worst-first in health mode, with the no-WebGL fallback canvas area", async () => {
  renderGlobe();
  await waitFor(() => expect(screen.getAllByTestId("venue-row").length).toBe(6));
  expect(screen.getAllByTestId("venue-row")[0].textContent).toContain("SFO Terminal 2");
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();   // jsdom has no WebGL
});

test("mode switch toggles the legend and re-sorts the rail most-active-first", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  fireEvent.click(screen.getByTestId("mode-live"));
  expect(screen.getByTestId("globe-legend").textContent).toContain("Composing");
  expect(screen.getAllByTestId("venue-row")[0].textContent).toContain("Dallas North Mall");
});

test("clicking a rail row opens the venue panel for that venue", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  const dallas = screen.getAllByTestId("venue-row")
    .find((r) => r.textContent?.includes("Dallas North Mall"))!;
  fireEvent.click(dallas);
  await waitFor(() => expect(screen.getByTestId("venue-panel")).toBeInTheDocument());
  expect(fetchMapLocation).toHaveBeenCalledWith("loc_dal_north");
  expect(screen.getByTestId("panel-rollup").textContent).toContain("2 systems");
});

test("panel close returns to the bare globe", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  fireEvent.click(screen.getAllByTestId("venue-row")[0]);
  await waitFor(() => screen.getByTestId("venue-panel"));
  fireEvent.click(screen.getByTestId("panel-close"));
  expect(screen.queryByTestId("venue-panel")).not.toBeInTheDocument();
});
```

- [ ] Append the failing nav test to `/Users/jn/code/godview-prototype/src/components/Shell.test.tsx`:

```tsx
test("Shell nav includes the Globe page after Fleet", () => {
  render(<MemoryRouter><Shell><div>content</div></Shell></MemoryRouter>);
  const globe = screen.getByText("Globe");
  expect(globe).toBeInTheDocument();
  expect(globe.closest("a")).toHaveAttribute("href", "/globe");
});
```

- [ ] Append the failing deep-link test to `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx`, following that file's existing mock setup (reuse its `vi.mock("../data/api", ...)` block as-is; render with a route instead of a bare component):

```tsx
import { Routes, Route } from "react-router-dom";

test("deep link /systems/:systemId opens that system's drilldown on load", async () => {
  render(
    <MemoryRouter initialEntries={["/systems/s1"]}>
      <Routes><Route path="/systems/:systemId?" element={<SystemsLogs />} /></Routes>
    </MemoryRouter>);
  await waitFor(() => expect(fetchSystem).toHaveBeenCalledWith("s1"));
});
```

(Adapt the exact `fetchSystem` mock reference to the names already mocked at the top of that test file — the file already mocks `../data/api`; assert on its existing `fetchSystem` mock.)

- [ ] Run: `npx vitest run src/pages/Globe.test.tsx src/components/Shell.test.tsx src/pages/SystemsLogs.test.tsx` — expect FAIL (no `./Globe` module; no "Globe" nav text; `fetchSystem` not called with "s1").
- [ ] Commit (red): `test(globe): globe page composition, Globe nav item, /systems/:id deep link (red)`
- [ ] Implementation — create `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`:

```tsx
import { useMemo, useState } from "react";
import { Shell } from "../components/Shell";
import { AsyncState } from "../components/AsyncState";
import { usePolling } from "../hooks/usePolling";
import { fetchMap } from "../data/api";
import { clusterVenues, sortRail, type GlobeDot, type MapMode } from "../data/globeSelectors";
import { GlobeCanvas, type Focus } from "../components/globe/GlobeCanvas";
import { ModeLegend } from "../components/globe/ModeLegend";
import { VenueRail } from "../components/globe/VenueRail";
import { VenuePanel } from "../components/globe/VenuePanel";
import type { MapVenue } from "../data/apiTypes";

export function Globe() {
  const { data, loading, error, refetch } = usePolling(fetchMap, 5000);   // dashboard cadence
  const [mode, setMode] = useState<MapMode>("health");
  const [altitude, setAltitude] = useState(2.5);           // globe.gl default POV altitude
  const [panelId, setPanelId] = useState<string | null>(null);
  const [focus, setFocus] = useState<Focus | null>(null);
  const [railOpen, setRailOpen] = useState(false);         // mobile bottom sheet

  const venues = data?.venues ?? [];
  const dots = useMemo(() => clusterVenues(venues, altitude), [venues, altitude]);
  const railVenues = useMemo(() => sortRail(venues, mode), [venues, mode]);

  const flyTo = (lat: number, lng: number) =>
    setFocus((f) => ({ lat, lng, token: (f?.token ?? 0) + 1 }));
  const selectVenue = (v: MapVenue) => {
    setPanelId(v.location_id);
    setRailOpen(false);
    if (v.lat != null && v.lng != null) flyTo(v.lat, v.lng);
  };
  const onDotClick = (dot: GlobeDot) => {
    if (dot.kind === "venue") selectVenue(dot.venue);
    else flyTo(dot.lat, dot.lng);      // cluster: fly below the threshold so it de-clusters
  };

  return (
    <Shell crumb="Globe">
      <div className="flex items-center justify-between gap-3 mb-3 flex-wrap">
        <h1 className="text-[18px] font-semibold">Globe</h1>
        <ModeLegend mode={mode} onMode={setMode} />
      </div>
      <AsyncState loading={loading} error={error} hasData={!!data} onRetry={refetch}>
        <div className="grid grid-cols-1 lg:grid-cols-[280px_minmax(0,1fr)] gap-4 h-[calc(100vh-170px)] min-h-[420px]">
          <div className="hidden lg:block overflow-auto border border-border rounded-[10px] p-2">
            <VenueRail venues={railVenues} mode={mode} selectedId={panelId} onSelect={selectVenue} />
          </div>
          <div className="relative overflow-hidden border border-border rounded-[10px] bg-bg">
            <GlobeCanvas dots={dots} mode={mode} focus={focus}
              onDotClick={onDotClick} onAltitudeChange={setAltitude} />
            <button data-testid="rail-toggle" onClick={() => setRailOpen(true)}
              className="lg:hidden absolute bottom-3 left-3 rounded-md border border-border bg-elev px-3 py-1.5 text-[12px]">
              Venues ({railVenues.length})
            </button>
            {/* Venue panel: right slide-in on desktop, bottom sheet on mobile — single mount. */}
            {panelId && (
              <>
                <div className="fixed inset-0 z-40 bg-black/50 lg:hidden" onClick={() => setPanelId(null)} />
                <div data-testid="venue-panel-wrap"
                  className="fixed inset-x-0 bottom-0 z-50 h-[70vh] overflow-hidden rounded-t-xl border-t border-border
                             lg:absolute lg:left-auto lg:top-0 lg:right-0 lg:bottom-0 lg:z-10 lg:h-auto lg:w-[380px] lg:rounded-none lg:border-t-0">
                  <VenuePanel key={`venue:${panelId}`} locationId={panelId} onClose={() => setPanelId(null)} />
                </div>
              </>
            )}
          </div>
        </div>
        {/* Mobile rail sheet — same overlay pattern as Shell's mobile nav. */}
        {railOpen && (
          <div data-testid="mobile-rail" className="fixed inset-0 z-50 lg:hidden">
            <div className="absolute inset-0 bg-black/50" onClick={() => setRailOpen(false)} />
            <div className="absolute inset-x-0 bottom-0 max-h-[70vh] overflow-auto rounded-t-xl border-t border-border bg-sidebar p-3">
              <VenueRail venues={railVenues} mode={mode} selectedId={panelId} onSelect={selectVenue} />
            </div>
          </div>
        )}
      </AsyncState>
    </Shell>
  );
}
```

- [ ] Modify `/Users/jn/code/godview-prototype/src/routes.tsx`:

```tsx
import { createBrowserRouter } from "react-router-dom";
import { MainDashboard } from "./pages/MainDashboard";
import { CompositionActivity } from "./pages/CompositionActivity";
import { AdDetail } from "./pages/AdDetail";
import { SystemsLogs } from "./pages/SystemsLogs";
import { Fleet } from "./pages/Fleet";
import { Globe } from "./pages/Globe";

export const router = createBrowserRouter([
  { path: "/", element: <MainDashboard /> },
  { path: "/compositions", element: <CompositionActivity /> },
  { path: "/compositions/:adRunId", element: <AdDetail /> },
  { path: "/systems/:systemId?", element: <SystemsLogs /> },
  { path: "/fleet", element: <Fleet /> },
  { path: "/globe", element: <Globe /> },
]);
```

- [ ] Modify `/Users/jn/code/godview-prototype/src/components/Shell.tsx` — in the `nav` array's "God View" group, add after the Fleet entry (single line):

```ts
    { to: "/globe", label: "Globe" },
```

- [ ] Modify `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx` — surgical deep-link support only (two changes): add a NEW `react-router-dom` import line (the file currently has none), then initialize `open` from the param. Verified at plan time: the detail fetch is driven by `useEffect(..., [open])` (SystemsLogs.tsx:18-21), so a non-null initial `open` fetches on mount — no extra effect needed:

```tsx
import { useParams } from "react-router-dom";
// inside SystemsLogs():
const { systemId } = useParams();
const [open, setOpen] = useState<string | null>(systemId ?? null);
```

(Replace the existing `const [open, setOpen] = useState<string | null>(null);` line; touch nothing else in that file.)

- [ ] Run: `npx vitest run src/pages/Globe.test.tsx src/components/Shell.test.tsx src/pages/SystemsLogs.test.tsx src/App.test.tsx` — expect PASS (App.test renders the router; `/systems` path change must not break it or any existing SystemsLogs test).
- [ ] Commit (green): `feat(globe): /globe page (rail + canvas + panel + mobile sheets), Globe nav, /systems/:id deep link`

---

## Task 9 — Full suite, typecheck, build, lint, bundle sanity

**Files** — none new; fixes only if something below fails (each fix scoped + committed with reason).

**Steps**

- [ ] `npx vitest run` — full suite green (all pre-existing tests too).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. Inspect `dist/assets/`: confirm (a) both earth textures were emitted as hashed assets, and (b) three/globe.gl landed in a **separate lazy chunk** (the dynamic import) rather than the entry chunk — `ls -lS dist/assets | head` and check the entry JS did not grow by ~1 MB. Record the chunk sizes in the commit message.
- [ ] Quick smoke in a real browser (dev server, mocked-nothing but backend may be absent — the page must show the AsyncState error banner, the fallback-free globe, and an empty rail without crashing): `npm run dev`, open `http://localhost:5173/globe`, verify the globe renders and auto-rotates with zero venues and the error banner if ops-api is down. (This is a visual sanity check, not the E2E.)
- [ ] Commit: `chore(globe): full suite + tsc + build green; three/globe.gl in lazy chunk (sizes noted)`
- [ ] Ask git-flow-manager to push the branch and open a PR titled `feat(globe): God View globe page (Plan B)` against `main` with the structured description (Summary / Motivation / Implementation / Tests / Risks). Request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings before Task 10.

---

## Task 10 — Live Playwright E2E (after Plan A is merged + seeded)

**DEPENDENCY:** This task runs only after **Plan A (mras-ops: `/god-view/map` endpoints + `seed_demo_fleet.sql`) is merged and the dev DB is seeded**, and the dev stack is up (ops-api on `:8080`, projector running). If Plan A's merged payload diverges from the types in Task 2 (esp. `composing_count`/`playing_count` — see Global Constraints), reconcile `apiTypes.ts`/selectors first as a scoped fix commit.

**Files** — none (live drill; findings become fix commits on the same branch or follow-up issues).

**Steps**

- [ ] Preconditions: seed applied (`docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/seed/seed_demo_fleet.sql` per spec §5, if not already), optionally the demo-traffic generator running gently for Live-mode motion. Start the frontend: `npm run dev` in the worktree (`http://localhost:5173`), `VITE_OPS_API_URL` unset (defaults to `http://localhost:8080`).
- [ ] **Headless WebGL note:** headless Chromium needs software GL. If driving via the Playwright MCP browser, WebGL may or may not be available depending on its launch flags; if scripting Playwright directly, launch with `chromium.launch({ args: ["--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--ignore-gpu-blocklist"] })`. **Fallback rule (spec §7):** if headless GL proves flaky (canvas absent / `globe-fallback` shown), run all DOM assertions below anyway (rail, legend, panel, links work regardless), and cover the visual with a headed/real-browser screenshot pass.
- [ ] Navigate to `http://localhost:5173/globe`.
- [ ] **Globe mounted:** assert `[data-testid="globe-canvas"] canvas` exists (globe.gl injects a `<canvas>`). Record which path (WebGL vs fallback) the run took.
- [ ] **No re-init on poll (spec §3 guardrail):** evaluate `window.__c = document.querySelector('[data-testid="globe-canvas"] canvas')`, wait ≥ 12 s (two poll ticks), then assert `document.querySelector('[data-testid="globe-canvas"] canvas') === window.__c`.
- [ ] **Rail:** assert `[data-testid="venue-row"]` count ≥ 12 (the seeded fleet) and that the real demo box's venue appears among them.
- [ ] **Mode switch:** click `[data-testid="mode-live"]`; assert `[data-testid="globe-legend"]` now contains "Composing" and "Playing"; click `[data-testid="mode-health"]`; assert it contains "Failures (last hour)".
- [ ] **Venue click → panel:** click the first `[data-testid="venue-row"]`; wait for `[data-testid="venue-panel"]`; assert `[data-testid="panel-rollup"]` text matches `/\d+ systems/`, at least one `[data-testid="device-row"]` exists with a `[data-testid="status-dot"]`, and system links have `href^="/systems/"`.
- [ ] **Panel link → Ad Detail:** if the seeded venue has ad runs (run the generator briefly if the list is empty), click the first `[data-testid="panel-adrun"]`; assert the URL is `/compositions/<id>` and the Ad Detail pipeline graph page renders.
- [ ] **Mobile pass:** resize viewport to 390×844; assert `[data-testid="rail-toggle"]` is visible, opens `[data-testid="mobile-rail"]`, and selecting a venue there opens the panel as a bottom sheet.
- [ ] Take screenshots (health mode, live mode, open panel) for the session log; if the run used the DOM-fallback path, repeat the visual check headed and screenshot that.
- [ ] Fix anything found (scoped commits, red→green where code changes), then ask git-flow-manager to merge the PR (merge commit) after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with `repo@sha`, E2E evidence, gotchas) and file any remaining follow-ups (e.g. Volume/Error/Campaign modes, arcs — spec §8 out-of-scope) as GitHub issues.

---

## Self-review notes (spec §3 coverage check, done at plan time)

- `/globe` route + "Globe" nav (desktop + mobile overlay reuse the same `NavContent`) — Task 8. ✓
- Auto-rotate when idle / stop on user drag — Task 5 (`controls().autoRotate` + `start` listener). ✓
- Mode switcher + legend (Health | Live Ad Runs), pipeline built to take later modes (a new `MapMode` + legend entry + `dotColor` branch) — Tasks 3/6. ✓
- Health encoding: active→green, degraded→yellow, offline/retired→gray, **red reserved for `failures_last_hour > 0`** — Task 3 `healthTone`. ✓
- Live encoding: pulse=composing-ish, glow=playing, red ring=failed recent, dim=idle — Tasks 3/4 (`liveState`, `ringsFor`, `dotColor`), with the flagged `composing_count`/`playing_count` contract note. ✓
- Venue rail: worst-first (Health) / most-active-first (Live), monospace stats, click → fly + panel — Tasks 3/6/8. ✓
- Venue panel: header + rollup line, systems → cameras/displays with status + `last_seen_at`, recent ad runs, links `/compositions/:adRunId`, `/systems/:id` (deep-link support added surgically to SystemsLogs), `/fleet` — Tasks 7/8. ✓
- Semantic aggregation: pure client-side city clustering keyed on city/lat-lng, altitude threshold, rolled-up counts — Task 4, WebGL-free unit tests. ✓
- Hover tooltip: `pointLabel` ← `dotSummary` — Tasks 4/5. ✓
- Guardrails: init only in ref-mount effect, WebGL guard + graceful fallback (rail still lists fleet), dynamic import keeps three out of jsdom, poll diffs never re-init, dispose on unmount, local Vite-imported textures, no arcs — Task 5 + throwing-mock test. ✓
- Venues with `lat/lng: null` listed in rail ("no coords"), never plotted — Tasks 4/6. ✓
- Polling: `usePolling` at 5000 ms (dashboard cadence); panel fetched on open + polled while open (mounted keyed) — Tasks 7/8. ✓
- Mobile: rail + panel become sheets consistent with Shell's mobile-nav overlay pattern; desktop/TV-first — Task 8. ✓
- Out of scope honored (§8): no Volume/Error/Campaign modes, no arcs, no in-globe sub-venue zoom, no auth, no editing from the globe.
