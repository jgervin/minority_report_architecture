# Flat Map v4 — Plan I / Plan J Gate-Check

**Date:** 2026-07-14 · **Verdict: PASS WITH FIXES/NOTES** (contracts align; 4 items locked below). Sequence **I → J** (J rebases on merged I).

Plans: `2026-07-14-flatmap-i-map-visual.md` (10 tasks) · `2026-07-14-flatmap-j-chrome.md` (10 tasks).
Shared boundary is small: FlatMap.tsx (page shell — Plan J owns; Plan I edits behavior/state only) + FlatMapCanvas.tsx (Plan I owns map data; Plan J adds one additive prop) + the icon set (Plan I authors geometry; Plan J's legend mirrors it) + `GlobeCanvas.zoomCmd` (Plan J authors; Plan I doesn't touch GlobeCanvas).

## FIX 1 — Icon consistency (legend ↔ map). LOCKED.
Plan I's `iconSvg.ts` is charter-pure (no React) and stores the four icons as `ICON_NODES` geometry (Building2/Server/Video/MonitorPlay) + exports `IconKind` + `ICON_STATUSES=["ok","warn","crit","off"]`. Plan J's legend renders React lucide components, so it CANNOT import a component map from the pure module. **Resolution (drop Plan J's "which branch applies" ambiguity):** Plan J's `MapLegend` (Task 8) defines `KIND_ICON: Record<IconKind, LucideIcon>` **locally** using the SAME four spec-§5 lucide components, and **imports `IconKind` from Plan I's `iconSvg.ts` + `TONE_HEX`/`HealthTone` from `globeSelectors.ts`** for colors. Plan J Task 1 MUST verify the four icon names match Plan I's `ICON_NODES` source (drift guard). No reusable React `KIND_ICON` export from Plan I is required (Plan I uses geometry, not components). The icon CHOICE is single-sourced in spec §5 + Plan I `ICON_NODES`; both plans cite it.

## NOTE 2 — FlatMapCanvas.tsx is a SECOND shared file (additive). OK under I → J.
Plan I heavily edits `FlatMapCanvas.tsx` (venue symbol layer replacing DOM markers, pre-tinted building icons, one-hop flyTo effect, `onNodeClick` prop, icon-image registration on load). Plan J Task 7 adds a `mapZoomCmd` prop + a new effect for the map +/- buttons. Because J rebases on merged I, Plan J's addition is **purely additive** (new prop + new effect) and must NOT restructure Plan I's layers/effects. Low risk; sequence handles it.

## VERIFY 3 — Removing `orgColors` must not break the corner globe. (Plan I Task 1 must check.)
Plan I drops the org-halo (owner decision) → removes the `orgColors` memo (`FlatMap.tsx:46-47`) + the `orgColors=` prop on `<FlatMapCanvas>` (`:112`). **Before removing, Plan I Task 1 MUST confirm the corner-globe `<GlobeCanvas>` (dots-only, `FlatMap.tsx:117-125`) does NOT consume `orgColors` for its dot coloring.** If it does, keep `orgColors` flowing to the corner globe and only drop the map-venue halo. (Carried into the Task 1 dispatch.)

## CONFIRM 4 — Legend labels vs status tokens. (Display concern, Plan J owns; no conflict.)
Internal token vocabulary is `HealthTone` = `ok|warn|crit|off` (Plan I features + icon-image names). Plan J's legend shows human labels mapped to `TONE_HEX` colors: **active↔ok (green) · degraded↔warn (amber) · failures↔crit (red) · offline↔off (grey)**. Legend rows use these labels + colors; no vocabulary conflict.

## Clean (verified aligned)
- Both plans: TDD red→green per task; pure modules unit-tested; mapbox/canvas isolation via dynamic-import-behind-guard.
- Reuse-not-fork: Plan I reuses `TONE_HEX`/`HealthTone`, **replaces** (not orphans) `venueMarkers.ts` → `venueFeatures.ts` (+ migrated test); Plan J additive to `GlobeCanvas`.
- `GlobeCanvas.zoomCmd:{delta,token}|null` — Plan J authors, mirrors the token-bumped `focus` one-shot; `/globe` never passes it (byte-identical); test asserts Globe.tsx usage unchanged.
- FlatMap.tsx JSX tree at `:101` (grid), `:117-125` (corner globe), `:126-130` (right-panel mount): Plan I edits props/handlers only (not the element tree); Plan J owns their chrome/layout. No collision under I → J.
