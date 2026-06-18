# Serialized Inference Worker (Design)

**Date:** 2026-06-18
**Status:** Approved by owner (brainstorming session 2026-06-18)
**Repos affected:** `mras-vision` only
**Motivation:** the live `POST /enroll` reliably **segfaults** the vision process. Confirmed root
cause (systematic debugging, 2026-06-18): `DeepFace`/TensorFlow/mediapipe native inference is **not
safe to call concurrently**, but today the camera loop runs inference on background threads every
frame while `/enroll` runs `embedder.embed` on the event-loop thread → concurrent `DeepFace.represent`
on a shared model/TF-session/MPS(Metal) context → native crash. Proven: standalone `embed()` works
(dim 512); the crash only occurs inside the running server; covering the lens did **not** help
because the camera calls `DeepFace.represent` every frame regardless (the detector always runs).

---

## Goal

Make all native ML inference **serialized onto a single dedicated worker thread**, so no two
inference calls (camera frames *or* enrollment) ever run concurrently. This eliminates the segfault,
is correct for thread-affine Metal/TF models (one consistent thread), and removes the
thread-oversubscription left over from the Bug B throttle work.

**Done means:** every native inference site (face embed, mood, objects/YOLO, attention/mediapipe,
and the enroll embed) runs through one shared `max_workers=1` executor; models are prewarmed on that
same thread; and `POST /enroll` while a person is in front of the camera no longer crashes. Verified
by a serialization unit test plus a live walk-up-and-enroll E2E.

## Owner decision from the brainstorm

| Question | Decision |
|---|---|
| Serialization approach | **Single dedicated inference worker** (`max_workers=1` ThreadPoolExecutor) shared by ALL native inference, over the alternative (a shared lock + moving enroll off-loop). Chosen because it also fixes Metal thread-affinity and oversubscription, and there's one obvious place to route inference (no easy-to-miss call site). |

## Architecture

A new module owns the single inference thread; every inference site submits to it.

```
            ┌───────────────────────────── mras-vision ─────────────────────────────┐
camera loop ─┐                                                                       │
enroll ──────┼─▶ src/perception/infer.run_inference(fn, *args)                       │
prewarm ─────┘        └─▶ ThreadPoolExecutor(max_workers=1)  ── one thread, FIFO ──▶ DeepFace / mediapipe / YOLO
```

**New module `src/perception/infer.py`:**
- A process-wide `ThreadPoolExecutor(max_workers=1)` (module singleton).
- `async def run_inference(fn, *args)` → `await get_running_loop().run_in_executor(_POOL, fn, *args)`.
- `def shutdown()` → `_POOL.shutdown()` for clean lifespan teardown.

**Call sites rerouted from `run_in_executor(None, …)` (or sync) to `run_inference(…)`:**
- `main.py` `process_frame`: `embedder.embed_all` (was `run_in_executor(None, …)`).
- `main.py` `lifespan` prewarm: `embedder.prewarm` and `yolo.prewarm` run **on the inference
  worker** (so the models load on the same thread that will infer — Metal thread-affinity).
- `src/perception/analyzers/mood.py`: the `DeepFace.analyze` call.
- `src/perception/analyzers/objects.py`: the YOLO `_detect_and_color` call.
- `src/perception/analyzers/attention.py`: the mediapipe `_estimate_poses` call (`attention.py:146`).
- `src/enrollment/enroller.py`: `embedder.embed(img)` → `await run_inference(embedder.embed, img)`
  (this both serializes it *and* moves it off the event-loop thread, so a long enroll no longer
  blocks the async server either).

## Behavior / performance notes

- Per frame, embed + (throttled) mood/objects + attention now run **sequentially** on the one
  worker instead of across threads. Real throughput is ~unchanged: the GPU (MPS) already serializes
  inference, mood/objects are already throttled to ~1 Hz (Bug B), and the GIL already serialized
  most of it. The win is no concurrent native access (no crash) and no thread oversubscription.
- `gather_scene_context` still fans analyzers out with its `asyncio.wait` budget; their executor
  submissions simply queue on the one worker and the budget still drops laggards (enrichment is
  intentionally lossy).
- Enroll now queues behind the current frame's inference (sub-second) — fine; enrollment is rare.

## Error handling / edge cases

- A failing inference still raises inside `run_inference` and is handled by each call site exactly
  as today (analyzers catch and drop the frame; enroll records `failed`).
- Worker thread dies? `max_workers=1` ThreadPoolExecutor replaces the worker on next submit
  (standard behavior); models are module/instance state and re-used.
- Shutdown: `lifespan` calls `infer.shutdown()` after cancelling tasks.

## Testing strategy (TDD)

- **Serialization unit test:** submit two `run_inference` calls that each set a "running" flag and
  sleep; assert they never overlap (a shared counter never exceeds 1) — proves single-worker
  serialization.
- **Prewarm-on-worker test:** assert prewarm is invoked via `run_inference` (so the model loads on
  the inference thread).
- **Analyzer/enroll refactor:** existing mood/objects/attention/enrollment unit tests must stay
  green (the change is internal — same results, just routed through the shared worker).
- **Live E2E (the real proof — native crash can't be unit-tested):** start vision, stand in front of
  the camera, `POST /enroll` (additive) with a photo → **no segfault**, gallery member added. This is
  the definition of done; record it in `docs/SESSION_LOG.md`.

## v1 scope boundary

**In:** the `infer` single-worker module; rerouting all six inference sites (embed, mood, objects,
attention, enroll, prewarm); lifespan shutdown.

**Deferred (YAGNI):** a multi-GPU / multi-worker inference pool; batching frames; moving inference to
a separate process; configurable worker count (one worker is correct for a single Metal device).
