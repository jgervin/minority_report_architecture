# Flat Map v4 — Plan J: Chrome/Controls (godview-prototype)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the chrome/controls half of the Flat Map v4 UX/UI polish lane
(`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-14-flatmap-v4-design.md` §3 D/E/F/G +
§6 "Plan J scope"): a compact collapsible corner legend (§D), left-rail + right-panel collapse on **both**
`/map` and `/globe` (§E, amended I3), the corner-globe nav window's reposition + size toggle + +/- zoom (§F,
amended M1), and themed Mapbox +/- zoom buttons (§G, amended M3). **Plan J touches no map data** — venue/building
rendering, icons, and the one-hop flyTo fix are Plan I's job
(`/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-14-flatmap-i-map-data.md`, if/when
written — this plan does not create it). Frontend-only (`godview-prototype`). No backend changes.

**Sequencing (LOCKED):** Plan J branches from `main` **after Plan I merges** (spec §6: "Sequence I → J"). Plan I is
the risky, coupled map-data/icon lane; Plan J is lower-risk React/CSS chrome. The two plans share almost nothing —
only the additive `GlobeCanvas.zoomCmd` prop Plan J authors, and the icon set Plan J's legend consumes from Plan I
(see "Contract" below) — so the boundary is clean, but Task 1 must re-verify the merged Plan I surface before
touching anything, because file/line references in this plan were captured pre-Plan-I and may have shifted.

**Architecture:** Every genuinely new stateful concern gets the smallest shared surface, not a shared monolith
(outside-review amendment I3, explicit ban below). Two rails differ materially (Globe's is `hidden lg:block` +
`OrgChips` + a mobile `railOpen` bottom-sheet; FlatMap's is always-visible + `VenueRail` only) so there is **no**
shared `CollapsibleRail` component — instead a tiny `useRailCollapse()` hook (boolean + toggle) and a shared
`<CollapseToggle>` button, each page wiring its own grid-template swap. The right-panel "collapse" is **already
implemented** on both pages (`onClose={() => setPanel(null)}` + selection → `setPanel(...)`) — the only new
right-panel work is a shared `<PanelWrapper>` positioning component so FlatMap's bare-mounted panel gets the same
responsive docking Globe's `venue-panel-wrap` already has. `GlobeCanvas` gains exactly one new prop (`zoomCmd`),
additive and optional, mirroring its existing token-bumped `focus` one-shot pattern — `/globe` never passes it, so
`Globe.tsx`'s `<GlobeCanvas>` call stays byte-identical except for the unrelated rail-collapse/panel-wrapper changes
this same lane makes to `Globe.tsx` itself (not to `GlobeCanvas.tsx`). `FlatMapCanvas` gains one analogous additive
prop (`mapZoomCmd`, deliberately differently named from `GlobeCanvas.zoomCmd` to avoid confusion inside `FlatMap.tsx`,
which uses both). No new Mapbox/globe.gl/three imports anywhere Plan J touches — every new file is plain
React/Tailwind/lucide-react.

**Tech Stack:** React 19 + Vite + Tailwind 3 (JIT content-scanned — see the static-class gotcha in Global
Constraints) + react-router-dom v7 + vitest 4 / Testing Library (jsdom, incl. `renderHook`); `lucide-react@1.23.0`
(installed, unused pre-Plan-I/J — free to adopt); `mapbox-gl`/`globe.gl`/`three` stay confined to their existing
dynamic-import islands (`FlatMapCanvas.tsx`, `GlobeCanvas.tsx`) — Plan J never imports them directly.

---

## Global Constraints

- **Sequencing (LOCKED): Plan J branches from `main` AFTER Plan I is merged.** Task 1 is a contract preflight
  against Plan I's actual merged surface (icon-image registry / icon-component export, any renamed layers, and
  whether Plan I shifted line numbers in `FlatMap.tsx`/`FlatMapCanvas.tsx` that this plan references). On any
  mismatch, reconcile mechanically (name/path substitution) or STOP and report — do not improvise against a
  divergent Plan I surface.
- **`GlobeCanvas` gets one additive-only prop; `/globe` stays functionally byte-identical.** `zoomCmd?: { delta:
  number; token: number } | null` is the ONLY change to `GlobeCanvas.tsx` in this plan. It must not touch dispose,
  `paused`, `onPovChange`, or any existing effect. `Globe.tsx`'s `<GlobeCanvas .../>` call never passes `zoomCmd` —
  a test must assert this (Task 2). `Globe.tsx` ITSELF does change in this plan (rail collapse + panel wrapper,
  Task 4) — the "byte-identical" guarantee is scoped to `GlobeCanvas.tsx`'s behavior/props contract, not to
  `Globe.tsx`'s markup.
- **mapbox-gl / globe.gl / three isolation preserved.** Every file this plan creates (`useRailCollapse.ts`,
  `CollapseToggle.tsx`, `PanelWrapper.tsx`, `MapLegend.tsx`) is pure React/Tailwind/lucide-react — no WebGL import,
  no dynamic `import("mapbox-gl")`/`import("globe.gl")`/`import("three")` anywhere. The two existing islands
  (`FlatMapCanvas.tsx`, `GlobeCanvas.tsx`) each gain exactly one additive prop + one additive effect; no second
  `new Map`/`new Globe`, no new guard reimplementation.
- **Do NOT build a monolithic shared rail/collapse component (outside-review I3 — explicit ban).** Globe's rail and
  FlatMap's rail differ materially; each page wires its own grid-template swap using the shared hook + toggle only.
- **Right-panel close stays `setPanel(null)`; do not introduce a separate `panelCollapsed` boolean.** Selection
  already reopens the panel via `setPanel(...)` on both pages (verified, outside-review I3) — a parallel
  "collapsed" flag would break that unless every selection handler also cleared it. Keep the existing mechanism;
  Plan J only adds the shared positioning wrapper around it.
