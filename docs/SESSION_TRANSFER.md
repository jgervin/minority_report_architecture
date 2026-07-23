# Session Transfer — MRAS / AdFace "God View"

**Written:** 2026-07-23. Snapshot handoff for starting a fresh agent session. For the full
blow-by-blow history and run reference, read `docs/SESSION_LOG.md` (newest-first journal) — this
file is the curated overview + the live TODO split (agent side vs. owner/hosting side).

---

## 0. New-session bootstrap (do this first)

1. Read, in order: **this file**, `docs/SESSION_LOG.md` (top-to-bottom), `TODOS.md`,
   `adface_architecture.md`.
2. Read `CLAUDE.md` — it is binding. Key rules: **absolute file paths everywhere**; **never run
   raw git/gh as the main agent — delegate to the `git-flow-manager` subagent** (prefix
   `CLAUDE_GIT_OK=1`); **one git worktree per ticket**; TDD red→green in git history; **verify a
   dev server responds (HTTP 200) before telling the owner to open a URL**; merge commits, not
   squash.
3. Recent work uses the Superpowers flow: `brainstorming` → `writing-plans` →
   `subagent-driven-development` (fresh implementer per task → per-task spec+quality review → live
   Playwright E2E gate → whole-branch review → merge → close-out). Specs/plans live in
   `docs/superpowers/specs|plans/`.

---

## 1. What the project is

**MRAS / AdFace** is a live-demo "Minority Report"-style personalized-advertising pipeline:
cameras perceive people → a composer generates a personalized ad (Remotion video) → displays play
it. **God View** is the operator/monitoring layer that visualizes the whole fleet (orgs → venues →
systems → cameras/displays) and live ad-run activity.

### The repos (5 MRAS + 1 standalone UI)

