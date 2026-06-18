# God View — Handoff Context (for the next Claude agent)

**Written:** 2026-06-18. **Author:** prior session (perception bugfixes + gallery + planning).
**Your mission:** design and build the **God View** — a UX/UI (plus the backend it needs) that shows,
**across all locations**, both **live activity** and **history**:
- who is currently identified (and their signals: mood, attention),
- what is being composed in real time (and what advertisers have uploaded/bound),
- what is currently playing on each display,
- what was played, and **whether the person actually watched it**.

> **Start with the workflow, not code.** This project uses brainstorm → spec → plan → execute
> (Superpowers skills) with PRs per task batch and git delegated to the `git-flow-manager` subagent.
> The God View is a large creative feature: **invoke `superpowers:brainstorming` first**, produce a
> spec in `docs/superpowers/specs/`, then `superpowers:writing-plans`. Read `CLAUDE.md` (repo root)
> — its rules are mandatory. Read `docs/SESSION_LOG.md` top-to-bottom before acting.

---

## 1. System at a glance (5 repos)

| Repo | Role | Runs as | Port |
|------|------|---------|------|
| `mras-vision` | Camera → face detect/embed/track, identity resolution, perception (objects/mood/attention/gaze), enrollment | **native macOS** (not Docker — needs the webcam; MPS/Metal) | 8001 |
| `mras-composer` | Ad selection, TTS, overlay/clip assembly, pushes clips to kiosk over WebSocket | Docker | 8002 |
| `mras-overlays` | Remotion render sidecar (advertiser components → overlay video) | Docker (internal) | 3000 (internal) |
| `mras-ops` | `api/` (FastAPI ops + **event stream**) and `frontend/` (React/Vite **activity-feed dashboard** + advertiser authoring) | Docker | api **8080**, frontend **3000** |
| `mras-display` | Electron kiosk: N fullscreen windows (`display-1..N`), plays clips, idle shuffle | Electron (native) | 8003 (health) |
| infra | Postgres 5432, Qdrant 6333, Redis (transient only) | Docker | — |

