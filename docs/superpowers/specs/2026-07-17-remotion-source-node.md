# Spec — Remotion source inside the Composition node

**Date:** 2026-07-17 · **Status:** decisions locked, ready to plan
**Mockup (owner-reviewed):** https://claude.ai/code/artifact/0c3923a3-7014-40d2-bda4-9cb9545bbf67
**Handoff:** `/Users/jn/code/minority_report_architecture/docs/handoff-07-remotion-node-in-composition-2026-07-17.md`

## Owner ask

> In the view that shows the elements of the videos that are generated (the n8n-like
> composition/workflow), any video that contains Remotion content should show the code of that
> Remotion content inside the composition element that contains it.

## Locked decisions (owner, 2026-07-17)

1. **Default state: EXPANDED.** The code panel is open on load; internal scroll caps node height.
   Collapsible to a one-line summary via a chevron toggle.
2. **Props strip: KEEP.** Shows per-viewer personalization bindings
   (e.g. `name ← viewer.visible_name`) under the code.
3. **Backend scope: SAME TICKET.** Persist-source + expose-to-god-view ship in this batch —
   the UI has nothing to render without them.
4. **Endpoint shape: FOLD INTO AD-RUN DETAIL.** No new endpoint; `GET /god-view/ad-runs/:id`
   joins `components` (+`ads`) so `composition_run` carries the source and creative metadata.

## Scope — two repos, two PRs

### A. Backend (`mras-ops`)

1. **Migration `/Users/jn/code/mras-ops/db/migrations/029_component_source.sql`** —
   `ALTER TABLE components ADD COLUMN source text;` (nullable — pre-existing rows have no source;
   no backfill in this ticket).
2. **Persist on ingest** — `POST /components`
   (`/Users/jn/code/mras-ops/api/src/main.py:57-69`) already receives `{name, source}`; add
   `source` to the `INSERT INTO components`.
3. **Expose to god view** — the composition SELECT in
   `/Users/jn/code/mras-ops/api/src/godview/ad_runs.py:70-75` LEFT JOINs
   `components` (on `composition_runs.component_id`) and `ads` (on `composition_runs.ad_id`) and
   adds to `composition_run`: `source`, `component_slug`, `props_schema`, plus from `ads`:
   `default_props`, `personalized_field`, `base_video`. All nullable (runs without a
   component/ad, or components ingested pre-migration, return `null`s; response shape otherwise
   unchanged).

### B. Frontend (`godview-prototype`)

1. **Types** — extend `composition_run` in
   `/Users/jn/code/godview-prototype/src/data/apiTypes.ts` with the new nullable fields.
2. **Graph data** — `adRunGraph()` Composition node
   (`/Users/jn/code/godview-prototype/src/data/selectors.ts:101-104`) passes
   `source`/`component_slug`/props metadata through `data` when
   `render_mode === "remotion"` and `source` is non-null.
3. **Node UI** — new `RemotionSourcePanel` rendered inside the Composition node variant of
   `/Users/jn/code/godview-prototype/src/components/PipelineNode.tsx` (node widens for this
   variant), per the mockup:
   - Filename header `<component_slug>.tsx` + collapse chevron (default expanded) + **Copy**
     button (`navigator.clipboard`).
   - Syntax-highlighted `.tsx` with line numbers. **Zero-dep highlighting**: a small hand-rolled
     tokenizer (keywords / strings / comments / JSX tags / numbers) — no bundle-heavy highlighter
     (cf. godview issue #36 bundle concerns).
   - Internal scroll with a max height; the node never grows unbounded.
   - **Props strip**: `personalized_field ← viewer.visible_name` binding + `default_props`
     key:values.
4. **Non-remotion / no-source behavior** — node is byte-for-byte the current one when
   `render_mode !== "remotion"` **or** `source` is null. No layout shift for other render modes.
5. **Layout** — Composition node x-positions in `adRunGraph()` may need adjustment for the wider
   node; downstream nodes (`Ad Run` x640, `Playback` x860) shift right only in the
   remotion-with-source case (or the panel renders within a width that avoids overlap — plan
   decides, mockup governs).

## Known implementation gotchas (must land in the plan)

- **@xyflow scroll capture**: the code panel needs `nowheel` (and `nodrag` on selectable text /
  the Copy button) classes so scrolling code doesn't zoom/pan the canvas.
- **Tailwind literal classes** — any arbitrary-value class must be a full literal string chosen
  by a ternary (JIT).
- **Node 25 localStorage** — if any persistence is added (collapse state is per-render, NOT
  persisted — out of scope), unit tests need `vi.stubGlobal`.
- **TDD red→green with split commits**; implementers never run git; all git via
  `git-flow-manager`; worktrees under `.claude/worktrees/`; merge commits, not squash.
- **E2E** needs a remotion ad-run in the dev DB **whose component was ingested AFTER the
  migration** (source column populated). Recipe: re-POST the demo component via
  `POST /components`, re-run a trigger, then open `/compositions/:adRunId` in real Chrome via
  Playwright MCP. ops-api rebuild required (`docker compose up -d --build mras-ops-api`) and
  migration applied manually to the existing dev volume (init scripts only run on fresh DBs).

## Out of scope

- Backfilling `source` for pre-existing components (sidecar disk copy stays untouched);
  re-ingest is the documented path.
- Sidecar (`mras-overlays`) changes — none needed.
- Editing/executing the source from god view; sandboxing (deferred, pre-existing).
- Persisting the collapse state.

## Definition of done

- Backend: failing tests first (migration column present; ingest persists source; ad-run detail
  carries joined fields; null-safe when component/ad missing) → green.
- Frontend: failing tests first (selector pass-through; panel renders for
  remotion-with-source; unchanged node otherwise; copy button; collapse toggle) → green.
- Live Playwright E2E on real data shows the expanded source panel with props strip on a
  remotion ad-run detail page.
- Design-review pass (owner-locked gate) against the mockup before merge.
- SESSION_LOG + memory updated; follow-up issues filed.
