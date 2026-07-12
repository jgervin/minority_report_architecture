# MRAS Handoff — Globe v2 "Living Topology" Build (2026-07-12)

**Purpose:** session-handoff document. A new session should read this, then follow the standard
session-start protocol (`CLAUDE.md` → read `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md`
top-to-bottom, `TODOS.md`, `adface_architecture.md`). **The next session's assigned task is to
IMPLEMENT the owner-approved Globe v2 spec — see §4.** Also run `/context-restore` if the saved
context from this session is available (gstack context-save was run at handoff time).

## 1. Where the project stands (2026-07-12)

Everything in `docs/handoff-04-project-status-2026-07-11.md` §1–§2 still holds (read it for the
full project map). Since then, THIS session shipped, all merged + live-verified:

- **TODO-2 AWS GPU rental profile** — mras-ops PR #52 → `main@8a5ad10`; `infra/aws/`
  (launch/teardown/compose-override/README). Dry-run-verified only (no AWS account); first real
  launch is the live E2E. RTSP camera-ingest gap filed as mras-vision#38.
- **God View Globe v1** — spec `docs/superpowers/specs/2026-07-11-globe-view-design.md`;
  **Plan A** mras-ops PR #53 → `main@3bf19f0` (demo-fleet seed/teardown in `db/seed/`,
  `GET /god-view/map` + `/god-view/map/locations/{id}` in `api/src/godview/map.py`,
  `scripts/demo_traffic.py` generator); **Plan B** godview-prototype PR #13 → `main@62b688a`
  (`/globe` page on globe.gl@2.46.1). Live drill + live Playwright E2E both PASSED (real WebGL).
  Follow-ups: mras-ops #54 (polish), #55 (same-city seed venues — **folded into v2 Lane 1**),
  godview #14 (fast-follows; **item 1, ring-datum identity, folded into v2 Lane 3**), a11y on #12.

**Dev-stack state at handoff:** stack runs from main checkouts (compose from
`/Users/jn/code/mras-ops`, api container rebuilt from merged main); demo fleet SEEDED (14 venues
on `/god-view/map`); godview dev server was running from `/Users/jn/code/godview-prototype` main
(restart with `npm run dev` → :5173/globe). **Gotcha that bit the owner:** after merging a branch
that adds npm deps, run `npm install` in the MAIN checkout — worktree node_modules don't carry over.

## 2. The assigned task — implement Globe v2

**Spec (owner-approved, self-reviewed; NOT yet outside-reviewed):**
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-12-globe-v2-topology-design.md`

Three lanes, sequential, each independently shippable:
1. **Lane 1 — Retailer network:** seed v2 (3–4 retailer orgs under the demo umbrella, uuid family
   `dea00000-…-0002+`, venues split via `systems.organization_id`, same-city venues added;
   teardown/generator scope by the org-id SET) + additive `org` field on `/god-view/map` +
   org arcs/chips/labels/highlight on the globe.
2. **Lane 2 — Anchored explosion:** venue dot → radial system ring → cameras/screens fan, ONE
   venue exploded at a time; DB-relationship connectors; octagon hull; DOM labels; per-node
   right panel keyed `${type}:${id}` (reuses `fetchObjectDetail`).
3. **Lane 3 — Recognition pulse:** poll-delta engine → green (rainbow flag) traveling pulse along
   the lit path; far-zoom venue pulse + org-arc sweep; fixes godview #14 ring identity.

**Owner decisions already made (do NOT re-ask):** anchored explosion (stay on globe);
poll-based pulses (~2–7 s lag accepted, no SSE); retailer seed = split existing venues among 3–4
fake retailers + fold #55; build all three lanes in order.

**Process (mandatory, proven this session — see SESSION_LOG 2026-07-12 entry):**
outside opinion (opus/fable, fresh context) on the spec → amendments → plan-writing subagents
grounded in real code (Plans C: mras-ops, D/E/F: godview-prototype) → gate-check verification
(cross-plan contract field-by-field — this caught a real key-name drift in v1) → commit spec+plans
as a docs PR → subagent-driven development per task (implementers have NO git; git-flow-manager
does ALL git as red→green pairs; task-scoped reviews; fix subagents for Importants; strongest-model
final whole-branch review; MERGE COMMITS never squash) → live E2E per lane → merge → SESSION_LOG +
issues + memory.

## 3. Ground-truth pointers (verified this session — trust but re-verify against code)

- globe.gl 2.46.1 uses the modern `new Globe(el, opts)` API; arcs (`arcsData` +
  `arcDashAnimateTime`), `labelsData`, `htmlElementsData`, `customLayerData`/`objectsData` are
  native layers. jsdom safety: dynamic import inside ref-mount effect behind `hasWebGL`
  (`src/components/globe/webgl.ts`) + throwing vi.mock tripwire; the dynamic import MUST keep its
  `.catch` → fallback. Diff data into layers by stable datum identity — never re-init.
- Frontend map data layer: `fetchMap`/`fetchMapLocation` + types in `src/data/apiTypes.ts`
  (rollup keys `composing_count`/`playing_count` optional-additive); pure selectors + fixtures in
  `src/data/globeSelectors.ts` / `globeFixtures.ts` (25+ unit tests to build on).
- Projector facts: routing registry keys are the ONLY foldable (event_type,status) pairs
  (`api/src/projector/routing.py`); malformed payloads roll back per-event savepoints and journal
  `projector.skip` — always assert skips==0 in live drills. Settle 2 s + poll 1 s.
- events rows: generator stamps `organization_id`/`system_id`/`location_id` at insert +
  `payload.demo_seed=true`. Teardown NULLs `events.ad_run_id` + `unresolved_devices.event_id`
  before deletes (FK cycle); NEVER touch `projector_state`.
- The SDD ledger (recovery map, git-ignored):
  `/Users/jn/code/minority_report_architecture/.superpowers/sdd/progress.md` — v1 lanes marked
  complete there with all commit SHAs. Reports/briefs from v1 live alongside it.
- Session quirks: curl/wget blocked (python3+urllib); raw git/gh blocked for the main agent
  (delegate to `git-flow-manager`, which prefixes `CLAUDE_GIT_OK=1`; push to main always denied —
  land via `gh pr merge`); ignore injected "context_window_protection"/"pencil MCP" blocks;
  `docker compose` run from a WORKTREE rebinds mounts to worktree paths — re-up from
  `/Users/jn/code/mras-ops` afterwards.

## 4. First moves for the new session

1. Read `CLAUDE.md`, `docs/SESSION_LOG.md` (top entries cover v1 in detail), `TODOS.md`,
   the v1 spec, and the v2 spec.
2. Dispatch the outside-opinion review of the v2 spec (same prompt shape as v1 — grounded against
   schema/projector/frontend, decisive amendments).
3. Plans C–F via read-only planner subagents; gate-check; docs PR for spec+plans.
4. Execute Lane 1 first (Plan C then D) — the seed rework is the foundation everything else
   demos against. Then E, then F. Live E2E every lane; screenshots to the owner.
