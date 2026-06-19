# Serialized Inference Worker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every native ML inference in `mras-vision` (face embed, mood, objects/YOLO, attention/mediapipe, enroll embed, and model prewarm) through one shared `max_workers=1` worker thread, so concurrent inference (the cause of the `/enroll` segfault) is impossible.

**Architecture:** A new `src/perception/infer.py` owns a single-worker `ThreadPoolExecutor` and a `run_inference(fn, *args)` coroutine helper. Each inference site swaps `loop.run_in_executor(None, …)` (or a sync call) for `await run_inference(…)`. Models prewarm on the same worker (Metal thread-affinity).

**Tech Stack:** Python 3.9 (vision venv — `from __future__ import annotations`), asyncio, `concurrent.futures.ThreadPoolExecutor`, pytest (`asyncio_mode=auto`).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-18-serialized-inference-worker-design.md`

---

## File Structure

- Create `src/perception/infer.py` — single-worker pool + `run_inference` + `shutdown`.
- Modify `main.py` — reroute `embed_all` + prewarms; shutdown in lifespan.
- Modify `src/perception/analyzers/mood.py`, `objects.py`, `attention.py` — reroute the inference call.
- Modify `src/enrollment/enroller.py` — reroute `embedder.embed` (off the event loop).
- Create `tests/test_infer.py`.

All paths relative to `/Users/jn/code/mras-vision`. Tests: `.venv/bin/python -m pytest <path> -v`.

---

### Task 1: The single-worker inference module

**Files:**
- Create: `src/perception/infer.py`
- Test: `tests/test_infer.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_infer.py
import asyncio
from src.perception.infer import run_inference


async def test_run_inference_serializes_calls_on_one_worker():
    state = {"running": 0, "max": 0}

    def work():
        state["running"] += 1
        state["max"] = max(state["max"], state["running"])
        import time
        time.sleep(0.05)
        state["running"] -= 1
        return "ok"

    results = await asyncio.gather(run_inference(work), run_inference(work),
                                   run_inference(work))
    assert results == ["ok", "ok", "ok"]
    assert state["max"] == 1  # never two at once → single worker serialized them


async def test_run_inference_passes_args():
    assert await run_inference(lambda a, b: a + b, 2, 3) == 5
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_infer.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.perception.infer'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/perception/infer.py
from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor

# One worker: all native inference (DeepFace/mediapipe/YOLO) is serialized onto a
# single thread. DeepFace/TF/Metal are not safe to call concurrently — running the
# camera loop's inference and an /enroll embed at once segfaults the process.
_POOL = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mras-infer")


async def run_inference(fn, *args):
    """Submit a native-inference callable to the single shared worker thread."""
    return await asyncio.get_running_loop().run_in_executor(_POOL, fn, *args)


def shutdown() -> None:
    _POOL.shutdown(wait=False)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_infer.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add src/perception/infer.py tests/test_infer.py
git commit -m "feat(vision): single-worker inference executor (serializes native ML)"
```

---

### Task 2: Route face embed + prewarm through the worker

**Files:**
- Modify: `main.py`
- Test: existing suite (no regression) + import check

- [ ] **Step 1: Add the import**

In `main.py`, near the other `src.perception` imports:
```python
from src.perception.infer import run_inference, shutdown as infer_shutdown
```

- [ ] **Step 2: Reroute the per-frame embed**

In `process_frame`, replace:
```python
    faces = await loop.run_in_executor(None, embedder.embed_all, frame)
```
with:
```python
    faces = await run_inference(embedder.embed_all, frame)
```

- [ ] **Step 3: Prewarm on the inference worker**

In `lifespan`, replace the two prewarm lines:
```python
    await loop.run_in_executor(None, embedder.prewarm)  # D13: load model before camera starts
```
with:
```python
    await run_inference(embedder.prewarm)  # D13: load model on the inference worker thread
```
and the yolo prewarm:
```python
        await loop.run_in_executor(None, yolo.prewarm)
```
with:
```python
        await run_inference(yolo.prewarm)
```

- [ ] **Step 4: Shut the pool down on teardown**

In `lifespan`, after the existing `cam_task.cancel()` / `await db.close()` shutdown block (after `yield`), add:
```python
    infer_shutdown()
```

- [ ] **Step 5: Verify import + full suite**

Run:
```bash
cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"
.venv/bin/python -m pytest -q
```
Expected: `ok` then all pass.

- [ ] **Step 6: Commit**

```bash
git add main.py
git commit -m "feat(vision): route face embed + prewarm through the inference worker"
```

---

### Task 3: Route the three analyzers through the worker

**Files:**
- Modify: `src/perception/analyzers/mood.py`, `objects.py`, `attention.py`
- Test: existing analyzer tests must stay green

- [ ] **Step 1: mood.py**

Add import: `from src.perception.infer import run_inference`. Remove the now-unused
`loop = asyncio.get_running_loop()` line. Replace:
```python
                analysis = await loop.run_in_executor(
                    None, lambda c=crop: DeepFace.analyze(
                        img_path=c, actions=["emotion"],
                        detector_backend="skip", enforce_detection=False))
