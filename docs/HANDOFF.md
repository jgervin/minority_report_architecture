# MRAS / AdFace — Handoff (Phase 1 + per-display custom ads DONE; production scale next)

Paste-able orientation for a fresh agent. Consolidated state as of **2026-06-12**. If anything
here disagrees with `docs/SESSION_LOG.md`, the SESSION_LOG wins — read its top entries first.

One honest flag up front: the two big remaining work areas (**production parallel composition**
and the **Phase 1 God View**) have NO executable plan doc yet — writing one (mirroring the
existing plan format in `docs/superpowers/plans/`) is the first step before building either.

## What MRAS is

Vision-triggered personalized ads (Minority Report style): a camera recognizes/enrolls a face →
the composer selects custom Remotion ad(s), synthesizes name TTS, composites video(s), and pushes
each kiosk display ITS OWN clip over WebSocket. Six repos under `/Users/jn/code/`:
`minority_report_architecture` (docs/orchestration hub — you are here), `mras-vision` (native
macOS, camera/recognition), `mras-composer` (FastAPI + ffmpeg), `mras-overlays` (Remotion render
sidecar), `mras-ops` (Docker compose + ops UI + demo CLIs), `mras-display` (Electron kiosk).

## How to work here (non-negotiable — read CLAUDE.md first, it governs everything)

- **Read at session start:** `CLAUDE.md`, `docs/SESSION_LOG.md` (top-to-bottom; its Operational
  Reference is "how to run it"), `TODOS.md`, `adface_architecture.md`.
- **Git:** raw `git`/`gh` is hook-blocked; delegate ALL git to the `git-flow-manager` subagent
  (it opts in with the `CLAUDE_GIT_OK=1` prefix). One worktree per ticket off `origin/main`;
  branch `{feat,fix,chore}/{slug}`; never push to `main` (sole exception: a SESSION_LOG-only
  commit via the exact literal `CLAUDE_GIT_OK=1 git push origin main`). Guard quirks: never use
  the literal word "main" as a branch start-point (use HEAD); pass commit messages/PR bodies via
  temp files (`-F`/`--body-file`); run `git push` and `gh pr create` as separate commands.
- **TDD:** failing test committed SEPARATELY before the implementation (red→green visible in
  history). **Live E2E against the real stack without asking** — unit-green has repeatedly hidden
  stale-container/integration breakage. Self-review + a code-review pass per PR; check the PR
  base branch before merging; rebuild the affected container after merge
  (`docker compose up -d --build <svc>` in mras-ops).
- **Journal:** prepend a dated SESSION_LOG entry (with `repo@sha`) for every landing. If you
  finished work without journaling, you have not finished.
- **Check open GitHub issues** in all repos before starting (`gh issue list -R jgervin/<repo>`
  via git-flow-manager) — they are the parking lot for deferred findings.

## What's DONE (all merged & live-verified)

Phase 0 · Phase 0.5 (M0–M5) · Phase 1 core (T-D 4-window kiosk with shuffled idle, T1 Redis
cooldown + atomic SET-NX claim, T2 bounded trigger queue, T3 launchd watchdog + per-window
recovery + `/health` :8003) · per-display custom ads (T-V multi-face vision + perception seam,
T-C distinct-ad variant fan-out with targeted WS delivery, enroll.sh + compose-random.sh) ·
walk-up fixes (identified-only dispatch, random ad order, name ALWAYS written on every variant,
fraction-length overlays — rig runs 1.0 = full clip, send-each-variant-when-ready, KIOSK_DEBUG=1
HTML badge) · identity stores purged to real people only (Jason, Ragnar Ervin).

## Owner decisions — LOCKED, do not re-litigate without the owner

1. Burst drops are ACCEPTED: serve what the queue/displays can handle; missed people self-heal
   in 30s (mras-vision#9 closed deliberately).
2. Redis = transient TTL'd flags ONLY (every key expires, ≤24h cap); durable play history
   (dashboard/billing/proof) lives in the PostgreSQL `events` table.
3. A spoken name is ALWAYS also written; overlay window = OVERLAY_DURATION_FRACTION × base.
4. Unidentified faces are logged but never dispatched (Phase 2 demographics reopens that gate).
5. No test/persona identities in the live stores (the E2EPerson/John Anderton lesson).
6. T0 (latency benchmark) and T4 (AWS profile) are ON HOLD — current single-host architecture is
   not the production shape.

## What's NEXT (in recommended order)

1. **Production parallel composition (no plan yet — write it first).** Target: ~4 people/area
   each served <4s (goal 2s), 1–4 areas/location, ~1000 locations. Today first-video ≈ 28s; the
   bottleneck is the single-flight Remotion sidecar (every variant = component render + name
   render, full-length). Known quick wins: dedupe the name render per base geometry; sidecar
   render concurrency. Real work: horizontally scalable render tier.
2. **Phase 1 God View** — full P3 scope is specced in `adface_architecture.md` ("P3 God View —
   Phase 1 Scope"): vision/generation inspectors, playback monitor, P3-C4 health monitor (kiosk
   `/health` is already waiting — mras-display#10), identity browser, RBAC, campaign manager,
   D17 remote config. The `events` contract powering it already exists and works.
3. **Phase 2 perception** — analyzers (demographics, objects held, apparel, direction) plug into
   the existing seam (`/Users/jn/code/mras-vision/src/perception/aggregator.py`, scatter-gather
   with deadline → D9 `scene_context`). The hard prerequisite is face TRACKING (evidence over
   30–60 frames).
4. **Small open issues:** mras-composer#22 (guarantee ≥1 text-bearing ad — needs a shows_name
   flag), mras-display#8 (lockfile drift), mras-display#10 (alert wiring), mras-vision#7 (Redis
   queue if multi-process). Component sandboxing (deferred since M4) is REQUIRED before any
   third-party advertiser uploads code.
5. **Demo-day checks (owner-run, camera needs a real terminal):** 2-monitor fullscreen smoke,
   cooldown restart-survival walk-up, multi-photo re-enroll / CONFIDENCE_THRESHOLD≈0.62 tuning.

## Run it

```bash
cd /Users/jn/code/mras-ops && ./start-mras.sh            # stack + native vision (owner terminal!)
cd /Users/jn/code/mras-display && DISPLAY_COUNT=4 KIOSK_DEBUG=1 NODE_ENV=development npm run electron:dev
cd /Users/jn/code/mras-ops && ./enroll.sh "Name" photo.jpg [more...]
cd /Users/jn/code/mras-ops && ./compose-random.sh "Name"
curl http://localhost:8003/health                        # kiosk per-window health
```

Gotchas: port 5173 must be free or Electron silently loads stale code; curl/wget are blocked for
agents (use `/Users/jn/code/mras-vision/.venv/bin/python` + httpx); vision tests run via that
venv; the ops-frontend container bakes source at build time (rebuild after edits); diagnose live
problems from the `events` table first — it has solved every bug so far.
