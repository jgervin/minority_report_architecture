# God View Globe v2 — Plan D: org arcs, org chips, highlight, labels (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lane 1's frontend on the existing `/globe` page — per-retailer org arc chains drawn dim by default, an org-chips legend near the venue rail, highlight interaction (venue dot / rail row / org chip click lights that retailer's whole network with a brighter color + dash sweep; clicking elsewhere/again clears), and venue/cluster text labels at mid zoom that fade by altitude — per the spec `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md` §3 "Globe (godview-prototype)".

**Architecture:** All new logic is pure, jsdom-testable selectors in a new module (`/Users/jn/code/godview-prototype/src/data/topologySelectors.ts`) fed by the existing `fetchMap` payload; `GlobeCanvas` (`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`) stays the only imperative island and gains two more identity-diffed layers (`arcsData`, `labelsData`) using the exact Map-keyed datum cache pattern its points already use (GlobeCanvas.tsx:93-107). Highlight state lives in the page (`/Users/jn/code/godview-prototype/src/pages/Globe.tsx`) and reaches the island as a plain prop read through a latest-value ref (same pattern as `modeRef`, GlobeCanvas.tsx:30).

**Tech Stack:** No new dependencies — `globe.gl@2.46.1` is already pinned (`/Users/jn/code/godview-prototype/package.json`) and its arc/label layers ship with it. React 19 + Vite 8 + Tailwind 3 + vitest 4 / Testing Library (jsdom; `/Users/jn/code/godview-prototype/vitest.config.ts:7` — `environment: "jsdom"`, `setupFiles: "./src/test/setup.ts"`).

## Global Constraints

- **Plan C dependency:** live data for arcs/chips comes from Plan C (mras-ops: seed v2 retailer split + `/god-view/map` `org` field — planned in parallel, spec §3 "API" subsection). All unit tests in this plan run against fixtures — **no backend required until the final live E2E task**, which runs only after Plan C is merged and seed v2 is applied. The new frontend types are **optional-additive** (see Contract below) so the page runs unchanged against an un-upgraded backend: no `org` fields → zero chips, zero arcs, labels still work.
- **Contract (consumes)** — the exact additive API fields this plan assumes Plan C emits (gate-check this section field-by-field against Plan C):
  - Each venue in `GET /god-view/map` gains **`org: { id: string, name: string } | null`** — the venue's dominant org by system count, derived from `systems.organization_id`, with deterministic tie-break (`count DESC, organization_id`) and `name` joined from `organizations`; `null` when the venue has no systems with an org.
  - Each venue's `rollup` gains **`last_run_created_at: string | null`** (ISO timestamp; `max(ar_created_at)` in the existing `act` CTE). **Plan D only types this field** (Lane 3's delta engine consumes it; nothing in this plan reads it) so the frontend contract lands in one place.
  - Both fields are additive; no existing field changes shape. The REAL demo venue surfaces its real org ("Demo Org") in `org` — a **single-venue org**, which this plan's chips/arcs must tolerate (chip renders, zero arcs).
  - NOT consumed by this plan (Lane 2/3 contracts, typed in Plans E/F): panel-payload `ad_runs[].display_id`, `MapSystemDevice.screen_id`.
- **globe.gl / three must never load in jsdom.** Unchanged v1 guardrails: dynamic `import("globe.gl")` inside the ref-mount effect after the `hasWebGL()` guard (GlobeCanvas.tsx:34-41; guard in `/Users/jn/code/godview-prototype/src/components/globe/webgl.ts:1-8`), plus the throwing-factory tripwire `vi.mock("globe.gl", () => { throw ... })` in `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx:11`. All new arc/chip/label logic is pure selectors; GlobeCanvas only wires accessors.
- **Identity-diff every layer datum** (spec §3 amendment: this discipline extends to EVERY v2 layer). Arc and label datums get the same Map-keyed cache as points (GlobeCanvas.tsx:93-107): stable keys (`${orgId}:${fromId}->${toId}` for arcs, `label:${dotId}` for labels), cached datum objects mutated in place, never a fresh object set per poll — a fresh-object arc set would restart every dash animation fleet-wide. Never re-init the globe (init once per mount, GlobeCanvas.tsx:34-89; dispose on unmount, GlobeCanvas.tsx:82-88).
- **Animation-lifecycle decision (spec §3 amendment, decided here):** `arcDashAnimateTime` is a continuous LOOP (three-globe.d.ts:110-111), not a one-shot. Plan D's highlight is a **looping dash sweep for as long as the org is highlighted** — it should read as "lit", so the loop is the desired semantics and no one-shot lifecycle is built. The explicit one-shot pulse lifecycle (temporary arc datum removed after one period / `arcDashInitialGap` staging) is **Lane 3 / Plan F**, not this plan.
- **Verified globe.gl API names** (from `/Users/jn/code/godview-prototype/node_modules/three-globe/dist/three-globe.d.ts` unless noted): `arcsData` (:78-79), `arcStartLat`/`arcEndLat`/`arcStartLng`/`arcEndLng` (:80-87, defaults match our `startLat`… datum fields), `arcColor` (:92-93), `arcAltitudeAutoScale` (:96-97), `arcStroke` (:98-99), `arcDashLength` (:104-105), `arcDashGap` (:106-107), `arcDashInitialGap` (:108-109), `arcDashAnimateTime` (:110-111), `arcsTransitionDuration` (:112-113); `labelsData` (:300-301), `labelLat`/`labelLng`/`labelText`/`labelColor`/`labelAltitude`/`labelSize` (:302-313), `labelResolution` (:318-319), `labelIncludeDot` (:320-321), `labelsTransitionDuration` (:326-327); `onGlobeClick` (`/Users/jn/code/godview-prototype/node_modules/globe.gl/dist/globe.gl.d.ts:73`).
- **Highlight restyle mechanism:** globe.gl accessors are captured at init, so highlight changes re-apply by re-setting `arcsData` with the **same identity-stable datums** while the accessors read the current value from a ref — exactly how v1's mode switch restyles points (`modeRef` read inside `pointColor` at GlobeCanvas.tsx:57 + `mode` in the data-effect deps at GlobeCanvas.tsx:107). Retained datum identity means unaffected arcs keep their state; only the toggled org's arcs change dash values (their sweep starting on highlight is the intent).
- Labels are plain three.js text sprites (`labelText` takes a string, not HTML) — no `escapeHtml` needed (that stays for the HTML `pointLabel` tooltip, globeSelectors.ts:159-168).
- Desktop/TV-first; keep the app's dark aesthetic. Org arc colors come from a fixed palette **distinct from the status hues** (`/Users/jn/code/godview-prototype/tailwind.config.ts:11-13`: ok `#34d399`, warn `#f5b942`, crit `#f2545b`, accent `#45c4ff`) so arcs never read as health, and the legend must not imply data flows between stores (spec §8: chains are a visual abstraction).
- **All git via the git-flow-manager subagent** (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers never run raw `git`/`gh`. Work on branch `feat/globe-d-org-arcs-chips-labels` in a dedicated worktree of `/Users/jn/code/godview-prototype`. **Commit each failing test separately from the implementation that greens it** (red→green pairs must show in history). Merge commits (not squash) on PR merge.
- Verification commands (confirmed against `/Users/jn/code/godview-prototype/package.json` scripts): `npm test` (= `vitest run`), `npx vitest run <paths>` for single files, `npx tsc -b` (the build script is `tsc -b && vite build`), `npm run build`, `npm run lint` (oxlint).
- Reference every file by absolute path.

---

## Task 1 — Worktree + additive API typing

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` (two additive optional fields in the existing Globe map section, apiTypes.ts:121-144)

**Interfaces** — none observable at runtime (types-only infra task; no TDD pair — additive optional typing has no red-able runtime behavior; verified by `npx tsc -b` + full suite. The fields are consumed by Task 2's red tests.)

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/globe-d-org-arcs-chips-labels` from `main` for `/Users/jn/code/godview-prototype`. All subsequent file paths in this plan refer to that worktree's checkout (written here as the repo's canonical absolute paths).
- [ ] In `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`, extend the Globe map section (currently apiTypes.ts:121-144) — add one interface and two optional fields, nothing else:

```ts
// Plan-C additive (globe v2 Lane 1): venue's dominant org. Optional so the UI runs
// against an un-upgraded backend (absent org fields -> no chips, no arcs).
export interface MapVenueOrg { id: string; name: string; }
```

  In `MapVenueRollup` (apiTypes.ts:123-129), append after `composing_count?: number; playing_count?: number;`:

```ts
  last_run_created_at?: string | null;                // Plan-C additive (Lane 3 delta signal; typed here, read in Plan F)
```

  In `MapVenue` (apiTypes.ts:130-135), append after `rollup: MapVenueRollup;`:

```ts
  org?: MapVenueOrg | null;                           // Plan-C additive (Lane 1 org arcs/chips)
```

- [ ] Verify: `npx tsc -b` clean; `npm test` — full suite still green (optional fields break nothing; `fetchMap` at `/Users/jn/code/godview-prototype/src/data/api.ts:105` passes the JSON through untouched, so no fetcher change is needed).
- [ ] Commit via git-flow-manager: `feat(globe): additive MapVenue.org + rollup.last_run_created_at typing (v2 Lane 1 contract)`

---

## Task 2 — Fixtures v2 + org grouping + greedy nearest-neighbor chain builder

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (add org fields + `last_run_created_at` to the existing six venues — additive, so all 29 existing selector tests and the component tests keep passing)
- Create: `/Users/jn/code/godview-prototype/src/data/topologySelectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/topologySelectors.test.ts`

**Interfaces**

Consumes: `MapVenue`, `MapVenueOrg` from `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`.

