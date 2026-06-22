# MRAS / AdFace — System Overview & Handoff

**Audience:** systems architect (review) and Director of Product Management (handoff).
**Status date:** 2026-06-21. **Verified against:** live code in all 5 repos (not from memory).

This document is layered: **Part 1** is a plain-language product/exec summary; **Part 2** is the
technical architecture. For the canonical component diagram and the full record of locked engineering
decisions, see the companion `/Users/jn/code/minority_report_architecture/adface_architecture.md`. For
the running engineering journal ("what changed, when, how to run it"), see
`/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md`.

**Build-state legend** (used throughout):
- ✅ **BUILT** — implemented, on `main`, with tests; most also live-verified on the demo rig.
- 🟡 **PARTIAL** — some of the capability exists; scope is called out.
- ⬜ **PLANNED** — designed and/or scoped, not yet built. Preserved here so nothing falls off the roadmap.

---

# Part 1 — Product & Executive Summary

## What MRAS is

MRAS (Minority Report Advertising System; product name **AdFace**) is a **fully-managed digital
out-of-home (DOOH) advertising system**. A camera near a display detects people; if a person is a
**known, opted-in** individual, the system plays a **personalized** video ad that greets them by name;
otherwise it plays a standard ad. The screen is **never dark** — it always runs a rotating standard
playlist and layers personalization on top when it can.

It is a **direct, fully-managed operating model**: the platform operator runs everything (hardware,
enrollment, content, monitoring). In v1.0 there are no advertiser self-service portals and no DSP/SSP
integrations. Full actor/role model: `/Users/jn/code/minority_report_architecture/mras_ecosystem_and_users.md`.

## What it can do today (capabilities)