**Run it:** `cd /Users/jn/code/mras-ops && PERCEPTION_DEBUG=1 ./start-mras.sh` (brings up Docker
stack + starts native vision in the foreground; must be the user's terminal for camera permission).
Kiosk separately: `cd /Users/jn/code/mras-display && NODE_ENV=development npm run electron:dev`.
**Gotcha:** `start-mras.sh` already starts vision; `run-vision-native.sh` is only for "Docker up,
vision down" — running both collides on port 8001.

**Architecture decision that matters most for you (D19):** the Postgres **`events` table is the
append-only source of truth** for "what happened." Redis holds only transient TTL'd flags (cooldowns),
never durable history. **The God View is fundamentally a reader/visualizer of the `events` table
plus a few relational tables.**

---

## 2. The data model — your primary source

### `events` (append-only journal — THE God View backbone)
```
id bigserial | trigger_id uuid | ts timestamptz | service text | event_type text
| status text | payload jsonb | asset_ref text
indexes: (trigger_id), (ts DESC)
```
A single user interaction is correlated by **`trigger_id`** (one detection → its dispatch →
composition → playback share a trigger_id). `ts DESC` is indexed for recent-first feeds.

**Every event type currently emitted (service / event_type / status) and what it tells you:**

| service | event_type | status(es) | Meaning for the God View | payload shape (real example) |
|---|---|---|---|---|
| mras-vision | `detection` | `success`, `error` | **Someone was seen/identified.** `uuid` (null = unknown), `confidence`, `is_new_visitor`, and `scene_context` (the rich signal). | `{"uuid":"f487…","confidence":0.897,"is_new_visitor":false,"scene_context":{"viewer":{"mood":"sad","track_id":"t-1","attending":true,"evidence_frames":41,"mood_confidence":0.55},"objects":[{"bbox":[…],"color":"black","label":"person","source":"yolo11n","confidence":0.7}],"faces_tracked":1}}` |
| mras-vision | `gaze` | `success` | **Did they watch?** Per-track attention over a ~3s window. Join with `playback` (same screen, overlapping window) to answer "watched the ad." | `{"uuid":"f487…","track_id":"t-1","screen_id":"screen_0","window_start":"…","window_end":"…","attending_fraction":0.8,"samples":5}` |
| mras-vision | `dispatch` | `error`, `dropped` | A trigger to the composer failed (`error`) or was shed under load (`dropped`, queue full). | `{"error":"…"}` / `{"reason":"TRIGGER_DROPPED","queue_max":8}` |
| mras-vision | `perception` | `error` | Tracker/perception fault (rare). | `{"error":"…"}` |
| mras-vision | `augment` | `success`/`rejected` | **PLANNED, not yet built** (adaptive enrollment Plan 2 / PR #13): a gallery embedding was auto-added. | `{"uuid":…,"confidence":…,"frames":…,"ts":…}` |
| mras-composer | `composition` | `standard_selected`, `no_display`, `orchestrated` | What the composer decided: standard/idle ad, no free display, or (PLANNED orchestration) a personalized program started. **Coarse today** — see gap §5. | mostly `{}` |
| mras-composer | `tts_attempt` | `success`, `error` | Name voiceover synthesized (or failed). | `{}` / `{"error":"TTS_UNAVAILABLE"}` |
| mras-composer | `playback` | `dispatched` | **A clip was sent to a display to play.** `video` filename; `screen_id` (`display-N`) on the per-display path. **There is NO "started/ended/watched" ack yet** — see gap §5. | `{"video":"<uuid>.mp4","screen_id":"display-2"}` (screen_id absent on the legacy broadcast path) |

**To see them live:** `docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT ts,service,event_type,status,payload FROM events ORDER BY ts DESC LIMIT 20;"`

### Relational tables
- **`identities`** (`uuid, name, embedding float4[], embedding_status, is_blocked, created_at, updated_at`) — enrolled people.
- **`identity_embeddings`** (`id, identity_uuid FK, embedding float4[], source 'enroll'|'auto', quality, provenance jsonb, created_at`) — **the multi-embedding gallery** (shipped this session). A person has many embeddings (lighting/pose conditions); recognition = max cosine similarity over them. The God View may show enrolled people + gallery health.
- **`ads`** (`base_video, component_id FK, default_props, personalized_field, is_active, created_at`) and **`components`** (`slug, status`) — **advertiser uploads**: a Remotion component bound to an ad. Managed via ops-api `POST/GET /components`, `POST/GET/DELETE /ads`. This is your "what advertisers uploaded/bound" panel source.
- **Qdrant** collection `mras_embeddings` (512-dim cosine) — the vector index for recognition; one point per gallery embedding, `payload.uuid` groups them.

---

## 3. Real-time paths (what's happening *now*)

- **ops-api SSE: `GET http://localhost:8080/events/stream`** — **already exists** and is your starting
  point. It replays the last 20 events then polls the `events` table every 1s and streams new rows as
  Server-Sent Events (`/Users/jn/code/mras-ops/api/src/main.py:177`). The current
  `mras-ops/frontend` "activity feed" consumes this.
- **Composer → kiosk WebSocket** (`mras-composer/main.py` `WSManager`): the composer pushes
  `{"type":"play","video_url",…}` to a specific `display-N`; idle is the kiosk's own shuffle. This is
  the "what's playing now" signal — but today it's only observable via the `playback/dispatched` event
  (the composer logs the dispatch), not a confirmed render.
- **Recognition is healthy now** (~0.89 confidence) after the gallery + re-enrollment work; expect
  frequent `detection/success` with populated `scene_context.viewer` once a person dwells ~3s.

---

## 4. Mapping the God View panels → data (and where instrumentation is thin)

| God View panel | Data source today | Good enough? |
|---|---|---|
| **Who is identified (now)** | recent `detection/success` events (`uuid` → join `identities.name`); `scene_context.viewer` = mood/attending/evidence | ✅ usable; "presence/left" is inferred from recency (no explicit presence event yet — orchestration PR #12 adds a `/presence` stream) |
| **What advertisers uploaded/bound** | `ads` + `components` tables via ops-api `/ads`, `/components` | ✅ usable |
| **What is being composed in real time** | `composition` + `tts_attempt` events | ⚠️ **coarse** — statuses are `standard_selected`/`no_display`/`orchestrated` with mostly-empty payloads. There's no "render N% / rendering variant X for uuid Y" signal. Likely needs **new instrumentation** (richer composition/render events) for a satisfying live view. |
| **What is playing now** | `playback/dispatched` (video, screen_id) | ⚠️ **dispatch only** — no "playback started/ended" ack from the kiosk yet. Orchestration PR #12 adds kiosk `clip_ended`; you may want a `playback/started` too. |
| **What was played + did they watch** | `playback` ⋈ `gaze` (same screen, overlapping window → `attending_fraction`) | ✅ the join works (Phase 2 design); presentation is yours to build |

---

## 5. Known gaps you will likely need to close (backend work)

1. **"Across all locations" does not exist yet.** The system is **single-location**: one camera group
   `screen_id="screen_0"` → displays `display-1..4`. There is **no `location_id`** anywhere. To do a
   multi-location God View you'll need a location dimension: e.g., a `locations` table, tag each vision
   instance with a `LOCATION_ID`, and stamp it onto every event payload (and/or a column). This is
   net-new and foundational for your mission — **scope it early.**
2. **"Composing in real time" is under-instrumented.** Add composition lifecycle events
   (selected → rendering → ready → dispatched) if you want a live compose view. Today you mostly see
   the terminal decision.
3. **No playback confirmation.** Only `dispatched`. A `playback/started` + `clip_ended` (the latter is
   in the orchestration plan) would let the God View show true "now playing" + completion.
4. **SSE scaling.** The current `/events/stream` is a 1s table poll, fine for one screen. A God View
   across many locations/clients may want filtered streams (by location/type), since-cursor history
   queries, and aggregation endpoints — extend ops-api.

---

## 6. Current state — what's shipped vs planned (so you build on solid ground)

**Shipped / on `main`:**
- Phase 0/1/2 perception (detect, track, mood, attention, objects/color, `gaze`), per-display custom ads, multi-display kiosk.
- **Multi-embedding gallery** (max-similarity recognition) + **additive re-enroll** — `mras-vision` + `mras-ops` migration `003_identity_embeddings.sql`. Recognition is now reliable (~0.89).
- **Serialized inference worker** (`mras-vision/src/perception/infer.py`) — all native ML on one worker thread; fixed a `/enroll` segfault. **Relevance to you:** don't add concurrent heavy GPU calls; if backend work touches vision inference, route it through `run_inference`.

**Planned (spec + TDD plans written, NOT built) — docs PRs in `minority_report_architecture`:**
- **PR #12 — Temporal display orchestration:** bounded 2-round-per-person ad programs, even-split + newest-wins across displays, event-driven pacing via a new kiosk `clip_ended` event and a new vision→composer `/presence` stream. **Several of these signals are exactly what the God View wants to show** — coordinate; you may even implement the `/presence` + `clip_ended` plumbing as shared groundwork.
- **PR #13 — Adaptive enrollment Plan 2:** gated auto-augmentation (adds `augment` events) + purge.
- **PR #14 (docs):** the serialized-inference design/plan (already implemented & merged as `mras-vision` #18).

Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/` (dated 2026-06-17/18).

---

## 7. Where to build (suggested)

- **Backend:** extend **`mras-ops/api`** (FastAPI, `api/src/main.py`) — add location-aware,
  filtered, paginated event queries + richer/filterable streams. It already owns `/events/stream`,
  `/ads`, `/components`, and the DB pool.
- **Frontend:** the God View UI — either extend **`mras-ops/frontend`** (React + Vite + TypeScript;
  current activity feed in `frontend/src/App.tsx`, advertiser authoring in `Authoring.tsx`) or a new
  app in that repo. Match existing stack/patterns.
- **New signals** (presence, playback lifecycle, location_id, compose progress) are cross-repo —
  follow the per-repo branch + PR + `git-flow-manager` workflow; coordinate with PR #12's plumbing so
  you don't build it twice.

---

## 8. Gotchas / invariants (don't relearn these the hard way)

- **`events` is the source of truth; never put durable history in Redis** (Redis = TTL flags only).
- **Vision runs native** (camera/MPS); it's not in the default `docker compose up`. Camera enroll/inference must run from the user's terminal (camera permission).
- **Recognition threshold** `CONFIDENCE_THRESHOLD=0.67` is a **local `.env` override** in `mras-vision/.env` (gitignored); code default is 0.68. May be re-tuned now that it's a gallery.
- **Git:** never commit to `main` directly (except `docs/SESSION_LOG.md`, which has a guard exception); delegate all git to the `git-flow-manager` subagent; one branch per ticket; PR per batch.
- **`screen_id` is overloaded:** `screen_0` = camera group; `display-1..4` = individual kiosk displays. Keep them distinct (and add `location_id` above both).

---

## 9. First steps for you

1. Read `CLAUDE.md`, `docs/SESSION_LOG.md` (newest entries first cover all of the above), and skim `docs/superpowers/specs/2026-06-17-*` + `2026-06-18-*`.
2. Run the stack, open `http://localhost:8080/events/stream` (raw SSE) and `http://localhost:3000` (current activity feed) to see what exists.
3. Watch the `events` table live (SQL in §2) while a person walks up, to feel the data.
4. **Brainstorm the God View** (`superpowers:brainstorming`) — especially nail: the location model (§5.1), which signals are "live" vs "historical," real-time transport (extend SSE vs WebSocket), and whether to fold in PR #12's presence/clip_ended plumbing. Then spec → plan → execute.