Produces (in `topologySelectors.ts`, this task's slice):

```ts
export interface OrgChipDatum { id: string; name: string; color: string; venueCount: number; }
export const ORG_PALETTE: string[];                       // 6 hues, distinct from status colors
export function orgsFromVenues(venues: MapVenue[]): OrgChipDatum[];   // sorted by name, palette by index
export interface OrgArcDatum {
  key: string;                                            // `${orgId}:${fromId}->${toId}` — stable identity-diff key
  orgId: string; color: string;
  startLat: number; startLng: number; endLat: number; endLng: number;
}
export function buildOrgChains(venues: MapVenue[]): OrgArcDatum[];
export function hexToRgba(hex: string, alpha: number): string;
```

**Chain-builder determinism rules** (the unit-tested contract):
1. Eligible venues: `org` non-null AND `lat`/`lng` non-null (no-coords venues stay rail-only, as in v1).
2. Group by `org.id`; orgs processed in `org.id` order.
3. Within a group, sort venues by `location_id` ascending; the chain **starts at the smallest `location_id`**.
4. Repeat: from the current venue, hop to the **nearest unvisited** venue by haversine great-circle distance; on an exact tie, the smaller `location_id` wins.
5. Emit one arc per hop. An org with 0–1 eligible venues emits **zero arcs** (the real demo venue's "Demo Org" case).
6. Output is a pure function of the venue list — shuffled input produces identical arcs.

**Steps**

- [ ] Extend `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (committed with the red test, matching Plan B's fixture-with-red discipline). Org spread across the existing six venues (globeFixtures.ts:15-36) — designed to cover multi-venue chain, single-venue org, no-coords exclusion, and an org-less venue:

```ts
// Additions only — each venue object gains an `org` entry; two rollups gain last_run_created_at.
// loc_dal_north:  org: { id: "org_northline", name: "Northline Apparel" }
//                 rollup gains last_run_created_at: "2026-07-12T11:59:40Z"
// loc_dal_gal:    org: { id: "org_corebrew",  name: "Corebrew Coffee" }
// loc_sfo:        org: { id: "org_northline", name: "Northline Apparel" }
//                 rollup gains last_run_created_at: "2026-07-12T11:58:00Z"
// loc_berlin:     org: null                       // org-less venue (un-upgraded-backend shape)
// loc_billboard:  org: { id: "org_vantage",   name: "Vantage Motors" }   // single-venue org w/ coords
// loc_nocoords:   org: { id: "org_corebrew",  name: "Corebrew Coffee" }  // counted in chip, excluded from chain
```

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/data/topologySelectors.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { ORG_PALETTE, buildOrgChains, hexToRgba, orgsFromVenues } from "./topologySelectors";
import { venues } from "./globeFixtures";
import type { MapVenue } from "./apiTypes";

const v = (location_id: string, lat: number | null, lng: number | null,
  org: { id: string; name: string } | null): MapVenue => ({
  location_id, name: location_id, location_type: "store", city: null, country: null, lat, lng,
  rollup: { systems: 1, cameras: 1, displays: 1, worst_status: "active",
    active_ad_runs: 0, runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null },
  org,
});

describe("orgsFromVenues (spec §3: one chip per org present in the payload)", () => {
  it("groups by org id, sorts by name, assigns palette colors by index, counts venues", () => {
    expect(orgsFromVenues(venues)).toEqual([
      { id: "org_corebrew", name: "Corebrew Coffee", color: ORG_PALETTE[0], venueCount: 2 },
      { id: "org_northline", name: "Northline Apparel", color: ORG_PALETTE[1], venueCount: 2 },
      { id: "org_vantage", name: "Vantage Motors", color: ORG_PALETTE[2], venueCount: 1 },
    ]);
  });
  it("org-less venues (null or absent org) contribute no chip", () => {
    expect(orgsFromVenues([v("a", 0, 0, null)])).toEqual([]);
  });
  it("palette hues are distinct from the status colors (arcs must never read as health)", () => {
    for (const hex of ORG_PALETTE) {
      expect(["#34d399", "#f5b942", "#f2545b", "#5b6472"]).not.toContain(hex);
    }
  });
});

describe("buildOrgChains (greedy nearest-neighbor chain per org — NOT a mesh)", () => {
  it("fixture fleet: Northline gets its one hop; single-venue and coords-less orgs get none", () => {
    expect(buildOrgChains(venues)).toEqual([
      { key: "org_northline:loc_dal_north->loc_sfo", orgId: "org_northline",
        color: ORG_PALETTE[1],                       // Northline's chip color
        startLat: 32.9, startLng: -96.8, endLat: 37.62, endLng: -122.38 },
    ]);   // org_corebrew: only 1 venue has coords -> 0 arcs; org_vantage: 1 venue -> 0 arcs
  });
  it("chains greedily by distance, not input/sorted order", () => {
    // Same-org venues on a meridian: a(0), b(50), c(10), d(60). Sorted start = a;
    // greedy: a->c (10) -> b (40) -> d (10). Two of three hops differ from id order.
    const arcs = buildOrgChains([
      v("a", 0, 0, { id: "o1", name: "O1" }), v("b", 50, 0, { id: "o1", name: "O1" }),
      v("c", 10, 0, { id: "o1", name: "O1" }), v("d", 60, 0, { id: "o1", name: "O1" }),
    ]);
    expect(arcs.map((a) => a.key)).toEqual(["o1:a->c", "o1:c->b", "o1:b->d"]);
  });
  it("is deterministic under input reordering (pure function of the venue set)", () => {
    const shuffled = [...venues].reverse();
    expect(buildOrgChains(shuffled)).toEqual(buildOrgChains(venues));
  });
  it("an org with 0 or 1 eligible venues emits zero arcs (real demo venue's Demo Org case)", () => {
    expect(buildOrgChains([v("solo", 10, 10, { id: "o1", name: "O1" })])).toEqual([]);
    expect(buildOrgChains([v("nc", null, null, { id: "o1", name: "O1" })])).toEqual([]);
  });
  it("two orgs chain independently", () => {
    const arcs = buildOrgChains([
      v("a1", 0, 0, { id: "oa", name: "A" }), v("a2", 1, 0, { id: "oa", name: "A" }),
      v("b1", 0, 50, { id: "ob", name: "B" }), v("b2", 1, 50, { id: "ob", name: "B" }),
    ]);
    expect(arcs.map((a) => a.key)).toEqual(["oa:a1->a2", "ob:b1->b2"]);
  });
});

describe("hexToRgba", () => {
  it("converts hex + alpha to an rgba() string", () => {
    expect(hexToRgba("#45c4ff", 0.25)).toBe("rgba(69,196,255,0.25)");
    expect(hexToRgba("#a78bfa", 1)).toBe("rgba(167,139,250,1)");
  });
});
```

- [ ] Run: `npx vitest run src/data/topologySelectors.test.ts` — expect FAIL: `Cannot find module './topologySelectors'`.
- [ ] Run: `npx vitest run src/data/globeSelectors.test.ts` — the 29 pre-existing selector tests must still PASS with the extended fixtures (org fields are additive; nothing in `clusterVenues`/`sortRail` reads them — globeSelectors.ts:35-47, 76-119).
- [ ] Commit (red) via git-flow-manager: `test(globe): org chips grouping + greedy NN chain builder — fixtures v2 + red tests`
- [ ] Minimal implementation — create `/Users/jn/code/godview-prototype/src/data/topologySelectors.ts`:

```ts
// Pure Lane-1 topology selectors (globe v2 spec §3) — org chips, org arc chains, arc styling,
// zoom labels. No WebGL, no React; GlobeCanvas only wires these into globe.gl accessors.
import type { MapVenue } from "./apiTypes";

// ---- Org chips: one per org present in the payload, sorted by name, fixed palette by index.
export interface OrgChipDatum { id: string; name: string; color: string; venueCount: number; }

/** Hues deliberately distinct from the status colors (ok/warn/crit/off) — arcs are brand
 * networks, not health (spec §8: no traffic/health semantics implied). */
export const ORG_PALETTE = ["#45c4ff", "#a78bfa", "#f472b6", "#fb923c", "#2dd4bf", "#818cf8"];

export function orgsFromVenues(venues: MapVenue[]): OrgChipDatum[] {
  const byId = new Map<string, { name: string; count: number }>();
  for (const v of venues) {
    if (!v.org) continue;
    const cur = byId.get(v.org.id) ?? { name: v.org.name, count: 0 };
    cur.count += 1;
    byId.set(v.org.id, cur);
  }
  return [...byId.entries()]
    .sort(([ia, a], [ib, b]) => a.name.localeCompare(b.name) || ia.localeCompare(ib))
    .map(([id, o], i) => ({
      id, name: o.name, color: ORG_PALETTE[i % ORG_PALETTE.length], venueCount: o.count,
    }));
}

// ---- Org arc chains: greedy nearest-neighbor chain per org (deterministic; NOT a full mesh —
// 100 stores would be 4,950 mesh arcs, spec §3). Keys are identity-diff-stable.
export interface OrgArcDatum {
  key: string;                       // `${orgId}:${fromId}->${toId}`
  orgId: string; color: string;
  startLat: number; startLng: number; endLat: number; endLng: number;
}

const EARTH_R_KM = 6371;
function haversineKm(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const rad = Math.PI / 180;
  const dLat = (bLat - aLat) * rad, dLng = (bLng - aLng) * rad;
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_R_KM * Math.asin(Math.sqrt(h));
}

export function buildOrgChains(venues: MapVenue[]): OrgArcDatum[] {
  const colors = new Map(orgsFromVenues(venues).map((o) => [o.id, o.color]));
  const groups = new Map<string, MapVenue[]>();
  for (const v of venues) {
    if (!v.org || v.lat == null || v.lng == null) continue;   // rail-only venues never chain
    groups.set(v.org.id, [...(groups.get(v.org.id) ?? []), v]);
  }
  const arcs: OrgArcDatum[] = [];
  for (const [orgId, members] of [...groups.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    if (members.length < 2) continue;                         // 0-1 venues -> zero arcs
    const rest = [...members].sort((a, b) => a.location_id.localeCompare(b.location_id));
    let cur = rest.shift()!;                                  // chain starts at smallest id
    while (rest.length > 0) {
      let best = 0;
      for (let i = 1; i < rest.length; i++) {
        // strict < keeps the earlier (smaller location_id) entry on exact ties
        if (haversineKm(cur.lat!, cur.lng!, rest[i].lat!, rest[i].lng!)
          < haversineKm(cur.lat!, cur.lng!, rest[best].lat!, rest[best].lng!)) best = i;
      }
      const next = rest.splice(best, 1)[0];
      arcs.push({
        key: `${orgId}:${cur.location_id}->${next.location_id}`,
        orgId, color: colors.get(orgId)!,
        startLat: cur.lat!, startLng: cur.lng!, endLat: next.lat!, endLng: next.lng!,
      });
      cur = next;
    }
  }
  return arcs;
}
```

  Plus the color helper:

```ts
export function hexToRgba(hex: string, alpha: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}
```

- [ ] Run: `npx vitest run src/data/topologySelectors.test.ts src/data/globeSelectors.test.ts` — expect PASS.
- [ ] Commit (green): `feat(globe): orgsFromVenues chips + buildOrgChains greedy NN chain (deterministic, unit-tested)`

---

## Task 3 — Arc styling accessors + mid-zoom label selectors

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/topologySelectors.ts` (append)
- Test: `/Users/jn/code/godview-prototype/src/data/topologySelectors.test.ts` (append)

**Interfaces**

Consumes: `GlobeDot` from `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` (globeSelectors.ts:60-65).

Produces (appended to `topologySelectors.ts`):

```ts
export const ARC_DIM: { alpha: number; stroke: number };                  // 0.25 / 0.3 — dim default
export const ARC_LIT: { stroke: number; dashLength: number; dashGap: number; dashAnimateTime: number };
export function arcColorFor(a: OrgArcDatum, highlightOrgId: string | null): string;
export function arcStrokeFor(a: OrgArcDatum, highlightOrgId: string | null): number;
export function arcDashFor(a: OrgArcDatum, highlightOrgId: string | null):
  { dashLength: number; dashGap: number; dashAnimateTime: number };
export interface LabelDatum { id: string; lat: number; lng: number; text: string; size: number; color: string; }
export const LABEL_MAX_ALTITUDE: number;   // 2.0 — no labels above this (far zoom stays clean)
export const LABEL_FADE_START: number;     // 1.4 — fully opaque at/below this
export function labelAlpha(altitude: number): number;                     // 1 → 0 linear fade
export function labelsFor(dots: GlobeDot[], altitude: number): LabelDatum[];
```

**Styling decisions** (pinned by tests; visual tuning happens at E2E as scoped commits):
- Dim default: org color at 25% alpha, stroke 0.3, **solid** (dashLength 1, dashGap 0, dashAnimateTime 0 — no animation cost for the resting fleet).
- Highlighted: full org color, stroke 0.75, looping dash sweep (dashLength 0.5, dashGap 0.2, dashAnimateTime 1500 ms) — loop-as-"lit" per the Global Constraints lifecycle decision.
- Labels (spec §3): cluster label = `"${city} · ${n} venues"`, venue label = venue name; sizes 0.8 / 0.5; color `rgba(230,233,238,α)` (the app's text hex `#e6e9ee`, tailwind.config.ts:11) with α from `labelAlpha`, rounded to 2 decimals for stable strings. Which labels exist at which zoom falls out of `clusterVenues` (globeSelectors.ts:76-119): above `CLUSTER_ALTITUDE` (1.2, globeSelectors.ts:68) the dots ARE clusters, so mid zoom (1.2–2.0) shows city+count labels and below 1.2 shows venue-name labels. Deep-zoom node labels are Lane 2, not this plan.

**Steps**

- [ ] Write the failing tests — append to `/Users/jn/code/godview-prototype/src/data/topologySelectors.test.ts` (extend the import with `ARC_DIM, ARC_LIT, arcColorFor, arcDashFor, arcStrokeFor, labelAlpha, labelsFor, LABEL_FADE_START, LABEL_MAX_ALTITUDE, type OrgArcDatum`; also import `clusterVenues` from `./globeSelectors`):

```ts
describe("arc styling (dim by default; highlighted org lit with looping dash sweep)", () => {
  const arc: OrgArcDatum = { key: "o1:a->b", orgId: "o1", color: "#a78bfa",
    startLat: 0, startLng: 0, endLat: 1, endLng: 1 };
  it("dim default: org color at ARC_DIM.alpha, thin, solid, unanimated", () => {
    expect(arcColorFor(arc, null)).toBe(hexToRgba("#a78bfa", ARC_DIM.alpha));
    expect(arcStrokeFor(arc, null)).toBe(ARC_DIM.stroke);
    expect(arcDashFor(arc, null)).toEqual({ dashLength: 1, dashGap: 0, dashAnimateTime: 0 });
  });
  it("highlighted org: full color, thicker, looping dash sweep (loop == 'lit', one-shot is Plan F)", () => {
    expect(arcColorFor(arc, "o1")).toBe("#a78bfa");
    expect(arcStrokeFor(arc, "o1")).toBe(ARC_LIT.stroke);
    expect(arcDashFor(arc, "o1")).toEqual({
      dashLength: ARC_LIT.dashLength, dashGap: ARC_LIT.dashGap, dashAnimateTime: ARC_LIT.dashAnimateTime });
  });
  it("some OTHER org highlighted: this arc stays dim", () => {
    expect(arcColorFor(arc, "o2")).toBe(hexToRgba("#a78bfa", ARC_DIM.alpha));
    expect(arcDashFor(arc, "o2").dashAnimateTime).toBe(0);
  });
});

describe("labelsFor (spec §3: venue/cluster labels at mid zoom, fading by altitude)", () => {
  it("far zoom (>= LABEL_MAX_ALTITUDE) has no labels", () => {
    expect(labelsFor(clusterVenues(venues, 2.5), 2.5)).toEqual([]);
  });
  it("mid zoom: cluster labels are city + venue count, faded by altitude", () => {
    const alt = 1.7;                                     // halfway through the fade band
    const labels = labelsFor(clusterVenues(venues, alt), alt);
    const dallas = labels.find((l) => l.id === "label:cluster:Dallas|US")!;
    expect(dallas.text).toBe("Dallas · 2 venues");
    expect(dallas.size).toBe(0.8);
    expect(dallas.color).toBe("rgba(230,233,238,0.5)");  // labelAlpha(1.7) = 0.5
    expect(dallas.lat).toBeCloseTo((32.9 + 32.93) / 2, 5);
  });
  it("near zoom (below CLUSTER_ALTITUDE): every plotted venue gets a name label at full opacity", () => {
    const labels = labelsFor(clusterVenues(venues, 0.8), 0.8);
    expect(labels).toHaveLength(5);                      // all but loc_nocoords (never plotted)
    const sfo = labels.find((l) => l.id === "label:loc_sfo")!;
    expect(sfo.text).toBe("SFO Terminal 2");
    expect(sfo.size).toBe(0.5);
    expect(sfo.color).toBe("rgba(230,233,238,1)");
  });
  it("labelAlpha: 1 at/below LABEL_FADE_START, linear to 0 at LABEL_MAX_ALTITUDE", () => {
    expect(labelAlpha(1.0)).toBe(1);
    expect(labelAlpha(LABEL_FADE_START)).toBe(1);
    expect(labelAlpha(1.7)).toBeCloseTo(0.5, 5);
    expect(labelAlpha(LABEL_MAX_ALTITUDE)).toBe(0);
    expect(labelAlpha(3)).toBe(0);
  });
});
```

- [ ] Run: `npx vitest run src/data/topologySelectors.test.ts` — expect FAIL: `arcColorFor` (etc.) not exported.
- [ ] Commit (red): `test(globe): arc dim/lit styling accessors + mid-zoom label selectors with altitude fade (red)`
- [ ] Minimal implementation — append to `/Users/jn/code/godview-prototype/src/data/topologySelectors.ts` (add `import type { GlobeDot } from "./globeSelectors";` at the top):

```ts
// ---- Arc styling: dim by default; the highlighted org's whole network lights up with a
// looping dash sweep (arcDashAnimateTime LOOPS by design — reads as "lit"; the one-shot
// pulse lifecycle is Lane 3 / Plan F, spec §3 amendment).
export const ARC_DIM = { alpha: 0.25, stroke: 0.3 };
export const ARC_LIT = { stroke: 0.75, dashLength: 0.5, dashGap: 0.2, dashAnimateTime: 1500 };

export function arcColorFor(a: OrgArcDatum, highlightOrgId: string | null): string {
  return a.orgId === highlightOrgId ? a.color : hexToRgba(a.color, ARC_DIM.alpha);
}
export function arcStrokeFor(a: OrgArcDatum, highlightOrgId: string | null): number {
  return a.orgId === highlightOrgId ? ARC_LIT.stroke : ARC_DIM.stroke;
}
export function arcDashFor(a: OrgArcDatum, highlightOrgId: string | null) {
  return a.orgId === highlightOrgId
    ? { dashLength: ARC_LIT.dashLength, dashGap: ARC_LIT.dashGap, dashAnimateTime: ARC_LIT.dashAnimateTime }
    : { dashLength: 1, dashGap: 0, dashAnimateTime: 0 };    // solid + static at rest
}

// ---- Mid-zoom labels (spec §3): cluster = city + venue count, venue = name; fade by altitude.
// Plain three.js text (labelText takes a string, not HTML) — no escaping needed here.
export interface LabelDatum { id: string; lat: number; lng: number; text: string; size: number; color: string; }

export const LABEL_MAX_ALTITUDE = 2.0;   // no labels above (far zoom stays clean)
export const LABEL_FADE_START = 1.4;     // fully opaque at/below

export function labelAlpha(altitude: number): number {
  if (altitude >= LABEL_MAX_ALTITUDE) return 0;
  if (altitude <= LABEL_FADE_START) return 1;
  return (LABEL_MAX_ALTITUDE - altitude) / (LABEL_MAX_ALTITUDE - LABEL_FADE_START);
}

export function labelsFor(dots: GlobeDot[], altitude: number): LabelDatum[] {
  const alpha = Math.round(labelAlpha(altitude) * 100) / 100;
  if (alpha === 0) return [];
  const color = `rgba(230,233,238,${alpha})`;              // app text color #e6e9ee
  return dots.map((d) => d.kind === "cluster"
    ? { id: `label:${d.id}`, lat: d.lat, lng: d.lng,
        text: `${d.city} · ${d.venues.length} venues`, size: 0.8, color }
    : { id: `label:${d.id}`, lat: d.lat, lng: d.lng, text: d.venue.name, size: 0.5, color });
}
```

- [ ] Run: `npx vitest run src/data/topologySelectors.test.ts` — expect PASS.
- [ ] Commit (green): `feat(globe): arc dim/lit accessors + labelsFor with cluster/venue text and altitude fade`

---

## Task 4 — OrgChips component

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/OrgChips.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/globe/OrgChips.test.tsx`

**Interfaces**

```ts
export function OrgChips(props: {
  orgs: OrgChipDatum[];                // pre-computed by the page via orgsFromVenues
  activeId: string | null;             // highlighted org (page-owned state)
  onToggle: (id: string) => void;      // page toggles: same id -> clear
}): JSX.Element | null;
```

**Steps**

- [ ] Write the failing test `/Users/jn/code/godview-prototype/src/components/globe/OrgChips.test.tsx`:

```tsx
import { render, screen, fireEvent } from "@testing-library/react";
import { vi } from "vitest";
import { OrgChips } from "./OrgChips";
import { orgsFromVenues } from "../../data/topologySelectors";
import { venues } from "../../data/globeFixtures";

const orgs = orgsFromVenues(venues);

test("renders one chip per org with name and venue count", () => {
  render(<OrgChips orgs={orgs} activeId={null} onToggle={() => {}} />);
  const chips = screen.getAllByTestId("org-chip");
  expect(chips).toHaveLength(3);
  expect(chips[0].textContent).toContain("Corebrew Coffee");
  expect(chips[0].textContent).toContain("2");
  expect(chips[2].textContent).toContain("Vantage Motors");   // single-venue org still gets a chip
});

test("the active org's chip is marked; the rest are not", () => {
  render(<OrgChips orgs={orgs} activeId="org_northline" onToggle={() => {}} />);
  const states = screen.getAllByTestId("org-chip").map((c) => c.getAttribute("data-active"));
  expect(states).toEqual(["false", "true", "false"]);
});

test("clicking a chip calls onToggle with its org id (page owns toggle-to-clear)", () => {
  const onToggle = vi.fn();
  render(<OrgChips orgs={orgs} activeId={null} onToggle={onToggle} />);
  fireEvent.click(screen.getAllByTestId("org-chip")[1]);
  expect(onToggle).toHaveBeenCalledWith("org_northline");
});

test("renders nothing when the payload carries no orgs (un-upgraded backend)", () => {
  render(<OrgChips orgs={[]} activeId={null} onToggle={() => {}} />);
  expect(screen.queryByTestId("org-chips")).not.toBeInTheDocument();
});
```

- [ ] Run: `npx vitest run src/components/globe/OrgChips.test.tsx` — expect FAIL: `Cannot find module './OrgChips'`.
- [ ] Commit (red): `test(globe): org chips legend — per-org chip, active marking, toggle callback, empty-payload null (red)`
- [ ] Implementation — create `/Users/jn/code/godview-prototype/src/components/globe/OrgChips.tsx`:

```tsx
import type { OrgChipDatum } from "../../data/topologySelectors";

// Small org legend near the rail (spec §3 Lane 1). Chips only render when the payload
// carries orgs, so the page is unchanged against an un-upgraded backend.
export function OrgChips({ orgs, activeId, onToggle }: {
  orgs: OrgChipDatum[]; activeId: string | null; onToggle: (id: string) => void;
}) {
  if (orgs.length === 0) return null;
  return (
    <div data-testid="org-chips" className="flex flex-wrap gap-1.5 mb-2">
      {orgs.map((o) => {
        const active = activeId === o.id;
        return (
          <button key={o.id} data-testid="org-chip" data-org-id={o.id}
            data-active={active ? "true" : "false"} onClick={() => onToggle(o.id)}
            className={`flex items-center gap-1.5 rounded-full border px-2 py-0.5 font-mono text-[10.5px] ${
              active ? "bg-elev text-text" : "border-border text-dim hover:bg-elev"}`}
            style={active ? { borderColor: o.color } : undefined}>
            <span className="h-2 w-2 rounded-full shrink-0" style={{ backgroundColor: o.color }} />
            <span className="truncate max-w-[120px]">{o.name}</span>
            <span className="text-faint">{o.venueCount}</span>
          </button>
        );
      })}
    </div>
  );
}
```

- [ ] Run: `npx vitest run src/components/globe/OrgChips.test.tsx` — expect PASS.
- [ ] Commit (green): `feat(globe): OrgChips legend — per-org color chip with venue count and active state`

---

## Task 5 — GlobeCanvas arc/label layers + page highlight wiring

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` (new props + two identity-diffed layers + `onGlobeClick` clear)
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` (existing renders gain the new required props; rerender coverage)
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` (highlight state, chips, arcs/labels memos)
- Test: `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx` (append — highlight interaction is the observable red surface)

**Interfaces**

GlobeCanvas props change (extends GlobeCanvas.tsx:16-22):

```ts
export function GlobeCanvas(props: {
  dots: GlobeDot[];
  mode: MapMode;
  focus: Focus | null;
  arcs: OrgArcDatum[];                     // NEW — pre-built org chains
  labels: LabelDatum[];                    // NEW — pre-built mid-zoom labels
  highlightOrgId: string | null;           // NEW — read via ref inside arc accessors
  onDotClick: (dot: GlobeDot) => void;
  onAltitudeChange: (altitude: number) => void;
  onBackgroundClick?: () => void;          // NEW — globe-background click clears highlight
}): JSX.Element;
```

**Highlight semantics (page-owned, stated once):** `highlightOrgId` state in `Globe.tsx`. Set by: org-chip click (toggle — same id clears), rail-row click and venue-dot click (the venue's `org?.id ?? null`, alongside the existing panel-open + fly, Globe.tsx:27-35). Cleared by: clicking the active chip again, selecting an org-less venue, or clicking the globe background (`onGlobeClick`). Closing the panel does NOT clear the highlight (a chip can be lit with no panel). Cluster-dot click keeps its v1 fly-to-de-cluster behavior (Globe.tsx:34) and does not touch the highlight.

**Steps**

- [ ] Write the failing tests — append to `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx` (its existing `vi.mock("../data/api", ...)` block at Globe.test.tsx:7-11 already feeds the org-bearing fixtures; jsdom renders the GlobeCanvas fallback, so chips are the observable highlight surface here — arcs are E2E-verified):

```tsx
test("renders one org chip per org in the payload, near the rail", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  const chips = screen.getAllByTestId("org-chip");
  expect(chips).toHaveLength(3);
  expect(chips.map((c) => c.textContent).join(" ")).toContain("Northline Apparel");
});

test("chip click highlights that org; clicking the same chip again clears", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  const northline = screen.getAllByTestId("org-chip")
    .find((c) => c.getAttribute("data-org-id") === "org_northline")!;
  fireEvent.click(northline);
  expect(northline.getAttribute("data-active")).toBe("true");
  fireEvent.click(northline);
  expect(northline.getAttribute("data-active")).toBe("false");
});

test("selecting a venue (rail row) highlights its org's chip", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  const dallas = screen.getAllByTestId("venue-row")
    .find((r) => r.textContent?.includes("Dallas North Mall"))!;
  fireEvent.click(dallas);
  const northline = screen.getAllByTestId("org-chip")
    .find((c) => c.getAttribute("data-org-id") === "org_northline")!;
  expect(northline.getAttribute("data-active")).toBe("true");
});

test("selecting an org-less venue clears any highlight", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  fireEvent.click(screen.getAllByTestId("org-chip")[0]);      // light Corebrew
  const berlin = screen.getAllByTestId("venue-row")
    .find((r) => r.textContent?.includes("Berlin Flagship"))!; // fixture org: null
  fireEvent.click(berlin);
  const states = screen.getAllByTestId("org-chip").map((c) => c.getAttribute("data-active"));
  expect(states).toEqual(["false", "false", "false"]);
});
```

- [ ] Also update `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` in the same red commit: every existing `<GlobeCanvas …/>` render gains `arcs={buildOrgChains(venues)} labels={[]} highlightOrgId={null}` (import `buildOrgChains` from `../../data/topologySelectors`), and the rerender test flips `highlightOrgId` between `null` and `"org_northline"` and passes a non-empty `labels` array. These assert the fallback survives the new props and the throwing `globe.gl` mock (GlobeCanvas.test.tsx:11) still proves three never loads — they are guardrail updates riding in the red commit (the genuinely-failing tests are the Globe.test.tsx ones above; the imperative arc/label wiring itself is only observable in the live E2E, exactly as v1's point wiring was).
- [ ] Run: `npx vitest run src/pages/Globe.test.tsx src/components/globe/GlobeCanvas.test.tsx` — expect FAIL: no `org-chip` testids rendered by the page (and GlobeCanvas prop-type errors surface under `npx tsc -b`).
- [ ] Commit (red): `test(globe): page-level org-chip highlight interactions + GlobeCanvas new-prop guardrails (red)`
- [ ] Implement `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` — four surgical extensions to the existing island (everything else untouched):

  1. **Imports + props + refs** — import `arcColorFor, arcDashFor, arcStrokeFor, type LabelDatum, type OrgArcDatum` from `../../data/topologySelectors`; add the three new props (+ optional `onBackgroundClick`); add latest-value refs beside `modeRef` (GlobeCanvas.tsx:28-30):

```ts
  const highlightRef = useRef(highlightOrgId); highlightRef.current = highlightOrgId;
  const bgClickRef = useRef(onBackgroundClick); bgClickRef.current = onBackgroundClick;
```

  2. **Init chain additions** — inside the one-time init (after `.onZoom(...)`, GlobeCanvas.tsx:66; the existing `as any` cast at GlobeCanvas.tsx:49 already covers accessor typing). Datum field names `startLat`/`startLng`/`endLat`/`endLng` match three-globe's accessor defaults (three-globe.d.ts:80-87), so only styling accessors are wired:

```ts
        // Org arcs (v2 Lane 1): dim at rest; the highlighted org's network lights + sweeps.
        .arcColor((a: OrgArcDatum) => arcColorFor(a, highlightRef.current))
        .arcStroke((a: OrgArcDatum) => arcStrokeFor(a, highlightRef.current))
        .arcAltitudeAutoScale(0.4)
        .arcDashLength((a: OrgArcDatum) => arcDashFor(a, highlightRef.current).dashLength)
        .arcDashGap((a: OrgArcDatum) => arcDashFor(a, highlightRef.current).dashGap)
        .arcDashAnimateTime((a: OrgArcDatum) => arcDashFor(a, highlightRef.current).dashAnimateTime)
        .arcsTransitionDuration(0)          // no enter-tween: restyles must not re-tessellate mid-dash
        // Mid-zoom labels (v2 Lane 1): plain text sprites, content/fade pre-computed in selectors.
        .labelLat((l: LabelDatum) => l.lat)
        .labelLng((l: LabelDatum) => l.lng)
        .labelText((l: LabelDatum) => l.text)
        .labelColor((l: LabelDatum) => l.color)
        .labelSize((l: LabelDatum) => l.size)
        .labelAltitude(0.015)
        .labelResolution(2)
        .labelIncludeDot(false)             // points layer already draws the dots
        .labelsTransitionDuration(0)        // labels re-set on zoom ticks; tweens would churn
        .onGlobeClick(() => bgClickRef.current?.())   // background click clears highlight
```

  3. **Arc layer effect** — after the existing points/rings data effect (GlobeCanvas.tsx:93-107), same Map-keyed identity cache; `highlightOrgId` in the deps so a toggle re-sets `arcsData` with the SAME datum identities and the accessors re-evaluate (the proven v1 restyle mechanism — mode in deps at GlobeCanvas.tsx:107). Only the toggled org's dash values change, so only its arcs restart their sweep; every other arc keeps its state (spec §3 identity-diff amendment):

```ts
  // ARCS — identity-diffed like points; stable key `${orgId}:${fromId}->${toId}`.
  const arcDatumsRef = useRef(new Map<string, OrgArcDatum>());
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe) return;
    const prev = arcDatumsRef.current;
    const next = new Map<string, OrgArcDatum>();
    for (const a of arcs) {
      const d = prev.get(a.key) ?? { ...a };
      Object.assign(d, a);                 // refresh fields in place, keep object identity
      next.set(a.key, d);
    }
    arcDatumsRef.current = next;
    globe.arcsData([...next.values()]);
  }, [arcs, highlightOrgId, ready]);
```

  4. **Label layer effect** — identical pattern keyed on `l.id`:

```ts
  // LABELS — identity-diffed; re-set on zoom ticks (labels array changes with altitude,
  // same cadence the points layer already re-sets on — Globe.tsx recomputes dots per tick).
  const labelDatumsRef = useRef(new Map<string, LabelDatum>());
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe) return;
    const prev = labelDatumsRef.current;
    const next = new Map<string, LabelDatum>();
    for (const l of labels) {
      const d = prev.get(l.id) ?? { ...l };
      Object.assign(d, l);
      next.set(l.id, d);
    }
    labelDatumsRef.current = next;
    globe.labelsData([...next.values()]);
  }, [labels, ready]);
```

- [ ] Implement `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` — surgical additions (imports: `OrgChips`, `buildOrgChains, labelsFor, orgsFromVenues` from `../data/topologySelectors`):

```tsx
  // after the existing state (Globe.tsx:14-19):
  const [highlightOrgId, setHighlightOrgId] = useState<string | null>(null);

  // after the existing memos (Globe.tsx:22-23):
  const orgs = useMemo(() => orgsFromVenues(venues), [venues]);
  const arcs = useMemo(() => buildOrgChains(venues), [venues]);
  const labels = useMemo(() => labelsFor(dots, altitude), [dots, altitude]);

  const toggleOrg = (id: string) => setHighlightOrgId((cur) => (cur === id ? null : id));
  // in selectVenue (Globe.tsx:27-31), add one line:
  //   setHighlightOrgId(v.org?.id ?? null);
```

  Render changes: `<GlobeCanvas … arcs={arcs} labels={labels} highlightOrgId={highlightOrgId} onBackgroundClick={() => setHighlightOrgId(null)} />` (Globe.tsx:49-50); mount `<OrgChips orgs={orgs} activeId={highlightOrgId} onToggle={toggleOrg} />` at the top of the desktop rail column (above `<VenueRail …/>`, Globe.tsx:45-47) and at the top of the mobile rail sheet (Globe.tsx:72-74) — "near the rail" per spec §3.
- [ ] Run: `npx vitest run src/pages/Globe.test.tsx src/components/globe/GlobeCanvas.test.tsx src/components/globe/OrgChips.test.tsx` — expect PASS (including all pre-existing Globe page tests).
- [ ] Run: `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe): org arc + label layers (identity-diffed), OrgChips in rail, page highlight state`

---

## Task 6 — Full suite, typecheck, build, lint, PR

**Files** — none new; fixes only if something below fails (each fix scoped + committed with reason).

**Steps**

- [ ] `npm test` (= `npx vitest run`) — full suite green, including all pre-existing v1 globe/fleet/dashboard tests.
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. Confirm the three/globe.gl code still lives in its lazy chunk (the dynamic import at GlobeCanvas.tsx:41 is untouched, but verify the entry chunk didn't absorb it via the new `topologySelectors` imports — `topologySelectors.ts` must import NOTHING from globe.gl/three; `ls -lS dist/assets | head`).
- [ ] Quick visual smoke without a backend: `npm run dev`, open `http://localhost:5173/globe` — page must render the AsyncState error banner (or an empty rail) with zero chips and zero arcs, no crash (the optional-additive contract at work).
- [ ] Ask git-flow-manager to push the branch and open a PR titled `feat(globe): org arcs + chips + highlight + labels (Plan D, v2 Lane 1)` against `main` with the structured description (Summary / Motivation / Implementation / Tests / Risks; note the Plan C dependency for live data). Request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings before Task 7.
- [ ] Commit any review fixes as scoped commits (red→green where behavior changes).

---

## Task 7 — Live Playwright E2E (after Plan C is merged + seed v2 applied)

**DEPENDENCY:** Runs only after **Plan C (mras-ops: seed v2 retailer split + `org` field + `last_run_created_at`) is merged, seed v2 is applied to the dev DB** (including the 3 same-city venues — hudson/battersea/emirates, Plan C Task 1), and the dev stack is up (ops-api on `:8080`, projector running). If Plan C's merged payload diverges from the Contract (consumes) in Global Constraints — field name, nesting (`org` on the venue, `last_run_created_at` inside `rollup`), or nullability — reconcile `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` + selectors first as a scoped fix commit.

**Files** — none (live drill; findings become fix commits on the same branch or follow-up issues).

**Steps**

- [ ] Preconditions: seed v2 applied; dev stack up; `npm run dev` in the worktree (`http://localhost:5173`), `VITE_OPS_API_URL` unset (defaults to `http://localhost:8080`).
- [ ] **Headless WebGL note (v1 finding):** v1's live E2E rendered real WebGL in headless Chromium with **no special flags** — expect the same; if the canvas is absent / `globe-fallback` shows, fall back to v1's recipe (DOM assertions regardless + headed screenshot pass).
- [ ] Navigate to `http://localhost:5173/globe`. Assert `[data-testid="globe-canvas"] canvas` exists.
- [ ] **No re-init on poll (unchanged guardrail):** stash the canvas element reference, wait ≥ 12 s (two poll ticks), assert the same element is still attached.
- [ ] **Chips from live data:** assert `[data-testid="org-chip"]` count ≥ 5 (Plan C seeds 4 retailer orgs — Northline Apparel, Vantage Motors, Corebrew Coffee, Meridian Screens — + the real venue's "Demo Org") and the chip texts include the seeded retailer names (per Plan C's seed, e.g. "Northline Apparel"). The Demo Org chip is a **single-venue org — it must render and highlight without arcs and without errors** (spec §3 amendment).
- [ ] **Arcs render dim by default:** screenshot the resting far-zoom globe — retailer chains visible as faint colored arcs (visual evidence; arcs are three.js objects, not DOM).
- [ ] **Org chip click lights the right network:** click a retailer chip; assert its `data-active="true"`; take TWO screenshots ~1 s apart — the org's arcs are brighter/thicker and the dash sweep has visibly moved between frames (loop = lit); other orgs' arcs stayed dim.
- [ ] **Clicking again clears:** click the same chip; assert `data-active="false"`; screenshot shows all arcs dim again.
- [ ] **Rail-row highlight:** click a retailer venue's rail row — panel opens (v1 behavior) AND that org's chip goes active; screenshot.
- [ ] **Background click clears:** click empty ocean on the globe canvas; assert every chip is `data-active="false"`.
- [ ] **Clustering + labels at mid zoom:** at far zoom, the seeded same-city venues render as one cluster dot (screenshot; the rail still lists them separately). Click that cluster dot — the v1 fly-to lands at altitude `CLUSTER_ALTITUDE * 0.6` = 0.72 (GlobeCanvas.tsx:114), below `LABEL_FADE_START`, so venue-name labels must be visible at full opacity (screenshot). Zoom out slowly through the 1.2–2.0 band and screenshot a cluster label ("<City> · N venues") mid-fade.
- [ ] **Un-highlighted regression pass:** mode switch (Health/Live), venue panel, and mobile 390px layout (chips render inside the rail sheet) all still work — quick click-through, no full re-drill.
- [ ] Capture screenshots (resting arcs, lit network x2 frames, labels near + mid) for the session log. Tune arc/label constants (`ARC_DIM`/`ARC_LIT`/sizes/`arcAltitudeAutoScale`) against real screen space if needed — each tune is a scoped commit updating the pinned selector tests in the same commit.
- [ ] Fix anything found (scoped commits, red→green where code changes), then ask git-flow-manager to merge the PR (merge commit) after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with `repo@sha`, E2E evidence, gotchas) and file remaining follow-ups as GitHub issues (e.g. `onArcClick`-to-highlight nicety; cluster-rollup aggregation of `last_run_created_at` — deferred to Lane 3).

---

## Self-review notes (spec §3 "Globe (godview-prototype)" coverage check, done at plan time)

- Org arcs: per-retailer greedy nearest-neighbor chain, pure + unit-tested + deterministic (rules enumerated in Task 2), NOT a mesh — Task 2. ✓
- 0–1-venue orgs (the REAL demo venue's "Demo Org") emit zero arcs and still get a chip — Tasks 2/4, E2E-asserted in Task 7. ✓
- Arcs dim by default via `arcsData`; highlight = brighter color + `arcDashAnimateTime` sweep — Tasks 3/5, exact accessor names verified against three-globe.d.ts:78-113. ✓
- Animation-lifecycle amendment honored: loop-as-"lit" decided explicitly; one-shot lifecycle deferred to Plan F — Global Constraints + Task 3. ✓
- Highlight surfaces: venue dot (via `selectVenue`, shared with rail rows) + rail row + org chip; clears on re-click / org-less venue / globe background (`onGlobeClick`, globe.gl.d.ts:73) — Task 5. ✓
- Org chips legend near the rail, one chip per org in the payload — Tasks 4/5 (desktop rail column + mobile sheet). ✓
- Labels via `labelsData` at mid zoom: cluster = city + venue count, venue = name, fading by altitude; deep-zoom node labels left to Lane 2 — Task 3 (three-globe.d.ts:300-327). ✓
- Identity-diff discipline for every new layer datum (stable keys, Map cache, mutate-in-place) — Task 5, mirroring GlobeCanvas.tsx:93-107; restyle via same-identity `arcsData` re-set (v1's proven mode-switch mechanism). ✓
- jsdom never touches three: all logic in pure selectors; throwing `vi.mock("globe.gl", ...)` tripwire kept (GlobeCanvas.test.tsx:11); GlobeCanvas remains the only imperative surface. ✓
- Optional-additive typing (`org?`, `last_run_created_at?`) so the UI runs against an un-upgraded backend (zero chips / zero arcs, no crash) — Tasks 1/6 smoke. ✓
- No new deps; no changes to seeding/API (Plan C's job); no traffic/route semantics implied by arcs (spec §8). ✓