| Capability | State | What it means for the product |
|---|---|---|
| **Recognize an enrolled person and greet them by name on-screen** | ✅ BUILT | Walk-up → name spoken (TTS) + name rendered as an animated overlay on the ad. |
| **Always-on signage with standard ad rotation** | ✅ BUILT | Displays loop a standard playlist when no one is recognized. |
| **Multi-screen "video wall" choreography** | ✅ BUILT | One recognition drives a timed program across up to ~4 screens (see "temporal orchestration" below). |
| **Custom branded ad templates** | ✅ BUILT | Operators upload a video + a custom animated component and bind it to an ad; the viewer's name is injected at play time. |
| **Scene understanding** (what's in frame, viewer mood, are they watching) | ✅ BUILT (signals captured) / ⬜ used in ad selection | The system detects objects/colors, viewer mood, and attention, and records whether a person watched an ad. **Nothing consumes these for targeting yet** — that's the next product lever. |
| **Self-improving recognition** | ✅ BUILT | Recognition gets more reliable over time by safely (and reversibly) capturing additional high-quality face samples of enrolled people. |
| **Operator activity dashboard** | 🟡 PARTIAL | A live event feed + an ad/component authoring screen exist. The broader "God View" (health monitoring, identity browser, analytics, RBAC admin) is **planned, not built**. |
| **GenAI-generated video ads** | ⬜ PLANNED | Designed (Runway/Kling/etc. path); not built. |
| **Advertiser/brand self-service dashboard** | ⬜ PLANNED | Deferred pending business-model confirmation. |
| **Demographic-tier ads** (age/gender without identity) | ⬜ PLANNED | The 3-tier model reserves this middle tier; not built. |

## The end-to-end experience (today, in plain language)

1. A person walks toward a screen. A camera samples frames continuously.
2. The system matches their face against enrolled people. If it's a **confident match** to an
   opted-in person (and they're not blocklisted), it starts a **personalized program**.
3. Every screen the operator owns first plays a shared **opener** ad with that person's name (spoken
   and shown). When that finishes, the screens split into pairs and play a second round of variants.
   Then the wall returns to the standard rotation.
4. The same person is **not re-served** for a cooldown window (currently 2 minutes on the demo rig), so
   they get one clean program rather than an endless loop.
5. Everything that happened — detection, what played, whether the person watched — is logged and visible
   in the operator's live activity feed.

## What's working vs. pending (honest status)

- **Working & demoed live:** the full recognition → personalization → multi-screen program loop;
  name overlays; custom ad templates; TTS with automatic fallback; the activity feed; self-improving
  enrollment; scene/attention signal capture.
- **Known limitations / pending:**
  - **Recognition is marginal** under demo lighting (confidence clusters right at the threshold).
    Mitigation in progress: re-enroll the demo subject under demo lighting; the self-improving gallery
    also helps over time.
  - **Scene/attention signals aren't used for targeting yet** — they're captured but not consumed.
  - **The "God View" operator console is thin** — feed + authoring only; monitoring/identity/analytics
    panels are planned.
  - **Single camera / single location** — multi-camera and multi-location are planned.
  - **No advertiser-facing surfaces, no GenAI video, no demographic tier** — all planned.
  - **Content note:** ads bound to a name-rendering template currently show the name twice (template +
    overlay). Tracked as TODO-9, deferred.

## Roadmap at a glance

- **Phase 0 (MVP personalization loop):** ✅ complete and live.
- **Phase 0.5 (on-screen name overlays):** ✅ complete (Remotion render sidecar).
- **Phase 1 (venue readiness):** ✅ core complete — shared cooldown, burst handling, kiosk
  auto-restart, multi-display. ⬜ remaining: AWS GPU profile, full God View.
- **Phase 2 (scale & intelligence):** 🟡 perception **part 1** (signal capture) built; ⬜ part 2
  (use signals in ad selection/generation), GenAI video, demographic tier, multi-camera, multi-location.
- **Deferred:** brand self-service dashboard (P4) pending business model.

Deferred/again-planned work items live in `/Users/jn/code/minority_report_architecture/TODOS.md`
(TODO-2 AWS GPU, TODO-7 use perception signals, TODO-8 multi-camera, TODO-9 double-name, etc.).

---

# Part 2 — Technical Architecture

## System shape

MRAS is **5 services across 5 repos** plus shared infrastructure. The original design names two
"pillars": **P1 (vision/identity)** and **P2 (composition/delivery)**, with **P3 (God View)** as the
operator console. The services communicate over **direct HTTP/WebSocket — there is no event bus**
(a deliberate decision; see `adface_architecture.md` D1).

| Service (repo) | Role | Stack | Port | How it runs |
|---|---|---|---|---|
| **mras-vision** | P1 — face detection, identity resolution, perception, enrollment; fires triggers | Python / FastAPI; DeepFace (ArcFace) on MPS | **8001** | **Native on macOS** (the camera can't be passed into Docker); compose service is behind a `docker-vision` profile and excluded by default |
| **mras-composer** | P2 — ad selection, TTS, ffmpeg assembly, **temporal orchestration**, serves clips + WS to kiosks | Python / FastAPI; ffmpeg | **8002** | Docker |
| **mras-display** | The Electron kiosk — multi-window signage, plays what the composer sends | Electron 31 + React 18 + Vite | renderer **5173**, health **8003** | Native (Electron); `npm run electron:dev` |
| **mras-ops** | God View — `api/` (FastAPI) + `frontend/` (React/Vite) + DB migrations | Python + React | api **8080**, frontend **3000** | Docker |
| **mras-overlays** | Remotion render sidecar — renders the animated name overlay / custom components to transparent video | Node 22 + TypeScript + Remotion 4 + React 19 | **3000** (internal only) | Docker |

**Shared infrastructure (Docker):** PostgreSQL 16 (`5432`), Qdrant 1.12.6 vector DB (`6333`),
Redis 7 (`6379`, loopback-only, transient cooldown coordination — no persistence).

**One-command startup:** `mras-ops/start-mras.sh` (starts Docker + the compose stack, then native
vision in the foreground). Kiosk is a separate terminal: `cd mras-display && npm run electron:dev`.

## End-to-end data flow (current, orchestrated path)

```
Camera → mras-vision (detect → embed → match against Qdrant gallery)
   │  if confident match to opted-in, non-blocklisted person:
   ├─► POST /presence  ──► mras-composer  (who is present, per screen)
   └─► POST /trigger   ──► mras-composer  (this identity, now)
                              │
                              ├─ select ad (3-tier gate; standard short-circuits here)
                              ├─ Orchestrator.on_identify(uuid) → command list
                              ├─ TTS (ElevenLabs → Gemini fallback → silent)
                              ├─ render name overlay  ──► POST mras-overlays /render
                              ├─ ffmpeg assemble (base video + audio + overlay)
                              └─ WS "play" ──► mras-display kiosks (per screen_id)
                                                   │ on clip end:
                                                   └─ WS "clip_ended" ──► composer
                                                          └─ Orchestrator.on_clip_ended → next round
   every event (detection, gaze, composition, playback, …) → Postgres `events`
                                                          └─ mras-ops /events/stream (SSE) → God View feed
```

## What each service does (detail)

### mras-vision (P1) — ✅ BUILT
- **Capture & detect:** OpenCV capture loop; DeepFace (ArcFace) embeddings on Apple MPS. Frame
  sampling (`FRAME_SAMPLE_RATE`, default 5). Model pre-warmed at startup.
- **Identity resolution:** queries Qdrant (`mras_embeddings`, 512-dim cosine) against a
  **multi-embedding gallery** grouped by person; match if best score ≥ `CONFIDENCE_THRESHOLD`
  (code default 0.68, demo rig override **0.67**). Below threshold → `is_new_visitor=true`.
- **Dispatch with backpressure:** a single-consumer `asyncio.Queue` (`TRIGGER_QUEUE_MAX`, default 8)
  drains triggers to the composer — non-blocking so the camera loop never stalls (serialized-inference
  worker; also fixes a native-crash concurrency bug).
- **Cooldown:** per-`screen_id:uuid` claim before each trigger via Redis (in-memory fallback);
  `COOLDOWN_SECS` (code default 30, demo rig **120**), `MAX_ADS_BEFORE_COOLDOWN` (1).
- **Perception (Phase 2 part 1):** per-frame object/color detection (YOLO + k-means), viewer mood
  (DeepFace emotion), and attention (head-pose gaze). Heavy models throttled to ~1 Hz
  (`PERCEPTION_ANALYZER_INTERVAL_S`). Enriches each trigger's `scene_context` and writes `gaze` events
  (per-track attention windows). Live debug view at `GET /debug/live`.
- **Presence reporting:** `PresenceReporter` periodically POSTs identified live tracks per screen to
  composer `/presence` (drives orchestration co-presence).
- **Adaptive enrollment:** gated, audited, reversible **auto-augmentation** — when an enrolled person
  is seen at high confidence with enough good frames (`AUG_*` gates), an additional embedding is added
  (`source='auto'`, capped/evicted by redundancy, `enroll` anchors protected). Manual enroll is
  additive and non-destructive.
- **Endpoints:** `POST /enroll`, `GET /identity`, `GET /debug/live`, `GET /health`.

### mras-composer (P2) — ✅ BUILT
- **Ad selection:** 3-tier gate — **Personalized** → (Demographic ⬜ planned) → **Standard**. Standard/
  stranger/blocklisted short-circuits before orchestration.
- **Temporal display orchestration** (the multi-screen choreography): a pure-state-machine
  `Orchestrator` + an I/O `OrchestratorRuntime`. Each identification runs a bounded **2-round program**
  — a shared **opener** on all owned displays, then a paired **A/A/B/B** round 2, then idle. Co-present
  people are even-split across displays (newest-wins tiebreak); handoff only at clip end (never
  mid-clip). A **watchdog** advances a display if a kiosk never reports `clip_ended` (dead-display
  backstop). Render-ahead during the opener; render gaps idle then resume.
- **TTS gateway:** disk cache → **ElevenLabs** (`eleven_turbo_v2`) → **Google Gemini**
  (`gemini-2.5-flash-preview-tts`) → silent. (Note: the old "MisoOne" backup in the original design was
  replaced by Gemini.)
- **Assembly:** ffmpeg splices base video + name audio + overlay inserts (software libx264; validated
  well under the latency budget — ~1–2s, see TODO-5 in `TODOS.md`).
- **Overlay:** always composites an animated name overlay via the `mras-overlays` sidecar; custom
  bound components also rendered there.
- **Endpoints:** `POST /trigger`, `POST /presence`, `POST /preview`, `GET /playlist`, `WS /ws?screen_id=…`,
  `GET /health`, static `/assets/*` and `/media/*`.

### mras-display (kiosk) — ✅ BUILT
- Electron, **multi-window** (`DISPLAY_COUNT`, default 4, clamp ≤10): fullscreen-per-monitor when
  enough monitors, else a tiled grid. Each window connects as `/ws?screen_id=display-<n>`, shuffles the
  idle playlist independently, and plays composer-pushed personalized clips.
- **Orchestration client:** on a personalized clip's `ended`, emits `clip_ended` and waits for the
  composer to decide the next clip (does not auto-advance); a `{type:idle}` message resumes idle shuffle.
- **Watchdog / self-heal:** auto-recreates a crashed renderer (backoff), reloads on unresponsive, and
  exposes a per-window health server on **8003**.

### mras-ops (God View / P3) — 🟡 PARTIAL
- **api/ (8080):** custom-component + ad CRUD (`/components`, `/ads`), and the live **`GET /events/stream`**
  (SSE over the `events` table). `GET /health`.
- **frontend/ (3000):** **two tabs only** — **Authoring** (upload component, create/bind ads) and
  **Activity Feed** (live event table with ▶ play links for dispatched clips).
- ⬜ **Planned (designed, not built):** vision/detection inspector, generation inspector, playback/
  attention monitor, identity & embedding browser, system-health monitor, RBAC/account admin, campaign
  manager, remote runtime-config admin. Full Phase-1 scope is preserved in `adface_architecture.md`
  ("P3 God View — Phase 1 Scope") and the dashboard data-mapping in `docs/GODVIEW_HANDOFF.md`.

### mras-overlays (render sidecar) — ✅ BUILT
- Node/Remotion HTTP service. `POST /render {compositionId, props}` → transparent video insert;
  `POST /components` registers a custom component at runtime; `GET /health` reports "warm" once the
  bundle + headless Chromium are ready (first ~10–90s after start it's still warming → composer silently
  falls back to no-overlay). One warm Chromium = renders are serialized. Host-internal only (composer
  reaches it at `http://mras-overlays:3000`).

## Data model (PostgreSQL — `mras-ops/db/migrations/`)

| Table | Migration | Purpose |
|---|---|---|
| `identities` | 001 | Enrolled people: `uuid`, `name`, `embedding`, `embedding_status`, `is_blocked`. PII lives here (not in the vector DB). |
| `events` | 001 | Append-only event log (the observability spine): `trigger_id`, `ts`, `service`, `event_type`, `status`, `payload jsonb`, `asset_ref`. Indexed `(ts DESC)`, `(trigger_id)`. |
| `campaigns` | 001 | Minimal Phase-0 campaign rows (base video + TTS template). |
| `components` | 002 | Custom Remotion components: `slug`, `status` (bundling/ready/failed), `props_schema`. |
| `ads` | 002 | Authored ads: `base_video`, `component_id`, `default_props`, `personalized_field`, `is_active`. |
| `identity_embeddings` | 003 | **Multi-embedding gallery** for adaptive enrollment: `identity_uuid` (FK, cascade), `embedding`, `source` (`enroll`/`auto`), `quality`, `provenance`. |

**Vector store:** Qdrant collection `mras_embeddings` (512-dim cosine), one point per gallery embedding,
payload keyed by `uuid` so multi-embedding identities resolve by group-max similarity.

## Event types (the `events` table, by emitter)

| Service | `event_type` / `status` | Meaning |
|---|---|---|
| mras-vision | `detection`/`success`,`error` | a face was resolved (or failed) |
| mras-vision | `dispatch`/`dropped`,`error` | trigger dropped (queue full) or dispatch failed |
| mras-vision | `gaze`/`success` | per-track attention window (the "did they watch" signal) |
| mras-vision | `perception`/`error` | perception/tracker failure (non-fatal) |
| mras-vision | `augment`/`success` | adaptive-enrollment embedding added |
| mras-composer | `composition`/`standard_selected`,`orchestrated` | ad path chosen |
| mras-composer | `tts_attempt`/`success`,`error` | TTS outcome |
| mras-composer | `overlay`/`error`, `assembly`/`error` | render/assembly failures |
| mras-composer | `playback`/`dispatched` | a clip was sent to a kiosk (carries `video`, `screen_id`, `person`) |

**Attention-outcome analytics** ("did person X watch ad Y") = a SQL join of `gaze` × `playback` rows on
screen + time window. The join is now possible end-to-end (the `playback` side was recently restored for
the orchestrated path).

## Key tunables (defaults; demo-rig overrides noted)

- **Recognition:** `CONFIDENCE_THRESHOLD` 0.68 (rig **0.67**), `FRAME_SAMPLE_RATE` 5,
  `DEEPFACE_BACKEND` mps (rig) / cpu (compose default) / cuda (cloud).
- **Pacing:** `COOLDOWN_SECS` 30 (rig **120**), `MAX_ADS_BEFORE_COOLDOWN` 1, `TRIGGER_QUEUE_MAX` 8.
- **Displays:** `DISPLAY_COUNT` 4 (clamp ≤10).
- **Perception:** `PERCEPTION_ANALYZER_INTERVAL_S` 1.0, `VIEWER_MIN_EVIDENCE_S` 3.0, `QDRANT_GALLERY_FANOUT` 15.
- **Auto-augment gates:** `AUG_MIN_CONF` 0.90, `AUG_MIN_DWELL_S` 5.0, `AUG_MIN_FRAMES` 10,
  `AUG_MAX_REDUNDANCY` 0.95, `AUG_GALLERY_CAP` 12.
- **Overlay:** `OVERLAY_PRESET` turbulence-warp, `OVERLAY_DURATION_FRACTION` 0.5 (rig **1.0**, full-length).

## Known drift / cleanup flags (for the reviewing architect)

These are accurate-as-of-2026-06-21 discrepancies between the original design and the code — surfaced so
the next architect isn't misled:

1. **Remote runtime config (design decision D17) is not wired.** Vision's `.env` points
   `REMOTE_CONFIG_URL` at `http://localhost:8080/config/v1/runtime`, but no code reads it and ops-api has
   no such route. Centrally-managed runtime config is **planned, not built**.
2. **TTS chain changed:** design says ElevenLabs → MisoOne → HuggingFace; code is ElevenLabs → Gemini →
   silent. `mras-composer/.env.example` is stale (lists MisoOne/HF, omits the Gemini/overlay vars the app
   actually uses — those live in compose).
3. **`scene_context` is no longer `{}`** (the design's Phase-0 placeholder) — it's populated by Phase 2
   perception, but **nothing consumes it for ad selection yet** (TODO-7).
4. **God View is far thinner than the documented Phase-1 scope** — feed + authoring only.
5. **Demo-rig env overrides** (`0.67`, `120s`, overlay full-length) live in machine-local `.env` files,
   not in compose — documented in `SESSION_LOG.md`'s Operational Reference.

## Where to go deeper

- **Canonical diagram + every locked engineering decision:** `adface_architecture.md`.
- **Actors, roles, RBAC, scope:** `mras_ecosystem_and_users.md`.
- **Product requirements:** `adface_prd.md`.
- **Per-feature design specs & implementation plans:** `docs/superpowers/specs/` and `docs/superpowers/plans/`.
- **God View dashboard data mapping:** `docs/GODVIEW_HANDOFF.md`.
- **Running engineering journal + how-to-run + gotchas:** `docs/SESSION_LOG.md` (newest entry first).
- **Open/deferred work:** `TODOS.md`.
</content>
</invoke>