```
with:
```python
                analysis = await run_inference(
                    lambda c=crop: DeepFace.analyze(
                        img_path=c, actions=["emotion"],
                        detector_backend="skip", enforce_detection=False))
```

- [ ] **Step 2: objects.py**

Add import: `from src.perception.infer import run_inference`. Remove the unused
`loop = asyncio.get_running_loop()` line. Replace:
```python
        return await loop.run_in_executor(None, self._detect_and_color, frame)
```
with:
```python
        return await run_inference(self._detect_and_color, frame)
```
(Note: this is the cache-miss branch from the Bug B throttle; the throttle's early-return path is unchanged.)

- [ ] **Step 3: attention.py**

Add import: `from src.perception.infer import run_inference`. Remove the unused
`loop = asyncio.get_running_loop()` line. Replace (`attention.py:146`):
```python
            poses = await loop.run_in_executor(None, self._estimate_poses, frame)
```
with:
```python
            poses = await run_inference(self._estimate_poses, frame)
```

- [ ] **Step 4: Run the analyzer suites**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_mood_analyzer.py tests/test_objects_analyzer.py tests/test_attention_analyzer.py -v`
Expected: PASS (the change is internal — same results via the shared worker).

- [ ] **Step 5: Commit**

```bash
git add src/perception/analyzers/mood.py src/perception/analyzers/objects.py src/perception/analyzers/attention.py
git commit -m "feat(vision): route mood/objects/attention inference through the worker"
```

---

### Task 4: Route the enroll embed through the worker (off the event loop)

**Files:**
- Modify: `src/enrollment/enroller.py`
- Test: existing enrollment suite must stay green

- [ ] **Step 1: Add the import**

In `enroller.py`: `from src.perception.infer import run_inference`.

- [ ] **Step 2: Reroute the embed call**

Replace (`enroller.py:75`):
```python
                embeddings.append(embedder.embed(img))
```
with:
```python
                embeddings.append(await run_inference(embedder.embed, img))
```
(`run_enrollment` is already `async`, so `await` is valid here. This serializes the enroll embed with the camera loop AND moves it off the event-loop thread.)

- [ ] **Step 3: Run the enrollment suite**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_enrollment.py -v`
Expected: PASS (the mocked `embedder.embed` is simply invoked via the worker).

- [ ] **Step 4: Full suite**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/enrollment/enroller.py
git commit -m "fix(vision): serialize enroll embed on the inference worker (fixes /enroll segfault)"
```

---

### Task 5: Live E2E — the real proof

**Files:** none (native crash can't be unit-tested; this is the definition of done).

- [ ] **Step 1: Start the stack** (your terminal): `cd /Users/jn/code/mras-ops && PERCEPTION_DEBUG=1 ./start-mras.sh`
- [ ] **Step 2: Stand in front of the camera** (so the camera loop is actively inferring — the exact condition that crashed before).
- [ ] **Step 3: Additive enroll via the LIVE endpoint** (the path that used to segfault):
  ```
  curl -s -F csv_file=@e.csv -F photos=@jason_now.jpg -F additive=true http://localhost:8001/enroll
  ```
  Expected: a JSON result (e.g. `{"enrolled":0,"updated":1,"failed":[]}`) and **vision stays up — no segmentation fault.**
- [ ] **Step 4: Confirm it served and survived:**
  ```
  docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT i.name, e.source, count(*) FROM identity_embeddings e JOIN identities i ON i.uuid=e.identity_uuid GROUP BY 1,2 ORDER BY 1,2;"
  ```
  And verify the vision process is still running (the `start-mras` terminal didn't print a segfault).
- [ ] **Step 5: Record** the result in `docs/SESSION_LOG.md` (live `/enroll` no longer crashes).

---

## Plan self-review (run before handing off)

- [ ] Full vision suite green: `.venv/bin/python -m pytest -q`; `import main` ok.
- [ ] `grep -rn "run_in_executor(None" src/ main.py` returns **only** `src/camera/capture.py` (the `cap.read` camera frame-grab — that is I/O, NOT ML inference, and must stay on the default pool; routing it through the single inference worker would block the worker). Every *inference* site must be gone.
- [ ] Live E2E (Task 5) observed — `/enroll` under live camera no longer segfaults. This is the definition of done.
