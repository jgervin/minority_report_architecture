# Flat Map v4 — Plan I: map data/visual layer (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the risky, coupled map-data/visual layer of the Flat Map v4 spec
(`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-14-flatmap-v4-design.md` §6 "Plan I scope"):
close both hard bugs (teal-square one-hop flyTo, world-tier label stacking) and give venues + building
nodes real line icons. Concretely: §A one-hop `flyTo` to building tier (amendments I1 + I2) · §B venue declutter
by replacing the DOM-marker `venueMarkers.ts` with a new GeoJSON venue **symbol layer** (B2) · §C non-SDF
**pre-tinted raster** lucide icons for venues + building nodes (B1/M2) · §H building-node click → `NodePanel` ·
plus the cross-cutting #30 anchor-memo churn fix + the I4 cross-layer symbol-collision handling. **Org-halo is
DROPPED** (owner decision) — venue icons are colored by STATUS only.

**Architecture:** every decision testable in jsdom is a **pure function** in a new/edited selector module
(`/Users/jn/code/godview-prototype/src/data/iconSvg.ts`, `/Users/jn/code/godview-prototype/src/data/venueFeatures.ts`,
edits to `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts`) — plain strings / GeoJSON-shaped objects,
no mapbox/WebGL/canvas import. `<FlatMapCanvas>` stays the **only Mapbox imperative island**; Plan I adds the venue
source/layer, the icon-image registration, and the node-click handler INSIDE it, behind the existing
`hasWebGL() && VITE_MAPBOX_TOKEN` guard. The one canvas-touching step (SVG string → `ImageBitmap` →
`map.addImage`) lives in a NEW module reached ONLY via dynamic `import(...)` behind that guard — exactly the
`mapboxImpl.ts` / `mapPulseLayer.ts` discipline — so jsdom never rasterizes anything. **Frontend-only
(godview-prototype). No backend changes.**

**Tech Stack:** React 19 + Vite + Tailwind 3 + react-router-dom v7 + vitest 4 / Testing Library (jsdom);
`mapbox-gl@3.26.0` (proprietary Mapbox TOS — do NOT strip the attribution/logo control); `lucide-react@1.23.0`
(already a dependency, currently unused in `src/`; adopted here for its `__iconNode` stroke geometry);
`globe.gl@2.46.1` + `three@0.185.1` (corner globe — NOT touched by Plan I). **No new runtime dependencies.**

## Global Constraints

- **mapbox-gl isolation via dynamic import (binding).** `mapbox-gl` is imported ONLY inside
  `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts` (`mapboxImpl.ts:4-5`), reached exclusively
  via dynamic `import("./mapboxImpl")` from `<FlatMapCanvas>`'s WebGL/token-guarded init effect
  (`FlatMapCanvas.tsx:67-74`). Plan I introduces **no second `new Map`** and imports `mapbox-gl` nowhere else.
- **jsdom has no WebGL and no canvas — canvas-touching code hides behind the guarded dynamic import.** jsdom's
  `hasWebGL()` is false, so the init effect early-returns and the map is never constructed
  (`FlatMapCanvas.tsx:69`). The SVG→`ImageBitmap` rasterizer needs `createImageBitmap`/canvas, which jsdom lacks →
  it lives in a NEW `/Users/jn/code/godview-prototype/src/components/flatmap/iconImages.ts`, reached ONLY via
  dynamic `import("./iconImages")` inside the map `load` handler (which never runs in jsdom). The FlatMapCanvas
  jsdom test adds a throwing `vi.mock("./iconImages", …)` tripwire (the `mapPulseLayer.ts` pattern,
  `FlatMapCanvas.test` precedent) — it must never fire on the fallback path.
- **Pure modules are unit-tested in jsdom; the pure/imperative seam is `__iconNode → SVG string`.** `iconSvg.ts`
  (string assembly only, NO canvas), `venueFeatures.ts`, and the `buildingFeatures.ts` edits are pure and carry all
  Plan I unit tests. The raster step and every `map.addImage`/`map.addLayer`/`map.on` call are imperative and
  covered only by the live E2E + the tripwire.
- **TDD red→green each task (binding).** Write the failing test FIRST and watch it fail; **commit the failing test
  separately from the implementation that greens it** (red→green pairs must show in git history — memory
  `feedback-tdd-commit-granularity`). Refactor only with tests green.
- **Reuse, do NOT fork (binding, CLAUDE.md §3 + spec §8).** Extend `buildingFeatures.ts`, `mapSelectors.ts`
  (`mapTier` unchanged; selection stops using `nextFlyZoom`), `TONE_HEX`/`healthTone`/`statusGlyph`. **`venueMarkers.ts`
  is REPLACED by `venueFeatures.ts`** (its test migrated) — an explicit replacement, not an orphan. Any import/state
  Plan I's edits leave unused (e.g. `orgColors` once the org-halo is dropped) is removed in the SAME task that
  orphans it; pre-existing dead code is left alone.
- **Org-halo DROPPED (owner decision).** Venue icons are tinted by STATUS only (`healthTone(rollup)` → `TONE_HEX`).
  The `orgColors` prop/ref on `<FlatMapCanvas>` and its page-side `orgColors` memo exist ONLY to feed the old
  DOM-marker halo (`FlatMapCanvas.tsx:163`, `venueMarkers.ts:33-35`); Task 5 removes them as orphans of the migration.
  Do NOT reintroduce an org tint anywhere on the flat map.
- **No `icon-color` — status is baked into the pre-tinted raster (binding, B1/M2).** `icon-color` only tints SDF
  images; Plan I uses `{ sdf:false }` rasters. Per-status color is baked in at rasterization time via `TONE_HEX`;
  the symbol layer selects the correct pre-tinted image with `"icon-image": ["concat", ["get","kind"], "-",
  ["get","status"]]`. Never set `icon-color` on any Plan I layer.
- **Do NOT strip the Mapbox attribution/logo control (TOS).** `mapboxImpl.ts:16` sets `attributionControl:true`;
  Plan I touches no attribution control.
- **Discriminates-proof for every invariant test (memory: v2 caught a VACUOUS test).** Any test asserting a pure
  invariant (sort-key ordering, SVG-string shape, status mapping) MUST carry a one-line note stating the concrete
  mutation that reddens it. A test with no such mutation is vacuous — do not ship it.
