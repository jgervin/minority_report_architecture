# MRAS / AdFace — Project Brief (paste as first message in new sessions)

## Context
- MRAS / "AdFace": vision-triggered **personalized digital ads** (Minority Report style). Camera recognizes/enrolls a face → composer picks ad, synthesizes personalized TTS, assembles a video, pushes to a kiosk display over WebSocket.
- Multi-repo, under `/Users/jn/code/`:
  - `minority_report_architecture` — docs/orchestration hub (this brief, `docs/SESSION_LOG.md`, plans, PRD).
  - `mras-composer` — Python FastAPI + ffmpeg; assembles ads. Image: `python:3.11-slim` + ffmpeg + fonts-dejavu-core, **NO Node**.
  - `mras-overlays` — **NEW** Node/Remotion repo; renders transparent animated overlays. GitHub: `jgervin/mras-overlays` (private).
  - `mras-display` — Electron/React kiosk player (live kiosk; `mras-kiosk` is superseded).
  - `mras-vision` — face recog; runs **native macOS, not Docker** (webcam). `mras-ops` — Docker compose (postgres/qdrant), holds the ad pool `mras-ops/assets`.
- Demoed live; sessions die to reboot/`/clear`. `docs/SESSION_LOG.md` = source of truth: **read it first; prepend a dated entry when done** (cite `repo@sha`).
- Workflow (mandatory): branch/worktree per task; **TDD red→green, commit the failing test SEPARATELY from the impl** (red→green must show in git history — user preference); one PR per task; commit trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Don't self-merge to `main` without explicit user OK.

## Requirements (overlay feature)
- Advertisers add **animated text/elements** to ad videos — CapCut/After-Effects style (warp/turbulence/kinetic typography), parameterized via JSON.
- Phase 0.5 (DONE): preset templates + JSON; **host-CLI preview only**; transparent overlays composited via ffmpeg.
- CLI reads a **random base from the kiosk pool** (`mras-ops/assets`, mixed res), writes clips to **`~/Desktop/mras-clips`** (NOT the pool, never pushed to kiosk).

## Architecture decisions
- Engine = **Remotion** (React + headless Chromium), JSON props. (Not three.js; Remotion can host `@remotion/three` later.)
- `mras-overlays` is a separate Node repo so the composer image stays Node-free.
- Transparency = **ProRes 4444 `.mov`** and **MUST pass `--pixel-format=yuva444p10le`** — ProRes 4444 alone emits no alpha (→ overlay composites as a black box). WebM/VP9-alpha + PNG-seq are documented fallbacks.
- Overlay dims/fps/duration **derived per base clip** via ffprobe → props → Remotion `calculateMetadata`. Never hardcode (pool clips are 854×480 AND 1280×720, all 24fps).
- ffmpeg composite per overlay: `setpts=PTS+<s>/TB` then `overlay=0:0:eof_action=pass:enable='between(t,<s>,<e>)'`, chained `[v0]→[v1]…`. `eof_action=pass` is **required** (else base freezes on last overlay frame).
- ffmpeg input order: base `0`, audio inserts `1..N`, overlay clips `N+1..` (audio graph untouched).
- `assemble(base_video, audio_inserts:list[(Path,int)], trigger_id, overlay_text=None, overlay_inserts:list[(Path,start_ms,end_ms)]|None)`.
- `OverlaySpec` (frozen dataclass): `text, start_ms, duration_ms→end_ms, preset∈{fade,turbulence-warp}, color, position∈{top,center,bottom}, font_size, font_family`. `--overlay` JSON is **camelCase**; `--draw MS TEXT` = back-compat → default `fade`.
- Render cmd (`render_overlay`, injectable runner, run OUTSIDE the assemble semaphore, dir from env `MRAS_OVERLAYS_DIR` default `/Users/jn/code/mras-overlays`):
  `npx remotion render src/index.ts Overlay <out.mov> --props=<file> --codec=prores --prores-profile=4444 --pixel-format=yuva444p10le`
