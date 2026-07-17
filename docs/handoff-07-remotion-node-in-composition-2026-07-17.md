# Handoff 07 — Remotion source inside the Composition node (+ session state)

**Date:** 2026-07-17 · **From:** Claude Code (Opus 4.8) session · **Read next:** `docs/SESSION_LOG.md` (top), this file, then the "active feature" section below.

---

## TL;DR — where things stand

**Shipped this session** (all merged to `godview-prototype@main`, live from main):
- **Flat Map v4 — Plan I** (skeuomorphic Fluent 3D device icons on status rings + hub-centered building tree + node-click → device panel) — `godview-prototype@d0900dd`, PR #32.
- **Flat Map v4 — Plan J** (rail collapse on /map + /globe, right-docked `PanelWrapper`, corner-globe top-left + size toggle + zoom, map +/- zoom, compact `MapLegend`) — `godview-prototype@f29a69c`, PR #33.
- **Collapsible GOD VIEW nav sidebar** (Shell.tsx nav → 64px icon rail + top toggle + localStorage persist, dark/desktop only) — `godview-prototype@9a7897c`, PR #40.
- Docs/planning tracked in `minority_report_architecture@d3920c0` (PRs #56/#57/#58). 6 follow-up issues filed: **godview #34–#39**.

**Active / next up (NO code written yet):** *"Show the Remotion source code inside the Composition node of the ad-run pipeline graph."* A UI mockup is published and was presented to the owner; the build is **blocked on 3 owner decisions** + **one backend prerequisite**. Everything you need is below.

**Current HEADs:** `godview-prototype` main = `9a7897c` · `minority_report_architecture` main = `d3920c0` (may be ahead once this handoff commits).

---

## THE ACTIVE FEATURE — Remotion source inside the Composition node

### What the owner asked for
> "In the view that shows the elements of the videos that are generated (the n8n-like composition/workflow), any video that contains Remotion content should show the code of that Remotion content inside the composition element that contains it. Provide a UI example to review before coding."

### The mockup (published — review it first)
- **Artifact URL:** https://claude.ai/code/artifact/0c3923a3-7014-40d2-bda4-9cb9545bbf67
- To view/read it from a new session: `WebFetch` that URL. To iterate it: call the `Artifact` tool with `url:` set to that URL (otherwise a new URL is minted). The HTML source lived in the (ephemeral) session scratchpad — treat the artifact as the source of truth; re-author from it if needed.
- **Design shown:** the code lives inside the **Composition node** (the node that already carries `render_mode`) — a collapsible, syntax-highlighted `.tsx` panel with a filename header, line numbers, a Copy button, internal scroll (node never grows unbounded), and a **props strip** showing per-viewer personalization (`name ← viewer.visible_name`). It appears **only when `render_mode === "remotion"`**; other render modes leave the node unchanged.

### PENDING OWNER DECISIONS — these gate the build (get answers before implementing)
1. **Default state** — ship expanded (owner asked to *see* the code) or collapsed-to-a-one-line-summary (keeps dense graphs scannable)?
2. **Props strip** — keep it (shows the personalization binding) or drop it as noise?
3. **Backend scope** — include the persist-source + endpoint work in this ticket or split it out? And endpoint shape preference: dedicated `GET /components/:id/source` **vs.** folding `source` into the existing `GET /god-view/ad-runs/:id`.

### ⚠️ FEASIBILITY BLOCKER — the Remotion source is NOT reachable from the frontend today
This is the crux. The `.tsx` cannot be displayed with current data; a backend piece is required first. Verified facts (repo · file:line):
- **Frontend gets only a bare `component_id` UUID + `render_mode` + flags.** `fetchAdRun(id)` → `GET /god-view/ad-runs/{id}` (`godview-prototype/src/data/api.ts:32`), served by `mras-ops/api/src/godview/ad_runs.py`. The composition SELECT (`ad_runs.py:70-75`) returns `render_mode, status, error_code, error_message, used_*, ad_id, component_id, input_asset_id, output_asset_id` — **it does NOT join `components`/`ads`**, so no `slug`, no `props_schema`, no `base_video`, no `default_props`, no source.
- **The `.tsx` source is dropped on ingest.** `POST /components` (`mras-ops/api/src/main.py:57-69`) forwards `{name, source}` to the render sidecar, then `INSERT INTO components` persists **only** `(name, slug, status, error, props_schema)` — the source string is never stored in Postgres. `components` table (`mras-ops/db/migrations/014_creative.sql:32-37`): `id, name, slug, status, error, props_schema` — **no source/tsx/bundle column**.
- **The only physical copy of the source is on the sidecar's local disk.** `writeComponent()` (`mras-overlays/src/components.ts:31-42`) writes `src/custom/<slug>.tsx` and re-bundles. The sidecar exposes only `POST /render`, `POST /components`, `GET /health` (`mras-overlays/src/server.ts:56-136`) — **no GET returns source or a bundle**. Composition id convention is `comp-<slug>` (`mras-overlays/src/components.ts:71`, `Root.tsx:36-50`).
- **`mras-ops` component reads are metadata-only.** `GET /components` (`main.py:91`) → `id,name,slug,status,error,props_schema,created_at`. There is `POST` and `DELETE /components/{id}` but **no `GET /components/{id}`**.

**Backend prerequisite (two small pieces):**
1. **Persist the source on ingest** — add a `source text` column to `components` (new migration) and store the `.tsx` in the `POST /components` insert (`main.py`). (Alternative: add a sidecar GET route that serves `src/custom/<slug>.tsx` — but persisting in Postgres is cleaner and survives sidecar restarts.)
2. **Expose it to god view** — either a dedicated `GET /components/:id/source` (mras-ops), **or** join `component_id → components/ads` into `GET /god-view/ad-runs/:id` so the response carries `source` (+ `props_schema`, `default_props`, `personalized_field`, `base_video`). Owner decision #3 above.

### Where the UI code goes (frontend)
- **`godview-prototype`** uses `@xyflow/react` **v12.11.2** (`package.json:15`, CSS in `src/main.tsx:4`).
- **The graph is the ad-run detail screen:** `/compositions/:adRunId` → `src/pages/AdDetail.tsx` (`<ReactFlow>` at `:69`, `nodeTypes={{ pipeline: PipelineNode }}` at `:12`; 2-col grid `[1fr_300px]` = flow canvas + right `<Inspector>`). (The `/compositions` list screen `src/pages/CompositionActivity.tsx` is a card grid, NOT the graph.)
- **Nodes/edges are built by `adRunGraph()`** in `src/data/selectors.ts:73-130` — a manual left→right layout: `Trigger(x0) → Decision(x200) → Composition(x420) → Ad Run(x640) → Playback(x860)` + `Viewer Exposure` + satellites `Decision inputs`/`Creative inputs`. **The Composition node is `selectors.ts:101-104`** (currently shows `render_mode, status, error_code, error_message, used_likeness, used_voice_clone`). The `Creative inputs` satellite (`:114-118`) carries `component_id` etc.
- **The node box renderer is `src/components/PipelineNode.tsx`** (StatusDot + label + `sub` line). The Remotion source panel would be a variant of this node (or a new node type) rendered when `render_mode === "remotion"` and source is present.
- **Types:** `render_mode` enum incl. `"remotion"` at `src/data/types.ts:13`; `composition_run` shape at `src/data/apiTypes.ts:57`.

**Repos in play:** `godview-prototype` (React frontend), `mras-ops` (FastAPI + Postgres migrations), `mras-overlays` (Remotion render sidecar).

---

## Process to follow (non-negotiables — the twice-proven pipeline)
Same process used for Flat Map v3/v4 and the nav collapse:
1. **Brainstorm/spec → outside review → plans → gate-check → build via `superpowers:subagent-driven-development`** (fresh implementer per task + per-task spec+quality review + whole-branch review) **→ live Playwright E2E → a dedicated design-review pass (owner-locked gate) → merge → close-out** (SESSION_LOG + memory + follow-up issues).
2. **All git via the `git-flow-manager` subagent** — the main agent must NOT run raw `git`/`gh` (a session-wide guard blocks it). **Merge commits, not squash** (preserves red→green history).
3. **TDD red→green**, and **commit the failing test separately from the impl** so red→green shows in git history.
4. **Subagent workspace discipline:** every implementer starts with `cd <worktree> && pwd`; the bare repo checkout is READ-ONLY reference; controller existence-checks files before commit. One worktree per branch under `.claude/worktrees/`.
5. **Implementers never run git** — they write code + tests, verify, leave uncommitted; `git-flow-manager` commits the red→green pairs (stage test file, then impl file).
6. **Tailwind gotcha:** arbitrary-value classes (`w-[64px]`, `lg:grid-cols-[…]`) must be FULL LITERAL strings selected by a ternary — never string-interpolated (JIT won't generate the CSS).
7. **Node 25 gotcha:** the global `localStorage` is non-functional and shadows jsdom's — persistence unit tests need `vi.stubGlobal`; verify real persistence via E2E.
8. **Secret handling:** the Mapbox token (for /map + /globe E2E) goes ONLY in a gitignored `.env` in the worktree — never commit/log/put in a PR or SESSION_LOG; discard it at close-out. (The Remotion-node feature is on the /compositions screen and does NOT need the token, but other pages/E2E might.)

---

## How to run / E2E
- **Frontend:** `npx vite` in the `godview-prototype` worktree (or `--port <n> --strictPort`). The GOD VIEW app serves all pages incl. `/compositions` and `/compositions/:id`.
- **Backend data:** `mras-ops` ops-api on **:8080** provides ad-run data (`GET /god-view/ad-runs/:id`). See `docs/SESSION_LOG.md` → "Operational Reference" for the full stack (ports: vision 8001, composer 8002, ops-api 8080, ops-frontend 3000, postgres 5432, qdrant 6333; `docker compose up` from `mras-ops/`; native vision via `run-vision-native.sh`).
- **E2E:** drive via the Playwright MCP tools (the browser is the user's real Chrome — only touch the app tab). Prefer a clean dev-server restart before an E2E to avoid HMR-warmup artifacts.

---

## Source-of-truth pointers
- **`docs/SESSION_LOG.md`** — cross-repo journal; newest entries are `2026-07-16 (b)` (nav collapse) and `2026-07-16` (Flat Map v4). Read top-first every session.
- **SDD ledger** — `minority_report_architecture/.superpowers/sdd/progress.md` (gitignored scratch on disk; granular per-task record of this session incl. all SHAs and the Remotion-node investigation). Recover from it + `git log` if context is lost.
- **v4 plans/specs** — `docs/superpowers/plans/2026-07-14-flatmap-i-map-visual.md`, `…-j-chrome.md`, `…-ij-gate-check.md`; `docs/superpowers/specs/2026-07-14-flatmap-v4-*.md` (now tracked, PR #58).
- **Memory** (`~/.claude/.../memory/MEMORY.md`): `project-flatmap-v4-shipped`, `reference-node25-localstorage-jsdom`, plus the standing process memories.
- **Mockup artifact:** https://claude.ai/code/artifact/0c3923a3-7014-40d2-bda4-9cb9545bbf67

## Open follow-up backlog (godview-prototype issues)
- **#34** Flat Map chrome polish (legend divider, collapsed-rail treatment, globe size-toggle contrast, pill chevron, panel text-vs-icons)
- **#35** a11y: icon-only chrome buttons lack aria-labels
- **#36** bundle: split `iconImages` into url-only + register modules (`[INEFFECTIVE_DYNAMIC_IMPORT]`)
- **#37** world-tier: cluster/offset co-located venue markers
- **#38** test/lint hygiene (localStorage teardown, ModeLegend fast-refresh warning, Plan I call-count flake, `nextFlyZoom` dead code)
- **#39** friendly labels for unnamed devices + building-label edge-clip

---

**First action for the next session:** get the owner's answers to the 3 pending decisions (default state · props strip · backend scope), then spec + plan the feature (frontend node variant + the backend persist-source/endpoint) and execute it through the process above.