- **Plan J does not re-touch the `anchor`-memo churn fix (#30 / outside-review I4) or any map-data/icon work.**
  Those are Plan I's job and are assumed merged before Task 1 starts. If Task 1 finds them NOT merged, STOP and
  report — do not fix Plan I's scope inside a Plan J branch.
- **Tailwind static-class gotcha (binding — a real correctness risk in this lane).** Tailwind's JIT scans literal
  class strings in source (`tailwind.config.ts` `content: ["./index.html", "./src/**/*.{ts,tsx}"]`). A
  template-literal arbitrary-value class (e.g. `` `h-[${size}px]` ``) is invisible to that scanner and its CSS is
  never generated. Every arbitrary-value class this plan introduces (the two corner-globe sizes 300px/225px, the
  two rail grid-template columns, any collapsed-width classes) MUST appear as full literal strings in the source,
  selected via a ternary/branch — never string-interpolated.
- **TDD red → green, each task.** Write the failing test first and watch it fail, then implement, then verify
  green. Commit the failing test separately from the implementation that greens it (red→green pairs must show in
  git history).
- **All git via the git-flow-manager subagent**
  (`/Users/jn/code/minority_report_architecture/.claude/agents/git-flow-manager.md`) — implementers NEVER run raw
  `git`/`gh`. Work on branch `feat/flatmap-j-chrome-controls` in a DEDICATED worktree of
  `/Users/jn/code/godview-prototype`, branched from `main` (post-Plan-I merge). Merge commits (not squash) on PR
  merge.
- **Subagent workspace discipline (4 drift incidents in v2 — memory `feedback-subagent-workspace-discipline`):**
  (1) Step 1 of EVERY implementer dispatch is `cd <worktree path> && pwd` to lock the workspace and echo it back;
  (2) the bare repo path `/Users/jn/code/godview-prototype` is a READ-ONLY reference — all edits happen in the
  worktree checkout; (3) the controller runs an existence-check (`ls` the files the task creates/modifies in the
  worktree) BEFORE dispatching each commit. Never commit from the bare path.
- **Discriminates-proof for every invariant test (memory: v2 caught a VACUOUS StrictMode test).** Any test
  asserting a toggle/lifecycle invariant (collapse flips, zoom direction, clamp bounds) MUST be accompanied by a
  one-line note stating the concrete mutation that makes it fail. A test with no such mutation is vacuous.
- **Verify commands** (confirmed against `/Users/jn/code/godview-prototype/package.json`): `npx vitest run [files]`
  (script `test` = `vitest run`), `npx tsc -b` (build runs `tsc -b && vite build`), `npm run lint` (oxlint),
  `npm run build`.
- Reference every file by ABSOLUTE path.

---

## Contract (Plan J authors: `GlobeCanvas.zoomCmd`; consumes from Plan I: icon set)

**Plan J authors** the additive `GlobeCanvas` prop:
```ts
zoomCmd?: { delta: number; token: number } | null;   // delta > 0 = zoom in (altitude decreases); token bumps re-fire
```
Consumed in a new effect that mirrors the existing token-bumped `focus` one-shot pattern
(`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx:23` — the `Focus` interface —
and `:474-480` — the camera effect). It reads the current altitude via `globe.pointOfView()` (getter, confirmed on
pinned `globe.gl@2.46.1`) and sets `globe.pointOfView({ altitude: clamp(current - delta) }, ms)`. Purely additive:
does not touch dispose, `paused`, or `onPovChange`; `/globe` (which never passes `zoomCmd`) stays byte-identical.

**Plan J's legend (§D) CONSUMES Plan I's icon set/colors** so the legend renders the same icons the map/building
layer uses. Plan I is expected to land a per-kind icon mapping (lucide components, spec §5 defaults: venue
`Building2`, system `Server`, camera `Video`, display `MonitorPlay`) alongside its icon-image raster registry
(`kind-status` `map.addImage` names) — **the exact export name/location is NOT yet known** (Plan I doesn't exist in
the codebase as of this writing) and Task 1 MUST grep the merged Plan I branch for it. If Plan I exports a reusable
`KIND_ICON`-shaped mapping (e.g. from `src/data/buildingFeatures.ts`, `src/data/venueFeatures.ts`, or a new
`src/components/flatmap/iconRegistry.ts`), Plan J's `MapLegend` imports it directly so the two can never visually
drift. If Plan I does NOT export a reusable icon-component mapping (only inline `icon-image` string names for
Mapbox), Plan J's `MapLegend` defines its own small `KIND_ICON` map using the SAME lucide components (spec §5
names) as a documented, scoped fallback duplication — Task 1 records which branch applies.

