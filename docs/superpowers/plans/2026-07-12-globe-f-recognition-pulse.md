# Globe v2 — Plan F: Lane 3 recognition pulse (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recognitions visible on the globe, poll-delta driven — per the spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md` §5.
Far zoom: when a venue's `last_run_created_at` advances (or `playing_count` rises), the venue dot
pulses and ONE dash sweep runs along its org's arcs. Deep zoom (Plan E's exploded venue): when an
ad_run in the detail payload transitions planned → dispatched/playing, the attributed camera node
flashes and a traveling pulse runs camera → system → display along the Lane 2 connectors. While in
this code, fix godview-prototype **#14 item 1**: ring datum identity, so the v1 composing/failed
ring pulse no longer resets phase on every poll.

**Architecture:** A pure **delta engine** (`/Users/jn/code/godview-prototype/src/data/pulseDelta.ts`)
compares consecutive poll payloads and returns pulse descriptors; a pure datum-identity helper
(`upsertDatums`, appended to Plan E's existing
`/Users/jn/code/godview-prototype/src/components/globe/datumCache.ts` beside its `diffDatums`)
extends the identity-cache discipline — which Plan E already generalized and refactored the point
layer onto — to the remaining animated layers (rings, pulse/sweep datums). A tiny jsdom-testable hook
(`/Users/jn/code/godview-prototype/src/hooks/usePollDelta.ts`) holds the previous payload and emits
sequenced pulse batches. ALL animation lifecycles that aren't pure — one-shot ring timers, sweep-arc
removal timers, the requestAnimationFrame dash-offset loop — live ONLY in GlobeCanvas (the
imperative island) plus a dynamically-imported three helper module that jsdom can never reach.
Delta engine, camera attribution, path computation, and sweep-arc selection are pure and
fixture-tested against consecutive-poll fixture pairs.

**Tech Stack:** React 19 + Vite 8 + vitest 4 / Testing Library (jsdom); globe.gl@2.46.1;
`three@0.185.1` is already a DIRECT pinned dependency (Plan E promoted it from transitive — do
NOT re-pin or add a second entry). **No new dependencies** — the
traveling pulse uses `three/examples/jsm/lines` (`Line2`/`LineGeometry`/`LineMaterial`), whose
`dashOffset` uniform is the per-frame animation knob (verified at
`/Users/jn/code/godview-prototype/node_modules/three/examples/jsm/lines/LineMaterial.js:14,622` —
core `LineDashedMaterial` has NO dashOffset; do not use it).

## Global Constraints

- **Lane order dependency:** this plan branches from `main` AFTER Plans C (mras-ops seed v2 + API
  additions), D (org arcs/chips/labels), and E (anchored explosion) are merged. Task 1 is a
  contract preflight that verifies the merged surface against the "Contract (consumes)" section
  below; on any mismatch, reconcile the contract first (scoped commit) or stop and report — do not
  improvise against a divergent Plan D/E surface.
- **Poll-delta, not push (owner decision, spec §2):** trigger sources are the REAL pipeline —
  `python3 -m scripts.demo_traffic` for seeded venues, live recognition on the demo box. Accepted
  lag ≈ **2–7 s** (5 s poll at `/Users/jn/code/godview-prototype/src/pages/Globe.tsx:14` + ~2–3 s
  projector settle, `/Users/jn/code/mras-ops/scripts/demo_traffic.py:42-44`). The E2E task must
  judge "responsive", not "instant".
- **Identity-diff discipline (spec §3 amendment, generalized):** three-globe keys per-datum
  animation state on datum **object identity**. v1's rings mint fresh objects every poll
  (`/Users/jn/code/godview-prototype/src/data/globeSelectors.ts:190-200` returns fresh datums;
  `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx:106` re-sets them
  verbatim) — that is the confirmed #14 item-1 phase-reset bug. EVERY animated datum this plan
  touches or adds (status rings, pulse rings, base+sweep arcs, custom-layer pulse datums) goes
  through the Task 2 identity cache. A one-shot datum is identity-stable for its whole lifetime.
- **One-shot lifecycles are explicit:** `arcDashAnimateTime` and ring `repeatPeriod` are
  continuous LOOPS (three-globe.d.ts:110-111, 296-297). Every one-shot animation = temporary
  datum added → removal timer fires after exactly one period → datum removed. All timers are
  tracked and cleared on unmount; the rAF loop is cancelled on unmount (hours-long TV sessions).
- **jsdom never touches three:** the delta engine/hook/selectors import no three. The traveling
  pulse's three code lives in `/Users/jn/code/godview-prototype/src/components/globe/pulseLayer.ts`,
  reached ONLY via dynamic `import("./pulseLayer")` inside GlobeCanvas after the WebGL guard —
  same pattern as `import("globe.gl")` (GlobeCanvas.tsx:41). The GlobeCanvas jsdom test adds a
  throwing `vi.mock` for it, like the existing globe.gl throwing mock.
- **Engine inert on un-upgraded payloads:** every consumed field that Plans C/E added is typed
  optional; a payload without `last_run_created_at` / `display_id` / `org` degrades signal-by-signal
  (documented per function) and NEVER crashes. First poll (no previous) → no pulses. Coalescing —
  two recognitions inside one poll window animate once per affected path — is accepted (spec §8).
- **Color:** green default (`#34d399`, the existing `TONE_HEX.ok`); rainbow behind ONE config
  constant (`PULSE_RAINBOW` in pulseDelta.ts — a one-line switch).
