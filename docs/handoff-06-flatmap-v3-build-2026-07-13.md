# MRAS Handoff — Flat Map v3 "Command Map" Build (2026-07-13)

**Purpose:** session-handoff document. A new session should read this, then the standard
session-start protocol (`CLAUDE.md` → `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md`
top-to-bottom, `TODOS.md`, `adface_architecture.md`). **The assigned task is to IMPLEMENT the
owner-directed Flat Map v3 spec** —
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md`.

## 1. Where the project stands

Globe v2 "Living Topology" is COMPLETE and live (all three lanes, same-day build 2026-07-12):
mras-ops #56 @48f7096, godview-prototype #15 @85938cd + #17 @2a6c0b3 + #21 @a56d7af. See
SESSION_LOG entries (c)/(d)/(e) and the SDD ledger
(`/Users/jn/code/minority_report_architecture/.superpowers/sdd/progress.md`) for the full record.
A same-night tuning PR made the org-arc streaks slow candy-cane stripes (owner feedback).

## 2. The assigned task — Flat Map v3

Spec: `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-13-flatmap-v3-design.md`
(owner-directed, NOT yet outside-reviewed). Owner decisions locked 2026-07-12 (do NOT re-ask):
**keep both surfaces** (globe untouched), **Mapbox GL JS** (token via `VITE_MAPBOX_TOKEN` — the
OWNER must create the Mapbox account/token; ask for it before the live E2E, dev can proceed
against the graceful no-token fallback), **corner globe = v1 dots-only** driving flat-map
fly-to, **2D glyph/card graphics** at building zoom (reference images archived per spec §status;
ask the owner to drop the three screenshots into `dashboard_images_ideas/` if not done).

**Process (mandatory, twice-proven — v1 and v2):** outside opinion on the spec (fresh-context
strongest model, grounded against godview-prototype code + the shipped globe modules) →
amendments → Plans G/H via read-only planners → gate-check (field-by-field on the
GlobeCanvas-mini contract + selector reuse surface) → docs PR → subagent-driven dev
(implementers NO git; git-flow-manager commits red→green pairs; task reviews; strongest-model
final review; MERGE COMMITS) → live Playwright E2E per plan → merge → SESSION_LOG/memory.

## 3. Ground-truth pointers (verified 2026-07-12)

- Reusable-by-design modules (all pure unless noted): `src/data/globeSelectors.ts` (dots,
  clustering, rings), `src/data/topologySelectors.ts` (org grouping/chains/palette),
  `src/data/explodeSelectors.ts` (deterministic layout helpers — the fallback layout for
  coordless devices can reuse its sorted-ids discipline), `src/data/pulseDelta.ts` (both delta
  engines + pulseColor), `src/hooks/usePollDelta.ts` (strict-consecutive; clears prev on null),
  `src/hooks/useVenueDetailPoll.ts`, `src/components/globe/datumCache.ts`.
  `GlobeCanvas` props: pass `arcs=[] labels=[] highlightOrgId=null explosion=null
  liveSystems=∅ onNodeClick=noop farPulses=null deepPulses=null` for v1-dots behavior — recon
  whether that suffices for "mini" mode or a size/interaction flag is needed.
- Data: `/god-view/map` + `/god-view/map/locations/{id}` + `fetchObjectDetail` cover the spec;
  additive-only if a gap appears. Devices have lat/lng columns; seeded ones may be null.
- WebGL discipline: dynamic import behind a capability guard + throwing vi.mock tripwire + pure
  selectors — apply the SAME pattern to mapbox-gl (own lazy chunk; token-absent = graceful
  fallback state, mirror the WebGL fallback).
- Session quirks (unchanged): raw git/gh blocked (git-flow-manager only; push-to-main denied —
  land via `gh pr merge` with MERGE COMMITS); curl/wget blocked (python3+urllib); worktree
  npm-install doesn't carry to main post-merge (and the owner's :5173 dev server may need a
  bounce after dep-adding merges); **subagent workspace discipline** — every implementer
  dispatch: cd+pwd lock step 1, "bare repo path = READ-ONLY reference", controller
  existence-check before every commit dispatch (4 drift incidents in the v2 build; see memory
  `feedback-subagent-workspace-discipline`).
- Demo pulses: `python3 -m scripts.demo_traffic --rate 10 --duration 600` from
  `/Users/jn/code/mras-ops` (dev DB is seeded v2: 17 venues, 4 retailer orgs).

## 4. First moves

1. Protocol reads; then the v3 spec + the v2 spec (for the reuse surface).
2. Outside-opinion review of the v3 spec; apply amendments.
3. Plans G (map shell + corner globe + fly-to + venue layers) and H (building-level 2D topology
   + cards + pulses) via read-only planners; gate-check; docs PR.
4. Execute Plan G then H, live E2E each (screenshots to owner; get the Mapbox token from the
   owner before the E2E), merge, close out.