**FlatMap.tsx file/state both plans touch (collision risk) — Plan J owns chrome/layout, Plan I owns map-data
content, of the SAME regions:**
- **Grid template** (`FlatMap.tsx:101`, `grid-cols-1 lg:grid-cols-[280px_minmax(0,1fr)] ...`) — Plan I does not
  touch this (it's inside the map canvas / data layer, not the page shell); Plan J adds the collapse-conditional
  swap to `[40px_...]`. Low collision risk, but Task 1 re-confirms the line is unchanged post-Plan-I.
- **Right-panel bare mount** (`FlatMap.tsx:127-130`, `{panel && (panel.type === "venue" ? <VenuePanel .../> :
  <NodePanel .../>)}`) — Plan I does not touch panel mounting (Plan H's node-click fold-in, §H, is Plan I's Task,
  and it only sets `panel` state via `map.on("click", ...)`, it does not touch the JSX that renders the panel).
  Plan J wraps this exact JSX in `<PanelWrapper>`. Collision risk: LOW but real — if Plan I's §H work reshapes this
  block (e.g. adds a new panel type), Task 1 re-reads it fresh before wrapping.
- **Corner-globe container** (`FlatMap.tsx:117-125`, `absolute bottom-3 left-3 h-[300px] w-[300px] ...` +
  `<GlobeCanvas ... />`) — Plan I does not touch this (it's the mini-globe nav window, not the Mapbox canvas). Plan
  J repositions it (top-left), adds the size toggle, and adds `zoomCmd` to its `<GlobeCanvas>` call. Collision
  risk: LOW — Plan I has no reason to touch this block, but Task 1 re-confirms it is unchanged.
- **Building on merged-I is clean** as a result: Plan I's edits land inside `FlatMapCanvas.tsx`'s effects/sources/
  layers and the pure data modules (`venueFeatures.ts`, `buildingFeatures.ts`, `mapSelectors.ts`), not in the page
  shell regions Plan J touches. The one true shared surface is the `GlobeCanvas.zoomCmd` prop (Plan J authors it;
  Plan I never reads or writes it) and the icon set (Plan I authors it; Plan J's legend reads it).

---

## File structure (created / modified by Plan J)

**Created:**
- `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts` — MODIFIED (not created), adds pure zoom-altitude
  math (`nextZoomAltitude`, `MIN_ALTITUDE`, `MAX_ALTITUDE`, `PINCH_STEP_ALTITUDE`, `ZOOM_BUTTON_STEP`).
- `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts` — MODIFIED (existing file), new test block.
- `/Users/jn/code/godview-prototype/src/hooks/useRailCollapse.ts` — new: `boolean + toggle` hook, shared by both
  pages' rails.
- `/Users/jn/code/godview-prototype/src/hooks/useRailCollapse.test.ts`
- `/Users/jn/code/godview-prototype/src/components/CollapseToggle.tsx` — new: shared rail collapse/reopen button
  (top-level `src/components/`, alongside `Shell.tsx`/`AsyncState.tsx` — not page-specific).
- `/Users/jn/code/godview-prototype/src/components/CollapseToggle.test.tsx`
- `/Users/jn/code/godview-prototype/src/components/PanelWrapper.tsx` — new: shared right-panel positioning
  wrapper (parallel to Globe's inline `venue-panel-wrap` markup, now shared).
- `/Users/jn/code/godview-prototype/src/components/PanelWrapper.test.tsx`
- `/Users/jn/code/godview-prototype/src/components/flatmap/MapLegend.tsx` — new: compact collapsible corner
  legend, FlatMap-only (consumes Plan I's icon set + the existing `ModeLegend` status-key table).
- `/Users/jn/code/godview-prototype/src/components/flatmap/MapLegend.test.tsx`

**Modified:**
- `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx` — additive `zoomCmd` prop + effect only.
- `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx` — new prop threaded + fallback test
  + the "Globe.tsx never passes zoomCmd" source-text regression test.
- `/Users/jn/code/godview-prototype/src/pages/Globe.tsx` — rail collapse (hook + toggle + grid swap) + `PanelWrapper`
  refactor of the existing inline `venue-panel-wrap` markup.
- `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx` — rail-collapse assertions.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx` — rail collapse; `PanelWrapper` mount (new — was bare);
  corner-globe reposition + size toggle + `zoomCmd` wiring; map +/- buttons + `mapZoomCmd` wiring; `MapLegend`
  mount.
- `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx` — all of the above, assertions.
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx` — additive `mapZoomCmd` prop + effect
  only.
- `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx` — new prop threaded + fallback
  test.
- `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts` — one-line optional change:
  `attributionControl: true` → `attributionControl: { compact: true }`.
- `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.tsx` — one-word change: `const LEGEND` →
  `export const LEGEND` (so `MapLegend.tsx` can reuse the existing status-key table instead of duplicating it).

---

## Task 1 — Worktree + Plan I contract preflight

**Files** — none modified (read-only verification; no TDD pair).

**Steps**

- [ ] Ask git-flow-manager to create a worktree + branch `feat/flatmap-j-chrome-controls` from `main` for
  `/Users/jn/code/godview-prototype` (**Plan I must already be merged to `main`; if not, STOP and report**). Record
  the worktree checkout path; **Step 1 of every later dispatch is `cd <that path> && pwd`.** The bare
  `/Users/jn/code/godview-prototype` is a READ-ONLY reference only.
- [ ] Confirm the three FlatMap.tsx chrome regions this plan touches are structurally unchanged post-Plan-I (line
  numbers may shift — record fresh ones): `grep -n "grid-cols-1 lg:grid-cols" src/pages/FlatMap.tsx`; `grep -n
  "panel.type === .venue." src/pages/FlatMap.tsx`; `grep -n "corner-globe" src/pages/FlatMap.tsx`. If any block is
  STRUCTURALLY different from what this plan assumes (e.g. panel mount now branches on a 4th panel type, or the
  corner-globe container was moved), reconcile mechanically (Tasks below get renumbered/adjusted) or STOP if the
  divergence is structural, not cosmetic.
- [ ] Confirm `GlobeCanvas`'s `Focus` interface + camera effect line numbers: `grep -n "export interface Focus\|globe.pointOfView({ lat: focus.lat" src/components/globe/GlobeCanvas.tsx` — Plan I should not have touched
  `GlobeCanvas.tsx` at all (record confirmation either way).
- [ ] Confirm `FlatMapCanvas`'s camera effect (the one Plan I's §A amendment changes — duration/easing/split
  `flyToVenue`) has landed and record its POST-Plan-I exact form: `grep -n "map.flyTo" src/components/flatmap/FlatMapCanvas.tsx`. Task 7's `mapZoomCmd` effect must be added as a SIBLING effect, not edited into this one.
- [ ] Confirm Plan I's icon-set export (Contract section above): `grep -rn "Building2\|lucide-react" src/data src/components/flatmap` and `grep -rn "addImage" src/components/flatmap`. Record the exact icon-component export
  name/module if one exists, and the exact `kind`/`status` string values used in the `icon-image` names (needed so
  `MapLegend`'s rows/labels match). If no reusable icon-component export exists, record that Task 8 uses the
  documented fallback (Plan J defines its own `KIND_ICON` using the same lucide names).
- [ ] Confirm `ModeLegend.tsx`'s `LEGEND` table is still module-local (not yet exported) and its exact shape:
  `grep -n "const LEGEND" src/components/globe/ModeLegend.tsx`.
- [ ] Confirm `lucide-react` resolves the icon names this plan uses: `ChevronLeft`, `ChevronRight`, `ChevronUp`,
  `ChevronDown`, `Plus`, `Minus`, `Maximize2`, `Minimize2` — `grep -n "export" node_modules/lucide-react/dist/esm/lucide-react.js | grep -E "^export \{|Chevron|Plus|Minus|Maximize|Minimize"` (or equivalent — a `tsc -b` failure on a
  bad import name is an acceptable fallback confirmation once Tasks 3/6/7/8 compile).
- [ ] Sanity: `npx vitest run` and `npx tsc -b` green on the fresh branch before any change.

---

## Task 2 — `GlobeCanvas` additive `zoomCmd` prop (pure altitude math + effect + Globe.tsx-unchanged guard)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`

**Interfaces**
```ts
// globeSelectors.ts additions — pure, jsdom-testable, no globe.gl/three import.
export const MIN_ALTITUDE = 0.3;          // clamp floor: just above DEVICE_ALTITUDE (0.35, explodeSelectors.ts:17)
export const MAX_ALTITUDE = 4;            // clamp ceiling: comfortably above the default pov.altitude (2.5)
export const PINCH_STEP_ALTITUDE = 0.3;   // ~one mouse-wheel/pinch tick's altitude delta (chosen: 25% of CLUSTER_ALTITUDE=1.2)
export const ZOOM_BUTTON_STEP = PINCH_STEP_ALTITUDE * 2;   // §F M1: "step = 2x a pinch step"

/** delta > 0 = zoom IN (altitude decreases); clamps to [MIN_ALTITUDE, MAX_ALTITUDE]. */
export function nextZoomAltitude(currentAltitude: number, delta: number): number;
```
```ts
// GlobeCanvas.tsx — ONE new prop, ONE new effect. Mirrors the existing Focus/camera-effect pattern
// (GlobeCanvas.tsx:23, :474-480). Optional so every existing call site (incl. Globe.tsx) compiles unchanged.
zoomCmd?: { delta: number; token: number } | null;
```

**Wiring decision:** the effect reads `globe.pointOfView()` (getter — confirmed on pinned `globe.gl@2.46.1`,
already used at `GlobeCanvas.tsx:479` as a setter) for the CURRENT altitude, computes
`nextZoomAltitude(current, zoomCmd.delta)` (pure, from `globeSelectors.ts` — no clamp/direction logic duplicated
inside the imperative effect), and calls `globe.pointOfView({ altitude: next }, 400)` — 400ms, a snappy
button-triggered zoom, shorter than the 1200ms venue fly-to (`GlobeCanvas.tsx:479`) since it's a discrete nudge, not
a big camera move. Does not set `autoRotate = false` (unlike the `focus` effect) — a zoom nudge shouldn't stop
casual auto-rotation. Effect deps `[zoomCmd, ready]`, guards `!globe || !zoomCmd` — identical guard shape to the
`focus` effect.

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/data/globeSelectors.test.ts`:
```ts
import { MAX_ALTITUDE, MIN_ALTITUDE, PINCH_STEP_ALTITUDE, ZOOM_BUTTON_STEP, nextZoomAltitude } from "./globeSelectors";

describe("nextZoomAltitude — additive globe zoom (delta>0 = zoom in)", () => {
  it("zooming in (positive delta) decreases altitude", () => {
    // Discriminates-proof: swapping `current - delta` for `current + delta` flips this and fails.
    expect(nextZoomAltitude(2.0, 0.5)).toBeCloseTo(1.5);
  });
  it("zooming out (negative delta) increases altitude", () => {
    expect(nextZoomAltitude(1.5, -0.5)).toBeCloseTo(2.0);
  });
  it("clamps to MIN_ALTITUDE / MAX_ALTITUDE", () => {
    // Discriminates-proof: removing either Math.min/Math.max makes one of these fail.
    expect(nextZoomAltitude(MIN_ALTITUDE + 0.05, 10)).toBe(MIN_ALTITUDE);
    expect(nextZoomAltitude(MAX_ALTITUDE - 0.05, -10)).toBe(MAX_ALTITUDE);
  });
  it("ZOOM_BUTTON_STEP is exactly 2x PINCH_STEP_ALTITUDE (spec M1)", () => {
    expect(ZOOM_BUTTON_STEP).toBeCloseTo(PINCH_STEP_ALTITUDE * 2);
  });
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/data/globeSelectors.test.ts` — FAIL: `nextZoomAltitude`/etc.
  not exported.
- [ ] **Commit (red):** `test(globe): pure zoom-altitude math for the additive GlobeCanvas.zoomCmd prop (red)`
- [ ] **Implement** the constants + `nextZoomAltitude` in `globeSelectors.ts` per the Interfaces block.
- [ ] **Run to verify it passes:** `npx vitest run src/data/globeSelectors.test.ts` → PASS; `npx tsc -b` → clean.
- [ ] **Commit (green):** `feat(globe): pure zoom-altitude math (clamp + direction) for additive globe zoom`
- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.test.tsx`:
```tsx
import { readFileSync } from "node:fs";

test("GlobeCanvas accepts zoomCmd on the fallback path without crashing (additive, optional)", () => {
  const { rerender } = render(<GlobeCanvas dots={[]} mode="health" focus={null}
    arcs={[]} labels={[]} highlightOrgId={null} explosion={null} liveSystems={new Set()}
    farPulses={null} deepPulses={null} onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  // no zoomCmd passed at all — proves it's optional, existing callers compile unchanged
  rerender(<GlobeCanvas dots={[]} mode="health" focus={null}
    arcs={[]} labels={[]} highlightOrgId={null} explosion={null} liveSystems={new Set()}
    farPulses={null} deepPulses={null} zoomCmd={{ delta: 0.3, token: 1 }}
    onDotClick={noop} onNodeClick={noop} onPovChange={noop} />);
  expect(screen.getByTestId("globe-fallback")).toBeInTheDocument();
});

test("regression: Globe.tsx (the /globe page) never passes zoomCmd to GlobeCanvas", () => {
  // Discriminates-proof: if a future edit threads zoomCmd through Globe.tsx's <GlobeCanvas .../>
  // call, this source-text guard goes red — /globe must stay byte-identical per the Contract.
  const src = readFileSync(new URL("../../pages/Globe.tsx", import.meta.url), "utf8");
  expect(src).not.toMatch(/zoomCmd/);
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/components/globe/GlobeCanvas.test.tsx` — FAIL: TS unknown
  prop `zoomCmd` on the first new test (the regression test passes vacuously before the prop exists — note this;
  it becomes meaningful once Task 2's prop lands and stays green throughout the rest of this plan).
- [ ] **Commit (red):** `test(globe): GlobeCanvas accepts additive zoomCmd; Globe.tsx stays byte-identical (red)`
- [ ] **Implement** the `zoomCmd` prop + effect in `GlobeCanvas.tsx` per the Wiring decision. Add it directly below
  the existing `focus` camera effect (`GlobeCanvas.tsx:474-480`) as a new, separate `useEffect` block — do not
  merge into the existing one.
- [ ] **Run to verify it passes:** `npx vitest run src/components/globe/GlobeCanvas.test.tsx` → PASS; `npx tsc -b`
  → clean.
- [ ] **Commit (green):** `feat(globe): additive GlobeCanvas.zoomCmd prop — token-bumped altitude nudge, /globe untouched`

---

## Task 3 — Shared collapse primitives: `useRailCollapse` + `CollapseToggle` + `PanelWrapper`

**Files**
- Create: `/Users/jn/code/godview-prototype/src/hooks/useRailCollapse.ts` + `.test.ts`
- Create: `/Users/jn/code/godview-prototype/src/components/CollapseToggle.tsx` + `.test.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/PanelWrapper.tsx` + `.test.tsx`

**Interfaces**
```ts
// useRailCollapse.ts — generic boolean+toggle, scoped to rail collapse per outside-review I3
// ("a tiny useRailCollapse() hook (boolean + toggle)"). NOT reused for the legend's own collapse
// (Task 8 uses a plain local useState — a second single-use boolean doesn't warrant a shared hook).
export function useRailCollapse(initial?: boolean): [boolean, () => void];
```
```tsx
// CollapseToggle.tsx — shared rail collapse/reopen button. Scoped to the two rails (Globe + FlatMap);
// the legend's own header-chevron (§D) is a visually distinct "pill" affordance, not this component
// (see Task 8 wiring notes — avoids over-generalizing one component into an unrelated shape).
export function CollapseToggle({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }): JSX.Element;
// renders a button data-testid="rail-collapse-toggle", aria-label flips between
// "Expand venue list" / "Collapse venue list", icon flips ChevronRight (collapsed) / ChevronLeft (expanded).
```
```tsx
// PanelWrapper.tsx — parallel to Globe's existing inline venue-panel-wrap markup (Globe.tsx:138-140),
// now shared so FlatMap's bare-mounted panel (FlatMap.tsx:127-130) gets the same responsive docking.
export function PanelWrapper({ children, onScrimClick }: {
  children: React.ReactNode;
  onScrimClick?: () => void;   // Globe passes this (mobile scrim); FlatMap omits it (no mobile scrim behavior — non-goal)
}): JSX.Element;
// Renders data-testid="venue-panel-wrap" with Globe.tsx's EXACT existing className string
// (fixed inset-x-0 bottom-0 z-50 h-[70vh] overflow-hidden rounded-t-xl border-t border-border
//  lg:absolute lg:left-auto lg:top-0 lg:right-0 lg:bottom-0 lg:z-10 lg:h-auto lg:w-[380px]
//  lg:rounded-none lg:border-t-0) wrapping {children}. If onScrimClick is provided, also renders
// the mobile scrim div (fixed inset-0 z-40 bg-black/50 lg:hidden) before it, exactly as Globe.tsx:137.
```

**Steps**

- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/hooks/useRailCollapse.test.ts`:
```ts
import { act, renderHook } from "@testing-library/react";
import { useRailCollapse } from "./useRailCollapse";

describe("useRailCollapse — boolean + toggle", () => {
  it("defaults to expanded (false) and flips on toggle", () => {
    const { result } = renderHook(() => useRailCollapse());
    expect(result.current[0]).toBe(false);
    act(() => result.current[1]());
    expect(result.current[0]).toBe(true);
    // Discriminates-proof: a toggle implemented as `setCollapsed(true)` (not a flip) passes the
    // first act() but fails this second one.
    act(() => result.current[1]());
    expect(result.current[0]).toBe(false);
  });
  it("accepts an initial value", () => {
    const { result } = renderHook(() => useRailCollapse(true));
    expect(result.current[0]).toBe(true);
  });
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/hooks/useRailCollapse.test.ts` — FAIL: module not found.
- [ ] **Commit (red):** `test(hooks): useRailCollapse — boolean+toggle for rail collapse (red)`
- [ ] **Implement** `useRailCollapse.ts` (a two-line `useState` + flip closure).
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(hooks): useRailCollapse — shared rail collapse state for both pages`
- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/components/CollapseToggle.test.tsx`:
```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { vi } from "vitest";
import { CollapseToggle } from "./CollapseToggle";

test("calls onToggle when clicked", () => {
  const onToggle = vi.fn();
  render(<CollapseToggle collapsed={false} onToggle={onToggle} />);
  fireEvent.click(screen.getByTestId("rail-collapse-toggle"));
  expect(onToggle).toHaveBeenCalledTimes(1);
});

test("aria-label reflects collapsed state (discriminates-proof: hardcoding one label fails this)", () => {
  const { rerender } = render(<CollapseToggle collapsed={false} onToggle={() => {}} />);
  expect(screen.getByTestId("rail-collapse-toggle")).toHaveAttribute("aria-label", "Collapse venue list");
  rerender(<CollapseToggle collapsed={true} onToggle={() => {}} />);
  expect(screen.getByTestId("rail-collapse-toggle")).toHaveAttribute("aria-label", "Expand venue list");
});
```
- [ ] **Run to verify it fails:** FAIL — module not found.
- [ ] **Commit (red):** `test(components): CollapseToggle — shared rail collapse button (red)`
- [ ] **Implement** `CollapseToggle.tsx` per the Interfaces block (lucide `ChevronLeft`/`ChevronRight`).
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(components): CollapseToggle — shared rail collapse/reopen button`
- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/components/PanelWrapper.test.tsx`:
```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { vi } from "vitest";
import { PanelWrapper } from "./PanelWrapper";

test("wraps children in the venue-panel-wrap positioning container", () => {
  render(<PanelWrapper><div data-testid="child" /></PanelWrapper>);
  expect(screen.getByTestId("venue-panel-wrap")).toContainElement(screen.getByTestId("child"));
});

test("renders no scrim when onScrimClick is omitted (FlatMap usage — no mobile scrim)", () => {
  render(<PanelWrapper><div /></PanelWrapper>);
  expect(document.querySelector(".bg-black\\/50")).toBeNull();
});

test("renders a clickable scrim when onScrimClick is provided (Globe usage)", () => {
  const onScrimClick = vi.fn();
  render(<PanelWrapper onScrimClick={onScrimClick}><div /></PanelWrapper>);
  const scrim = document.querySelector(".bg-black\\/50")!;
  expect(scrim).not.toBeNull();
  fireEvent.click(scrim);
  expect(onScrimClick).toHaveBeenCalledTimes(1);
});
```
- [ ] **Run to verify it fails:** FAIL — module not found.
- [ ] **Commit (red):** `test(components): PanelWrapper — shared right-panel positioning + optional scrim (red)`
- [ ] **Implement** `PanelWrapper.tsx`, copying Globe.tsx's exact `venue-panel-wrap` className string
  (`Globe.tsx:138-140`) verbatim so the refactor in Task 4 is a no-visual-diff extraction, not a redesign.
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(components): PanelWrapper — shared right-panel docking, parallel to Globe's venue-panel-wrap`

---

## Task 4 — Globe page: left-rail collapse + `PanelWrapper` refactor

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx`

**Wiring**
- Import `useRailCollapse`, `CollapseToggle`, `PanelWrapper`.
- `const [railCollapsed, toggleRail] = useRailCollapse();` (defaults to expanded — existing tests, which assert
  `venue-row`/`org-chip` counts without ever touching a collapse control, keep passing unmodified).
- Grid template (`Globe.tsx:119`): branch the `lg:grid-cols-[...]` class on `railCollapsed` — both literal strings
  must appear in source (Tailwind static-class gotcha):
  ```tsx
  <div className={`grid grid-cols-1 gap-4 h-[calc(100vh-170px)] min-h-[420px] transition-[grid-template-columns] duration-200 ${
    railCollapsed ? "lg:grid-cols-[40px_minmax(0,1fr)]" : "lg:grid-cols-[280px_minmax(0,1fr)]"}`}>
  ```
- Rail column (`Globe.tsx:120-123`): change `hidden lg:block` → `hidden lg:flex lg:flex-col`, always render
  `<CollapseToggle collapsed={railCollapsed} onToggle={toggleRail} />` at the top, and conditionally render the
  existing `<OrgChips>` + `<VenueRail>` only when `!railCollapsed`:
  ```tsx
  <div className="hidden lg:flex lg:flex-col overflow-auto border border-border rounded-[10px] p-2">
    <CollapseToggle collapsed={railCollapsed} onToggle={toggleRail} />
    {!railCollapsed && (<><OrgChips orgs={orgs} activeId={highlightOrgId} onToggle={toggleOrg} />
      <VenueRail venues={railVenues} mode={mode} selectedId={selectedVenueId} onSelect={selectVenue} /></>)}
  </div>
  ```
- Right panel (`Globe.tsx:135-147`): replace the inline scrim + `venue-panel-wrap` div with
  `<PanelWrapper onScrimClick={() => setPanel(null)}>{panelNode}</PanelWrapper>` where `panelNode` is the existing
  `panel.type === "venue" ? <VenuePanel .../> : <NodePanel .../>` conditional, unchanged. This is a pure extraction
  — the rendered className strings must be identical (verified by `PanelWrapper` copying them verbatim in Task 3).
- Mobile `railOpen` bottom-sheet (`Globe.tsx:31,130-133,151-159`) is a SEPARATE, untouched piece of state — desktop
  `railCollapsed` only affects the `lg:` column; mobile behavior is out of scope (spec §4 non-goals).

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/Globe.test.tsx`:
```tsx
test("desktop rail collapses via the toggle and reopens", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  fireEvent.click(screen.getByTestId("rail-collapse-toggle"));
  expect(screen.queryByTestId("venue-row")).toBeNull();     // rail content hidden while collapsed
  fireEvent.click(screen.getByTestId("rail-collapse-toggle"));
  await waitFor(() => expect(screen.getAllByTestId("venue-row").length).toBeGreaterThan(0));
});

test("right panel renders inside the shared venue-panel-wrap", async () => {
  renderGlobe();
  await waitFor(() => screen.getAllByTestId("venue-row"));
  fireEvent.click(screen.getAllByTestId("venue-row")[0]);
  await waitFor(() => screen.getByTestId("venue-panel"));
  expect(screen.getByTestId("venue-panel-wrap")).toContainElement(screen.getByTestId("venue-panel"));
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/pages/Globe.test.tsx` — FAIL: `rail-collapse-toggle` testid
  not found.
- [ ] **Commit (red):** `test(globe): desktop rail collapse + shared PanelWrapper wiring (red)`
- [ ] **Implement** the Wiring block above. Do not touch mobile `railOpen`, `OrgChips`, `VenueRail`, or the globe
  canvas itself.
- [ ] **Run to verify it passes:** `npx vitest run src/pages/Globe.test.tsx` → PASS (all pre-existing tests too —
  they never touch the collapse control, so `railCollapsed=false` default keeps them byte-identical); `npx tsc -b`
  → clean.
- [ ] **Commit (green):** `feat(globe): left-rail collapse + shared PanelWrapper for the right panel`

---

## Task 5 — FlatMap page: left-rail collapse + right-panel `PanelWrapper` mount

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Wiring** (parallel to Task 4, adapted to FlatMap's simpler always-visible rail — no `OrgChips`, no mobile sheet)
- `const [railCollapsed, toggleRail] = useRailCollapse();`
- Grid template (`FlatMap.tsx:101`): same branch as Task 4 (`[40px_...]` vs `[280px_...]`, both literal strings in
  source).
- Rail column (`FlatMap.tsx:102-108`): always-visible on FlatMap (no `hidden lg:block` — FlatMap's rail has no
  mobile-hide behavior today, per the investigation), so only the toggle + conditional `<VenueRail>` change:
  ```tsx
  <div className="flex flex-col overflow-auto border border-border rounded-[10px] p-2">
    <CollapseToggle collapsed={railCollapsed} onToggle={toggleRail} />
    {!railCollapsed && <VenueRail venues={railVenues} mode={mode} selectedId={selectedVenueId} onSelect={...} />}
  </div>
  ```
- Right panel (`FlatMap.tsx:127-130`, currently mounted BARE): wrap in `<PanelWrapper>` with **no** `onScrimClick`
  (FlatMap has no mobile-sheet/scrim precedent today — adding one is out of scope, spec §4 non-goals; the wrapper's
  positioning classes still apply, giving FlatMap the same right-docked desktop layout Globe has):
  ```tsx
  {panel && (
    <PanelWrapper>
      {panel.type === "venue"
        ? <VenuePanel key={`venue:${panel.id}`} locationId={panel.id} onClose={() => setPanel(null)} />
        : <NodePanel key={`${panel.type}:${panel.id}`} type={panel.type} id={panel.id} detail={detail} onClose={() => setPanel(null)} />}
    </PanelWrapper>
  )}
  ```

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`:
```tsx
describe("FlatMap chrome — rail collapse + panel wrapper (Plan J)", () => {
  it("desktop rail collapses via the toggle and reopens", async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "");
    renderPage();
    await waitFor(() => expect(screen.getByTestId("venue-rail")).toBeInTheDocument());
    fireEvent.click(screen.getByTestId("rail-collapse-toggle"));
    expect(screen.queryByTestId("venue-rail")).toBeNull();
    fireEvent.click(screen.getByTestId("rail-collapse-toggle"));
    await waitFor(() => expect(screen.getByTestId("venue-rail")).toBeInTheDocument());
  });
  it("right panel mounts inside the shared venue-panel-wrap", async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "");
    renderPage();
    await waitFor(() => screen.getByText("Dallas North"));
    fireEvent.click(screen.getByText("Dallas North"));
    await waitFor(() => expect(screen.getByTestId("venue-panel-wrap")).toBeInTheDocument());
  });
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/pages/FlatMap.test.tsx` — FAIL: `rail-collapse-toggle` not
  found.
- [ ] **Commit (red):** `test(flatmap): desktop rail collapse + PanelWrapper mount (red)`
- [ ] **Implement** the Wiring block above.
- [ ] **Run to verify it passes:** PASS (all pre-existing FlatMap tests too); `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(flatmap): left-rail collapse + PanelWrapper for the previously-bare right panel`

---

## Task 6 — FlatMap corner globe: reposition top-left + size toggle (300↔225) + globe +/- zoom

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Interfaces / constants** — local to `FlatMap.tsx` (page-only concern, not shared):
```ts
const GLOBE_SIZE_KEY = "flatmap.cornerGlobeSize";   // localStorage — best-effort, try/catch
```

**Wiring**
- Reposition: `absolute bottom-3 left-3` → `absolute top-3 left-3` on the corner-globe container
  (`FlatMap.tsx:118`).
- Size state:
  ```ts
  const [globeSize, setGlobeSize] = useState<300 | 225>(() => {
    try { return localStorage.getItem(GLOBE_SIZE_KEY) === "225" ? 225 : 300; } catch { return 300; }
  });
  const toggleGlobeSize = () => setGlobeSize((s) => {
    const next = s === 300 ? 225 : 300;
    try { localStorage.setItem(GLOBE_SIZE_KEY, String(next)); } catch {}
    return next;
  });
  ```
- Container class — **both size classes must be full literal strings** (Tailwind static-class gotcha):
  ```tsx
  <div data-testid="corner-globe" className={globeSize === 300
    ? "absolute top-3 left-3 h-[300px] w-[300px] overflow-hidden rounded-[10px] border border-border bg-bg"
    : "absolute top-3 left-3 h-[225px] w-[225px] overflow-hidden rounded-[10px] border border-border bg-bg"}>
  ```
- Size-toggle button, window's top-right corner: `<button data-testid="globe-size-toggle" onClick={toggleGlobeSize}
  className="absolute top-1 right-1 z-10 ...">` using lucide `Maximize2`/`Minimize2` (icon reflects the ACTION —
  `Maximize2` shown when currently 225 (tap to grow), `Minimize2` shown when currently 300 (tap to shrink)).
- Globe zoom command state + buttons, window's bottom-right corner (top-right is taken by the size toggle):
  ```ts
  const [globeZoomCmd, setGlobeZoomCmd] = useState<{ delta: number; token: number } | null>(null);
  const bumpGlobeZoom = (delta: number) => setGlobeZoomCmd((c) => ({ delta, token: (c?.token ?? 0) + 1 }));
  ```
  ```tsx
  <div className="absolute bottom-1 right-1 z-10 flex flex-col gap-1">
    <button data-testid="globe-zoom-in" onClick={() => bumpGlobeZoom(ZOOM_BUTTON_STEP)}><Plus size={12} /></button>
    <button data-testid="globe-zoom-out" onClick={() => bumpGlobeZoom(-ZOOM_BUTTON_STEP)}><Minus size={12} /></button>
  </div>
  ```
  (`ZOOM_BUTTON_STEP` imported from `../data/globeSelectors`, Task 2.)
- Pass `zoomCmd={globeZoomCmd}` into the existing `<GlobeCanvas .../>` call (`FlatMap.tsx:119-123`) — the ONLY
  change to that call besides adding the new sibling buttons around it.

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`:
```tsx
describe("FlatMap corner globe — reposition + size toggle + zoom (Plan J §F)", () => {
  const setup = async () => {
    vi.stubEnv("VITE_MAPBOX_TOKEN", "pk.test");
    vi.mocked(hasWebGL).mockReturnValue(true);
    renderPage();
    await waitFor(() => expect(screen.getByTestId("corner-globe")).toBeInTheDocument());
  };
  it("is positioned top-left (not bottom-left)", async () => {
    await setup();
    const cls = screen.getByTestId("corner-globe").className;
    expect(cls).toContain("top-3");
    expect(cls).not.toContain("bottom-3");
  });
  it("size toggle switches 300px <-> 225px", async () => {
    await setup();
    expect(screen.getByTestId("corner-globe").className).toContain("w-[300px]");
    fireEvent.click(screen.getByTestId("globe-size-toggle"));
    expect(screen.getByTestId("corner-globe").className).toContain("w-[225px]");
  });
  it("zoom +/- buttons are present and clickable without crashing", async () => {
    await setup();
    fireEvent.click(screen.getByTestId("globe-zoom-in"));
    fireEvent.click(screen.getByTestId("globe-zoom-out"));
    expect(screen.getByTestId("corner-globe")).toBeInTheDocument();   // no throw
  });
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/pages/FlatMap.test.tsx` — FAIL: `top-3` not present /
  `globe-size-toggle` / `globe-zoom-in` not found.
- [ ] **Commit (red):** `test(flatmap): corner globe reposition + size toggle + zoom buttons (red)`
- [ ] **Implement** the Wiring block above.
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(flatmap): corner globe top-left + 300<->225 size toggle + +/- zoom via GlobeCanvas.zoomCmd`

**Note on test design:** `GlobeCanvas` is NOT mocked in `FlatMap.test.tsx` (only `FlatMapCanvas` is) — it renders
its own real `globe-fallback` in jsdom (no WebGL), same as `Globe.test.tsx`. This plan deliberately does NOT add a
`GlobeCanvas` mock here (which would let the zoom test assert exact `zoomCmd` delta/token values) because doing so
would change how every OTHER pre-existing `corner-globe` assertion in this file observes the DOM — the "no crash"
style above is intentionally the same black-box style Plan H used for `FlatMapCanvas`'s own building-prop tests.

---

## Task 7 — FlatMap map +/- zoom buttons (`mapZoomCmd` on `FlatMapCanvas`, top-right)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts` (one-line, optional)

**Interfaces**
```ts
// FlatMapCanvas gains ONE new prop, deliberately named differently from GlobeCanvas's `zoomCmd`
// (this page uses both, in the same file, on two different cameras — distinct names avoid confusion):
mapZoomCmd?: { delta: number; token: number } | null;
```

**Wiring**
- New effect in `FlatMapCanvas.tsx`, added as a SIBLING to the existing camera (`focus`) effect
  (`FlatMapCanvas.tsx:247-251` pre-Plan-I; re-confirm its exact current line/form per Task 1) — do not merge into
  it:
  ```ts
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !mapZoomCmd) return;
    map.easeTo({ zoom: map.getZoom() + mapZoomCmd.delta });
  }, [mapZoomCmd, ready]);
  ```
- `MAP_ZOOM_STEP = 2` — a local const in `FlatMap.tsx` (2x Mapbox's default `zoomIn()`/`zoomOut()` per-click
  increment of 1, per spec §G/M3 "step 2x default"). Not shared/exported — page-only UI constant.
- Page state + buttons, positioned **top-right** of the map container (clear of the attribution — M3 — and clear
  of the corner-globe, which is now top-left):
  ```ts
  const [mapZoomCmd, setMapZoomCmd] = useState<{ delta: number; token: number } | null>(null);
  const bumpMapZoom = (delta: number) => setMapZoomCmd((c) => ({ delta, token: (c?.token ?? 0) + 1 }));
  ```
  ```tsx
  <div className="absolute top-3 right-3 z-10 flex flex-col gap-1">
    <button data-testid="map-zoom-in" onClick={() => bumpMapZoom(MAP_ZOOM_STEP)}><Plus size={14} /></button>
    <button data-testid="map-zoom-out" onClick={() => bumpMapZoom(-MAP_ZOOM_STEP)}><Minus size={14} /></button>
  </div>
  ```
  Pass `mapZoomCmd={mapZoomCmd}` into the existing `<FlatMapCanvas .../>` call.
- Optional one-line attribution tweak in `mapboxImpl.ts`: `attributionControl: true` → `attributionControl: {
  compact: true }`. Not required for correctness now that +/- moved to top-right (M3's collision is already
  avoided by the position choice), but low-risk and matches spec §G's "optionally set attribution compact."

**Steps**

- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.test.tsx`: thread `mapZoomCmd={null}` through every existing render, add one fallback-path test:
```tsx
test("mapZoomCmd is accepted on the fallback path without crashing", () => {
  const { rerender } = render(<FlatMapCanvas /* + required props */ mapZoomCmd={null} />);
  rerender(<FlatMapCanvas /* + required props */ mapZoomCmd={{ delta: 2, token: 1 }} />);
  expect(screen.getByTestId("map-unavailable")).toBeInTheDocument();
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/components/flatmap/FlatMapCanvas.test.tsx` — FAIL: TS unknown
  prop `mapZoomCmd`.
- [ ] **Commit (red):** `test(flatmap): FlatMapCanvas accepts additive mapZoomCmd on the fallback path (red)`
- [ ] **Implement** the `mapZoomCmd` prop + effect in `FlatMapCanvas.tsx`.
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(flatmap): additive FlatMapCanvas.mapZoomCmd prop — token-bumped easeTo zoom nudge`
- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`:
```tsx
it("map +/- buttons bump mapZoomCmd with the correct delta and an incrementing token", async () => {
  vi.stubEnv("VITE_MAPBOX_TOKEN", "pk.test");
  vi.mocked(hasWebGL).mockReturnValue(true);
  renderPage();
  await waitFor(() => expect(capturedProps).not.toBeNull());
  fireEvent.click(screen.getByTestId("map-zoom-in"));
  expect(capturedProps.mapZoomCmd).toEqual({ delta: 2, token: 1 });
  fireEvent.click(screen.getByTestId("map-zoom-out"));
  expect(capturedProps.mapZoomCmd).toEqual({ delta: -2, token: 2 });
});
```
  (Uses the existing prop-capturing `FlatMapCanvas` mock already established in this file — see
  `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx:25-30`.)
- [ ] **Run to verify it fails:** FAIL — `map-zoom-in` testid not found.
- [ ] **Commit (red):** `test(flatmap): map +/- buttons drive mapZoomCmd (red)`
- [ ] **Implement** the page wiring (buttons + state), and the optional `mapboxImpl.ts` attribution tweak.
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(flatmap): themed map +/- zoom buttons (top-right, step=2x default)`

---

## Task 8 — Compact collapsible corner legend (`MapLegend`, bottom-left)

**Files**
- Modify: `/Users/jn/code/godview-prototype/src/components/globe/ModeLegend.tsx` (one-word export)
- Create: `/Users/jn/code/godview-prototype/src/components/flatmap/MapLegend.tsx` + `.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`

**Interfaces**
```ts
// ModeLegend.tsx: one-word change — export the existing status-key table so MapLegend can reuse it
// instead of duplicating status labels/colors (avoids drift between the two legends).
export const LEGEND: Record<MapMode, { swatch: string; label: string }[]>;   // unchanged shape/values
```
```tsx
// MapLegend.tsx — FlatMap-only (the /map corner legend, spec §D). Consumes:
//  - Plan I's icon set (Contract section — exact import per Task 1's finding)
//  - ModeLegend's now-exported LEGEND table, for the status color key (reuses the SAME
//    active/degraded/offline/failures labels + ok/warn/crit/off swatch classes used everywhere else)
export function MapLegend({ mode, collapsed, onToggle }: {
  mode: MapMode; collapsed: boolean; onToggle: () => void;
}): JSX.Element;
```

**Wiring decisions**
- Position: `absolute bottom-3 left-3` (globe is top-left per Task 6, right panel is right-docked, map +/- is
  top-right — bottom-left is clear; spec §5 open-choice #2).
- Collapsed state is a plain local `useState` in `FlatMap.tsx` (NOT `useRailCollapse` — a second single-use
  boolean for an unrelated toggle doesn't warrant reusing a hook named for rail semantics; CLAUDE.md §2, no
  abstraction for single-use code).
- The legend's own header-chevron affordance is NOT the shared `<CollapseToggle>` (that component's shape —
  edge-of-rail tab — doesn't match the legend's "collapses to a `Legend` pill" requirement); `MapLegend` renders
  its own small chevron button inline (lucide `ChevronDown`/`ChevronUp`).
- Kind rows (venue/system/camera/display, icon + label) always show regardless of `mode`; the status color key
  below them is `LEGEND[mode]` (health vs live differ — matches `ModeLegend`'s existing per-mode convention
  exactly, so users see the SAME status vocabulary in both places).
- **Icon-set dependency on Plan I (state the resolved branch from Task 1's finding here in the PR description):**
  either `import { KIND_ICON } from "<Plan I's actual export>"`, or (fallback, if Plan I exports no reusable
  icon-component mapping) a locally-defined:
  ```ts
  const KIND_ICON = { venue: Building2, system: Server, camera: Video, display: MonitorPlay } as const;
  ```
  using the SAME lucide components spec §5 names, so the legend never shows an icon the map doesn't also use.

**Steps**

- [ ] **Write the failing test** `/Users/jn/code/godview-prototype/src/components/flatmap/MapLegend.test.tsx`:
```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { vi } from "vitest";
import { MapLegend } from "./MapLegend";

test("expanded: shows all 4 kind rows + the mode's status key", () => {
  render(<MapLegend mode="health" collapsed={false} onToggle={() => {}} />);
  expect(screen.getByText("Venue")).toBeInTheDocument();
  expect(screen.getByText("System")).toBeInTheDocument();
  expect(screen.getByText("Camera")).toBeInTheDocument();
  expect(screen.getByText("Display")).toBeInTheDocument();
  expect(screen.getByText("Active")).toBeInTheDocument();       // health-mode status key
  expect(screen.queryByText("Composing")).toBeNull();           // live-mode-only label absent
});
test("switching mode changes the status key (reuses ModeLegend's LEGEND table)", () => {
  const { rerender } = render(<MapLegend mode="health" collapsed={false} onToggle={() => {}} />);
  rerender(<MapLegend mode="live" collapsed={false} onToggle={() => {}} />);
  expect(screen.getByText("Composing")).toBeInTheDocument();
});
test("collapsed: renders only the Legend pill (discriminates-proof: ignoring `collapsed` leaves kind rows visible)", () => {
  render(<MapLegend mode="health" collapsed={true} onToggle={() => {}} />);
  expect(screen.getByTestId("map-legend-pill")).toBeInTheDocument();
  expect(screen.queryByText("Venue")).toBeNull();
});
test("clicking the pill / header chevron calls onToggle", () => {
  const onToggle = vi.fn();
  const { rerender } = render(<MapLegend mode="health" collapsed={true} onToggle={onToggle} />);
  fireEvent.click(screen.getByTestId("map-legend-pill"));
  expect(onToggle).toHaveBeenCalledTimes(1);
  rerender(<MapLegend mode="health" collapsed={false} onToggle={onToggle} />);
  fireEvent.click(screen.getByTestId("map-legend-collapse"));
  expect(onToggle).toHaveBeenCalledTimes(2);
});
```
- [ ] **Run to verify it fails:** `npx vitest run src/components/flatmap/MapLegend.test.tsx` — FAIL: module not
  found.
- [ ] **Commit (red):** `test(flatmap): MapLegend — compact collapsible kind+status legend (red)`
- [ ] **Implement:** first `export` the `LEGEND` const in `ModeLegend.tsx` (one word), then implement
  `MapLegend.tsx` per the Interfaces + Wiring blocks, resolving the icon-set import per Task 1's recorded finding.
- [ ] **Run to verify it passes:** `npx vitest run src/components/flatmap/MapLegend.test.tsx` → PASS; `npx tsc -b`
  → clean.
- [ ] **Commit (green):** `feat(flatmap): MapLegend — compact collapsible corner legend (kinds + status key)`
- [ ] **Write the failing test** — extend `/Users/jn/code/godview-prototype/src/pages/FlatMap.test.tsx`:
```tsx
it("mounts MapLegend bottom-left and it collapses to a pill", async () => {
  vi.stubEnv("VITE_MAPBOX_TOKEN", "");
  renderPage();
  await waitFor(() => expect(screen.getByTestId("map-legend")).toBeInTheDocument());
  fireEvent.click(screen.getByTestId("map-legend-collapse"));
  expect(screen.getByTestId("map-legend-pill")).toBeInTheDocument();
});
```
- [ ] **Run to verify it fails:** FAIL — `map-legend` testid not found (not yet mounted on the page).
- [ ] **Commit (red):** `test(flatmap): FlatMap mounts MapLegend (red)`
- [ ] **Implement:** mount `<MapLegend mode={mode} collapsed={legendCollapsed} onToggle={...} />` in `FlatMap.tsx`
  (local `useState` for `legendCollapsed`), as a sibling inside the map's relative container alongside the
  corner-globe / panel / zoom buttons.
- [ ] **Run to verify it passes:** PASS; `npx tsc -b` clean.
- [ ] **Commit (green):** `feat(flatmap): mount MapLegend bottom-left on the /map page`

---

## Task 9 — Full suite, typecheck, build, lint, gate-check, PR

**Files** — none new; fixes only if something below fails (each fix scoped + committed with its reason).

**Steps**

- [ ] `cd <worktree> && pwd` (workspace lock). `npx vitest run` — full suite green (all pre-existing tests too,
  incl. every Globe/FlatMap test that predates this plan — the rail-collapse default (expanded) and panel-wrapper
  extraction must not change any existing assertion's outcome).
- [ ] `npx tsc -b` — clean.
- [ ] `npm run lint` (oxlint) — clean.
- [ ] `npm run build` — succeeds. This lane adds no new dynamic-import chunk and no new heavy dependency (only
  `lucide-react`, already installed) — sanity-check bundle size did not regress meaningfully:
  `ls -lS dist/assets | head`; record sizes in the commit message.
- [ ] **Contract gate-check:** re-confirm `GlobeCanvas.tsx`'s `zoomCmd` prop is additive-only (dispose/`paused`/
  `onPovChange` unmodified — diff the file against Task 1's pre-change snapshot) and that `Globe.tsx` still never
  mentions `zoomCmd` (`grep -c zoomCmd src/pages/Globe.tsx` → 0). Re-confirm the icon-set import in `MapLegend.tsx`
  matches whatever Task 1 recorded from Plan I's merged branch (no stale assumption slipped through).
- [ ] Controller existence-check (workspace discipline): `ls src/hooks/useRailCollapse.ts
  src/components/CollapseToggle.tsx src/components/PanelWrapper.tsx src/components/flatmap/MapLegend.tsx` in the
  worktree before the final commit.
- [ ] Commit: `chore(flatmap): full suite + tsc + build + lint green (Plan J)`
- [ ] Ask git-flow-manager to push the branch and open a PR titled
  `feat(flatmap): chrome/controls — legend, panel collapse, corner-globe reposition+zoom, map +/- (Plan J)` against
  `main` with the structured description (Summary / Motivation / Implementation / Tests / Risks / rollout), noting:
  `GlobeCanvas.zoomCmd` is additive-only and `/globe` stays byte-identical except the unrelated rail/panel changes
  to `Globe.tsx` itself; the icon-set dependency resolution from Plan I (which branch applied — reusable export vs
  documented fallback); any Task-1 contract reconciliations. Request code review
  (superpowers:requesting-code-review) with the strongest available model; resolve findings before Task 10.

---

## Task 10 — Live Playwright E2E + design-review pass

**DEPENDENCY:** Plan I + Plan J merged-or-branch-live; dev stack up (ops-api, projector, seed applied); frontend
`npm run dev`. Findings become scoped fix commits on this branch or follow-up GitHub issues.

**Files** — none (live drill).

**Steps**

- [ ] Preconditions: confirm `/god-view/map` returns venues and the token is present so `<FlatMapCanvas>` and the
  corner `<GlobeCanvas>` both mount (not their fallback paths).
- [ ] **Corner globe:** confirm it renders **top-left**; click the size toggle and confirm the window visibly
  resizes 300px ↔ 225px; click the +/- buttons and confirm the mini-globe's altitude visibly changes (note the
  documented caveat: while `paused={cameraBusy}` during a main-map `flyTo`, a zoom press won't visibly animate
  until the fly ends — acceptable, per outside-review M1). Screenshot each state.
- [ ] **Map +/- buttons:** confirm they render top-right, do not overlap the Mapbox attribution, and visibly
  zoom the map in/out by the expected step. Screenshot.
- [ ] **Legend:** confirm the corner legend renders bottom-left with icons matching the building/venue map icons
  (Plan I's icon set) and the correct status color key for the active mode; confirm it switches with health/live
  mode; confirm the header-chevron collapses it to a `Legend` pill and the pill reopens it. Screenshot both states.
- [ ] **Rail collapse, both pages:** on `/map` and `/globe`, click the rail collapse toggle — confirm the rail
  narrows to a thin strip with a reopen handle and the map/globe canvas visibly widens to fill the freed space;
  click again to reopen. Screenshot both states on both pages.
- [ ] **Right panel, both pages:** select a venue on each page — confirm the panel opens right-docked (desktop) in
  the shared wrapper; close it; re-select — confirm it reopens (the pre-existing `setPanel(null)`/selection
  mechanism, now inside `PanelWrapper`, must be unaffected). Screenshot.
- [ ] **Two-WebGL hygiene:** with the corner globe present at both sizes, confirm smooth interaction on the target
  hardware and that the mini-globe still pauses during a Mapbox `flyTo` and resumes after (Plan G's `paused` prop,
  unaffected by this lane).
- [ ] **Longevity:** leave `/map` 10+ minutes under generator load — no console errors from the new chrome (rail
  collapse, legend, zoom buttons); navigate away and back — no leaked state.
- [ ] **Design-review gate (owner-locked decision — the gate v3 missed):** invoke a design-review pass (the
  `design-review` skill, or a live owner walkthrough) against the live `/map` and `/globe` pages covering: legend
  visual quality/spacing, rail-collapse affordance clarity, corner-globe size-toggle/zoom discoverability, map
  +/- button styling vs. the app's existing button conventions, panel-wrapper visual parity between the two pages.
  Fix anything flagged as a scoped commit (red→green where code changes are needed).
- [ ] Ask git-flow-manager to merge the PR (merge commit) after review + design-review are resolved and checks are
  green.
- [ ] Update `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (new dated entry: changes with
  `repo@sha`, E2E evidence + screenshots, design-review outcome, gotchas); file any deferred follow-ups as GitHub
  issues so nothing falls off the plan.

---

## Self-review notes (spec §6 "Plan J scope" coverage check, done at plan time)

- **§D compact collapsible corner legend:** Task 8 — `MapLegend.tsx`, bottom-left, kind rows + reused
  `ModeLegend.LEGEND` status key, collapses to a pill via header chevron. ✓
- **§E collapsible panels, both pages (I3):** Task 3 (shared `useRailCollapse`/`CollapseToggle`/`PanelWrapper`,
  explicitly NOT a monolithic shared rail) + Task 4 (Globe) + Task 5 (FlatMap). Right-panel close stays
  `setPanel(null)` throughout — no new `panelCollapsed` boolean introduced. ✓
- **§F corner globe reposition + size toggle + zoom (M1):** Task 6 — top-left, 300↔225 toggle (both literal
  Tailwind classes), +/- buttons driving the new additive `GlobeCanvas.zoomCmd` (Task 2). `/globe` stays
  byte-identical on the `GlobeCanvas` contract (source-text regression test in Task 2). ✓
- **§G map +/- zoom buttons (M3):** Task 7 — custom themed buttons (not `NavigationControl`), top-right (off the
  attribution), step = 2x default, via the new additive `FlatMapCanvas.mapZoomCmd`. ✓
- **Plan J touches no map data:** confirmed — every file this plan creates/modifies is chrome/layout (hooks,
  buttons, wrappers, legend, the two additive zoom props); no venue/building rendering, icon registry, or flyTo
  logic is touched (that's Plan I, assumed merged before Task 1). ✓
- **Sequenced after Plan I; contract consumed correctly:** Task 1 preflight re-verifies file/line assumptions and
  the icon-set export; Task 9 gate-check re-confirms both directions of the Contract (Plan J's `zoomCmd` stayed
  additive; the icon-set import matches what Plan I actually shipped). ✓
- **Discriminates-proofs on invariant tests (memory):** `nextZoomAltitude` direction/clamp, `useRailCollapse`
  flip, `CollapseToggle` aria-label swap, `MapLegend` collapsed-state gating, and the `Globe.tsx`-never-passes-
  `zoomCmd` regression each carry a stated mutation that reddens them. ✓
- **Subagent workspace discipline (memory):** cd+pwd lock step 1, bare-path read-only, existence-check before
  commit — Global Constraints + Tasks 1/9. ✓
- **Frontend-only, no backend changes:** confirmed — no `map.py`/schema edits anywhere in this plan. ✓
- **Process:** worktree branch, no raw git for implementers, red→green pairs watched failing, exact verify
  commands from `/Users/jn/code/godview-prototype/package.json`, PR + strongest-model review, live E2E +
  **dedicated design-review pass** (the owner-locked process gate v3 missed), SESSION_LOG close-out — Tasks
  1/9/10. ✓