- **All git via the git-flow-manager subagent**
  (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers
  never run raw `git`/`gh`. Work on branch `feat/globe-f-recognition-pulse` in a dedicated worktree
  of `/Users/jn/code/godview-prototype`. **Commit each failing test separately from the
  implementation that greens it** (red→green pairs must show in history; watch the test fail).
  Merge commits (not squash) on PR merge.
- Reference every file by absolute path.

## Contract (consumes) — verbatim, for gate-check against Plans C and E (and D)

**From Plan C (mras-ops API, additive; optional on the frontend):**

```ts
// MapVenueRollup gains (spec §3 API: max(ar_created_at) in the existing `act` CTE):
last_run_created_at?: string | null;
// playing_count already ships in v1 (/Users/jn/code/mras-ops/api/src/godview/map.py:124):
playing_count?: number;
// MapVenue gains (dominant org by system count, tie-break count DESC, organization_id):
org?: { id: string; name: string } | null;
// MapAdRun (detail payload ad_runs rows) gains — the traveling pulse's truthful display end:
display_id?: string | null;
// MapSystemDevice.screen_id — ALREADY typed by Plan E Task 2 (required, NULLABLE — the one
// convention everywhere; server sends it on cameras AND displays, map.py:150,154):
screen_id: string | null;
```

All five are typed in `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`. Plan D typed `org`
+ `last_run_created_at`; Plan E typed `screen_id` (plus `MapSystem.system_type`); `playing_count`
is v1 (Plan A). Task 1 confirms, and Task 3 adds the ONLY missing field:
`MapAdRun.display_id?: string | null`. There is NO `playbacks` array in the detail payload — status
transitions on `ad_runs` are the deep trigger (spec §5 amendment).

**From Plan D (org arcs, godview-prototype):**

```ts
// Pure selector (Plan D's actual module: /Users/jn/code/godview-prototype/src/data/topologySelectors.ts):
export interface OrgArcDatum {
  key: string;                       // `${orgId}:${fromId}->${toId}` — Plan D's identity-diff key
  orgId: string; color: string;
  startLat: number; startLng: number; endLat: number; endLng: number;
}
export function buildOrgChains(venues: MapVenue[]): OrgArcDatum[];   // greedy nearest-neighbor per org
```

- GlobeCanvas owns ONE `arcsData` set (base org arcs, identity-diffed). Plan F merges its
  temporary sweep datums into that same set — never a second arcs owner.
- Plan D wires arc color/stroke/dash as **per-datum accessors**, but they derive styling from
  `arcColorFor/arcStrokeFor/arcDashFor(a, highlightOrgId)` — they do NOT read datum-carried
  style fields. Task 6 extends those accessors to prefer sweep-datum-carried overrides (sweep
  datums carry their own color/stroke/dashLength/dashGap/dashInitialGap/dashAnimateTime) while
  preserving Plan D's styling for base arcs (flag the accessor change in the PR).

**From Plan E (anchored explosion, godview-prototype):**

```ts
// Pure layout (Plan E's actual module: /Users/jn/code/godview-prototype/src/data/explodeSelectors.ts):
export interface ExplodedNode {
  key: string;                      // Plan E convention: `${type}:${id}` — datum identity AND panel key
  type: "system" | "camera" | "display";   // Plan E's ExplodedNodeType
  id: string;
  venueId: string; systemId: string | null;
  name: string | null; status: string;
  screen_id: string | null; last_seen_at: string | null;
  lat: number; lng: number; altitude: number;
}
export interface ExplodedConnector { key: string; from: GeoPoint; to: GeoPoint; systemId: string; status: string; }
// (layout fn: explodeVenue(detail, tier) -> ExplosionLayout; Plan F consumes only nodes[])
```

- **Detail-poll ownership (spec §4 amendment):** the exploded venue owns its own
  `fetchMapLocation` poll — Plan E's `useVenueDetailPoll(explodedId)` hook at
  `/Users/jn/code/godview-prototype/src/hooks/useVenueDetailPoll.ts` (5 s), running whenever a
  venue is exploded, panel open or not. Plan F's deep delta consumes THAT hook's consecutive
  `MapLocationDetail` payloads (`detail`) — Plan F adds no second detail poll.
- GlobeCanvas owns ONE `customLayerData` set (Plan E connectors). Plan F merges pulse datums into
  it with a `kind` discriminator on the datum (`customThreeObject` switches on kind) — never a
  second custom-layer owner. three-globe animates nothing on this layer
  (three-globe.d.ts:362-367) — per-frame updates are ours via rAF.
- The PAGE owns the exploded state (Plan E Task 8: `explodedId` via `explodedVenueId`, `detail`
  via `useVenueDetailPoll`, layout via the `explodeVenue` memo — `explosion.nodes` are the layout
  nodes) and passes `explosion`/`liveSystems` down to GlobeCanvas; GlobeCanvas's `onPovChange`
  prop (Plan E's rename of `onAltitudeChange`) surfaces `{lat, lng, altitude}`.

**Trigger-source ground truth (read-only, verified this plan):**

- Foldable ad_run (event_type, status) pairs: `planned | dispatched | playing | completed | failed`
  (`/Users/jn/code/mras-ops/api/src/projector/routing.py:26-30`).
- Generator beat order (`/Users/jn/code/mras-ops/scripts/demo_traffic.py:84-107`): composition
  queued/rendering → **ad_run planned** → composition rendered → playback dispatched + **ad_run
  dispatched** → playback started + **ad_run playing** → playback ended + ad_run completed; beats
  are ≥ ~3 s apart (settle gap, demo_traffic.py:44,81-82), so a 5 s poll usually sees `planned`
  before `dispatched`.
- Camera pick ground truth (`/Users/jn/code/mras-ops/scripts/demo_traffic.py:150-153`): the
  system's **first non-retired camera ordered by `screen_id`**. `ad_runs` has no camera column —
  this heuristic is spec-locked (§5 amendment) and correct-by-construction for seeded pulses.
  Do NOT plan a schema change. The display end is truthful via `ad_runs.display_id`.

---

## Task 1 — Worktree + contract preflight

**Files** — none modified (read-only verification; no TDD pair).

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/globe-f-recognition-pulse` from
  `main` for `/Users/jn/code/godview-prototype` (Plans C/D/E must already be merged to `main`;
  if not, STOP and report). All subsequent paths refer to that worktree's checkout (written here
  as the repo's canonical absolute paths).
- [ ] Verify the merged Plan C surface from the worktree (types + live payload):
  `grep -n "last_run_created_at\|display_id\|screen_id\|org" src/data/apiTypes.ts` — record which
  of the five contract fields are already typed. If the dev stack is up, also
  `python3 -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://localhost:8080/god-view/map')); print(sorted(d['venues'][0]['rollup'].keys()), d['venues'][0].get('org'))"`
  and the same for one `/god-view/map/locations/{id}` payload (`ad_runs[0]` keys must include
  `display_id`; `systems[0].cameras[0]` keys must include `screen_id`).
- [ ] Verify the merged Plan D surface: confirm `buildOrgChains` and the `OrgArcDatum` shape in
  `/Users/jn/code/godview-prototype/src/data/topologySelectors.ts` (gate-checked against Plan D);
  locate where GlobeCanvas sets `arcsData` and confirm the arc color/stroke/dash accessors are
  per-datum (`arcColorFor`/`arcStrokeFor`/`arcDashFor`). Record any deviation.
- [ ] Verify the merged Plan E surface: locate the explosion layout module, the `ExplodedNode`
  shape and node-id convention, the exploded-venue detail poll in
  `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`, and the `customLayerData` merge point in
  GlobeCanvas. Record actual names.
- [ ] If any assumed name/shape differs from the Contract section: update THIS plan's remaining
  tasks mechanically (name substitution only) and note the deltas in the PR description. If a
  shape differs structurally (e.g. no per-venue detail poll exists), STOP and report — that is a
  Plan E gap, not a Plan F improvisation.
- [ ] Sanity: `npx vitest run` and `npx tsc -b` green on the fresh branch before any change.

---

## Task 2 — Rings-identity fix: `upsertDatums` + role-keyed ring ids (godview #14 item 1)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/datumCache.ts` (Plan E's module —
  append `upsertDatums` beside its `diffDatums`; do NOT create a second cache module)
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/datumCache.test.ts` (append)
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` (`ringsFor` ids gain the
  ring role)
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts` (ring id assertions)
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` (rings + points
  go through the cache)

**Interfaces**

```ts
// Appended to Plan E's datumCache.ts (which already generalized the point cache via diffDatums
// and refactored the point layer onto it, Plan E Task 4) — an id-keyed convenience for datums
// that carry `id` (rings, pulse rings). three-globe keys per-datum animation state (ring phase,
// arc dash phase) on datum OBJECT identity; fresh objects every poll restart every animation (#14).
export function upsertDatums<T extends { id: string }>(
  prev: Map<string, T>, next: T[],
): { map: Map<string, T>; list: T[] };
// Known id -> the PREVIOUS object, mutated in place (Object.assign) and reused.
// New id -> the new object. Ids absent from `next` are dropped from the returned map.
```

`ringsFor` change: ring ids become role-qualified — `ring:${dot.id}:composing` /
`ring:${dot.id}:failed` — so the island's Map is "keyed on venue id + ring role" (spec §5) and a
composing→failed flip is a NEW datum (fresh phase, correct), while composing→composing across
polls reuses the same object (phase holds).

**Steps**

- [ ] Write the failing tests. Append to
  `/Users/jn/code/godview-prototype/src/components/globe/datumCache.test.ts` (Plan E's file):

```ts
import { describe, expect, it } from "vitest";
import { upsertDatums } from "./datumCache";

interface D { id: string; color: string; }

describe("upsertDatums (identity-stable datums, godview #14 item 1)", () => {
  it("reuses the SAME object reference for a known id, with fields updated in place", () => {
    const a = { id: "x", color: "old" };
    const first = upsertDatums(new Map<string, D>(), [a]);
    const second = upsertDatums(first.map, [{ id: "x", color: "new" }]);
    expect(second.list[0]).toBe(a);              // identity held -> animation phase holds
    expect(a.color).toBe("new");                 // but content updated
  });
  it("mints new objects only for new ids and drops ids absent from next", () => {
    const first = upsertDatums(new Map<string, D>(), [{ id: "x", color: "c" }]);
    const second = upsertDatums(first.map, [{ id: "y", color: "c" }]);
    expect(second.map.has("x")).toBe(false);     // venue disappeared -> datum gone
    expect(second.list.map((d) => d.id)).toEqual(["y"]);
    expect(second.list[0]).not.toBe(first.list[0]);
  });
  it("empty next returns empty map/list (mode switch to health clears rings)", () => {
    const first = upsertDatums(new Map<string, D>(), [{ id: "x", color: "c" }]);
    const second = upsertDatums(first.map, []);
    expect(second.list).toEqual([]);
    expect(second.map.size).toBe(0);
  });
});
```

  And update the `ringsFor` assertions in
  `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts` (the existing
  `ringsFor emits pulse rings…` test) to the role-qualified ids:

```ts
    expect(rings).toEqual([
      { id: "ring:loc_dal_gal:composing", lat: 32.93, lng: -96.82, color: "#45c4ff", repeatPeriod: 900 },
      { id: "ring:loc_sfo:failed", lat: 37.62, lng: -122.38, color: "#f2545b", repeatPeriod: 1400 },
    ]);
```

- [ ] Run: `npx vitest run src/components/globe/datumCache.test.ts src/data/globeSelectors.test.ts`
  — expect FAIL (`upsertDatums` not exported; ring id mismatch).
- [ ] Commit (red): `test(globe): identity-stable datum cache + role-qualified ring ids (red, #14 item 1)`
- [ ] Implement — append to `/Users/jn/code/godview-prototype/src/components/globe/datumCache.ts`
  (Plan E's module, beside `diffDatums`):

```ts
// Id-keyed convenience over the same identity discipline diffDatums enforces (Plan E). Used for
// ring datums (status + one-shot pulse rings). three-globe keys per-datum animation
// state on datum OBJECT identity — fresh objects every poll restart every animation (#14).
export function upsertDatums<T extends { id: string }>(
  prev: Map<string, T>, next: T[],
): { map: Map<string, T>; list: T[] } {
  const map = new Map<string, T>();
  const list: T[] = [];
  for (const n of next) {
    const existing = prev.get(n.id);
    if (existing) {
      Object.assign(existing, n);
      map.set(n.id, existing); list.push(existing);
    } else {
      map.set(n.id, n); list.push(n);
    }
  }
  return { map, list };
}
```

  In `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` `ringsFor`
  (globeSelectors.ts:190-200): change the two pushed ids to `` `ring:${d.id}:composing` `` and
  `` `ring:${d.id}:failed` ``. Touch nothing else in the function.

  In `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` DATA effect
  (currently lines 93-107): route BOTH layers through the cache —

```tsx
  const pointCacheRef = useRef(new Map<string, PointDatum>());
  const ringCacheRef = useRef(new Map<string, RingDatum>());
  useEffect(() => {
    const globe = globeRef.current;
    if (!globe) return;
    const points = upsertDatums(pointCacheRef.current,
      dots.map((dot) => ({ id: dot.id, lat: dot.lat, lng: dot.lng, dot })));
    pointCacheRef.current = points.map;
    globe.pointsData(points.list);
    const rings = upsertDatums(ringCacheRef.current, ringsFor(dots, mode));
    ringCacheRef.current = rings.map;
    globe.ringsData(rings.list);
  }, [dots, mode, ready]);
```

  (Import `upsertDatums` from `./datumCache` and `type RingDatum` from
  `../../data/globeSelectors`. Reconciliation note: Plan E already routed the point layer through
  `diffDatums` — converting points to `upsertDatums` is optional unification; the REQUIRED change
  here is the RINGS path (v1 re-sets `ringsFor(dots, mode)` fresh each poll — the #14 bug).
  Plan D's arcs/labels effects already identity-diff via their own Map caches; leave them intact.)
- [ ] Run: `npx vitest run src/components/globe/datumCache.test.ts src/data/globeSelectors.test.ts src/components/globe/GlobeCanvas.test.tsx` — expect PASS (GlobeCanvas jsdom tests exercise the
  fallback path and must be untouched by the refactor).
- [ ] Commit (green): `fix(globe): identity-stable ring datums via upsertDatums — ring pulse phase holds across polls (#14 item 1)`

---

## Task 3 — Additive payload types + far-zoom delta engine

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` (only the contract fields Task 1
  found missing)
- Create: `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts`
- Create: `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (append consecutive-poll
  fixture pairs)

**Interfaces**

```ts
// pulseDelta.ts — pure delta engine (spec §5). No three, no React.
export const PULSE_RAINBOW = false;              // demo fun: one-line switch (spec §5)
export const PULSE_GREEN = "#34d399";            // TONE_HEX.ok
export function pulseColor(seq: number): string; // green, or hsl cycle when PULSE_RAINBOW

export interface FarPulse { venueId: string; lat: number; lng: number; orgId: string | null; }
export function diffFarPulses(prev: MapPayload | null, next: MapPayload): FarPulse[];
```

Signal rules (each documented in code):
- `prev === null` (first poll) → `[]`.
- Venue matched by `location_id`. Venue only in `next` (new) or only in `prev` (disappeared) →
  no pulse, no crash. Venue without coords → no pulse (nothing to animate).
- **Primary:** `last_run_created_at` present on BOTH sides and `next > prev` (ISO-8601 strings
  from one backend compare lexicographically). Present in `next` but null/absent in `prev`
  (backend upgraded mid-session, or first run ever) → NO pulse — avoids a fleet-wide pulse storm
  on upgrade.
- **Fallback:** `playing_count` present on BOTH sides and risen. Both signals firing → ONE pulse
  (coalesced per venue).
- Neither field on either side (un-upgraded backend) → engine inert.

**Steps**

- [ ] Write the failing test — append fixture pairs to
  `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts`:

```ts
// ---- Lane 3 consecutive-poll fixture pairs (Plan F). pollB is 5s after pollA.
const l3rollup = (over: Partial<MapVenueRollup> = {}): MapVenueRollup => ({
  systems: 1, cameras: 1, displays: 1, worst_status: "active",
  active_ad_runs: 0, runs_last_hour: 0, failures_last_hour: 0, last_activity_at: null,
  playing_count: 0, last_run_created_at: "2026-07-12T12:00:00+00:00", ...over,
});
const l3venue = (id: string, over: Partial<MapVenue> = {}): MapVenue => ({
  location_id: id, name: id, location_type: "store", city: "Austin", country: "US",
  lat: 30.27, lng: -97.74, org: { id: "org-north", name: "Northline Apparel" },
  rollup: l3rollup(), ...over,
});

export const mapPollA: MapPayload = { venues: [
  l3venue("v_advance"),                                       // last_run_created_at will advance
  l3venue("v_count", { rollup: l3rollup({ last_run_created_at: null, playing_count: 1 }) }),
  l3venue("v_still"),                                         // unchanged
  l3venue("v_gone"),                                          // disappears in pollB
  l3venue("v_nullprev", { rollup: l3rollup({ last_run_created_at: null }) }),
] };
export const mapPollB: MapPayload = { venues: [
  l3venue("v_advance", { rollup: l3rollup({ last_run_created_at: "2026-07-12T12:00:04+00:00" }) }),
  l3venue("v_count", { rollup: l3rollup({ last_run_created_at: null, playing_count: 2 }) }),
  l3venue("v_still"),
  l3venue("v_new"),                                           // appears fresh — no pulse
  l3venue("v_nullprev", { rollup: l3rollup({ last_run_created_at: "2026-07-12T12:00:04+00:00" }) }),
] };
// Un-upgraded backend: strip Plan-C fields entirely.
const stripL3 = ({ last_run_created_at: _l, playing_count: _p, ...r }: MapVenueRollup) => r;
export const mapPollAStripped: MapPayload =
  { venues: mapPollA.venues.map((v) => ({ ...v, org: undefined, rollup: stripL3(v.rollup) })) };
export const mapPollBStripped: MapPayload =
  { venues: mapPollB.venues.map((v) => ({ ...v, org: undefined, rollup: stripL3(v.rollup) })) };
```

  Then `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { diffFarPulses, pulseColor, PULSE_GREEN } from "./pulseDelta";
import { mapPollA, mapPollB, mapPollAStripped, mapPollBStripped } from "./globeFixtures";

describe("diffFarPulses (spec §5 far zoom)", () => {
  it("first poll (no previous) emits no pulses", () => {
    expect(diffFarPulses(null, mapPollB)).toEqual([]);
  });
  it("pulses when last_run_created_at advances (primary) or playing_count rises (fallback), once per venue", () => {
    const pulses = diffFarPulses(mapPollA, mapPollB);
    expect(pulses.map((p) => p.venueId).sort()).toEqual(["v_advance", "v_count"]);
    const adv = pulses.find((p) => p.venueId === "v_advance")!;
    expect(adv).toEqual({ venueId: "v_advance", lat: 30.27, lng: -97.74, orgId: "org-north" });
  });
  it("does NOT pulse: unchanged venue, new venue, disappeared venue, null->value upgrade", () => {
    const ids = diffFarPulses(mapPollA, mapPollB).map((p) => p.venueId);
    for (const noPulse of ["v_still", "v_new", "v_gone", "v_nullprev"]) {
      expect(ids).not.toContain(noPulse);
    }
  });
  it("is inert (no pulses, no crash) against an un-upgraded backend payload", () => {
    expect(diffFarPulses(mapPollAStripped, mapPollBStripped)).toEqual([]);
  });
  it("both signals firing on one venue still yields a single pulse", () => {
    const both = {
      venues: [{ ...mapPollB.venues[0],
        rollup: { ...mapPollB.venues[0].rollup, playing_count: 5 } }],
    };
    expect(diffFarPulses(mapPollA, both)).toHaveLength(1);
  });
});

describe("pulseColor", () => {
  it("is green by default for every seq (rainbow is a one-line config switch)", () => {
    expect(pulseColor(0)).toBe(PULSE_GREEN);
    expect(pulseColor(7)).toBe(PULSE_GREEN);
  });
});
```

- [ ] If Task 1 found contract fields missing from
  `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`, the red test also fails to typecheck —
  that is part of the red.
- [ ] Run: `npx vitest run src/data/pulseDelta.test.ts` — expect FAIL
  (`Cannot find module './pulseDelta'` / missing type fields).
- [ ] Commit (red): `test(globe): far-zoom recognition delta — fixture poll pairs + red engine tests`
- [ ] Implement. Add to `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` ONLY the contract
  fields Task 1 found missing (each `?`-optional, with a `// Plan-C additive (Lane 3)` comment).
  Create `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts`:

```ts
// Pure recognition-pulse delta engine (spec 2026-07-12 §5). Compares consecutive poll
// payloads; no three, no React, no timers — all lifecycles live in GlobeCanvas.
import type { MapPayload } from "./apiTypes";

export const PULSE_RAINBOW = false;   // flip to true for per-pulse rainbow hues (demo fun)
export const PULSE_GREEN = "#34d399"; // TONE_HEX.ok

export function pulseColor(seq: number): string {
  return PULSE_RAINBOW ? `hsl(${(seq * 47) % 360}, 90%, 60%)` : PULSE_GREEN;
}

export interface FarPulse { venueId: string; lat: number; lng: number; orgId: string | null; }

/** Far zoom: last_run_created_at advanced (primary; additive rollup field — runs_last_hour can
 * net to zero across a poll and last_activity_at moves on completions too, spec §3) or
 * playing_count rose (fallback). Both-sides-present rule keeps the engine inert against
 * un-upgraded backends and prevents a pulse storm when the field first appears. */
export function diffFarPulses(prev: MapPayload | null, next: MapPayload): FarPulse[] {
  if (!prev) return [];
  const before = new Map(prev.venues.map((v) => [v.location_id, v]));
  const out: FarPulse[] = [];
  for (const v of next.venues) {
    const p = before.get(v.location_id);
    if (!p || v.lat == null || v.lng == null) continue;
    const advanced = v.rollup.last_run_created_at != null
      && p.rollup.last_run_created_at != null
      && v.rollup.last_run_created_at > p.rollup.last_run_created_at;
    const rose = v.rollup.playing_count != null && p.rollup.playing_count != null
      && v.rollup.playing_count > p.rollup.playing_count;
    if (advanced || rose) {
      out.push({ venueId: v.location_id, lat: v.lat, lng: v.lng, orgId: v.org?.id ?? null });
    }
  }
  return out;
}
```

- [ ] Run: `npx vitest run src/data/pulseDelta.test.ts` — expect PASS. Run `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe): far-zoom recognition delta engine + pulse color config (spec §5)`

---

## Task 4 — Deep-zoom delta engine: transitions, camera attribution, pulse path

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts` (append)
- Modify: `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts` (append)
- Modify: `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts` (append detail poll pairs)

**Interfaces**

```ts
export interface DeepPulse { systemId: string; cameraId: string | null; displayId: string | null; }
export function diffDeepPulses(prev: MapLocationDetail | null, next: MapLocationDetail): DeepPulse[];

/** Spec-locked heuristic (§5 amendment): the system's first non-retired camera ordered by
 * screen_id — exactly demo_traffic's own pick (mras-ops scripts/demo_traffic.py:150-153).
 * ad_runs has NO camera column; do not invent one. */
export function attributionCamera(system: MapSystem): MapSystemDevice | null;

export interface GeoPoint { lat: number; lng: number; altitude: number; }
/** Ordered camera -> system -> display waypoints from Plan E's exploded layout nodes
 * (Plan E key convention `${type}:${id}`; nodes matched on `type` + `id`). Missing camera/display
 * legs are skipped truthfully; fewer than 2 resolvable points -> [] (nothing to draw). */
export function deepPulsePath(
  nodes: Pick<ExplodedNode, "key" | "type" | "id" | "lat" | "lng" | "altitude">[],
  pulse: DeepPulse,
): GeoPoint[];
```

Transition rules for `diffDeepPulses` (documented in code):
- `prev === null` → `[]`. `prev.location.id !== next.location.id` (exploded-venue switch; the
  detail poll's last-good data may briefly be the old venue) → `[]` — no cross-venue pulse storm.
- A run fires when `next.status ∈ {dispatched, playing}` AND (`prev` had it as `planned`, or the
  run is absent from `prev` — planned+dispatched landed inside one poll window). Once past
  `planned` in `prev` (`dispatched → playing` across polls) → no second pulse: one recognition,
  one pulse. `failed`/`completed`/`planned` in `next` → never fires.
- `system_id === null`, or the system missing from `next.systems` → skip (cannot attribute).
- Coalescing: dedupe on `${systemId}|${cameraId}|${displayId}` — two runs on one path in one
  poll window animate once (spec §8, accepted).
- `display_id` absent (un-upgraded backend) → `displayId: null`; the path truthfully ends at the
  system. Cameras without `screen_id` sort by `id` fallback; all-retired cameras → `cameraId: null`.

**Steps**

- [ ] Write the failing tests. Append to
  `/Users/jn/code/godview-prototype/src/data/globeFixtures.ts`:

```ts
// ---- Lane 3 deep-zoom detail poll pair (Plan F). Same venue, 5s apart.
const l3cam = (id: string, screen_id: string, status = "active"): MapSystemDevice =>
  ({ id, name: id, status, last_seen_at: null, screen_id });
const l3disp = (id: string): MapSystemDevice => ({ id, name: id, status: "active", last_seen_at: null, screen_id: id });
const l3sys = (id: string, cameras: MapSystemDevice[], displays: MapSystemDevice[]): MapSystem =>
  ({ id, name: id, zone: null, status: "active", system_type: "onsite_mras", cameras, displays });
const l3run = (id: string, status: string, system_id: string | null, display_id: string | null = null): MapAdRun =>
  ({ id, status, started_at: null, ended_at: null, system_id, system_name: system_id, display_id });

const l3systems = [
  // cam_z sorts FIRST by screen_id ("demo-a1") despite id order; cam_r is retired and skipped.
  l3sys("sys1", [l3cam("cam_a", "demo-b2"), l3cam("cam_z", "demo-a1"), l3cam("cam_r", "demo-a0", "retired")],
    [l3disp("disp1"), l3disp("disp2")]),
  l3sys("sys2", [l3cam("cam_only", "demo-c1")], [l3disp("disp3")]),
];
export const detailPollA: MapLocationDetail = {
  location: { id: "loc_x", name: "X", location_type: "store", city: null, country: null, lat: 30, lng: -97 },
  systems: l3systems,
  ad_runs: [
    l3run("ar_fires", "planned", "sys1"),
    l3run("ar_walks", "dispatched", "sys2", "disp3"),   // dispatched -> playing: NO second pulse
    l3run("ar_fails", "planned", "sys1"),
  ],
};
export const detailPollB: MapLocationDetail = {
  ...detailPollA,
  ad_runs: [
    l3run("ar_fires", "dispatched", "sys1", "disp1"),   // planned -> dispatched: fires
    l3run("ar_walks", "playing", "sys2", "disp3"),
    l3run("ar_fails", "failed", "sys1"),
    l3run("ar_burst", "playing", "sys1", "disp1"),      // absent -> playing (one-window burst): fires, coalesces with ar_fires
    l3run("ar_orphan", "playing", null),                // no system: skipped
  ],
};
```

  Append to `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts` (extend imports):

```ts
describe("diffDeepPulses (spec §5 deep zoom — ad_run status transitions; no playbacks array)", () => {
  it("first poll emits nothing", () => {
    expect(diffDeepPulses(null, detailPollB)).toEqual([]);
  });
  it("fires on planned->dispatched and on absent->playing; coalesces per camera->system->display path", () => {
    const pulses = diffDeepPulses(detailPollA, detailPollB);
    // ar_fires and ar_burst share path sys1/cam_z/disp1 -> ONE pulse; ar_walks was already
    // dispatched in prev -> no pulse; ar_fails failed -> no pulse; ar_orphan has no system.
    expect(pulses).toEqual([
      { systemId: "sys1", cameraId: "cam_z", displayId: "disp1" },
    ]);
  });
  it("emits nothing when the detail payload switched venues between polls", () => {
    const otherVenue = { ...detailPollB,
      location: { ...detailPollB.location, id: "loc_other" } };
    expect(diffDeepPulses(detailPollA, otherVenue)).toEqual([]);
  });
  it("is inert without display_id (un-upgraded backend): pulse ends at the system", () => {
    const stripped = { ...detailPollB,
      ad_runs: detailPollB.ad_runs.map(({ display_id: _d, ...r }) => r) };
    expect(diffDeepPulses(detailPollA, stripped)[0].displayId).toBeNull();
  });
});

describe("attributionCamera (demo_traffic ground truth: first non-retired by screen_id)", () => {
  it("orders by screen_id, not id, and skips retired cameras", () => {
    expect(attributionCamera(detailPollA.systems[0])!.id).toBe("cam_z");   // screen_id demo-a1
  });
  it("returns null when every camera is retired", () => {
    const sys = { ...detailPollA.systems[0],
      cameras: detailPollA.systems[0].cameras.map((c) => ({ ...c, status: "retired" })) };
    expect(attributionCamera(sys)).toBeNull();
  });
  it("falls back to id ordering when screen_id is null (nullable per Plan E's MapSystemDevice)", () => {
    const sys = { ...detailPollA.systems[0],
      cameras: detailPollA.systems[0].cameras.map((c) => ({ ...c, screen_id: null })) };
    expect(attributionCamera(sys)!.id).toBe("cam_a");
  });
});

describe("deepPulsePath (Plan E layout nodes, `${type}:${id}` keys)", () => {
  const nodes = [
    { key: "system:sys1", type: "system" as const, id: "sys1", lat: 30, lng: -97, altitude: 0.02 },
    { key: "camera:cam_z", type: "camera" as const, id: "cam_z", lat: 30.01, lng: -97, altitude: 0.02 },
    { key: "display:disp1", type: "display" as const, id: "disp1", lat: 29.99, lng: -97, altitude: 0.02 },
  ];
  it("orders camera -> system -> display", () => {
    const path = deepPulsePath(nodes, { systemId: "sys1", cameraId: "cam_z", displayId: "disp1" });
    expect(path.map((p) => p.lat)).toEqual([30.01, 30, 29.99]);
  });
  it("skips a missing display leg truthfully (camera -> system only)", () => {
    expect(deepPulsePath(nodes, { systemId: "sys1", cameraId: "cam_z", displayId: null }))
      .toHaveLength(2);
  });
  it("returns [] when fewer than 2 waypoints resolve (nothing to draw)", () => {
    expect(deepPulsePath(nodes, { systemId: "sys1", cameraId: null, displayId: null })).toEqual([]);
    expect(deepPulsePath([], { systemId: "sys1", cameraId: "cam_z", displayId: "disp1" })).toEqual([]);
  });
});
```

- [ ] Run: `npx vitest run src/data/pulseDelta.test.ts` — expect FAIL (missing exports).
- [ ] Commit (red): `test(globe): deep-zoom transition delta, camera attribution heuristic, pulse path (red)`
- [ ] Implement — append to `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts` per the
  Interfaces block (import `type ExplodedNode` from `./explodeSelectors` — Plan E's module;
  `attributionCamera` sorts `cameras.filter((c) => c.status !== "retired")` by
  `(a.screen_id ?? a.id).localeCompare(b.screen_id ?? b.id)`; `diffDeepPulses` follows the
  documented transition rules exactly).
- [ ] Run: `npx vitest run src/data/pulseDelta.test.ts` — expect PASS. `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe): deep-zoom delta engine — status transitions, spec-locked camera attribution, path (spec §5)`

---

## Task 5 — `usePollDelta` hook + sweep-arc selection

**Files**
- Create: `/Users/jn/code/godview-prototype/src/hooks/usePollDelta.ts`
- Create: `/Users/jn/code/godview-prototype/src/hooks/usePollDelta.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts` (append `arcsForOrgs`)
- Modify: `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts` (append)

**Interfaces**

```ts
// usePollDelta.ts — the ONLY stateful piece outside the island: holds the previous payload
// and emits sequenced batches. jsdom-testable; no three.
export interface PulseBatch<P> { seq: number; pulses: P[]; }
export function usePollDelta<T, P>(
  data: T | null,
  diff: (prev: T | null, next: T) => P[],   // must be a stable module-level function
): PulseBatch<P> | null;

// pulseDelta.ts — sweep-arc selection (pure): the org arcs to sweep for a pulse batch.
// Coalesces: two pulsing venues of one org in a batch sweep that org's arcs ONCE.
// OrgArcDatum = Plan D's arc datum (topologySelectors.ts; keyed on `key`, carries `color`).
export function arcsForOrgs(pulses: FarPulse[], arcs: OrgArcDatum[]): OrgArcDatum[];
```

Hook semantics: diffs only when the `data` object reference changes (usePolling's `setData`
replaces on success — `/Users/jn/code/godview-prototype/src/hooks/usePolling.ts:13`); a ref guard
makes React StrictMode's double-effect safe; an empty diff result does NOT bump `seq` (the island
re-triggers on `seq` change only).

**Steps**

- [ ] Write the failing tests. `/Users/jn/code/godview-prototype/src/hooks/usePollDelta.test.ts`
  (renderHook from `@testing-library/react`):

```tsx
import { renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { usePollDelta } from "./usePollDelta";

type Payload = { n: number };
const diff = (prev: Payload | null, next: Payload) =>
  prev && next.n > prev.n ? [next.n] : [];

describe("usePollDelta", () => {
  it("emits no batch on the first payload (no previous)", () => {
    const { result } = renderHook(({ d }) => usePollDelta(d, diff),
      { initialProps: { d: { n: 1 } as Payload | null } });
    expect(result.current).toBeNull();
  });
  it("emits a sequenced batch when a later payload diffs non-empty", () => {
    const { result, rerender } = renderHook(({ d }) => usePollDelta(d, diff),
      { initialProps: { d: { n: 1 } as Payload | null } });
    rerender({ d: { n: 2 } });
    expect(result.current).toEqual({ seq: 1, pulses: [2] });
    rerender({ d: { n: 5 } });
    expect(result.current).toEqual({ seq: 2, pulses: [5] });
  });
  it("does not bump seq on an empty diff or an identical object (StrictMode-safe)", () => {
    const p2 = { n: 2 };
    const { result, rerender } = renderHook(({ d }) => usePollDelta(d, diff),
      { initialProps: { d: { n: 1 } as Payload | null } });
    rerender({ d: p2 });
    rerender({ d: p2 });                       // same reference — no re-diff
    rerender({ d: { n: 2 } });                 // new object, empty diff — no batch bump
    expect(result.current).toEqual({ seq: 1, pulses: [2] });
  });
  it("ignores null data (fetch not yet resolved / error kept last-good)", () => {
    const { result, rerender } = renderHook(({ d }) => usePollDelta(d, diff),
      { initialProps: { d: null as Payload | null } });
    rerender({ d: null });
    expect(result.current).toBeNull();
  });
});
```

  Append to `/Users/jn/code/godview-prototype/src/data/pulseDelta.test.ts`:

```ts
describe("arcsForOrgs (one sweep per org per batch — coalescing)", () => {
  const arcs = [   // Plan D OrgArcDatum shape: `key` + `color`, not `id`
    { key: "a1", orgId: "org-north", color: "#45c4ff", startLat: 0, startLng: 0, endLat: 1, endLng: 1 },
    { key: "a2", orgId: "org-north", color: "#45c4ff", startLat: 1, startLng: 1, endLat: 2, endLng: 2 },
    { key: "a3", orgId: "org-brew", color: "#a78bfa", startLat: 5, startLng: 5, endLat: 6, endLng: 6 },
  ];
  const pulse = (venueId: string, orgId: string | null) =>
    ({ venueId, lat: 0, lng: 0, orgId });
  it("selects each pulsing org's arcs once, even with two venues of the same org", () => {
    const out = arcsForOrgs([pulse("v1", "org-north"), pulse("v2", "org-north")], arcs);
    expect(out.map((a) => a.key)).toEqual(["a1", "a2"]);
  });
  it("org-less venues (org null: single-venue orgs / no arcs) select nothing and do not crash", () => {
    expect(arcsForOrgs([pulse("v1", null)], arcs)).toEqual([]);
  });
});
```

- [ ] Run: `npx vitest run src/hooks/usePollDelta.test.ts src/data/pulseDelta.test.ts` — expect
  FAIL (missing module/export).
- [ ] Commit (red): `test(globe): usePollDelta batches + per-org sweep-arc coalescing (red)`
- [ ] Implement `/Users/jn/code/godview-prototype/src/hooks/usePollDelta.ts`:

```ts
import { useEffect, useRef, useState } from "react";

export interface PulseBatch<P> { seq: number; pulses: P[]; }

/** Holds the previous poll payload and emits sequenced pulse batches. `diff` must be a
 * stable module-level function (pulseDelta exports). Identity guard makes StrictMode's
 * double-effect and unrelated re-renders no-ops. */
export function usePollDelta<T, P>(
  data: T | null, diff: (prev: T | null, next: T) => P[],
): PulseBatch<P> | null {
  const prevRef = useRef<T | null>(null);
  const seqRef = useRef(0);
  const [batch, setBatch] = useState<PulseBatch<P> | null>(null);
  useEffect(() => {
    if (data == null || data === prevRef.current) return;
    const pulses = diff(prevRef.current, data);
    prevRef.current = data;
    if (pulses.length > 0) setBatch({ seq: ++seqRef.current, pulses });
  }, [data, diff]);
  return batch;
}
```

  Append `arcsForOrgs` to `/Users/jn/code/godview-prototype/src/data/pulseDelta.ts` (build the
  Set of non-null `orgId`s, filter `arcs`).
- [ ] Run: `npx vitest run src/hooks/usePollDelta.test.ts src/data/pulseDelta.test.ts` — PASS.
- [ ] Commit (green): `feat(globe): usePollDelta poll-pair hook + arcsForOrgs sweep selection`

---

## Task 6 — Island far zoom: one-shot venue pulse ring + org-arc dash sweep

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` (props)
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` (wiring)

**Interfaces**

```ts
// GlobeCanvas gains one prop (page precomputes everything pure):
farPulses: { seq: number; venues: FarPulse[]; sweepArcs: OrgArcDatum[] } | null;
```

**One-shot mechanisms (spec §3/§5 amendment — dash/ring animations natively LOOP):**

- **Venue pulse ring:** a temporary ring datum
  `{ id: "pulse:" + venueId + ":" + seq, lat, lng, color: pulseColor(seq), maxRadius: 4, propagationSpeed: 4, repeatPeriod: 10000 }`
  merged into the SAME `ringsData` array as the Task 2 status rings (one owner). `repeatPeriod`
  10 s ≫ removal timer `PULSE_RING_MS = 1500` ⇒ exactly one wavefront is ever emitted; the timer
  removes the datum and re-sets `ringsData`. This requires the v1 instance-level scalars at
  GlobeCanvas.tsx:63-64 to become per-datum accessors with the same defaults:
  `.ringMaxRadius((r) => r.maxRadius ?? 3)` / `.ringPropagationSpeed((r) => r.speed ?? 2)`
  (accessors exist: three-globe.d.ts:292-295) — status rings unchanged.
- **Org-arc sweep:** per pulsed org, temporary overlay arc datums (copies of that org's base
  arcs; Plan D datums are keyed on `key`)
  `{ key: "sweep:" + arc.key + ":" + seq, sweep: true, ...coords, color: pulseColor(seq), stroke: 0.6, dashLength: 0.35, dashGap: 1.65, dashInitialGap: 0.001, dashAnimateTime: SWEEP_MS }`
  with `SWEEP_MS = 1200`, merged into the SAME `arcsData` array as Plan D's base arcs (one
  owner); a timer removes them after `SWEEP_MS` — one dash period, one traversal, then gone
  (the "temporary arc datum removed after one period" lifecycle from spec §3). `dashLength +
  dashGap = 2` keeps at most one dash on the arc at a time. Dash constants are visual-tune
  candidates for the E2E task; the tested part is the lifecycle (add → timer → remove).
- **Timer + trigger hygiene:** a `handledSeqRef` skips already-animated batches (StrictMode /
  re-render safe); all `setTimeout` ids go into a `timersRef` Set cleared on unmount; active
  pulse/sweep datums live in island refs and are re-merged through `upsertDatums` so their
  identity holds for their whole lifetime.
  [ERRATUM 2026-07-12: as-built uses key-scoped removals per batch instead of clearing timers on supersede — final review adjudicated this strictly better than the literal wording (clearing would leak the old batch's datums). Do not "fix" the code to match this sentence.]

**Steps**

- [ ] Write the failing test — extend
  `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`: every existing
  `render(<GlobeCanvas …>)` gains `farPulses={null}`, plus one new jsdom test:

```tsx
test("fallback path ignores pulse batches without crashing (no three in jsdom)", () => {
  const { rerender } = render(<GlobeCanvas dots={[]} mode="live" focus={null} farPulses={null}
    onDotClick={noop} onPovChange={noop} /* + Plan D/E required props: arcs/labels/highlightOrgId/explosion/liveSystems/onNodeClick */ />);
  rerender(<GlobeCanvas dots={[]} mode="live" focus={null}
    farPulses={{ seq: 1, venues: [{ venueId: "v", lat: 1, lng: 2, orgId: null }], sweepArcs: [] }}
    onDotClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx` — expect FAIL (unknown prop
  type / missing required prop).
- [ ] Commit (red): `test(globe): GlobeCanvas farPulses prop accepted on the fallback path (red)`
- [ ] Implement in `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`:
  1. INIT chain: convert `ringMaxRadius`/`ringPropagationSpeed` to per-datum accessors (defaults
     3 / 2); extend Plan D's per-datum arc accessors (they call `arcColorFor`/`arcStrokeFor`/
     `arcDashFor(a, highlightRef.current)`) to prefer sweep-datum-carried overrides for datums
     with `sweep: true`, preserving Plan D's styling for base arcs (see Contract).
  2. Island refs: `pulseRingsRef` (active one-shot ring datums), `sweepArcsRef` (active sweep
     datums), `timersRef: Set<number>`, `handledSeqRef`.
  3. A `syncRings()` / `syncArcs()` pair that re-sets `ringsData` = status rings (Task 2 cache) +
     `pulseRingsRef.current` (via `upsertDatums` — ring datums carry `id`), and `arcsData` = base
     org arcs (Plan D's Map cache, keyed on `key`) + `sweepArcsRef.current` (identity-stable in
     the ref for their lifetime; use Plan E's `diffDatums` keyed on `a.key` if a cache pass is
     needed — Plan D arc datums have `key`, not `id`). Both called from the DATA effect and from
     timers.
  4. A `farPulses` effect: skip if `!globeRef.current || !farPulses || farPulses.seq ===
     handledSeqRef.current`; mark handled; build pulse-ring datums + sweep datums per the
     Interfaces block; sync; register removal timers (`PULSE_RING_MS`, `SWEEP_MS`) that delete
     from the refs and re-sync.
  5. Unmount cleanup: clear every timer in `timersRef` (extend the existing dispose block,
     GlobeCanvas.tsx:82-88).
- [ ] Wire `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`:

```tsx
const farBatch = usePollDelta(data, diffFarPulses);
const farPulses = useMemo(() => farBatch && {
  seq: farBatch.seq,
  venues: farBatch.pulses,
  sweepArcs: arcsForOrgs(farBatch.pulses, arcs),      // arcs = Plan D's buildOrgChains memo (Globe.tsx)
}, [farBatch, arcs]);
// pass farPulses={farPulses} to <GlobeCanvas>
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx src/pages/Globe.test.tsx` —
  expect PASS (Globe page tests run the fallback path; add `farPulses` to any GlobeCanvas mock if
  Plan D/E introduced one). `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe): far-zoom recognition pulse — one-shot venue ring + org-arc dash sweep (spec §5)`

---

## Task 7 — Island deep zoom: camera flash + traveling dash pulse (rAF)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/globe/pulseLayer.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` (wiring)

**Interfaces**

```ts
// GlobeCanvas gains one prop:
deepPulses: { seq: number; paths: { key: string; color: string; path: GeoPoint[] }[] } | null;

// pulseLayer.ts — the ONLY module that statically imports three. Reached exclusively via
// dynamic import("./pulseLayer") inside GlobeCanvas AFTER the WebGL guard (same rule as
// import("globe.gl"), GlobeCanvas.tsx:41) so jsdom never evaluates three.
export interface TravelingPulse {
  object3d: import("three").Object3D;   // group: Line2 (dashed) + camera-flash sphere
  tick(elapsedMs: number): boolean;     // advance dashOffset + flash fade; false when done
  dispose(): void;                      // geometry + material
}
export function buildTravelingPulse(
  points: { x: number; y: number; z: number }[],   // globe.getCoords output, camera-first
  color: string,
  container: { clientWidth: number; clientHeight: number },  // LineMaterial resolution
): TravelingPulse;
```

**Mechanism (spec §5 amendment: three-globe animates NOTHING on the custom layer —
per-frame updates are ours):**

- `buildTravelingPulse` uses `Line2` + `LineGeometry` + `LineMaterial` from
  `three/examples/jsm/lines/` with `dashed: true`; core `LineDashedMaterial` is NOT usable — it
  has no `dashOffset` (verified: only
  `/Users/jn/code/godview-prototype/node_modules/three/examples/jsm/lines/LineMaterial.js:14,622`
  exposes it). `line.computeLineDistances()` after geometry set;
  `material.resolution.set(w, h)` from the container (and refreshed by the existing
  ResizeObserver, GlobeCanvas.tsx:73). `tick()` sets `material.dashOffset = -elapsedMs * SPEED`
  (direction: dash travels camera → system → display; flip sign if the live E2E shows it
  backwards) and eases the camera-flash sphere (scale up + opacity down over ~600 ms); returns
  `false` after `TRAVEL_MS = 1800`.
- GlobeCanvas `deepPulses` effect: guard `!globeRef.current || seq already handled`; lazily
  `const layer = pulseLayerRef.current ??= await import("./pulseLayer")`; for each path, convert
  `GeoPoint`s via `globe.getCoords(lat, lng, altitude)` (three-globe.d.ts:371); merge a datum
  `{ id: "deeppulse:" + key + ":" + seq, kind: "deep-pulse", pulse }` into the SAME
  `customLayerData` set Plan E's connectors own, with `customThreeObject` switching on `kind`
  (`d.pulse.object3d` for ours; Plan E's builder otherwise).
- **One rAF loop for the island:** started when the first pulse becomes active, each frame calls
  `tick()` on every live pulse; a pulse returning `false` is removed from `customLayerData`
  (re-merge) and `dispose()`d; the loop stops when none remain; `cancelAnimationFrame` +
  dispose-all on unmount.

**Steps**

- [ ] Write the failing test — extend
  `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`: add the throwing
  guard mock next to the existing globe.gl one, thread `deepPulses={null}` through existing
  renders, and add:

```tsx
vi.mock("./pulseLayer", () => { throw new Error("pulseLayer (three) must not load in jsdom"); });

test("fallback path ignores deep pulse batches and never imports the three pulse layer", () => {
  const { rerender } = render(<GlobeCanvas dots={[]} mode="live" focus={null}
    farPulses={null} deepPulses={null} onDotClick={noop} onPovChange={noop} />);
  rerender(<GlobeCanvas dots={[]} mode="live" focus={null} farPulses={null}
    deepPulses={{ seq: 1, paths: [{ key: "sys1", color: "#34d399",
      path: [{ lat: 1, lng: 2, altitude: 0.02 }, { lat: 1.1, lng: 2, altitude: 0.02 }] }] }}
    onDotClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});
```

- [ ] Run: `npx vitest run src/components/globe/GlobeCanvas.test.tsx` — expect FAIL (missing prop
  type).
- [ ] Commit (red): `test(globe): deepPulses prop + pulseLayer never loads in jsdom (red)`
- [ ] Implement `/Users/jn/code/godview-prototype/src/components/globe/pulseLayer.ts` and the
  GlobeCanvas effect + rAF loop per the Interfaces/Mechanism blocks above.
- [ ] Wire `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` — consume Plan E's exploded
  detail poll (Task 1 recon names):

```tsx
const deepBatch = usePollDelta(detail, diffDeepPulses);   // detail = Plan E's useVenueDetailPoll(explodedId) payload
const explodedNodes = explosion?.nodes ?? null;           // explosion = Plan E's explodeVenue memo (Globe.tsx)
const deepPulses = useMemo(() => {
  if (!deepBatch || !explodedNodes) return null;
  const paths = deepBatch.pulses
    .map((p, i) => ({ key: `${p.systemId}|${p.cameraId ?? ""}|${p.displayId ?? ""}`,
      color: pulseColor(deepBatch.seq + i), path: deepPulsePath(explodedNodes, p) }))
    .filter((x) => x.path.length >= 2);
  return paths.length ? { seq: deepBatch.seq, paths } : null;
}, [deepBatch, explodedNodes]);
// pass deepPulses={deepPulses} to <GlobeCanvas>
```

- [ ] Run: `npx vitest run` — full suite green (jsdom never hit either throwing mock).
  `npx tsc -b` — clean.
- [ ] Commit (green): `feat(globe): deep-zoom traveling pulse — camera flash + Line2 dashOffset rAF along Lane 2 connectors (spec §5)`

---

## Task 8 — Full suite, typecheck, build, lint, bundle sanity, PR

**Files** — none new; fixes only if something below fails (each fix scoped + committed with reason).

**Steps**

- [ ] `npx vitest run` — full suite green (all pre-existing v1/D/E tests too).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. Bundle guardrail: the ENTRY chunk must not grow —
  `three/examples/jsm/lines` (pulseLayer) must land in a lazy chunk alongside/next to the
  globe.gl chunk (both reached only by dynamic import). `ls -lS dist/assets | head`; record chunk
  sizes in the commit message.
- [ ] Quick visual smoke: `npm run dev`, open `http://localhost:5173/globe` with the backend down
  — page renders v1 behavior, no pulses, no console errors (engine inert without payloads).
- [ ] Commit: `chore(globe): full suite + tsc + build + lint green; pulse layer in lazy chunk (sizes noted)`
- [ ] Ask git-flow-manager to push the branch and open a PR titled
  `feat(globe): Lane 3 recognition pulse + rings-identity fix (Plan F)` against `main` with the
  structured description (Summary / Motivation / Implementation / Tests / Risks), noting it
  addresses godview-prototype **#14 item 1** and any Task 1 contract reconciliations. Request
  code review (superpowers:requesting-code-review) with the strongest available model; resolve
  findings before Task 9.

---

## Task 9 — Live E2E: demo_traffic → pulses on the real stack

**DEPENDENCY:** Plans C/D/E merged and live; dev stack up (ops-api `:8080`, projector running,
seed v2 applied). Findings become scoped fix commits on this branch or follow-up issues.

**Files** — none (live drill).

**Steps**

- [ ] Preconditions: dev DB has seed v2 (retailer orgs + same-city venues); frontend `npm run dev`
  in the worktree (`http://localhost:5173`). Confirm `/god-view/map` rollups carry
  `last_run_created_at` and venues carry `org` (Task 1 recipe).
- [ ] Start the generator from `/Users/jn/code/mras-ops`:
  `python3 -m scripts.demo_traffic --rate 10 --duration 300`
  (per `/Users/jn/code/mras-ops/scripts/demo_traffic.py:201-208`; needs the dev `DATABASE_URL`
  default `postgresql://mras:mras@localhost:5432/mras`).
- [ ] Headless WebGL note (as Plan B Task 10): if driving via Playwright MCP and WebGL is
  unavailable, cover visuals with a headed/real-browser pass — the pulse checks below are
  intrinsically visual.
- [ ] **Far zoom:** on `/globe` at globe altitude, within ~2–7 s of a generator
  `ad_run/planned→playing` line (5 s poll + 2–3 s projector settle — accepted lag, spec §2, NOT
  a bug), observe: (a) a green one-shot ring pulse on the emitting venue's dot, (b) ONE dash
  sweep along that venue's org arcs that does NOT keep looping afterwards, (c) two rapid runs at
  one venue coalesce into one animation per poll window (accepted). Screenshot mid-sweep.
- [ ] **Ring-phase fix (#14 item 1):** switch to Live mode with a composing/failed venue visible
  (or use the generator's failure path, `--failure-pct`), watch a status ring across ≥ 3 poll
  boundaries: the ring wavefront must expand continuously, never snapping back to radius 0 at
  the 5 s tick. Compare against v1 behavior if in doubt (checkout main in another worktree).
- [ ] **Deep zoom:** click/zoom into an actively-emitting seeded venue so it explodes (Lane 2);
  within one poll of the generator printing `ad_run/dispatched` for that venue, observe: camera
  node flash on the system's FIRST camera (by screen_id — cross-check the generator's own log
  line naming the system), then the traveling dash pulse camera → system → display along the
  Lane 2 connectors, terminating (no loop) after ~2 s. Verify the display end matches the run's
  display when `display_id` is present. Screenshot mid-travel.
- [ ] **Longevity/hygiene:** leave the page 10+ minutes under generator load — no console errors,
  no unbounded datum growth (pulse/sweep datums must come AND GO), interaction stays smooth;
  navigate away and back — no leaked rAF/timer warnings.
- [ ] Owner-optional: validate with the real camera (live recognition on the demo box → far-zoom
  pulse on the real venue).
- [ ] Tune the flagged visual constants (dash length/gap, `SWEEP_MS`, `TRAVEL_MS`, dashOffset
  sign, flash size) as scoped commits if the live look demands it.
- [ ] Fix anything found (red→green where code changes), then ask git-flow-manager to merge the
  PR (merge commit) after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry:
  changes with `repo@sha`, E2E evidence + screenshots, gotchas); ask git-flow-manager to comment
  on godview-prototype #14 that item 1 is fixed (cite the PR) and file any remaining follow-ups
  as GitHub issues.

---

## Self-review notes (spec §5 coverage check, done at plan time)

- Pure delta engine on consecutive poll payloads, fully unit-tested with fixture pairs — Tasks
  3/4 (`diffFarPulses`, `diffDeepPulses`, fixture pairs in globeFixtures.ts). ✓
- Far zoom: `last_run_created_at` advance primary + `playing_count` rise fallback → venue pulse +
  ONE org-arc sweep with an explicit one-shot lifecycle (temporary datum + removal timer after
  one period — the spec-offered mechanism, chosen over `arcDashInitialGap` staging for
  determinism) — Tasks 3/6. ✓
- Deep zoom: ad_run status transition planned→dispatched/playing in the detail payload (no
  playbacks array) → camera flash + traveling pulse camera → system → display, per-frame
  dashOffset via rAF in the island (three-globe animates nothing on the custom layer) — Tasks
  4/7; `Line2`/`LineMaterial` because core LineDashedMaterial lacks dashOffset (verified). ✓
- Camera attribution spec-locked: first non-retired camera by `screen_id`, matching
  demo_traffic.py:150-153; NO schema change; display end truthful via `ad_runs.display_id` —
  Task 4 `attributionCamera` + fixtures proving screen_id-not-id ordering. ✓
- Edge handling: first poll inert; venue disappearing; venue-switch guard on the detail poll;
  coalescing once-per-path; absent fields → inert, optional-additive types — Tasks 3/4/5 tests. ✓
- Color: green default, rainbow behind `PULSE_RAINBOW` (one line) — Task 3. ✓
- Rings-identity fix #14 item 1: `upsertDatums` Map-keyed on venue id + ring role (points were
  already routed through Plan E's `diffDatums`); discipline extended to pulse rings, sweep arcs,
  and custom-layer pulse datums — Tasks 2/6/7. ✓
- Animation state (timers, rAF, handled-seq) ONLY in GlobeCanvas; jsdom never touches three
  (throwing mocks for both `globe.gl` and `./pulseLayer`) — Tasks 6/7. ✓
- Process: worktree branch, no raw git for implementers, red→green pairs watched failing, exact
  verify commands from `/Users/jn/code/godview-prototype/package.json`, PR + strongest-model
  review, live E2E with `demo_traffic --rate 10 --duration 300` and the accepted 2–7 s lag,
  SESSION_LOG close-out — Tasks 1/8/9. ✓
- Out of scope honored (spec §7): no SSE/push, no multi-venue explosion, no schema changes, no
  second data owners for rings/arcs/custom layers.
