# Phase 2 Perception — Part 1: Signal Identification (Design)

**Date:** 2026-06-12
**Status:** Approved by owner (brainstorming session 2026-06-12)
**Repo affected:** `mras-vision` only (native macOS process — camera, frames, MPS live there)
**Part 2 (using these signals for ad selection/generation): BACKLOGGED** — see TODO-7 in
`/Users/jn/code/minority_report_architecture/TODOS.md`. Part 1 produces signals; nothing consumes
them yet.

---

## Goal

From live camera frames, identify and persist four signals:

1. **Objects** in the frame (general scene objects, ~80 COCO classes to start).
2. **Color** of each identified object (dominant color, named).
3. **Mood** of each tracked person (happy/sad/angry/… 7-class emotion), stabilized over a track.
4. **Attention** — whether the identified person is facing the display, both as an instantaneous
   pre-trigger signal and as a per-playback outcome ("did they actually watch the ad").

**Done means:** signals ride the existing `scene_context` field of the P1→P2 `/trigger` payload,
every perception result is queryable in the Postgres `events` table (including new `gaze` rows),
and an annotated live debug view exists. Verified by unit/integration tests plus a live walk-up.

## Owner decisions from the brainstorm

| Question | Decision |
|---|---|
| Attention semantics | **Both paths**: instantaneous `attending` in `scene_context` + playback-time `gaze` events; "watched the ad" answered by query-time join with `playback` events. |
| Object scope | **General scene objects now**, but the detector layer is a **multi-backend gateway** with result fusion (average agreeing labels / pick highest confidence) so Nvidia LocateAnything, cloud VLMs, or additional models plug in later. Object→person association ("held/worn") must be addable without rework — deferred, not precluded. |
| Face tracking | **Included in part 1.** It is the hard prerequisite; mood/attention without 30–60 frames of accumulated evidence are noise. |
| Definition of done | Events table + payload **plus a live annotated debug view**. |
| Approach | **A — local specialist models** (YOLO-nano, k-means color, DeepFace emotion, MediaPipe head-pose, IoU face tracker). VLM and SOTA upgrades remain possible per-piece via the gateway/track abstractions. |

## Architecture

Pipeline today:

```
camera → every 5th frame → embed_all (embeddings only) → gather_scene_context({}) → resolve per face
```

Pipeline after:

```
camera → every 5th frame
  → embedder returns (embedding, bbox) per face         [stop discarding facial_area]
  → FaceTracker.update(faces) → tracks                  [NEW — the spine, runs before fan-out]
  → gather_scene_context(ANALYZERS, frame, tracks)      [seam keeps registry/budget/drop semantics]
       ├─ ObjectsAnalyzer   → gateway → [yolo11n backend] → fusion → objects + dominant colors
       ├─ MoodAnalyzer      → DeepFace emotion per track crop → per-track EMA over 30–60 frames
       └─ AttentionAnalyzer → MediaPipe head-pose per track → attending sample appended to track
  → resolve per face; scene_context = shared scene objects + THAT viewer's track signals
```

Structural rules:

1. **The tracker is the spine, not an analyzer.** Runs unconditionally before the analyzer
   fan-out. Analyzers read tracks; they do not track.
2. **Per-frame vs per-person:** objects+colors are scene-wide (shared per frame, as today);
   mood and attention live in a per-face `viewer` sub-dict specific to each resolve call. When
   object→person association lands (part 2+), associated objects move into `viewer` — the hook
   exists, no rework.
3. **Attention's two paths share one mechanism:** the same per-track evidence buffer serves the
   instantaneous `attending` boolean (pre-trigger) and the background gaze flusher (playback-time
   `gaze` event rows). "Did Jason watch the ad" = query-time join of `playback` rows (screen,
   start ts, duration) against `gaze` rows for Jason's uuid overlapping that window. No new
   cross-service wiring.
4. **Perception can never block identity dispatch.** The aggregator's existing 800ms
   budget/drop-laggard semantics are unchanged; `analyze(frame)` becomes `analyze(frame, tracks)`
   (the swap the aggregator docstring promised). A broken analyzer costs only its own signal.

## Components

All paths under `/Users/jn/code/mras-vision/`:

| Component | File | Purpose |
|---|---|---|
| Face tracker | `src/perception/tracker.py` (new) | Match faces across frames into `Track`s; hold evidence buffers; bind uuid on identification |
| Object gateway | `src/perception/objects/gateway.py` (new) | `DetectorBackend` protocol + fusion (overlapping boxes: same label → average confidence; conflict → highest wins) |
| YOLO backend | `src/perception/objects/yolo_backend.py` (new) | First backend: ultralytics `yolo11n` → `(label, confidence, bbox)` |
| Color naming | `src/perception/objects/color.py` (new) | k-means dominant color of bbox crop → nearest CSS-named color |
| Objects analyzer | `src/perception/analyzers/objects.py` (new) | Run gateway on frame, attach color per object |
| Mood analyzer | `src/perception/analyzers/mood.py` (new) | DeepFace emotion on track face crops; per-track EMA + majority over evidence window |
| Attention analyzer | `src/perception/analyzers/attention.py` (new) | MediaPipe head-pose yaw/pitch per track → attending sample |
| Gaze flusher | `src/perception/gaze_log.py` (new) | Every ~3s, write per-track attention summaries to `events` as `gaze` rows; final flush on track close |
| Aggregator | `src/perception/aggregator.py` (edit) | `analyze(frame, tracks)`; semantics unchanged |
| Embedder | `src/detection/embedder.py` (edit) | `embed_all` also returns `facial_area` bbox (DeepFace already computes it) |
| Wiring + debug | `main.py` (edit) | Tracker in `process_frame`, analyzers registered in `ANALYZERS`, `/debug/live` MJPEG endpoint |