| Repo | Role | Notes |
|---|---|---|
| `minority_report_architecture` | **Source of truth** for docs/orchestration (this repo) | `docs/SESSION_LOG.md`, specs/plans, architecture. No app runtime. |
| `mras-vision` | Perception (faces/people) | **Runs natively on macOS** (webcam can't pass into Docker), py3.9 venv, port **8001**. Start via `mras-ops/run-vision-native.sh` (CAM_INDEX=0 = built-in cam). Must launch from the owner's own terminal for the macOS camera permission prompt. |
| `mras-composer` | Ad composition (Remotion) | port **8002** |
| `mras-display` | Display/renderer | |
| `mras-ops` | Ops backend + God View schema/DB | **ops-api 8080**, ops-frontend **3000**, postgres **5432**, qdrant **6333**. `docker compose up` (from `mras-ops/`) brings up postgres, qdrant, composer, ops-api, ops-frontend (vision is excluded — native). |
| **`godview-prototype`** | **Standalone God View UI (the focus of recent work)** | Vite + React 19 SPA. NOT one of the 5 MRAS repos — a separate repo at `/Users/jn/code/godview-prototype`. shadcn UI + `@xyflow` graphs + a 3D globe (globe.gl/three) and a flat map (Mapbox GL). Talks to the live `mras-ops` read API. |

> Two "God View" frontends exist: the in-MRAS `mras-ops` ops-frontend (port 3000) and the newer
> standalone **`godview-prototype`** (Vite, port 5173). **All recent work is in `godview-prototype`.**

---

## 2. Current state (repo heads @ 2026-07-23)

- `godview-prototype` **main @ `ebb5673`** — clean, deployed nowhere yet (local dev only).
- `minority_report_architecture` **main @ `8cc45fb`** — docs/journal current.

### What shipped recently (the `/map` + `/globe` node arc — all merged, all live-E2E'd)

`godview-prototype` was brought to a consistent node-graph aesthetic across both views:

- **`/map` (flat Mapbox map) rebuild** (PR #48 + follow-ups #52): venues + devices render as **white
  rounded-square icon nodes** (lucide icon + label + status dot) via Mapbox HTML markers, with
  **green (active) / gray (idle)** connector edges; standard map interaction (hover→pointer,
  single-click→center+panel, double-click→expand device tree, chevron→collapse, zoom-driven
  detail); legend uses the same lucide icons; dead icon/glyph code removed; device (camera/display)
  labels appear only as you zoom in (system/venue labels always on).
- **`/globe` (3D globe) restyle** (PR #54): same **white-square markers** for world venue/cluster +
  drill-in system/camera/display nodes (replacing green sphere meshes); clusters get a bright
  status-colored ring + venue-count badge; drill-in connectors recolored green/gray; world org
  arcs kept. White squares are **opt-in** via a `nodeStyle="markers"` prop so the `/map` corner
  mini-globe (a shared `GlobeCanvas`) keeps its green dots.
- **Panels-always-on-top** (PR #55): `isolate` (isolation) on the map/globe canvas mounts +
  opaque docked panel, so node markers/edges never draw over the right side panel.
- **QA fixes** (PR #56, #57): `/globe` expand on **double-click** (not auto-expand);
  single-click centers + opens the panel. `/map` connector edges no longer orphan on zoom-out.
  **Double-click detection** rewritten to key off two `click` events (the native `dblclick` never
  fires on globe.gl's per-frame-reprojected markers) + stop idle auto-rotation on press.

Full suite 411/411, lint 0, tsc clean at `ebb5673`. Every change was live-E2E-verified with
Playwright on the real WebGL globe / Mapbox map.

---

## 3. How to run it (local dev)

**God View UI (`godview-prototype`):**
```
cd /Users/jn/code/godview-prototype
cp .env.example .env      # then fill in the two vars below
npm install
npm run dev               # Vite dev server on http://localhost:5173  (routes: /, /globe, /map, /fleet, ...)
```
Required env (`.env`, gitignored):
- `VITE_OPS_API_URL` — base URL of the `mras-ops` read API. Defaults to `http://localhost:8080` when unset.
- `VITE_MAPBOX_TOKEN` — Mapbox GL token for `/map`. When unset, `/map` shows the rail + corner
  globe + a "map unavailable" panel (the Mapbox basemap never loads, zero bytes fetched). `/globe`
  needs no token.

**Backend (so the UI has data):** from `mras-ops/` run `docker compose up` (postgres, qdrant,
composer, ops-api, ops-frontend). Vision is native: `mras-ops/run-vision-native.sh` from a real
terminal. NOTE: the standalone UI needs ops-api **migration 025 (screen_groups)** applied.

Scripts: `npm run build` (`tsc -b && vite build` → `dist/`), `npm run lint` (oxlint),
`npm run test` (vitest), `npm run preview`.

---

## 4. TODOs — Agent / development side

These are code/product tasks a coding agent would pick up. Nothing is blocking; the node arc is
complete. Open `godview-prototype` GitHub issues, triaged:

### Likely obsolete — verify against current code, then close
- **#28** "device NodePanel unreachable — building glyphs have no click handler" → **fixed** by the
  `/map` rebuild (#48): nodes are DOM markers with real click handlers → NodePanel.
- **#29** "per-type glyph icons computed but not rendered" → **superseded**: glyphs replaced by
  white-square lucide markers; glyph props deleted in #51.
- **#36** "split iconImages into url-only + register modules" → **obsolete**: `iconImages` deleted in #51.

### Still-open, worth doing (grouped)
- **Map interaction/perf:** #30 (memoize anchor — building `setData` re-fires every render), #31
  (staged flyTo takes 30–45s to reach building tier — slow), #25 (verify corner-globe `paused` GPU
  savings on TV hardware).
- **Map world-tier density:** #26 / #37 (co-located / geographically-clustered venue markers
  overlap at world tier — cluster/offset them). Partially mitigated (labels zoom-gated) but the
  marker-offset request stands.
- **Map polish/hygiene/a11y:** #34 (chrome polish), #35 (icon-only buttons need aria-labels), #38
  (test/lint hygiene), #39 (friendly labels for unnamed devices + building-label edge-clip).
- **Globe:** #18 (through-globe clicks can hit far-side venue hitboxes — camera teleport; re-verify
  now that markers use visibility-occlusion + dblclick stops rotation), #16 (onArcClick → highlight
  the arc's org), #20 (damp pov-driven re-renders during idle auto-rotate), #19 (scope the
  `three.d.ts` wildcard typing / lint-ban static three imports), #14 (ring-datum identity, deep-link
  sync, polish).
- **Other pages:** #10 (Fleet page — 4 review minors), #12 (mobile nav a11y + responsive nits), #5
  (SystemsLogs double-fetches on mount), #42 (Remotion source panel polish).

### Cross-repo / MRAS backend follow-ups (from SESSION_LOG)
- `mras-vision#38` — RTSP camera-source gap (needed for any non-local/headless camera).
- `mras-vision#23`, `mras-composer#29`, `mras-ops#39` — earlier God-View E2E follow-ups.
- AWS GPU compose profile for vision (mras-ops #52) is **dry-run-verified only** (no AWS account).

**Recommended next agent focus (if asked "what next"):** the map perf pair #30 + #31 (re-render
churn + slow staged fly), then world-tier marker overlap #37/#26. All are self-contained.

---

## 5. TODOs — Owner / hosting side (your list)

The whole system currently runs **locally only** (dev server + docker compose). To host it:

### A. God View UI (`godview-prototype`) — the easy part (static SPA)
1. **Pick a static host** — it builds to a static `dist/` (Vite SPA), so Vercel / Netlify /
   Cloudflare Pages / (S3 + CloudFront) all work. Build cmd `npm run build`, output dir `dist/`,
   SPA rewrite (all routes → `/index.html`). **No CI/CD or deploy config exists yet** (no
   vercel.json/netlify.toml/Dockerfile/GitHub Actions) — you or the agent must add it.
2. **Set the two build-time env vars** on the host: `VITE_OPS_API_URL` (must point at a
   *publicly reachable* ops-api, not localhost) and `VITE_MAPBOX_TOKEN`.

### B. Mapbox
3. **Create a Mapbox account** (free tier 50k map loads/mo) and generate a token →
   `VITE_MAPBOX_TOKEN`. **Restrict the token by URL** to your deployed domain (Mapbox token
   URL-allowlist) so it can't be reused elsewhere. (Note: Vite bakes `VITE_*` into the client
   bundle — the token is public by design; the URL restriction is the protection.)

### C. Backend (`mras-ops` API + data stores) — the bigger lift
4. **Host the ops-api** (port 8080) somewhere with a public URL (container host: Fly / Render /
   Railway / ECS / a VM). The UI hits it directly from the browser, so:
5. **CORS** — ops-api must allow the deployed frontend origin (currently assumes localhost).
6. **Auth** — there's no auth in front of the read API today; a public deployment needs at least a
   gateway/token or IP allowlist before exposing venue/fleet data.
7. **Managed Postgres** (RDS / Neon / Supabase) + **Qdrant** (Qdrant Cloud or self-host); run all
   migrations, **including 025 (screen_groups)** which the standalone UI depends on.
8. **Composer** (8002, Remotion rendering) — needs hosting too if live ad-runs are in the demo.

### D. Vision / camera
9. **Vision needs a camera source.** Native macOS webcam works only on a Mac you control; for a
   hosted/headless demo you need the **RTSP path (blocked on `mras-vision#38`)** or the **AWS GPU
   profile** (exists but dry-run-only — no AWS account yet, Linux TF wheels lack CUDA per
   SESSION_LOG). Decide the camera story before promising a live hosted demo.

### E. Nice-to-have
10. **CI** — add GitHub Actions to `godview-prototype` (build + `npm run test` + lint on PR, deploy
    on merge to main). None exists today.

**Minimum viable hosted demo (cheapest path):** static-host the UI (A) with a Mapbox token (B),
pointed at an ops-api you expose via a tunnel or small VM (C4–C7) seeded with demo data — camera
(D) can stay local/mocked initially.

---

## 6. Gotchas the next agent must know (hard-won this session)

- **jsdom can't run Mapbox or globe.gl** (WebGL/token guards early-return) → marker/click/zoom/edge
  behavior is **E2E-only**; TDD only the pure selectors. Live E2E needs the token in a gitignored
  worktree `.env` (copy from `/Users/jn/code/godview-prototype/.env`; discard at close-out).
- **Never depend on the native `dblclick` for globe.gl/Mapbox HTML markers** — they're reprojected
  every frame, so the browser doesn't synthesize `dblclick` on them. Detect it from two `click`
  events; stop `controls().autoRotate` on `mousedown` so the target holds still.
- **Verify pointer interactions via the real event path** — dispatching a synthetic `dblclick` in a
  test fires the listener directly and *hides* the native-delivery bug (this exact false-pass
  happened this session).
- **HTML-marker React roots must defer `root.unmount()`** via `queueMicrotask` (React 19 "unmount
  while rendering" under marker churn), and be unmounted on removal, on mode-switch clear, AND on
  dispose.
- **A "clear/reset" side effect must not be gated on a transient readiness flag** (`isStyleLoaded`)
  unless re-applied — that caused the `/map` orphaned-edges bug.
- **`GlobeCanvas` is shared** by `/globe` AND the `/map` corner mini-globe — check every call site
  before restyling it (the `nodeStyle` opt-in exists for exactly this reason).
- **Don't fight a dynamic marker z-index with a bigger fixed panel z-index** — `isolation: isolate`
  on the canvas mount is the value-independent fix (panels-always-on-top).
- **Dev-server hygiene:** stale Vite servers squat ports across worktree churn — kill by port and
  verify HTTP 200 before sharing a URL. Run E2E on a *different* port than the owner's QA server so
  you don't disrupt their session.
- **Subagent workspace discipline:** implementers drift to the bare repo path — always `cd` into
  the assigned worktree + `pwd` before editing; never edit `/Users/jn/code/godview-prototype/src`
  directly when a worktree is in play.

---

## 7. Live QA server (as of this handoff)

A Vite dev server is/was running on **http://localhost:5173/** from `godview-prototype` main
`ebb5673` for owner QA (routes `/globe`, `/map`). If it's gone, restart with
`cd /Users/jn/code/godview-prototype && npm run dev -- --port 5173`. Remote control via Telegram
was enabled this session (the owner can message the agent from their phone).