- **Subagent workspace discipline (4 drift incidents — memory `feedback-subagent-workspace-discipline`):**
  (1) Step 1 of EVERY implementer dispatch is `cd <worktree path> && pwd` to lock + echo the workspace;
  (2) the bare `/Users/jn/code/godview-prototype` is a READ-ONLY reference — all edits happen in the worktree;
  (3) the controller runs an existence-check (`ls` the files a task creates/modifies) BEFORE dispatching each commit.
  Never commit from the bare path.
- **All git via the git-flow-manager subagent** (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`)
  — implementers NEVER run raw `git`/`gh`. Work on branch `feat/flatmap-i-map-visual` in a DEDICATED worktree of
  `/Users/jn/code/godview-prototype`. Merge commits (not squash) on PR merge (preserves red→green).
- **Verify commands** (confirmed against `/Users/jn/code/godview-prototype/package.json`): `npx vitest run [files]`
  (script `test` = `vitest run`), `npx tsc -b` (build runs `tsc -b && vite build`), `npm run lint` (oxlint),
  `npm run build`.
- Reference every file by ABSOLUTE path.

---

## Contract (Plan I authors; Plan J consumes)

**LOCKED — verbatim. Gate-check this block against Plan J so the two plans don't collide.**

**A. What Plan I PRODUCES (its public surface):**
1. **The icon-image registry — image-name scheme.** On map `load`, Plan I registers one non-SDF raster per
   `kind × status`: **kinds = `venue` | `system` | `camera` | `display`**; **statuses = `ok` | `warn` | `crit` |
   `off`** (the `HealthTone` keys of `TONE_HEX`, `globeSelectors.ts:10`). Image name = `` `${kind}-${status}` `` (16
   images, e.g. `camera-warn`, `venue-crit`). Symbol layers select with
   `"icon-image": ["concat", ["get","kind"], "-", ["get","status"]]`; features MUST carry `properties.kind` and
   `properties.status` set to those exact token vocabularies.
2. **The symbol-layer feature schema** (both pure builders emit these `properties`):
   - `venueFeatures(venues)` → venue GeoJSON `Point` features: `{ kind:"venue", status: HealthTone, name: string,
     sys: number, id: string }`.
   - `buildingFeatures(nodes, mode, live)` → building glyph `Point` features gain `{ status: HealthTone, id: string }`
     ALONGSIDE the existing `{ key, kind, icon, color, label, glyph }`.

**B. What Plan J CONSUMES from Plan I: NOTHING.** Plan J (chrome/controls: legend, panel-collapse, corner-globe
reposition/size/zoom, map +/- buttons) touches **no map data, no symbol/icon layer, and none of the modules in this
plan.** Plan J's only shared contract is the **additive `GlobeCanvas.zoomCmd:{delta,token}|null` prop, which Plan J
authors** (spec §6) — Plan I neither produces nor consumes it. The plan boundary is clean; sequence I → J.

**C. Files BOTH plans edit — collision risk (Plan I must NOT restructure these; Plan J owns them):**
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` is edited by BOTH. Plan I edits **behavior/state only**:
  the fly-to functions (`FlatMap.tsx:80-92`), the fetch/render gate + `anchor` memo (`FlatMap.tsx:55-61`), the
  `panel` state on node-click (`FlatMap.tsx:45,86,127-130`), and removes the now-unused `orgColors` memo
  (`FlatMap.tsx:46-47`) + `<FlatMapCanvas>` `orgColors=` prop (`FlatMap.tsx:112`). Plan I must **NOT** restructure:
  (a) the grid template div `FlatMap.tsx:101` (`grid-cols-[280px_minmax(0,1fr)]`) — **Plan J's §E rail-collapse
  swaps this template;** (b) the right-panel mount block `FlatMap.tsx:126-130` (currently bare) — **Plan J wraps it
  in a positioning wrapper;** (c) the corner-globe mount `FlatMap.tsx:117-125` — **Plan J §F repositions/sizes it and
  adds `zoomCmd`.** Plan I keeps close == `setPanel(null)` (selection reopens the panel for free) so Plan J's collapse
  work stays orthogonal.
- **Guidance:** sequence I → J; Plan J rebases on merged Plan I. When Plan I edits `FlatMap.tsx`, keep the JSX
  structure of lines 101 + 117-130 intact (edit props/handlers, not the element tree) so Plan J's wrappers apply
  cleanly.

---

## File structure (created / modified by Plan I)

**Created:**
- `/Users/jn/code/godview-prototype/src/data/iconSvg.ts` — pure: lucide `__iconNode` (+ color hex) → SVG string;
  `ICON_NODES` (the 4 chosen icons' geometry), `ICON_STATUSES`, `iconImageName(kind,status)`. jsdom-tested.
- `/Users/jn/code/godview-prototype/src/data/iconSvg.test.ts`
- `/Users/jn/code/godview-prototype/src/data/venueFeatures.ts` — pure: `MapVenue[]` → venue GeoJSON symbol features
  + `venueSortKey`. jsdom-tested. (Parallel to `buildingFeatures.ts`.)
- `/Users/jn/code/godview-prototype/src/data/venueFeatures.test.ts` — the migrated `venueMarkers.test.ts` assertions,
  re-expressed as feature-shape assertions.
- `/Users/jn/code/godview-prototype/src/components/flatmap/iconImages.ts` — imperative canvas rasterizer +
  `map.addImage`; dynamic-import-only (jsdom never reaches it). No unit test — covered by the E2E + the tripwire.

**Modified:**
- `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts` — add `status` + `id` to glyph `properties`.
- `/Users/jn/code/godview-prototype/src/data/buildingFeatures.test.ts` — assert the two new properties.
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx` — venue source+layer replaces the
  DOM-markers effect; icon-image registration on load; building-glyph symbol layer switches to `icon-image`;
  node-click handler + `onNodeClick` prop; camera effect (`essential:true`, ~2 s, `MapFocus.duration`); drop
  `orgColors`.
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx` — thread new props on the fallback
  path; add the `iconImages` tripwire; drop venue-marker/`orgColors` assertions.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` — split fly-to; eager-fetch/zoom-gated-render decouple;
  `anchor` memo; `onNodeClick`→`setPanel`; remove `orgColors`.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx` — fly-to target zoom, gate, node-click assertions.

**Deleted (Task 5 — explicit replacement, not an orphan):**
- `/Users/jn/code/godview-prototype/src/data/venueMarkers.ts`
- `/Users/jn/code/godview-prototype/src/data/venueMarkers.test.ts`

---

## Task 1 — Worktree + preflight / contract verify

**Files** — none modified (read-only verification; no TDD pair).

**Steps**
- [ ] Ask git-flow-manager to create a worktree + branch `feat/flatmap-i-map-visual` from `main` for
  `/Users/jn/code/godview-prototype`. Record the checkout path; **Step 1 of every later dispatch is `cd <that path>
  && pwd`.** The bare `/Users/jn/code/godview-prototype` is READ-ONLY.
- [ ] Confirm the amended-spec baseline is on `main`: `git log --oneline -3` should show Plan G (#24) + Plan H (#27)
  merged (`main@3bc3ff7` per spec). If not, STOP and report.
- [ ] Confirm the current island facts Plan I edits, by grep (record exact line numbers if they drift):
  - `FlatMapCanvas.tsx`: the DOM-markers effect (`buildVenueMarker` at ~`:164`, `markersRef`, `lastTierModeRef`,
    `tier` memo ~`:136`, `orgColors`/`orgColorsRef` ~`:62,163`); the building layers added on `load`
    (`building-glyphs-symbol` ~`:104-111`, `building-glyphs-circle` ~`:97-103`, `building-connectors-line` ~`:93-96`);
    the camera effect `flyTo({… duration:1200})` ~`:250` (no `essential`); the `load` handler ~`:89-114`.
  - `FlatMap.tsx`: `flyToVenue`/`selectVenue`/`onCornerDotClick` ~`:80-92`; `buildingVenueId` gate ~`:55`; `anchor`
    literal ~`:57`; `orgColors` memo ~`:46-47`; `panel` state + mount ~`:45,127-130`.
  - `mapSelectors.ts`: `STAGE_ZOOM = { country:4, city:11, building:15.5 }` (`:16`), `CITY_ZOOM=5`, `BUILDING_ZOOM=14`.
- [ ] Confirm the reuse surface byte-unchanged: `TONE_HEX` + `type HealthTone` + `healthTone` (`globeSelectors.ts:10-19`),
  `statusGlyph` (`explodeSelectors.ts:210-214`), `MapVenue`/`MapVenueRollup` (`apiTypes.ts:127-141`), `MapNode`
  (`mapLayout.ts:8-18`).
- [ ] **Resolve the lucide `__iconNode` import specifier.** Verify the four modules export `__iconNode`:
  `node_modules/lucide-react/dist/esm/icons/{building-2,server,video,monitor-play}.mjs` (confirmed present, v1.23.0).
  Decide the import path Task 2 uses: PREFER `import { __iconNode as Building2Node } from "lucide-react/dist/esm/icons/building-2.mjs"`;
  if that subpath is not in lucide's `exports` map (build/tsc fails to resolve), FALL BACK to inlining the four
  `__iconNode` arrays as local `const`s in `iconSvg.ts` (verbatim from the v1.23.0 source, geometry reproduced in Task
  2 below). Record which path resolves. Also confirm `defaultAttributes` = `{ viewBox:"0 0 24 24", fill:"none",
  stroke:"currentColor", strokeWidth:2, strokeLinecap:"round", strokeLinejoin:"round" }`.
- [ ] Sanity: `npx vitest run` and `npx tsc -b` green on the fresh branch before any change.

---

## Task 2 — Pure lucide-SVG builder (`iconSvg.ts`)

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/iconSvg.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/iconSvg.test.ts`

**Interfaces**
```ts
// iconSvg.ts — PURE. String assembly only. No canvas, no mapbox, no react. jsdom-testable.
import { TONE_HEX, type HealthTone } from "./globeSelectors";

export type IconKind = "venue" | "system" | "camera" | "display";
// lucide __iconNode entry: [svgTag, attrs] (attrs include a `key` we drop).
export type IconNode = [string, Record<string, string | number>][];

export const ICON_NODES: Record<IconKind, IconNode>;   // Building2 / Server / Video / MonitorPlay geometry
export const ICON_STATUSES: readonly HealthTone[];      // ["ok","warn","crit","off"]

/** `${kind}-${status}` — the map.addImage name AND the icon-image expression target. */
export function iconImageName(kind: IconKind, status: HealthTone): string;
/** Assemble a lucide stroke SVG string, stroked in `colorHex`. viewBox 0 0 24 24, fill:none,
 *  stroke-width 2, round caps/joins (lucide defaultAttributes). Deterministic attribute order. */
export function iconSvg(kind: IconKind, colorHex: string): string;
```

Rules (each a test, with the discriminating mutation noted):
- `ICON_STATUSES` deep-equals `["ok","warn","crit","off"]` (the `TONE_HEX` keys). *Mutation: drop `"crit"` → the
  "16 combos" count test in Task 4's registry (and this length assert) reddens.*
- `iconImageName("camera","warn")` === `"camera-warn"`; `iconImageName("venue","crit")` === `"venue-crit"`.
  *Mutation: swap the separator/order → red.*
- `iconSvg("server", TONE_HEX.ok)` returns a string that: starts with `<svg`, contains `viewBox="0 0 24 24"`,
  `fill="none"`, `` stroke="${TONE_HEX.ok}" ``, `stroke-width="2"`, and contains the Server geometry (`<rect`
  twice + `<line` twice); contains NO `key=` attribute; ends with `</svg>`. *Mutation: hardcode `stroke="#fff"` →
  the per-status-color assert reddens (this is the whole point — status baked into the raster, no `icon-color`).*
- `iconSvg` is pure: same args → identical string.

**Steps**
- [ ] **Write the failing test** `iconSvg.test.ts` covering the four rules above (assert on substrings + a
  `.startsWith("<svg")`/`.includes("</svg>")` pair; assert `.includes("key=") === false`).
- [ ] **Run to verify it fails:** `npx vitest run src/data/iconSvg.test.ts` → FAIL (`Cannot find module './iconSvg'`).
- [ ] **Commit (red):** `test(flatmap): pure lucide __iconNode -> tinted SVG string builder (red)`
- [ ] **Implement** `iconSvg.ts`:
  - `ICON_NODES` = the four geometries. Source them per Task 1's resolution — either
    `import { __iconNode as … } from "lucide-react/dist/esm/icons/<kebab>.mjs"` for `building-2`, `server`, `video`,
    `monitor-play`, mapped `{ venue:Building2, system:Server, camera:Video, display:MonitorPlay }`; OR inline verbatim
    (v1.23.0): Server `[["rect",{width:"20",height:"8",x:"2",y:"2",rx:"2",ry:"2"}],["rect",{width:"20",height:"8",
    x:"2",y:"14",rx:"2",ry:"2"}],["line",{x1:"6",x2:"6.01",y1:"6",y2:"6"}],["line",{x1:"6",x2:"6.01",y1:"18",
    y2:"18"}]]`; Building2/Video/MonitorPlay geometry likewise from the Task-1 dump (drop each entry's `key`).
  - `iconSvg`: emit `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"
    stroke="${colorHex}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` + each child
    `<${tag} ${attrs}/>` (attrs serialized in insertion order, `key` skipped, values quoted) + `</svg>`.
  - `iconImageName` = `` `${kind}-${status}` ``; `ICON_STATUSES` = `["ok","warn","crit","off"] as const`.
- [ ] **Run to verify it passes:** `npx vitest run src/data/iconSvg.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): pure lucide-SVG builder (Building2/Server/Video/MonitorPlay, status-tinted)`

---

## Task 3 — Pure venue symbol features (`venueFeatures.ts`) + migrate the venueMarkers test

**Files**
- Create: `/Users/jn/code/godview-prototype/src/data/venueFeatures.ts`
- Create: `/Users/jn/code/godview-prototype/src/data/venueFeatures.test.ts` (migrated assertions)

**Interfaces**
```ts
// venueFeatures.ts — PURE. Local structural GeoJSON types (mapbox setData accepts them at runtime).
// Direct parallel to buildingFeatures.ts. No mapbox/react.
import type { MapVenue } from "./apiTypes";
import { type HealthTone, healthTone } from "./globeSelectors";

export interface VenuePointFeature {
  type: "Feature"; geometry: { type: "Point"; coordinates: [number, number] };  // [lng, lat]
  properties: { kind: "venue"; status: HealthTone; name: string; sys: number; id: string; sortKey: number };
}
export interface FeatureCollection<F> { type: "FeatureCollection"; features: F[]; }

/** Lower key => placed first => wins Mapbox label collision. Worst status first, then more systems.
 *  rank: crit 0, warn 1, off 2, ok 3; key = rank*1000 - sys. */
export function venueSortKey(status: HealthTone, sys: number): number;
/** One Point feature per venue with lat/lng present; status = healthTone(rollup); no org tint. */
export function venueFeatures(venues: MapVenue[]): FeatureCollection<VenuePointFeature>;
```

Rules (each a test — these ARE the migrated `venueMarkers.test.ts` assertions, re-expressed):
- **(migrated: "world tier rollup badge / name + system count")** a `venue()` with `rollup.systems=3`, `name:"Dallas
  North"` → a feature with `properties.name === "Dallas North"`, `properties.sys === 3`, `properties.id === "loc1"`,
  `properties.kind === "venue"`, and `geometry.coordinates === [lng, lat]` (GeoJSON order).
- **(migrated: "health-tone dot")** `worst_status:"active"` → `status === "ok"`; `worst_status:"degraded"` →
  `"warn"`; `failures_last_hour>0` → `"crit"` (via `healthTone`, so the tint comes from `TONE_HEX[status]` — NO org
  color anywhere). *Mutation: hardcode `status:"ok"` → the degraded/crit asserts redden.*
- **(migrated: "null org halo does not crash")** a venue with `org: null` (or absent) still emits a feature (org is
  irrelevant now — halo dropped). *Mutation: read `venue.org.color` → throws on null, reddens.*
- venues with `lat==null || lng==null` are skipped (mirrors the marker effect's `FlatMapCanvas.tsx:154` guard).
- `venueSortKey("crit",5) < venueSortKey("warn",5) < venueSortKey("ok",5)`; and for equal status, more systems
  sorts first: `venueSortKey("ok",9) < venueSortKey("ok",1)`. *Mutation: return a constant → both ordering asserts
  redden.*
- Pure + empty-safe: `venueFeatures([]).features === []`.

**Steps**
- [ ] **Write the failing test** `venueFeatures.test.ts` (reuse the `venue(over)` factory shape from
  `/Users/jn/code/godview-prototype/src/data/venueMarkers.test.ts:5-11`).
- [ ] **Run to verify it fails:** `npx vitest run src/data/venueFeatures.test.ts` → FAIL (`Cannot find module`).
- [ ] **Commit (red):** `test(flatmap): pure venue symbol features + sortKey (migrated from venueMarkers) (red)`
- [ ] **Implement** `venueFeatures.ts` per Interfaces + Rules. `venueSortKey`: `const RANK = {crit:0,warn:1,off:2,
  ok:3}; return RANK[status]*1000 - sys;`. Do NOT delete `venueMarkers.ts` yet (still imported by
  `FlatMapCanvas.tsx:5` until Task 5).
- [ ] **Run to verify it passes:** `npx vitest run src/data/venueFeatures.test.ts` → PASS; full `npx vitest run`
  (old `venueMarkers.test.ts` still green); `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): pure venue symbol features (status-only, sortKey) parallel to buildingFeatures`

---

## Task 4 — Icon-image raster module (`iconImages.ts`) behind the guard + FlatMapCanvas registers images on load

**Files**
- Create: `/Users/jn/code/godview-prototype/src/components/flatmap/iconImages.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`

**Interfaces**
```ts
// iconImages.ts — imperative, canvas-touching. Reached ONLY via dynamic import("./iconImages")
// inside FlatMapCanvas's load handler (after the WebGL/token guard). `map` typed `any` (island convention).
/** Rasterize every ICON_KINDS × ICON_STATUSES SVG to an ImageBitmap and register it non-SDF:
 *  map.addImage(iconImageName(kind,status), bitmap, { sdf:false }). Idempotent (skips map.hasImage). */
export async function registerIconImages(map: any): Promise<void>;
```

**Island wiring decisions** (inside FlatMapCanvas's existing guarded island):
- In the map `load` handler (`FlatMapCanvas.tsx:89`), make the callback async and **register images BEFORE adding any
  icon-image layer** (avoids "image not found" console warnings — success criterion is 0 console errors):
  `const { registerIconImages } = await import("./iconImages"); await registerIconImages(map);` then add the venue
  source/layer (Task 5) + building layers. Keep `mapRef.current = map; setReady(true)` last.
- `iconImages.ts` rasterizes with the browser canvas path: for each `(kind,status)` build `iconSvg(kind,
  TONE_HEX[status])` (imported PURE), wrap in a `Blob([svg], {type:"image/svg+xml"})`, `createImageBitmap(blob)` (or
  draw the SVG onto an offscreen `<canvas>` at ~48px and `getImageData`), then `map.addImage(name, bitmap,
  {sdf:false})`. Render at a crisp fixed pixel size (~48px); the layer sets `icon-size` (~0.5) to display ~24px.
- No `icon-color` anywhere (baked-in color). Type-only imports (`iconSvg`) are fine at module top of `iconImages.ts`;
  it imports `mapbox-gl` NOWHERE (the `map` is passed in) — the tripwire proves the DYNAMIC-IMPORT boundary, not a
  heavy dependency.

**Steps**
- [ ] **Write the failing test** — extend `FlatMapCanvas.test.tsx`: add `vi.mock("./iconImages", () => { throw new
  Error("iconImages (canvas) must not load in jsdom"); });` next to any existing `./mapPulseLayer` tripwire, and a
  test asserting the fallback path still renders `map-unavailable` (jsdom never runs `load` → never imports
  `iconImages`). *Discriminates-proof: if the load handler imported `./iconImages` unconditionally (outside the
  guard), the throwing mock fires and this reddens; it stays green only because the map is never constructed in
  jsdom.*
- [ ] **Run to verify it fails:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx`. If the tripwire
  mock is genuinely never reached the test may pass immediately — in that case make it RED by first asserting a
  symptom of the not-yet-written wiring (e.g. the test file imports `registerIconImages` type, or assert an
  interim). Prefer: land the tripwire green-by-construction but pair it with Task 5/6's prop tests for the red→green.
  (Note: registration adds no page-facing prop, so its own red→green rides on Task 5's venue-layer test; keep the
  tripwire in this commit.)
- [ ] **Commit (red):** `test(flatmap): iconImages canvas module never loads on the jsdom fallback path (red)`
- [ ] **Implement** `iconImages.ts` + the async `load`-handler registration per the wiring decisions.
- [ ] **Run to verify it passes:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx` → PASS (jsdom never
  reaches the throwing mock); `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): pre-tinted non-SDF icon rasters (kind×status) registered on map load`

---

## Task 5 — Venue symbol layer replaces the DOM-marker effect (retire venueMarkers.ts)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`
- Delete: `/Users/jn/code/godview-prototype/src/data/venueMarkers.ts`
- Delete: `/Users/jn/code/godview-prototype/src/data/venueMarkers.test.ts`

**Island wiring decisions:**
- On `load` (AFTER `registerIconImages`, BEFORE the building layers so building glyphs z-order ABOVE venues at
  building tier): add source `"venues"` (`{ type:"geojson", data: EMPTY_FC }`) and layer `"venue-symbol"`
  (`type:"symbol"`, `source:"venues"`):
  ```
  layout: {
    "icon-image": ["concat", ["get","kind"], "-", ["get","status"]],   // "venue-<status>"
    "icon-size": 0.5, "icon-allow-overlap": true, "icon-optional": false,
    "text-field": ["concat", ["get","name"], " · ", ["to-string",["get","sys"]], " sys"],
    "text-size": 11, "text-offset": [0, 1.1], "text-anchor": "top",
    "text-allow-overlap": false, "text-optional": true,      // drop label on collision, keep icon
    "symbol-sort-key": ["get","sortKey"],
    // labels: OFF below city tier, ON in the city band, OFF at building tier (building nodes win, I4):
    "text-opacity": ["step", ["zoom"], 0, CITY_ZOOM /*5*/, 1, BUILDING_ZOOM /*14*/, 0]
  }
  paint: { "text-color": ["get", ... status→hex ...], "text-halo-color": "#0a0d12", "text-halo-width": 1 }
  ```
  For `text-color`, use a `["match", ["get","status"], "ok", TONE_HEX.ok, "warn", TONE_HEX.warn, "crit",
  TONE_HEX.crit, TONE_HEX.off]` expression (or bake a `color` prop in `venueFeatures`; pick one — matching the
  `settlement-label` halo `#0a0d12` from `style.json` for legibility). No `icon-color`.
- **Replace the DOM-markers effect** (`FlatMapCanvas.tsx:141-170`) with a `venues` setData effect
  (deps `[venues, ready]`): guard `if (!map || !ready || !map.isStyleLoaded()) return;`
  `map.getSource("venues")?.setData(venueFeatures(venues));` — mirrors the building setData guard
  (`FlatMapCanvas.tsx:174-179`). `venueFeatures` is imported PURE from `../../data/venueFeatures`.
- **Remove orphans the migration creates** (Global Constraints — org-halo dropped): delete the
  `import { buildVenueMarker } from "../../data/venueMarkers"` (`:5`); `markersRef`, `lastTierModeRef`, the `tier`
  memo (`:136`, if now unused), and the `orgColors` prop + `orgColorsRef` (`:29,62,163`) + its removal from the
  dispose loop's marker cleanup (`:121`). If the local `zoom`/`setZoom` state (`:47,84-87`) is now read by nothing
  but the deleted `tier` memo, remove it too (keep the `map.on("zoom")` → `onZoomRef.current(z)` page callback).
- Then **delete `venueMarkers.ts` + `venueMarkers.test.ts`** (their sole consumer is gone → explicit replacement).

**Steps**
- [ ] **Write the failing test** — in `FlatMapCanvas.test.tsx` remove the `venue-marker`/`orgColors` assertions and
  drop `orgColors` from every `render(...)`; add a fallback-path test that `<FlatMapCanvas>` accepts `venues` and no
  longer accepts `orgColors` (TS error is the red). Delete `venueMarkers.test.ts` in the SAME red commit so the
  suite reflects the retirement.
- [ ] **Run to verify it fails:** `npx vitest run` → FAIL (TS: `orgColors` still required/passed, or `buildVenueMarker`
  import missing). Record the error.
- [ ] **Commit (red):** `test(flatmap): retire DOM venue markers; canvas accepts venues symbol source (red)`
- [ ] **Implement** the venue source/layer + setData effect + orphan removals; delete `venueMarkers.ts`.
- [ ] **Run to verify it passes:** `npx vitest run` → PASS; `npx tsc -b` + `npm run lint` → clean (lint catches any
  missed orphan import).
- [ ] **Commit (green):** `feat(flatmap): venue GeoJSON symbol layer (collision-managed labels, status icons) replaces DOM markers`

---

## Task 6 — Building glyphs switch to pre-tinted icons (+ `status`/`id` feature props)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/buildingFeatures.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`

**Interfaces** (extend the existing `PointFeature.properties`):
```ts
properties: {
  key: string; kind: MapNode["type"]; icon: string; color: string; label: string; glyph: string;
  status: HealthTone;   // NEW — nodeIconStatus(node.status): "active"→"ok","degraded"→"warn", else "off"
  id: string;           // NEW — node.id (node-click target, Task 8)
}
export function nodeIconStatus(status: string): HealthTone;  // pure; building nodes have no failures signal → no "crit"
```

**Wiring:**
- `buildingFeatures.ts`: add `nodeIconStatus` (active→ok, degraded→warn, else→off — same shape as `glyphColor`'s
  health branch, `buildingFeatures.ts:34-37`) and set `properties.status = nodeIconStatus(node.status)` +
  `properties.id = node.id`. Keep `kind`/`color`/`label`/`glyph`/`icon` (backward-compatible; `icon`/`glyph` may
  become unused after the layer switch — leave them, they're covered by existing tests and cheap).
- `FlatMapCanvas.tsx` `building-glyphs-symbol` layer (`:104-111`): swap the `text-field` glyph+label layout to
  **icon + name label**:
  ```
  layout: {
    "icon-image": ["concat", ["get","kind"], "-", ["get","status"]],   // "system-ok" etc.
    "icon-size": 0.5, "icon-allow-overlap": true,
    "text-field": ["get","label"], "text-size": 10, "text-offset": [0, 1.2],
    "text-allow-overlap": false, "text-optional": true,
  }
  paint: { "text-color": ["get","color"] }   // label color reuses the baked feature color; NO icon-color
  ```
  Keep the `building-glyphs-circle` layer (`:97-103`) as a subtle status ring under the icon (unchanged).
- Building glyph `kind` = `node.type` ∈ `system|camera|display` → image `"<type>-<status>"`; the venue kind is only
  used by Task 5. All 4×4 images exist (Task 4).

**Steps**
- [ ] **Write the failing test** — extend `buildingFeatures.test.ts`: assert a system glyph feature has
  `properties.status === "ok"` for `status:"active"`, `"warn"` for `"degraded"`, `"off"` for anything else, and
  `properties.id === node.id`. *Mutation: omit the `status` prop → red; hardcode `"ok"` → the degraded case reddens.*
- [ ] **Run to verify it fails:** `npx vitest run src/data/buildingFeatures.test.ts` → FAIL.
- [ ] **Commit (red):** `test(flatmap): building glyph features carry status + id for icon-image + node-click (red)`
- [ ] **Implement** `nodeIconStatus` + the two new props; switch the `building-glyphs-symbol` layer to `icon-image`.
- [ ] **Run to verify it passes:** `npx vitest run` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): building nodes render pre-tinted lucide icons (status-colored), name label kept`

---

## Task 7 — One-hop flyTo + eager-fetch / zoom-gated-render decouple + anchor memo (§A, I1/I2, #30)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Interfaces** (extend `MapFocus` on the island):
```ts
export interface MapFocus { lat: number; lng: number; zoom: number; token: number; duration?: number; }
```

**Wiring:**
- **Split fly-to (I1)** in `FlatMap.tsx` (`:80-92`): selecting a VENUE flies straight to
  `STAGE_ZOOM.building` (15.5) in one hop; a CLUSTER centroid flies to `STAGE_ZOOM.city` (11). Selection stops
  calling `nextFlyZoom(mapZoom)` (which may remain for a future manual step-zoom only):
  ```ts
  const flyTo = (lat:number, lng:number, zoom:number) =>
    setMapFocus((f) => ({ lat, lng, zoom, duration: 2000, token: (f?.token ?? 0) + 1 }));
  const selectVenue = (id:string, lat:number, lng:number) => {
    setSelectedVenueId(id); setPanel({ type:"venue", id, venueId:id });
    flyTo(lat, lng, STAGE_ZOOM.building);
  };
  const onCornerDotClick = (dot:GlobeDot) => dot.kind === "venue"
    ? selectVenue(dot.venue.location_id, dot.lat, dot.lng)
    : flyTo(dot.lat, dot.lng, STAGE_ZOOM.city);   // cluster → city, no selection
  ```
  (Update the rail `onSelect` at `:103-107` to call `flyTo(v.lat, v.lng, STAGE_ZOOM.building)`.) Import `STAGE_ZOOM`
  from `../data/mapSelectors`.
- **Camera effect (I1)** in `FlatMapCanvas.tsx` (`:247-251`):
  `map.flyTo({ center:[focus.lng,focus.lat], zoom:focus.zoom, duration: focus.duration ?? 2000, essential:true,
  curve:1.42, speed:1.2 });` (moderate curve/speed; `essential:true` so `prefers-reduced-motion` / backgrounded tabs
  still animate). Range 1800–2200ms is acceptable.
- **Decouple fetch from render (I2)** in `FlatMap.tsx` (`:55-61`): fetch EAGERLY on `selectedVenueId` (starts at
  click, preloads during the fly); compute the rendered `building` only when `mapTier(mapZoom)==="building"`:
  ```ts
  const { detail } = useVenueDetailPoll(selectedVenueId);            // eager — no zoom gate on fetch
  const atBuilding = mapTier(mapZoom) === "building";
  const building = useMemo(
    () => (atBuilding && nodes) ? buildingFeatures(nodes, mode, live) : null,
    [atBuilding, nodes, mode, live]);
  ```
  (Also gate `buildingPulses` on `atBuilding` so no tiny path pulses draw at world tier.) Net: detail is ready the
  instant tier flips; no building glyphs ever drawn at world tier; no settle latency. Keep the observed-zoom gate for
  RENDER, selection intent for FETCH — no separate "building intent" flag.
- **Anchor memo (#30)** in `FlatMap.tsx` (`:57`): memoize on lat/lng PRIMITIVES so the mini-globe's autorotate
  (`onPovChange`→`setPov`→re-render every frame) stops re-parsing GeoJSON:
  ```ts
  const anchor = useMemo(
    () => detail && detail.location.lat != null && detail.location.lng != null
      ? { lat: detail.location.lat, lng: detail.location.lng } : null,
    [detail?.location.lat, detail?.location.lng]);
  ```

**Steps**
- [ ] **Write the failing test** — in `FlatMap.test.tsx` (reuse the existing `FlatMapCanvas` prop-capturing mock):
  (a) selecting a venue captures `focus.zoom === 15.5` in ONE `setMapFocus` (not a `nextFlyZoom` ladder rung);
  (b) with a selected venue but map zoom in the CITY band, captured `building === null` while a `detail` fetch is in
  flight (eager-fetch/gated-render); (c) at building zoom, `building !== null`. *Mutation for (a): revert to
  `nextFlyZoom(mapZoom)` → from initial `mapZoom=1.4` the captured zoom becomes 4, reddening (a).*
- [ ] **Run to verify it fails:** `npx vitest run src/pages/FlatMap.test.tsx` → FAIL.
- [ ] **Commit (red):** `test(flatmap): one-hop flyTo to building zoom + eager-fetch/gated-render + anchor memo (red)`
- [ ] **Implement** the split fly-to, camera effect, decouple, and anchor memo. Do NOT restructure the grid div
  (`:101`) or the panel/corner-globe mounts (`:117-130`) — Contract §C (Plan J owns them).
- [ ] **Run to verify it passes:** `npx vitest run` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): one-hop flyTo to building tier + eager detail fetch + memoized anchor (#30/#31)`

---

## Task 8 — Building node click → NodePanel (§H)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Interfaces** (new additive prop on `<FlatMapCanvas>`):
```ts
onNodeClick: (sel: { type: "system" | "camera" | "display"; id: string }) => void;
```

**Wiring:**
- In the `load` handler, after adding `building-glyphs-symbol`, register:
  `map.on("click", "building-glyphs-symbol", (e) => { const f = e.features?.[0]; if (!f) return;
  onNodeClickRef.current({ type: f.properties.kind, id: f.properties.id }); });` — reads the `kind`/`id` props Task 6
  adds. Add an `onNodeClickRef` latest-callback ref (mirror `onZoomRef`, `:60`), plus optional
  `mouseenter`/`mouseleave` on the layer to toggle `map.getCanvas().style.cursor = "pointer"`.
- `FlatMap.tsx`: pass `onNodeClick={(sel) => setPanel({ type: sel.type, id: sel.id, venueId: selectedVenueId! })}`.
  `NodePanel` is already fed the page `detail` (`:129-130`) — no new fetch. Keep close == `setPanel(null)`.

**Steps**
- [ ] **Write the failing test** — `FlatMap.test.tsx`: extend the `FlatMapCanvas` mock to expose the captured
  `onNodeClick`; invoke it with `{type:"camera", id:"c1"}` and assert a `NodePanel` (`node-panel` testid) mounts
  keyed `camera:c1` fed by the page detail. *Mutation: page ignores `onNodeClick` → no panel → red.*
- [ ] **Run to verify it fails:** `npx vitest run src/pages/FlatMap.test.tsx` → FAIL (unknown prop `onNodeClick` /
  no panel).
- [ ] **Commit (red):** `test(flatmap): building node click opens its NodePanel (red)`
- [ ] **Implement** the `onNodeClick` prop + `map.on("click","building-glyphs-symbol",…)` + page wiring.
- [ ] **Run to verify it passes:** `npx vitest run` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(flatmap): building-node click -> device NodePanel (closes Plan H #28 gap)`

---

## Task 9 — Full suite, typecheck, lint, build, PR

**Files** — none new; scoped fixes only (each committed with its reason).

**Steps**
- [ ] `cd <worktree> && pwd`. `npx vitest run` — full suite green (jsdom never hits the `iconImages`/`mapPulseLayer`
  throwing mocks).
- [ ] `npx tsc -b` clean; `npm run lint` (oxlint) clean — lint must confirm NO orphan imports remain from the
  `venueMarkers`/`orgColors` retirement.
- [ ] `npm run build` succeeds. **Bundle guardrail:** `iconImages.ts` must land in a LAZY chunk (dynamic-import only,
  like `mapboxImpl`/`mapPulseLayer`); `iconSvg.ts`/`venueFeatures.ts` are pure and small. `ls -lS dist/assets | head`;
  record chunk sizes in the commit message.
- [ ] **Contract gate-check:** re-read the "Contract (Plan I authors; Plan J consumes)" block. Confirm the produced
  surface matches: image names `${kind}-${status}` with kinds `venue|system|camera|display` × statuses
  `ok|warn|crit|off`; `venueFeatures`/`buildingFeatures` `properties.kind/status/id`. Confirm Plan I did NOT
  restructure `FlatMap.tsx:101` or `:117-130` (Plan J's turf).
- [ ] Controller existence-check: `ls src/data/iconSvg.ts src/data/venueFeatures.ts
  src/components/flatmap/iconImages.ts` AND confirm `src/data/venueMarkers.ts` / `venueMarkers.test.ts` are GONE.
- [ ] Commit: `chore(flatmap): full suite + tsc + lint + build green; iconImages in lazy chunk (sizes noted)`
- [ ] Ask git-flow-manager to push the branch and open a PR titled
  `feat(flatmap): map data/visual layer — one-hop flyTo + venue symbol layer + pre-tinted icons + node click (Plan I)`
  against `main` with the structured description (Summary / Motivation / Implementation / Tests / Risks / rollout),
  noting: both hard bugs closed (#31 teal-square one-hop, label-stack); org-halo DROPPED; non-SDF pre-tinted rasters
  (B1); `venueMarkers.ts` explicitly REPLACED by `venueFeatures.ts` (B2); #30 anchor memo folded in; attribution
  kept. Request code review (superpowers:requesting-code-review) with the strongest available model; resolve findings
  before Task 10.

---

## Task 10 — Live Playwright E2E + design-review gate

**DEPENDENCY:** PR branch live; dev stack up (ops-api `:8080`, projector, seed applied); `VITE_MAPBOX_TOKEN` set in
the worktree env; frontend `npm run dev`. Findings become scoped fix commits on this branch or follow-up GitHub
issues.

**Files** — none (live drill).

**Steps**
- [ ] Preconditions: `/god-view/map` returns venues; `/god-view/map/locations/{id}` returns systems/cameras/displays.
  Token present so `<FlatMapCanvas>` mounts the map (not `map-unavailable`).
- [ ] Headless WebGL note: if Playwright MCP lacks WebGL, cover the visual checks with a headed/real-browser pass —
  the icon + fly-to + collision checks are intrinsically visual.
- [ ] **One-hop flyTo (no teal square):** from the initial world view, select a venue (rail or corner-globe dot). It
  flies in a SINGLE ~2 s hop straight to building tier; camera/system/display icons render; NO empty teal square,
  NO 3-click ladder. Screenshot.
- [ ] **World-tier declutter:** at world zoom with many venues, labels do NOT stack (Mapbox collision drops
  overlapping labels; icons stay). Zoom into the city band → names appear; zoom to building tier → venue names
  disappear and building nodes win (I4). Screenshot both.
- [ ] **Icons + color:** building nodes show recognizable line icons (Server / Video / MonitorPlay) tinted by status
  (green/amber/red/grey via `TONE_HEX`); venues show the Building2 icon status-tinted. No org tint anywhere.
- [ ] **Node click → panel:** click a system icon → `NodePanel` (system) with zone/status/system_type; camera →
  camera panel (screen_id/duty); display → display panel; venue (rail) → `VenuePanel`. Each keyed `${type}:${id}`
  (no stale content on switch).
- [ ] **No leak / 0 errors:** leave `/map` 10+ min under generator load — 0 app console errors (no "image not found"),
  no unbounded source/layer growth; the mini-globe pauses during a Mapbox `flyTo` and resumes; navigate away/back —
  no leaked rAF/timer warnings.
- [ ] Tune flagged visual constants (icon `icon-size`, raster pixel size, `text-offset`, `text-opacity` step
  thresholds, fly `duration`/`curve`/`speed`, `venueSortKey` ranks) as scoped commits if the live look demands it.
- [ ] **Design-review gate (the v3 miss):** run the design-review pass; sign off on venue/building icon legibility,
  label declutter, one-hop feel, and node-click affordance. File subjective polish as issues.
- [ ] Fix anything found (red→green where code changes), then ask git-flow-manager to merge the PR (merge commit)
  after review is resolved and checks are green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with
  `repo@sha`, E2E evidence + screenshots, gotchas); file deferred follow-ups (Plan J chrome; selected/hover label
  reveal; real per-device coords) as GitHub issues so nothing falls off the plan.

---

## Self-review notes (spec §6 "Plan I scope" coverage check, done at plan time)

- **§A one-hop flyTo (I1/I2):** Task 7 splits `flyToVenue` (venue→15.5, cluster→11), sets `essential:true` + ~2 s
  duration on the camera effect, and decouples eager fetch (on `selectedVenueId`) from zoom-gated render
  (`mapTier==='building'`). Closes #31 + the teal square. ✓
- **§B venue declutter / symbol migration (B2):** Task 3 (pure `venueFeatures` + migrated test) + Task 5 (venue
  symbol layer replaces the DOM-markers effect, `venueMarkers.ts`+test deleted, `text-allow-overlap:false` +
  `text-optional:true` + `symbol-sort-key` = real Mapbox collision; `text-opacity` zoom-step suppresses labels at
  world + building tiers). Org-halo dropped; `orgColors` removed. ✓
- **§C non-SDF pre-tinted icons (B1/M2):** Task 2 (pure `__iconNode`→SVG string), Task 4 (canvas rasterizer behind
  the dynamic-import guard + tripwire; `map.addImage(..., {sdf:false})` for 4×4 combos), Tasks 5/6 select via
  `["concat",["get","kind"],"-",["get","status"]]` — NO `icon-color`. ✓
- **§H node click:** Task 8 adds `onNodeClick` + `map.on("click","building-glyphs-symbol",…)` reading `kind`/`id`
  → page `setPanel`. ✓
- **#30 anchor memo + I4 cross-layer collision:** Task 7 memoizes `anchor` on lat/lng primitives; Task 5's
  `symbol-sort-key` + zoom-step label suppression + venue-below-building z-order handle cross-layer collision. ✓
- **Testability (binding):** all decisions pure + jsdom-tested (Tasks 2/3/6); the two canvas/Mapbox modules
  (`iconImages.ts`, and the existing `mapPulseLayer.ts`) are dynamic-import-only behind the guard, with throwing
  tripwires. ✓
- **Reuse-not-fork + org-halo dropped:** `venueMarkers.ts` explicitly REPLACED (not orphaned); `TONE_HEX`/`healthTone`/
  `statusGlyph`/`mapTier` reused; `orgColors` removed as an orphan of the migration. ✓
- **Plan J boundary:** Contract §B/§C — Plan J consumes nothing from Plan I and authors `GlobeCanvas.zoomCmd`;
  Plan I edits `FlatMap.tsx` behavior only and leaves the grid div (`:101`) + panel/corner-globe mounts
  (`:117-130`) structurally intact for Plan J. ✓
- **Process:** worktree branch, no raw git for implementers, red→green pairs watched failing, exact verify commands,
  PR + strongest-model review, live E2E + design-review gate, SESSION_LOG close-out — Tasks 1/9/10. ✓
