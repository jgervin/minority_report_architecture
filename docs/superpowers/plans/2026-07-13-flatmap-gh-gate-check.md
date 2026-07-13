# Flat Map v3 — Plan G / Plan H cross-plan GATE-CHECK (2026-07-13)

**Scope:** adversarial byte-level contract verification of
`/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-13-flatmap-g-map-shell.md` (Plan G, produces)
and `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-13-flatmap-h-building-topology.md`
(Plan H, consumes), against the locked contract block (both plans) and the real code at
`/Users/jn/code/godview-prototype`. Read-only. Boundary intent per spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md` §5.

---

## VERDICT: BLOCK → **RESOLVED 2026-07-13** (all 5 findings applied to the plans)

**Resolution (2026-07-13):** all five findings folded into Plan G / Plan H before build:
1. [BLOCKING] Island directory unified to `src/components/flatmap/` — every Plan H `components/map/` path
   substituted (0 remaining); the `import("./mapPulseLayer")` co-location now resolves.
2. [BLOCKING] `selectedVenueId` state added to Plan G's page (Task 9): rail `onSelect` and corner-globe
   dot-click (venue → select+fly-to-building; cluster → fly-to-city, no select) both set it; passed as
   `selectedId`. Plan H's building tier now has its input.
3. [IMPORTANT] Seam reconciled to PROPS+effects (the Plan-F GlobeCanvas pattern): Plan G's speculative
   `useFlatMap()` context + `children` slot dropped from the props interface, island wiring, render div,
   and page mount. Plan H already integrated via props.
4. [MINOR] `orgColors?: Map<string,string>` added to Plan G's FlatMapCanvas props interface.
5. [MINOR] Plan G Task 3 extraction span corrected to `explodeSelectors.ts:78-90` (JSDoc removed with helpers).

The plans are now BUILD-READY. Original BLOCK findings retained below as the record.

---

## VERDICT (original): BLOCK

Two blocking cross-plan mismatches must be reconciled before Plan G merges / Plan H builds:

1. **Directory divergence** — Plan G authors the Mapbox island under `src/components/flatmap/`; Plan H creates its
   pulse layer and edits the island under `src/components/map/`. Concrete breakage: `FlatMapCanvas`'s
   `import("./mapPulseLayer")` cannot resolve a `mapPulseLayer.ts` that lands in a different directory.
2. **Selected-venue state gap** — Plan H's entire building tier gates on a page-owned `selectedVenueId`, but Plan G's
   page never maintains one (it hardcodes `selectedId={null}` and only fly-to's on select). Plan H's core feature has
   no input.

Both findings are *self-flagged* by Plan H's own preflight/STOP clauses (Task 1), so the build will not silently ship
wrong — but the gate's mandate is ZERO impedance mismatch at the contract, and these are contract-level. Fix both in
Plan G (it owns the shared surface) before build. Everything else in the locked contract (A–E) verifies clean against
the real code.

---

## Contract diff table (locked block A–E)

| Item | G side | H side | Match? |
|---|---|---|---|
| **A** `GlobeCanvas paused?: boolean` → `pauseAnimation()`/`resumeAnimation()`; default falsy = /globe byte-identical | G Task 5: adds `paused?: boolean`, delegates to pure `applyAnimationState`; asserts /globe unchanged (re-runs `Globe.test.tsx` + `GlobeCanvas.test.tsx` untouched, Constraints L15 + Task 5 Step 6). Method names verified `globe.gl.d.ts:115-116`. | H Contract A: "exists after Plan G … Plan H does not touch it." | ✅ MATCH |
| **B** `MapTier='world'\|'city'\|'building'`; `mapTier(zoom:number):MapTier`; module `src/data/mapSelectors.ts` | G Task 2 authors exactly this at that path; thresholds CITY_ZOOM=5/BUILDING_ZOOM=14; staged landings consistency asserted. | H Contract B reproduces the type + signature at the same path; gate is `mapTier(zoom)==='building'`. | ✅ MATCH |
| **C** `MapNode{key,type,id,name,status,systemId,lat,lng,altitude:0}` + `buildingLayout(anchor,systems)`; module `src/data/mapLayout.ts`; reuses byId+ringPoint extracted+re-exported; satisfies `deepPulsePath` Pick | G Task 4 authors identical interface + signature at that path; Task 3 extracts byId/ringPoint to `src/data/layoutGeometry.ts`, re-exported from explodeSelectors (byte-unchanged). | H Contract C reproduces the interface byte-for-byte; consumes `buildingLayout` from `src/data/mapLayout.ts`; feeds `MapNode[]` to `deepPulsePath`. | ✅ MATCH (Pick verified below) |
| **D** `<FlatMapCanvas>` mounts iff `hasWebGL() && !!VITE_MAPBOX_TOKEN`; else `data-testid="map-unavailable"`; VenueRail always; corner GlobeCanvas when hasWebGL(); `.env.example` gets token; H mounts INSIDE, not re-guarding | G Task 9 page authors the exact seam; Task 1 adds `VITE_MAPBOX_TOKEN` to `.env.example`. | H Contract D reproduces the guard; "layers mount INSIDE it; do NOT re-implement the guard." | ✅ MATCH (guard string; but see Finding 3 on *how* H mounts) |
| **E** Reused verbatim: `diffFarPulses,diffDeepPulses,attributionCamera,deepPulsePath,usePollDelta`. NOT reused: `pulseRingDatum,sweepArcDatum,pulseLayer.ts` | G Self-review L944: G touches none of them. | H Constraints L48-57 reuses the five verbatim; writes NEW Mapbox equivalents for the three globe-only builders. | ✅ MATCH (purity/coupling verified below) |

---

## Findings

### 1. [BLOCKING] FlatMapCanvas / pulse-layer directory: `flatmap/` (G) vs `map/` (H)

**Mismatch.** Plan G places the island at `src/components/flatmap/FlatMapCanvas.tsx` and its isolated impl at
`src/components/flatmap/mapboxImpl.ts` (G Architecture L7; G Task 8 Files L686-688; test L688). Plan G's page imports it
from `../components/flatmap/FlatMapCanvas` and renders children there (G Task 9 L783-790).
Plan H assumes `src/components/map/` throughout: creates `src/components/map/mapPulseLayer.ts` (H L22, L164), modifies
`src/components/map/FlatMapCanvas.tsx` + `FlatMapCanvas.test.tsx` (H File-structure L168-171; Task 4 Files L466-467;
Task 5 Files L535-537), and mocks `../components/map/FlatMapCanvas` in the page test (H Task 6 L672).

**Concrete breakage (not just cosmetic).** Plan G's `FlatMapCanvas` reaches the pulse renderer via
`import("./mapPulseLayer")` (H Task 5 mechanism L570). That relative specifier resolves *next to FlatMapCanvas*. If
FlatMapCanvas lives in `flatmap/` but Plan H creates `mapPulseLayer.ts` in `map/`, the dynamic import cannot resolve —
runtime + `tsc -b` failure. (Note: `mapPulseLayer.ts`'s own `../../data/mapPulseGeometry` import and the `./mapPulseLayer`
mock are directory-agnostic — only the *co-location* with FlatMapCanvas matters.)

**Evidence:** G L7, L686-688, L783; H L22, L164-171, L466-467, L535-537, L672, L725.

**Recommended edit — canonical directory = `src/components/flatmap/` (Plan G owns/creates the file; `flatmap/` matches
the `FlatMap`/`FlatMapCanvas` names). Plan H yields.** Mechanically substitute `src/components/map/` →
`src/components/flatmap/` at every Plan H occurrence:
- H L22: `…/src/components/map/mapPulseLayer.ts` → `…/src/components/flatmap/mapPulseLayer.ts`
- H L164 (Created): same path → `flatmap/`
- H L168 (Modified): `…/src/components/map/FlatMapCanvas.tsx` → `…/flatmap/FlatMapCanvas.tsx`
- H L171 (Modified): `…/src/components/map/FlatMapCanvas.test.tsx` → `…/flatmap/FlatMapCanvas.test.tsx`
- H L176-177 caveat: change "the above assume `src/components/map/`" → "confirmed `src/components/flatmap/` (gate-check)"
- H Task 4 Files L466-467, Task 5 Files L535-537, Task 7 existence-check L725: `map/` → `flatmap/`
- H Task 6 test L672: `vi.mock("../components/map/FlatMapCanvas", …)` → `vi.mock("../components/flatmap/FlatMapCanvas", …)`

Plan H's Task 1 preflight (L199-201, L214) already says to locate `FlatMapCanvas` and substitute paths mechanically — but
leaving it to the implementer is the exact fragility this gate exists to remove. Pre-resolve it in the plan text.

---

### 2. [BLOCKING] Plan G never provides the page-owned `selectedVenueId` Plan H's building tier requires

**Gap in Plan G.** Plan H's building tier is gated on a page-held selected venue:
`buildingVenueId = mapTier(zoom) === "building" ? selectedVenueId : null` (H Task 6 L630), and H Contract L146/L630
asserts "the page already owns (Plan G) … a selected-venue id (rail/marker click)." **Plan G's page does not implement
this.** G Task 9 (L780) renders the rail with `selectedId={null}` hardcoded and `onSelect={(v)=> … flyToVenue(...)}` — it
flies to the venue but stores no selection; there is no `selectedVenueId` state anywhere in G's page composition
(L758-802), and G's venue markers (Task 7/8) carry `data-venue-id` but wire no click→page-selection callback.

The component supports it — `VenueRail` already exposes `selectedId: string | null` + `onSelect: (v)=>void`
(verified `src/components/globe/VenueRail.tsx:6-10,20-22`) — Plan G simply never threads a state through it.

**Evidence:** G Task 9 L780, L758-802; H Task 6 L630, H Contract L146; real code `VenueRail.tsx:6-22`.
Plan H's own STOP-clause (H Task 1 L214: "if … the page does not own zoom/selected-venue, STOP and report — that is a
Plan G gap") predicts exactly this.

**Recommended edit — add selected-venue state to Plan G (keeps "page owns selected-venue" true).** In G Task 9 page
composition (after L767):
- add `const [selectedVenueId, setSelectedVenueId] = useState<string | null>(null);`
- change the rail render (L780) so `onSelect` sets it AND flies:
  `onSelect={(v)=>{ setSelectedVenueId(v.location_id); if (v.lat!=null && v.lng!=null) flyToVenue(v.lat, v.lng); }}`
  and pass `selectedId={selectedVenueId}` (drop the hardcoded `null`).
- (Optional, for marker-click selection parity: expose the venue-marker click through `FlatMapCanvas` — but the rail
  path alone unblocks Plan H.)
Then Plan H reads `selectedVenueId` from the page as its contract already assumes. If instead the owner prefers Plan H to
own selection, update H Contract L146 to drop "already owns (Plan G)" and add a Plan H task to introduce the state — but
the cleaner fix is in G, which authors the page.

---

### 3. [IMPORTANT] Integration-model divergence: Plan G's `children`+`useFlatMap()` seam vs Plan H's props+effects

**Mismatch (not a locked-contract break, but unreconciled).** Plan G's internal FlatMapCanvas contract exposes a
`children?: ReactNode` slot + a `useFlatMap(): { map }` context "Plan H's child layers consume to reach the live map
instance" (G L70-83, L709), and G's page renders `{/* Plan H building layers mount here */}` as children (G L785).
Plan H does **not** use children or `useFlatMap()`: it **modifies FlatMapCanvas.tsx to add `building`/`farPulses`/
`buildingPulses` props + internal effects** using the island's own `map` ref (H File-structure L168, Task 4 L466-492,
Task 5 L532-575), explicitly "exactly as Plan F added farPulses/deepPulses to GlobeCanvas" (H L142), and the page passes
those as **props** (H Task 6 L655), never as children.

Both satisfy locked item D ("mount INSIDE FlatMapCanvas"). But the consequence is that Plan G's `useFlatMap()` context (and
the `children` slot) become **dead, single-…zero-use scaffolding** — Plan H never imports them. The props approach is the
codebase-established pattern (GlobeCanvas takes pulse props, not children), so Plan H is the more consistent side.

**Evidence:** G L70-83, L709, L785; H L142, L168, L466, L655.

**Recommended edit (pick one; Plan G is authoritative):**
- **Preferred:** In Plan G Task 8, drop the speculative `useFlatMap()` context export (and, if unused, the `children`
  prop) — Plan H will add its layer/pulse props to FlatMapCanvas directly (as it already plans). This honors CLAUDE.md §2
  (no single-use abstractions) and removes the divergence. Keep the page's mount point as the `<FlatMapCanvas … />` element
  itself (props), not a children comment.
- **Alternative:** keep the `children` slot (cheap) but note in both plans that Plan H integrates via props+effects, and
  `useFlatMap()` is a documented-but-currently-unused seam. At minimum, reconcile so a reviewer isn't surprised that G
  ships a context H never consumes.

---

### 4. [MINOR] `orgColors?` prop — harmless to Plan H; internal Plan G doc drift

Plan G adds `orgColors?: Map<string,string>` to FlatMapCanvas (G Task 8 L707; page passes it G Task 9 L784). It is **not**
in the locked block, and — worth noting — it is also **absent from Plan G's own internal FlatMapCanvas props interface**
(G L73-80), which is then contradicted by Task 8/9 adding/using it. **Clear for Plan H:** Plan H never references
`orgColors`; an extra optional prop it doesn't pass is a no-op. No action required for the G/H boundary. Optional tidy:
add `orgColors?: Map<string,string>` to G's L73-80 interface so Plan G is internally consistent.

**Evidence:** G L73-80 (omits) vs L707/L784 (adds/uses); H — no reference.

---

### 5. [MINOR] Plan G Task 3 line-range inconsistency for the byId/ringPoint extraction

Plan G Task 3 variously cites the helpers as `explodeSelectors.ts:81-90` (Files header) and `78-90` (Interfaces + Step 4).
Real code: JSDoc `78-80`, `ringPoint` `81-86`, `byId` `88-90` (verified). "Delete lines 78-90" is the correct span (it
removes the JSDoc that Step 4 re-copies into `layoutGeometry.ts`); the `81-90` phrasing would orphan the JSDoc. Net effect
is correct; align the two citations to `78-90` to avoid an implementer deleting only `81-90`.

**Evidence:** G Task 3 L216-219 vs L222; real code `explodeSelectors.ts:78-90`.

---

## Verified clean (no action)

- **Contract A — pause API + byte-identical /globe.** `pauseAnimation(): ChainableInstance` / `resumeAnimation():
  ChainableInstance` exist at `node_modules/globe.gl/dist/globe.gl.d.ts:115-116` (Plan G cites them correctly). Plan G
  asserts the /globe path stays byte-identical by re-running the untouched `Globe.test.tsx` + `GlobeCanvas.test.tsx` suites
  (G L15, Task 5 Step 6), and `Globe.tsx` is not edited. Idempotent `resumeAnimation` on falsy `paused` is sound.
- **Contract C — MapNode satisfies `deepPulsePath`'s Pick.** Verified against
  `src/data/pulseDelta.ts:93-95`: param is `Pick<ExplodedNode,"key"|"type"|"id"|"lat"|"lng"|"altitude">[]`.
  `ExplodedNode.type` = `ExplodedNodeType` = `"system"|"camera"|"display"` (`explodeSelectors.ts:25`) — **identical** to
  `MapNode.type`. `altitude: 0` (literal) is assignable to `number`. Excess MapNode fields (`name`, `status`, `systemId`)
  do NOT trip excess-property checks because a `MapNode[]` value (not an object literal) is passed. → No TS error; Plan H
  feeding `buildingLayout` output straight into `deepPulsePath` (H Task 6 L649) is valid.
- **Contract E — reuse/no-reuse verified against real code.**
  - `usePollDelta` (`src/hooks/usePollDelta.ts`) is a pure React hook (refs/state only, no three/globe/mapbox), returns
    `{ seq, pulses }` — matches both plans' usage.
  - `deepPulsePath`, `diffFarPulses` (`FarPulse{venueId,lat,lng,orgId}`, L15), `diffDeepPulses`
    (`DeepPulse{systemId,cameraId,displayId}`, L43), `attributionCamera`, `pulseColor` — all pure, no render coupling.
    Plan H's `mapPulseGeometry.test.ts` fixtures (`{venueId,lat,lng,orgId}`, GeoPoint `{lat,lng,altitude}`) match these
    shapes exactly.
  - NOT-reused list is genuinely globe-coupled: `pulseLayer.ts` statically imports `three` + `Line2/LineGeometry/
    LineMaterial` and consumes `globe.getCoords` `{x,y,z}` (`pulseLayer.ts:9-12,32`) — 100% globe/three. `pulseRingDatum`/
    `sweepArcDatum` build globe.gl RingDatum/OrgArcDatum (`pulseDelta.ts:127,144`). Correctly excluded; Plan H writes new
    Mapbox equivalents.
- **byId/ringPoint reuse (no duplication).** Plan H consumes `MapNode[]` from `mapLayout.ts` and never re-derives
  `byId`/`ringPoint`; its `buildingFeatures` parent lookup builds a local `Map<key,MapNode>` (not geometry). The
  `DIM = "#3a4150"` constant Plan H defines matches `explodeSelectors.ts:23`.
- **Reused panel/selector shapes match real code.** `VenuePanel({locationId,onClose})` (`VenuePanel.tsx:12`),
  `NodePanel({type,id,detail,onClose})` (`NodePanel.tsx:14-15`), `liveSystemIds` (`:182`), `statusGlyph` (`:221`),
  `MapSystem`/`MapSystemDevice` with **no lat/lng** (`apiTypes.ts:143-144`) — all as Plan H states; the
  fallback-only building layout premise (Amendment 1) is correct.
- **Task boundary is clean.** Plan G authors shell + 3 contracts and mounts NO building layers (G L14, L629); Plan H
  authors only building glyphs/connectors/labels/pulses/panels and authors no shell/contract. No task crosses the line.
- **Sequencing explicit.** Plan H branches from `main` AFTER Plan G merges (H L35), with a Task 1 contract preflight and a
  Task 7 gate-check.
- **Process discipline present on both sides.** Red→green pairs (separate red/green commits, watch-fail-first);
  git only via `git-flow-manager`; subagent workspace `cd && pwd` lock + read-only bare path + pre-commit existence
  check; absolute paths throughout; WebGL/mapbox jsdom tripwires (`vi.mock("mapbox-gl", …throw)` in G Task 8;
  `vi.mock("./mapPulseLayer", …throw)` in H Task 5) with discriminates-proof notes on H's invariant tests.
- **Guard string identical.** Both gate the island on `hasWebGL() && VITE_MAPBOX_TOKEN`, render `map-unavailable`
  fallback, always-render VenueRail, corner globe when `hasWebGL()`.

---

## One-line must-fix list

1. [BLOCKING] Unify the island directory: change all Plan H `src/components/map/` → `src/components/flatmap/` (else
   `import("./mapPulseLayer")` won't resolve).
2. [BLOCKING] Add `selectedVenueId` state to Plan G's page (set on rail `onSelect`, pass `selectedId={selectedVenueId}`) —
   Plan H's building tier has no input without it.
3. [IMPORTANT] Reconcile the mount seam: Plan H uses props+effects (Plan-F pattern), so drop Plan G's unused
   `useFlatMap()`/`children` context — or explicitly mark it a documented, unconsumed seam.
4. [MINOR] Add `orgColors?` to Plan G's L73-80 FlatMapCanvas props interface (Task 8/9 already use it); clear for Plan H.
5. [MINOR] Align Plan G Task 3's `81-90` citation to `78-90` (the JSDoc must be deleted with the two helpers).