- Fonts: `@remotion/google-fonts` Inter, `loadFont("normal",{weights:["800"],subsets:["latin"]})` (deterministic; default loadFont = ~126 net requests/render).
- Tests: capture `asyncio.create_subprocess_exec` args, assert `filter_complex` substrings; injectable runners; `tmp_path`/`caplog`. `pytest.ini`: `asyncio_mode=auto`, `addopts=-m "not slow"`; E2E marked `slow` (host-only).

## Current implementation state
- **Phase 0.5 M0/M1/M2 DONE, merged to `main`, verified E2E.** 52 unit + 1 slow E2E green.
- `mras-composer` main: `src/overlay/{probe,spec,renderer}.py`, `assembler.py` `_video_filter`, `cli.py` `--overlay`/`--draw`.
  - probe_video → VideoMeta(width,height,fps,duration_ms). spec.parse_overlay_specs. renderer.render_overlay. _video_filter (multi-overlay chaining). build_overlay_inserts (clamps end_ms to base duration).
- `mras-overlays` main: `Overlay` comp (calculateMetadata), presets `fade` + `turbulence-warp` (animated feTurbulence+feDisplacementMap), transparent bg, Inter, PNG frames. `tsc --noEmit` clean.
- Composer prod path (`/trigger`): select → synthesize(TTS: ElevenLabs→Gemini fallback) → assemble → WS "play". Serves `/assets` (pool), `/media` (output volume), `/playlist`. **Overlays NOT wired into `/trigger` yet** (CLI-only).
- CLI: `python -m src.cli --say MS TEXT [--overlay JSON] [--draw MS TEXT] [--video P|--assets D] [--out P|--out-dir D] [--open]`. `--say` uses macOS `say` (dev/preview voice, NOT prod ElevenLabs/Gemini).
- Demos: `~/Desktop/mras-clips/{m0_overlay_demo,m1_turbulence_warp_demo,m2_two_overlays_demo}.mp4`.
- Plan: `docs/superpowers/plans/2026-06-08-phase-0.5-overlays.md`.

## Known issues
- ProRes 4444 needs explicit `--pixel-format=yuva444p10le` for alpha (handled; keep it).
- Render latency = seconds→tens of seconds (headless Chromium) — **too slow for live per-trigger** (drives M3).
- CLI requires ≥1 `--say` even for overlay-only clips (audio-path coupling; minor).
- Arbitrary advertiser fonts not supported — Inter only.
- macOS `say` ≠ prod voice.

## Open questions
- Caching key design: what counts as "static" (per-ad, render once) vs "personalized" (per-viewer, re-render)?
- Deterministic arbitrary-font support.
- Should overlay-only (no `--say`) be allowed?
- `mras-overlays` PR flow (currently pushed straight to `main`, no PR).

## Next steps (future milestones)
### M3 — Live-kiosk render sidecar + caching
- Goal: overlays on the **live kiosk** at acceptable latency (today: CLI preview only; composer image has no Node).
- Run Remotion as a **separate Node container/"sidecar"** exposing e.g. `POST /render {props} → transparent .mov`; composer calls it over HTTP and composites with existing ffmpeg path (Python image stays Node-free).
- **Caching**: hash overlay spec (text+preset+style+base dims) → static/per-ad overlays render once & reuse; personalized/per-viewer text re-renders per trigger (pre-render for enrolled visitors; warm server / pre-bundled serve URL / `@remotion/lambda` for burst).
- Wire into `/trigger` flow + kiosk. Reuse `assemble(... overlay_inserts=...)` unchanged; only overlay *source* changes (HTTP vs local render).

### M4 — Full custom-code authoring
- Goal: advertisers supply **their own Remotion/React components** for arbitrary animation (beyond the fixed presets).
- Hard parts: **running untrusted code safely** (sandbox/isolation, resource limits, no fs/net/exfil), authoring/upload/preview UX, output validation guardrails (dims/duration/transparency conform).
- Security-heavy; its own plan.