**New dependencies:** `ultralytics`, `mediapipe`. Emotion comes from DeepFace (already installed);
color is pure numpy/cv2.

## Data shapes

`scene_context` (existing D9 field; `{}` remains the no-perception value):

```json
{
  "objects": [
    {"label": "backpack", "confidence": 0.87, "color": "red", "bbox": [x, y, w, h], "source": "yolo11n"}
  ],
  "viewer": {
    "track_id": "t-4821",
    "mood": "happy",
    "mood_confidence": 0.74,
    "attending": true,
    "evidence_frames": 42
  },
  "faces_tracked": 2
}
```

`viewer` appears only once a track has a minimum evidence window (configurable, default ~30
frames); before that the keys are absent. Consumers must treat every perception key as optional
enrichment.

`gaze` event payload (existing `events` table, reserved `gaze` event_type — **no migration**):

```json
{"track_id": "t-4821", "uuid": "f487f5b0-…", "window_start": "…", "window_end": "…",
 "attending_fraction": 0.83, "samples": 18, "screen_id": "display-1"}
```

`uuid` is null until the track binds an identity.

## Tracker mechanics

- Match by bbox IoU ≥ 0.3 against each track's last-seen bbox; ambiguous matches fall back to
  ArcFace embedding cosine similarity (≥ 0.75 = same person).
- Unmatched faces open new tracks. Tracks unseen ~2s (≈12 sampled frames) close → final gaze flush.
- Once a track's face resolves above the identity threshold, `track_id ↔ uuid` binds and sticks.
- Track state is in-process memory only. Redis holds nothing here (locked: Redis = transient
  TTL'd flags only; durable history = Postgres `events`).

## Attention model (honest framing)

Single webcam → this is **head orientation** (yaw/pitch within a cone toward the display), the
standard kiosk-distance proxy — not true eye-gaze. True gaze models are a per-piece upgrade behind
the same analyzer interface if quality demands it (non-goal now).

## Live debug view

`GET /debug/live` on the vision service (port 8001): MJPEG stream of annotated frames — object
boxes with label/color/confidence, face boxes with track id + mood + attending indicator (green
when facing the display). Annotation runs only while a client is connected AND `PERCEPTION_DEBUG=1`
— zero cost during demos. A future ops-UI embed is an `<img>` tag pointing at this URL.

## Performance

Per sampled frame (~6/sec) on the M3: yolo11n ~20–40ms, DeepFace emotion ~50–100ms/face,
MediaPipe head-pose ~10ms/face, color k-means ~5ms/object — inside the existing 800ms aggregator
budget for 1–4 people. All inference via `run_in_executor` (the embedder's pattern); models
prewarm at startup alongside ArcFace (D13 pattern). Laggards are dropped by the aggregator —
ad latency is never affected.

## Error handling

Mostly inherited (aggregator isolates analyzer failures). Additions:

1. A failing backend inside the object gateway is skipped; remaining backends still fuse.
2. The gaze flusher writes best-effort with the same try/except pattern as `_log_event`.
3. If the tracker itself raises, `process_frame` falls back to today's untracked path for that
   frame and logs a `perception`/`error` event. Identity dispatch is never blocked by perception.

## Testing (TDD, red→green per CLAUDE.md)

- **Tracker unit tests** (highest value): stable track id across frames; two crossing people
  don't swap (embedding tiebreaker); expiry closes + flushes; uuid binding sticks.
- **Analyzer unit tests:** known-color rectangles → color names; mocked backends → fusion
  picks/averages correctly; mood EMA stabilizes a noisy vote sequence; attending-fraction math.
- **Aggregator contract:** slow analyzer dropped, broken analyzer isolated (extends existing tests).
- **Integration:** fixture frames through `process_frame` → assert `scene_context` shape and
  `gaze` rows land in `events`.
- **Live E2E:** real walk-up — kiosk plays (Playwright), SQL confirms `detection` events with
  populated `scene_context`, `gaze` rows with `attending_fraction > 0` during playback,
  `/debug/live` renders annotations. Camera requires the owner's terminal → live portion is an
  owner-run check.
- **Identity hygiene (locked):** test fixtures use synthetic or non-enrolled faces only — never
  an enrolled real person's face against live stores; e2e teardown cleans any seeded identity.

## Non-goals (part 1)

- Using any signal for ad selection/generation — **part 2, backlogged as TODO-7**.
- Object→person association ("holding/wearing") — gateway + viewer sub-dict leave the hook.
- Demographic age/gender inference (separate Phase 2 item).
- True eye-gaze tracking; multi-camera track handoff; Nvidia LocateAnything backend (slot exists).
