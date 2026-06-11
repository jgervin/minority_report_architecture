# MRAS / AdFace — Handoff (M3/M4/M5 done; Phase 1 next)

Paste-able context for a new session. Read `docs/SESSION_LOG.md` (top entries) + `CLAUDE_PROJECT_BRIEF.md`
for full detail; this is the consolidated state as of 2026-06-09 (M5 + the mras-ops review fixes and
git-governance work have since merged — see the SESSION_LOG top entries).

**Next phase:** `docs/superpowers/plans/2026-06-11-phase-1-venue-readiness.md` — multi-camera venue
readiness (Redis cooldown, P1→P2 backpressure, kiosk watchdog, AWS GPU profile), consolidated from
`TODOS.md` TODO-1..4. Execute it ticket-by-ticket per the plan's closing checklist.

## What MRAS is
Vision-triggered **personalized digital ads** (Minority Report style). Camera recognizes/enrolls a face →
composer picks an ad, synthesizes personalized TTS, **renders an animated overlay**, composites a video,
and pushes it to a kiosk over WebSocket.

## Repos (under `/Users/jn/code/`)
- `minority_report_architecture` — docs/orchestration hub (SESSION_LOG, specs, plans, this file).
- `mras-composer` — Python FastAPI + ffmpeg. `/trigger`, `/preview`, assembles clips. Node-free image.
- `mras-overlays` — Node/Remotion sidecar. Renders transparent ProRes-4444 overlays over HTTP.
- `mras-ops` — Docker compose (postgres, qdrant, composer, ops-api, ops-frontend) + the ad pool `assets/`.
- `mras-vision` — face recognition; runs **native macOS** (webcam), not Docker.
- `mras-display` — Electron kiosk player (the live screen).

## M3 — Live-kiosk overlay render sidecar (DONE, merged)
- `mras-overlays` is a **warm HTTP render sidecar** (compose service): `POST /render {compositionId, props}`
  → transparent `.mov`. Bundles once + reuses one headless Chromium. ProRes 4444 + `imageFormat:png` +
  `pixelFormat:yuva444p10le` (alpha). Runs `tsx` directly (not `npm start`) + compose `init:true` so
  SIGTERM closes Chromium cleanly — it stops with `docker compose down`, not a separate process.
- `mras-composer` `/trigger`: identified viewer → synthesize TTS → render the name overlay via the
  sidecar → `assemble(overlay_inserts=…)` → WS "play". No caching (renders fresh; warm ≈ 1–3s).
- Kiosk burns nothing client-side; it just plays the composited mp4 URL.

## M4 — Custom-component ad authoring (DONE, merged)
Advertisers upload their own Remotion components and bind them to ads.
- **Sidecar**: `POST /components {name, source}` writes `src/custom/<slug>.tsx`, **hot re-bundles**,
  registers composition **`comp-<slug>`** (hyphen — Remotion forbids `_`). Applies each component's
  **zod schema defaults** at render (`Root` calculateMetadata + render with `composition.props`) — else
  omitted props are `undefined` → NaN → blank.
- **DB** (postgres): `components` (uuid, slug, status, props_schema) + `ads` (uuid, base_video,
  component_id FK, default_props, personalized_field, is_active).
- **ops-api**: `POST /components` (multipart → proxy to sidecar → persist, returns the **DB uuid** as
  `id`), `GET /components`, `POST/GET/PATCH /ads`.
- **composer**: `POST /preview` (render a component over a base, **spans the full clip** by default,
  trims/validates base path, graceful errors) → mp4 URL; `/trigger` selects the active custom ad for an
  identified viewer and renders it personalized.
- **ops-frontend** (`http://localhost:3000`): **Authoring** + **Activity Feed** tabs; "?" help panel;
  upload component; **base video = dropdown** of the pool (no free text); editable Props (JSON);
  **Create Ad auto-renders the finished ad and pops it up** (+ per-ad ▶ preview).
- **11 example overlays** in `/Users/jn/code/mras-overlays/examples/` (FallingSnow, Typewriter,
  LightLeak, ConfettiBurst, RisingBubbles, PeekerCharacter, FishSwim, LowerThirdBanner, ShootingStars,
  Fireflies, KineticText) + HelloName. Dependency-free, transparent overlays.

## How to run / test
- Start stack: `cd /Users/jn/code/mras-ops && docker compose up -d --build` (vision is native, separate).
- Migrations on an existing DB volume don't auto-apply: `docker compose exec -T postgres psql -U mras -d mras -f /docker-entrypoint-initdb.d/002_custom_components.sql`.
- Authoring: open `http://localhost:3000` → Authoring tab → upload a component (e.g.
  `/Users/jn/code/mras-overlays/examples/FallingSnow.tsx`) → create an ad (base from dropdown, Active) →
  the finished ad pops up. Props default to spanning the whole clip; use a bright color to see effects.
- **Generated + preview clips land in `/Users/jn/code/mras-ops/output/`** (host bind-mount, openable in
  Finder) and are served at `http://localhost:8002/media/<name>.mp4`.
- Live trigger without camera: seed an identity + `POST http://localhost:8002/trigger`
  `{"trigger_id":"t1","uuid":"<id>","is_new_visitor":false}` (see SESSION_LOG for the psql seed).
- Tests: composer `python -m pytest`; sidecar `npx tsx --test`; frontend `cd frontend && npm test`.

## Conventions (CLAUDE.md)
Branch/worktree per task; **TDD red→green, failing test committed separately**; one PR per task; commit
trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; **no self-merge to main without the
user's OK**; **§0: always reference files by absolute path**; keep `docs/SESSION_LOG.md` current.

## Open work
- **M5 — Authoring props-display** (spec: `docs/superpowers/specs/2026-06-09-m5-props-display.md`):
  auto-render a component's prop fields (labeled, default-filled) at upload via `zod-to-json-schema`,
  instead of a blank JSON box. Blocked-investigation noted: a component's named `schema` export isn't
  exposed via runtime dynamic import — needs build/upload-time extraction. **Not yet built.**
- Deferred from earlier: true-3D (three.js) overlay pack; sidecar sandbox/isolation for untrusted code
  (the going-live security blocker — filed as GitHub issues); rotation/targeting beyond `is_active`.
