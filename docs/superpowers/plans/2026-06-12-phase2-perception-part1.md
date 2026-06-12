# Phase 2 Perception Part 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From live camera frames, identify objects (+ dominant color), per-person mood, and per-person attention ("is/was the ID'd person watching the ad"), stabilized by a face tracker, surfaced via `scene_context`, Postgres `gaze` events, and a `/debug/live` MJPEG view.

**Architecture:** A `FaceTracker` runs before the existing analyzer fan-out and accumulates 30–60 frames of per-person evidence; analyzers (objects via a multi-backend gateway, mood via DeepFace, attention via MediaPipe head-pose) read frames+tracks under the aggregator's existing 800ms budget; a gaze flusher writes per-track attention windows to the `events` table. Perception NEVER blocks identity dispatch.

**Tech Stack:** Python 3.11 (mras-vision native venv), DeepFace (already installed — emotion), ultralytics `yolo11n` (new), MediaPipe (new), OpenCV/numpy, FastAPI, asyncpg.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-12-phase2-perception-part1-design.md`
**Repo:** ALL code changes in `/Users/jn/code/mras-vision/`. Tests run with `/Users/jn/code/mras-vision/.venv/bin/python -m pytest` (host pyenv lacks deps).
**Git:** every git/gh step is delegated to the `git-flow-manager` subagent (`CLAUDE_GIT_OK=1` prefix; raw git is hook-blocked). Worktree per PR batch, branch from HEAD (never the literal word "main" as start-point). Red test committed separately from green implementation.

**PR batches (one worktree/branch/PR each):**
- **Batch 1 (Tasks 1–3):** `feat/p2p1-face-tracker` — embedder bboxes, tracker, aggregator signature.
- **Batch 2 (Tasks 4–7):** `feat/p2p1-objects` — gateway+fusion, YOLO backend, color, objects analyzer.
- **Batch 3 (Tasks 8–12):** `feat/p2p1-mood-attention` — mood, attention, gaze events, debug view, wiring + deps.

**Config knobs introduced (env, with defaults):** `VIEWER_MIN_EVIDENCE_S=3.0`, `ATTENTION_WINDOW_S=2.0`, `TRACK_EXPIRY_S=2.0`, `GAZE_FLUSH_S=3.0`, `ATTENTION_YAW_DEG=25`, `ATTENTION_PITCH_DEG=20`, `YOLO_CONF=0.4`, `PERCEPTION_DEBUG=0`. At `FRAME_SAMPLE_RATE=5` (~6 evidence frames/s), 3s ≈ 18 frames of evidence.

---

### Task 1: Embedder returns face bounding boxes

DeepFace already computes `facial_area` per face; we currently throw it away. The tracker needs it.

**Files:**
- Modify: `/Users/jn/code/mras-vision/src/detection/embedder.py`
- Test: `/Users/jn/code/mras-vision/tests/test_embedder.py` (exists — extend)

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_embedder.py
from unittest.mock import patch
import numpy as np
from src.detection.embedder import Embedder, Face


def test_embed_all_returns_faces_with_bboxes():
    reps = [
        {"embedding": [0.1] * 512, "facial_area": {"x": 10, "y": 20, "w": 100, "h": 120}},
        {"embedding": [0.2] * 512, "facial_area": {"x": 300, "y": 40, "w": 90, "h": 110}},
    ]
    with patch("src.detection.embedder.DeepFace.represent", return_value=reps):
        faces = Embedder().embed_all(np.zeros((480, 640, 3), dtype=np.uint8))
    assert len(faces) == 2
    assert isinstance(faces[0], Face)
    assert faces[0].bbox == (10, 20, 100, 120)
    assert faces[0].embedding.dtype == np.float32
    assert faces[0].embedding.shape == (512,)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_embedder.py::test_embed_all_returns_faces_with_bboxes -v`
Expected: FAIL — `ImportError: cannot import name 'Face'`

- [ ] **Step 3: Commit the red test** (git-flow-manager) — `test: embed_all returns Face(embedding, bbox) — red`

- [ ] **Step 4: Write minimal implementation**

```python
# src/detection/embedder.py — add near top
from dataclasses import dataclass


@dataclass
class Face:
    embedding: np.ndarray
    bbox: tuple  # (x, y, w, h) in frame pixels


# replace embed_all body:
    def embed_all(self, frame: np.ndarray) -> list:
        """One Face (embedding + bbox) per detected face (LIVE path)."""
        return [
            Face(
                embedding=np.asarray(rep["embedding"], dtype=np.float32),
                bbox=(rep["facial_area"]["x"], rep["facial_area"]["y"],
                      rep["facial_area"]["w"], rep["facial_area"]["h"]),
            )
            for rep in self._represent(frame)
        ]
```

Update `main.py::process_frame` minimally so the suite stays green (full rewiring is Task 12):

```python
    faces = await loop.run_in_executor(None, embedder.embed_all, frame)
    if not faces:
        return
    scene_context = await gather_scene_context(ANALYZERS, frame)
    for face in faces:
        await resolver.resolve(
            face.embedding,
            faces_in_frame=len(faces),
            scene_context=scene_context,
        )
```

Existing tests that assert `embed_all(...)[0]` is an ndarray: change the assertion to `.embedding` (and pipeline tests that feed fake embeddings now build `Face(embedding=…, bbox=(0, 0, 10, 10))`). Mock reps in those tests gain a `"facial_area"` key.

- [ ] **Step 5: Run the full vision suite, verify green**

Run: `.venv/bin/python -m pytest -v`
Expected: ALL PASS

- [ ] **Step 6: Commit** — `feat: embed_all returns Face(embedding, bbox)`

---

### Task 2: FaceTracker — the spine

Pure, no model deps, heavily tested. IoU match + embedding tiebreak + expiry + evidence buffers + uuid binding.

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/tracker.py`
- Test: `/Users/jn/code/mras-vision/tests/test_tracker.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_tracker.py
import numpy as np
from src.detection.embedder import Face
from src.perception.tracker import FaceTracker, iou


def _face(x, y, w=100, h=120, emb_val=0.1):
    e = np.full(512, emb_val, dtype=np.float32)
    return Face(embedding=e / np.linalg.norm(e), bbox=(x, y, w, h))


def test_iou_overlapping_and_disjoint():
    assert iou((0, 0, 10, 10), (0, 0, 10, 10)) == 1.0
    assert iou((0, 0, 10, 10), (100, 100, 10, 10)) == 0.0


def test_same_face_keeps_track_id_across_frames():
    t = FaceTracker()
    [tr1] = t.update([_face(100, 100)], now=0.0)
    [tr2] = t.update([_face(110, 105)], now=0.2)  # small drift, high IoU
    assert tr1.track_id == tr2.track_id


def test_crossing_people_resolved_by_embedding_tiebreak():
    t = FaceTracker()
    a = _face(0, 0, emb_val=1.0)
    b = _face(500, 0, emb_val=-1.0)
    tracks = {tr.bbox[0]: tr.track_id for tr in t.update([a, b], now=0.0)}
    # both jump near the middle: IoU vs both priors is 0 → embeddings decide
    a2 = Face(embedding=a.embedding, bbox=(240, 0, 100, 120))
    b2 = Face(embedding=b.embedding, bbox=(260, 0, 100, 120))
    out = t.update([a2, b2], now=0.2)
    by_emb = {float(tr.embedding[0]): tr.track_id for tr in out}
    assert by_emb[float(a.embedding[0])] == tracks[0]
    assert by_emb[float(b.embedding[0])] == tracks[500]


def test_track_expires_and_lands_in_closed_pending():
    t = FaceTracker(expiry_s=2.0)
    [tr] = t.update([_face(100, 100)], now=0.0)
    live = t.update([], now=3.0)
    assert live == []
    assert [c.track_id for c in t.drain_closed()] == [tr.track_id]
    assert t.drain_closed() == []  # drained once


def test_uuid_binding_sticks():
    t = FaceTracker()
    [tr] = t.update([_face(100, 100)], now=0.0)
    tr.bind_uuid("f487f5b0-aaaa")
    [tr2] = t.update([_face(102, 101)], now=0.2)
    assert tr2.uuid == "f487f5b0-aaaa"
    tr2.bind_uuid("other")  # second bind is a no-op
    assert tr2.uuid == "f487f5b0-aaaa"


def test_viewer_summary_gated_by_dwell_then_reports_mood_and_attention():
    t = FaceTracker()
    [tr] = t.update([_face(100, 100)], now=0.0)
    for i in range(10):
        tr.add_mood_vote("happy", 0.8, ts=i * 0.2)
        tr.add_attention_sample(True, ts=i * 0.2)
    tr.add_mood_vote("angry", 0.9, ts=1.9)  # one blink-frame outlier
    assert tr.viewer_summary(now=1.0, min_evidence_s=3.0) is None  # gated
    s = tr.viewer_summary(now=3.5, min_evidence_s=3.0, window_s=2.0)
    assert s["mood"] == "happy"          # majority beats the outlier
    assert s["attending"] is True
    assert s["track_id"] == tr.track_id
    assert s["evidence_frames"] == 11


def test_attending_fraction_since():
    t = FaceTracker()
    [tr] = t.update([_face(100, 100)], now=0.0)
    for i, a in enumerate([True, True, False, True]):
        tr.add_attention_sample(a, ts=float(i))
    frac, n = tr.attending_fraction_since(0.5)   # samples at ts 1,2,3
    assert n == 3
    assert abs(frac - 2 / 3) < 1e-9
```

- [ ] **Step 2: Run, verify fail** — `.venv/bin/python -m pytest tests/test_tracker.py -v` → `ModuleNotFoundError: src.perception.tracker`

- [ ] **Step 3: Commit red** — `test: FaceTracker matching, expiry, binding, evidence — red`

- [ ] **Step 4: Implement**

```python
# src/perception/tracker.py
"""Face tracking — the Phase 2 spine (spec 2026-06-12).

Matches faces frame-to-frame (IoU first, ArcFace-embedding cosine as the
tiebreaker), accumulates per-track mood/attention evidence over 30-60
frames, binds track_id <-> identity uuid once resolved. Pure module: no
model deps, in-process state only (Redis stays transient-flags-only).
"""
import itertools
import time
from collections import Counter, deque
from dataclasses import dataclass, field

import numpy as np

_IOU_THRESHOLD = 0.3
_EMBED_THRESHOLD = 0.75
_counter = itertools.count(1)


def iou(a, b) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    union = aw * ah + bw * bh - inter
    return inter / union if union else 0.0


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b)) / denom if denom else 0.0


@dataclass
class Track:
    track_id: str
    bbox: tuple
    embedding: np.ndarray
    first_seen: float
    last_seen: float
    uuid: str | None = None
    mood_votes: deque = field(default_factory=lambda: deque(maxlen=60))
    attention_samples: deque = field(default_factory=lambda: deque(maxlen=120))
    flushed_through: float = 0.0  # gaze samples <= this ts already in Postgres

    def bind_uuid(self, uuid: str) -> None:
        if self.uuid is None:
            self.uuid = uuid

    def add_mood_vote(self, label: str, confidence: float, ts: float) -> None:
        self.mood_votes.append((label, confidence, ts))

    def add_attention_sample(self, attending: bool, ts: float) -> None:
        self.attention_samples.append((ts, attending))

    def viewer_summary(self, now: float, min_evidence_s: float = 3.0,
                       window_s: float = 2.0) -> dict | None:
        if now - self.first_seen < min_evidence_s or not self.mood_votes:
            return None
        counts = Counter(label for label, _, _ in self.mood_votes)
        mood = counts.most_common(1)[0][0]
        confs = [c for label, c, _ in self.mood_votes if label == mood]
        recent = [a for ts, a in self.attention_samples if now - ts <= window_s]
        return {
            "track_id": self.track_id,
            "mood": mood,
            "mood_confidence": round(sum(confs) / len(confs), 2),
            "attending": sum(recent) * 2 >= len(recent) if recent else False,
            "evidence_frames": len(self.mood_votes),
        }

    def attending_fraction_since(self, ts: float) -> tuple[float, int]:
        window = [a for t, a in self.attention_samples if t > ts]
        if not window:
            return 0.0, 0
        return sum(window) / len(window), len(window)


class FaceTracker:
    def __init__(self, expiry_s: float = 2.0,
                 iou_threshold: float = _IOU_THRESHOLD,
                 embed_threshold: float = _EMBED_THRESHOLD) -> None:
        self._tracks: dict[str, Track] = {}
        self._closed: list[Track] = []
        self._expiry_s = expiry_s
        self._iou_t = iou_threshold
        self._emb_t = embed_threshold

    def update(self, faces: list, now: float | None = None) -> list:
        now = time.monotonic() if now is None else now
        unmatched_tracks = dict(self._tracks)
        assigned: list[tuple] = []

        # Pass 1 — IoU greedy (best overlap first).
        pairs = sorted(
            ((iou(f.bbox, tr.bbox), f, tr)
             for f in faces for tr in unmatched_tracks.values()),
            key=lambda p: p[0], reverse=True,
        )
        matched_faces: set[int] = set()
        for score, f, tr in pairs:
            if score < self._iou_t:
                break
            if id(f) in matched_faces or tr.track_id not in unmatched_tracks:
                continue
            assigned.append((f, tr))
            matched_faces.add(id(f))
            del unmatched_tracks[tr.track_id]

        # Pass 2 — embedding tiebreak for what IoU couldn't place.
        for f in faces:
            if id(f) in matched_faces:
                continue
            best, best_sim = None, self._emb_t
            for tr in unmatched_tracks.values():
                sim = _cosine(f.embedding, tr.embedding)
                if sim >= best_sim:
                    best, best_sim = tr, sim
            if best is not None:
                assigned.append((f, best))
                matched_faces.add(id(f))
                del unmatched_tracks[best.track_id]

        for f, tr in assigned:
            tr.bbox, tr.embedding, tr.last_seen = f.bbox, f.embedding, now
        for f in faces:
            if id(f) not in matched_faces:
                tr = Track(track_id=f"t-{next(_counter)}", bbox=f.bbox,
                           embedding=f.embedding, first_seen=now, last_seen=now)
                self._tracks[tr.track_id] = tr

        # Expire stale tracks → closed_pending (gaze logger drains them).
        for tid, tr in list(self._tracks.items()):
            if now - tr.last_seen > self._expiry_s:
                self._closed.append(tr)
                del self._tracks[tid]
        return list(self._tracks.values())

    def live_tracks(self) -> list:
        return list(self._tracks.values())

    def drain_closed(self) -> list:
        closed, self._closed = self._closed, []
        return closed

    def track_for_bbox(self, bbox: tuple):
        """The live track whose box best overlaps bbox (None if no overlap)."""
        best = max(self._tracks.values(), key=lambda tr: iou(bbox, tr.bbox),
                   default=None)
        return best if best and iou(bbox, best.bbox) > 0 else None
```

- [ ] **Step 5: Run, verify green** — `.venv/bin/python -m pytest tests/test_tracker.py -v` → ALL PASS
- [ ] **Step 6: Commit** — `feat: FaceTracker — IoU+embedding tracking, evidence buffers, uuid binding`

---

### Task 3: Aggregator takes tracks; None results omitted

The swap the aggregator docstring promised: `analyze(frame, tracks)`. Person-analyzers (mood/attention) update tracks and return `None` — `None` must not pollute `scene_context`.

**Files:**
- Modify: `/Users/jn/code/mras-vision/src/perception/aggregator.py`
- Test: `/Users/jn/code/mras-vision/tests/test_aggregator.py` (exists — extend)

- [ ] **Step 1: Write the failing tests**

```python
# append to tests/test_aggregator.py
import pytest
from src.perception.aggregator import gather_scene_context


class _TrackReader:
    name = "mood"
    def __init__(self):
        self.seen_tracks = None
    async def analyze(self, frame, tracks):
        self.seen_tracks = tracks
        return None  # person-analyzer: writes into tracks, adds nothing scene-wide


class _SceneAnalyzer:
    name = "objects"
    async def analyze(self, frame, tracks):
        return [{"label": "cup"}]


@pytest.mark.asyncio
async def test_analyzers_receive_tracks_and_none_results_are_omitted():
    reader = _TrackReader()
    tracks = ["t1", "t2"]
    ctx = await gather_scene_context([reader, _SceneAnalyzer()], "frame", tracks)
    assert reader.seen_tracks == tracks
    assert ctx == {"objects": [{"label": "cup"}]}  # no "mood": None key
```

- [ ] **Step 2: Run, verify fail** — `.venv/bin/python -m pytest tests/test_aggregator.py -v` → FAIL (`analyze() takes 2 positional arguments but 3 were given` or TypeError on gather signature)
- [ ] **Step 3: Commit red** — `test: aggregator passes tracks, omits None results — red`
- [ ] **Step 4: Implement** — in `src/perception/aggregator.py`:

```python
class Analyzer(Protocol):
    name: str

    async def analyze(self, frame, tracks) -> dict | None: ...


async def gather_scene_context(analyzers, frame, tracks=None,
                               budget_ms: int = 800) -> dict:
    if not analyzers:
        return {}
    tracks = tracks or []
    tasks = {asyncio.create_task(a.analyze(frame, tracks)): a.name
             for a in analyzers}
    done, pending = await asyncio.wait(tasks, timeout=budget_ms / 1000)
    for task in pending:
        task.cancel()  # missed the budget — the ad ships without this signal
    context: dict = {}
    for task in done:
        try:
            result = task.result()
        except Exception:
            continue  # a broken analyzer costs its own signal, nothing else
        if result is not None:
            context[tasks[task]] = result
    return context
```

Update the existing aggregator tests' fake analyzers to the `analyze(self, frame, tracks)` signature. Update the module docstring: tracking has landed; analyzers take `(frame, tracks)`.

- [ ] **Step 5: Run full suite, verify green** — `.venv/bin/python -m pytest -v` → ALL PASS
- [ ] **Step 6: Commit** — `feat: aggregator passes tracks to analyzers, omits None results`
- [ ] **Step 7: Batch 1 close-out** — git-flow-manager: push `feat/p2p1-face-tracker`, open PR ("Phase 2 perception 1/3: face tracker spine"), self-review, request code review, merge after green; rebuild not needed (vision runs native).

---

### Task 4: Object gateway with multi-backend fusion

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/objects/__init__.py` (empty)
- Create: `/Users/jn/code/mras-vision/src/perception/objects/gateway.py`
- Test: `/Users/jn/code/mras-vision/tests/test_object_gateway.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_object_gateway.py
from src.perception.objects.gateway import Detection, ObjectGateway, fuse


def _d(label, conf, bbox=(0, 0, 100, 100), source="a"):
    return Detection(label=label, confidence=conf, bbox=bbox, source=source)


def test_fuse_agreeing_labels_average_confidence_and_merge_sources():
    [out] = fuse([[_d("cup", 0.8, source="yolo")], [_d("cup", 0.6, source="la")]])
    assert out.label == "cup"
    assert abs(out.confidence - 0.7) < 1e-9
    assert out.source == "la+yolo"


def test_fuse_conflicting_overlap_highest_confidence_wins():
    out = fuse([[_d("cup", 0.9, source="yolo")], [_d("bottle", 0.6, source="la")]])
    assert [(o.label, o.source) for o in out] == [("cup", "yolo")]


def test_fuse_disjoint_boxes_both_kept():
    out = fuse([[_d("cup", 0.9)], [_d("dog", 0.8, bbox=(500, 500, 80, 80))]])
    assert {o.label for o in out} == {"cup", "dog"}


def test_gateway_skips_failing_backend():
    class Good:
        name = "good"
        def detect(self, frame):
            return [_d("cup", 0.9, source="good")]

    class Broken:
        name = "broken"
        def detect(self, frame):
            raise RuntimeError("backend down")

    out = ObjectGateway([Broken(), Good()]).detect("frame")
    assert [o.label for o in out] == ["cup"]
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError: src.perception.objects`
- [ ] **Step 3: Commit red** — `test: object gateway fusion + backend isolation — red`
- [ ] **Step 4: Implement**

```python
# src/perception/objects/gateway.py
"""Multi-backend object detection gateway (owner direction 2026-06-12).

Backends (local YOLO today; Nvidia LocateAnything / cloud VLMs later) all
return Detection lists; fuse() merges them — overlapping boxes with the
SAME label average their confidence, conflicting labels keep the highest
confidence. A failing backend is skipped: it can never kill detection.
"""
import logging
from dataclasses import dataclass, replace
from typing import Protocol

from src.perception.tracker import iou

_FUSE_IOU = 0.5
logger = logging.getLogger(__name__)


@dataclass
class Detection:
    label: str
    confidence: float
    bbox: tuple  # (x, y, w, h)
    source: str


class DetectorBackend(Protocol):
    name: str

    def detect(self, frame) -> list: ...


def fuse(per_backend: list) -> list:
    flat = sorted((d for ds in per_backend for d in ds),
                  key=lambda d: d.confidence, reverse=True)
    kept: list[Detection] = []
    for d in flat:
        overlap = next((k for k in kept if iou(d.bbox, k.bbox) >= _FUSE_IOU), None)
        if overlap is None:
            kept.append(d)
        elif overlap.label == d.label:
            i = kept.index(overlap)
            kept[i] = replace(
                overlap,
                confidence=(overlap.confidence + d.confidence) / 2,
                source="+".join(sorted({overlap.source, d.source})),
            )
        # conflicting label on the same box: higher confidence already kept
    return kept


class ObjectGateway:
    def __init__(self, backends: list) -> None:
        self._backends = backends

    def detect(self, frame) -> list:
        results = []
        for b in self._backends:
            try:
                results.append(b.detect(frame))
            except Exception as exc:
                logger.warning("object backend %s failed (%s) — skipped",
                               b.name, exc)
        return fuse(results)
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: object gateway — multi-backend fusion, failure isolation`

---

### Task 5: YOLO backend

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/objects/yolo_backend.py`
- Modify: `/Users/jn/code/mras-vision/requirements.txt` (add `ultralytics>=8.2`)
- Test: `/Users/jn/code/mras-vision/tests/test_yolo_backend.py`

- [ ] **Step 1: Write the failing test** (mock the model — unit tests never load weights)

```python
# tests/test_yolo_backend.py
from unittest.mock import MagicMock
import numpy as np
from src.perception.objects.yolo_backend import YoloBackend


def _fake_result():
    box = MagicMock()
    box.cls = [MagicMock(item=lambda: 0)]
    box.conf = [MagicMock(item=lambda: 0.87)]
    xywh = np.array([[150.0, 200.0, 100.0, 80.0]])  # ultralytics: center x,y,w,h
    box.xywh = xywh
    result = MagicMock()
    result.boxes = [box]
    result.names = {0: "backpack"}
    return result


def test_detect_maps_yolo_output_to_detections():
    backend = YoloBackend()
    backend._model = MagicMock()
    backend._model.predict.return_value = [_fake_result()]
    [d] = backend.detect(np.zeros((480, 640, 3), dtype=np.uint8))
    assert d.label == "backpack"
    assert d.confidence == 0.87
    assert d.bbox == (100, 160, 100, 80)  # center → top-left corner
    assert d.source == "yolo11n"
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError: src.perception.objects.yolo_backend`
- [ ] **Step 3: Commit red** — `test: YOLO backend output mapping — red`
- [ ] **Step 4: Install dep + implement**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/pip install 'ultralytics>=8.2'` and add `ultralytics>=8.2` to `requirements.txt`.

```python
# src/perception/objects/yolo_backend.py
import os

from src.perception.objects.gateway import Detection

_CONF = float(os.getenv("YOLO_CONF", "0.4"))


class YoloBackend:
    name = "yolo11n"

    def __init__(self, model_path: str = "yolo11n.pt", conf: float = _CONF) -> None:
        self._model_path = model_path
        self._conf = conf
        self._model = None  # lazy: ultralytics import + weights only on first use

    def prewarm(self) -> None:
        self._ensure_model()

    def _ensure_model(self):
        if self._model is None:
            from ultralytics import YOLO  # import here: keeps test imports light
            self._model = YOLO(self._model_path)
        return self._model

    def detect(self, frame) -> list:
        results = self._ensure_model().predict(frame, conf=self._conf, verbose=False)
        detections = []
        for box in results[0].boxes:
            cx, cy, w, h = (float(v) for v in box.xywh[0])
            detections.append(Detection(
                label=results[0].names[int(box.cls[0].item())],
                confidence=round(float(box.conf[0].item()), 2),
                bbox=(int(cx - w / 2), int(cy - h / 2), int(w), int(h)),
                source=self.name,
            ))
        return detections
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Smoke the real model once (not in the suite):** `.venv/bin/python -c "from src.perception.objects.yolo_backend import YoloBackend; import cv2; b=YoloBackend(); b.prewarm(); print(b.detect(cv2.imread('tests/e2e/fixtures/test_face.jpg')))"` — expect at least `person` detected, ~weights auto-download on first run.
- [ ] **Step 7: Commit** — `feat: yolo11n object backend (lazy load, prewarm)`

---

### Task 6: Dominant color naming

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/objects/color.py`
- Test: `/Users/jn/code/mras-vision/tests/test_color.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_color.py
import numpy as np
from src.perception.objects.color import dominant_color_name


def _solid(bgr):
    return np.full((50, 50, 3), bgr, dtype=np.uint8)


def test_solid_colors_get_named():
    assert dominant_color_name(_solid((0, 0, 200))) == "red"      # BGR!
    assert dominant_color_name(_solid((200, 0, 0))) == "blue"
    assert dominant_color_name(_solid((255, 255, 255))) == "white"
    assert dominant_color_name(_solid((0, 0, 0))) == "black"


def test_majority_color_wins_in_mixed_crop():
    crop = _solid((0, 0, 200))
    crop[:10, :, :] = (200, 0, 0)  # 20% blue stripe
    assert dominant_color_name(crop) == "red"


def test_empty_crop_returns_unknown():
    assert dominant_color_name(np.zeros((0, 0, 3), dtype=np.uint8)) == "unknown"
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError`
- [ ] **Step 3: Commit red** — `test: dominant color naming — red`
- [ ] **Step 4: Implement**

```python
# src/perception/objects/color.py
"""Dominant color of an object crop → nearest named color. No model."""
import cv2
import numpy as np

_PALETTE = {  # RGB
    "red": (200, 30, 40), "orange": (255, 140, 0), "yellow": (250, 220, 50),
    "green": (60, 160, 60), "teal": (0, 150, 150), "blue": (40, 80, 200),
    "navy": (20, 30, 90), "purple": (130, 60, 180), "pink": (240, 130, 180),
    "brown": (130, 80, 40), "beige": (220, 200, 170), "white": (245, 245, 245),
    "gray": (130, 130, 130), "black": (15, 15, 15),
}


def dominant_color_name(crop_bgr: np.ndarray) -> str:
    if crop_bgr.size == 0:
        return "unknown"
    pixels = crop_bgr.reshape(-1, 3).astype(np.float32)
    k = min(3, len(pixels))
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 10, 1.0)
    _, labels, centers = cv2.kmeans(pixels, k, None, criteria, 3,
                                    cv2.KMEANS_PP_CENTERS)
    dominant_bgr = centers[np.bincount(labels.flatten()).argmax()]
    r, g, b = dominant_bgr[2], dominant_bgr[1], dominant_bgr[0]
    return min(_PALETTE,
               key=lambda n: (r - _PALETTE[n][0]) ** 2
                           + (g - _PALETTE[n][1]) ** 2
                           + (b - _PALETTE[n][2]) ** 2)
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: k-means dominant color naming`

---

### Task 7: Objects analyzer

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/analyzers/__init__.py` (empty)
- Create: `/Users/jn/code/mras-vision/src/perception/analyzers/objects.py`
- Test: `/Users/jn/code/mras-vision/tests/test_objects_analyzer.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_objects_analyzer.py
import numpy as np
import pytest
from src.perception.analyzers.objects import ObjectsAnalyzer
from src.perception.objects.gateway import Detection


class _FakeGateway:
    def detect(self, frame):
        return [Detection(label="backpack", confidence=0.87,
                          bbox=(10, 10, 30, 30), source="yolo11n")]


@pytest.mark.asyncio
async def test_objects_analyzer_attaches_color():
    frame = np.zeros((100, 100, 3), dtype=np.uint8)
    frame[10:40, 10:40] = (0, 0, 200)  # red square where the backpack is
    [obj] = await ObjectsAnalyzer(_FakeGateway()).analyze(frame, tracks=[])
    assert obj == {"label": "backpack", "confidence": 0.87, "color": "red",
                   "bbox": [10, 10, 30, 30], "source": "yolo11n"}
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError`
- [ ] **Step 3: Commit red** — `test: objects analyzer attaches color — red`
- [ ] **Step 4: Implement**

```python
# src/perception/analyzers/objects.py
import asyncio

from src.perception.objects.color import dominant_color_name


class ObjectsAnalyzer:
    """Scene-wide: detect objects via the gateway, attach dominant color."""

    name = "objects"

    def __init__(self, gateway) -> None:
        self._gateway = gateway

    async def analyze(self, frame, tracks) -> list:
        loop = asyncio.get_running_loop()
        detections = await loop.run_in_executor(None, self._gateway.detect, frame)
        objects = []
        for d in detections:
            x, y, w, h = d.bbox
            crop = frame[max(0, y):y + h, max(0, x):x + w]
            objects.append({
                "label": d.label, "confidence": d.confidence,
                "color": dominant_color_name(crop),
                "bbox": list(d.bbox), "source": d.source,
            })
        return objects
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: objects analyzer (gateway + color)`
- [ ] **Step 7: Batch 2 close-out** — push `feat/p2p1-objects`, PR "Phase 2 perception 2/3: objects + colors", review, merge.

---

### Task 8: Mood analyzer (DeepFace emotion — already installed)

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/analyzers/mood.py`
- Test: `/Users/jn/code/mras-vision/tests/test_mood_analyzer.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_mood_analyzer.py
from unittest.mock import patch
import numpy as np
import pytest
from src.detection.embedder import Face
from src.perception.analyzers.mood import MoodAnalyzer
from src.perception.tracker import FaceTracker


@pytest.mark.asyncio
async def test_mood_votes_land_on_the_right_track():
    tracker = FaceTracker()
    emb = np.ones(512, dtype=np.float32)
    [track] = tracker.update([Face(embedding=emb, bbox=(100, 100, 80, 100))], now=0.0)
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    analysis = [{"dominant_emotion": "happy", "emotion": {"happy": 92.1}}]
    with patch("src.perception.analyzers.mood.DeepFace.analyze",
               return_value=analysis) as mock:
        result = await MoodAnalyzer().analyze(frame, [track])
    assert result is None                      # person-analyzer adds no scene key
    label, conf, _ = track.mood_votes[-1]
    assert label == "happy"
    assert abs(conf - 0.92) < 0.01
    crop = mock.call_args.kwargs["img_path"]
    assert crop.shape == (100, 80, 3)          # analyzed the track's face crop


@pytest.mark.asyncio
async def test_deepface_failure_costs_nothing():
    tracker = FaceTracker()
    [track] = tracker.update(
        [Face(embedding=np.ones(512, dtype=np.float32), bbox=(10, 10, 50, 50))],
        now=0.0)
    with patch("src.perception.analyzers.mood.DeepFace.analyze",
               side_effect=RuntimeError("model exploded")):
        result = await MoodAnalyzer().analyze(
            np.zeros((480, 640, 3), dtype=np.uint8), [track])
    assert result is None
    assert len(track.mood_votes) == 0
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError`
- [ ] **Step 3: Commit red** — `test: mood analyzer votes per track, failure-isolated — red`
- [ ] **Step 4: Implement**

```python
# src/perception/analyzers/mood.py
import asyncio
import time

from deepface import DeepFace


class MoodAnalyzer:
    """Per-person: DeepFace emotion on each track's face crop → mood vote.

    Returns None — evidence accumulates IN the track; viewer_summary()
    reports it once the dwell gate passes.
    """

    name = "mood"

    async def analyze(self, frame, tracks) -> None:
        loop = asyncio.get_running_loop()
        now = time.monotonic()
        for track in tracks:
            x, y, w, h = track.bbox
            crop = frame[max(0, y):y + h, max(0, x):x + w]
            if crop.size == 0:
                continue
            try:
                analysis = await loop.run_in_executor(
                    None, lambda c=crop: DeepFace.analyze(
                        img_path=c, actions=["emotion"],
                        detector_backend="skip", enforce_detection=False))
            except Exception:
                continue  # this frame's vote is lost; the track survives
            dominant = analysis[0]["dominant_emotion"]
            confidence = analysis[0]["emotion"][dominant] / 100.0
            track.add_mood_vote(dominant, round(confidence, 2), now)
        return None
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: mood analyzer — DeepFace emotion votes per track`

---

### Task 9: Attention analyzer (MediaPipe head-pose)

The MediaPipe call is thin glue; the tested logic is the yaw/pitch cone and pose→track matching.

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/analyzers/attention.py`
- Modify: `/Users/jn/code/mras-vision/requirements.txt` (add `mediapipe>=0.10`)
- Test: `/Users/jn/code/mras-vision/tests/test_attention_analyzer.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_attention_analyzer.py
from unittest.mock import patch
import numpy as np
import pytest
from src.detection.embedder import Face
from src.perception.analyzers.attention import AttentionAnalyzer, HeadPose, is_attending
from src.perception.tracker import FaceTracker


def test_attending_cone():
    assert is_attending(HeadPose(center=(0, 0), yaw=0.0, pitch=0.0))
    assert is_attending(HeadPose(center=(0, 0), yaw=24.0, pitch=-19.0))
    assert not is_attending(HeadPose(center=(0, 0), yaw=40.0, pitch=0.0))
    assert not is_attending(HeadPose(center=(0, 0), yaw=0.0, pitch=30.0))


@pytest.mark.asyncio
async def test_samples_land_on_track_whose_bbox_contains_pose_center():
    tracker = FaceTracker()
    emb = np.ones(512, dtype=np.float32)
    [near, far] = tracker.update(
        [Face(embedding=emb, bbox=(100, 100, 80, 100)),
         Face(embedding=-emb, bbox=(400, 100, 80, 100))], now=0.0)
    poses = [HeadPose(center=(140, 150), yaw=5.0, pitch=0.0),    # in `near`
             HeadPose(center=(440, 150), yaw=60.0, pitch=0.0)]   # in `far`
    with patch.object(AttentionAnalyzer, "_estimate_poses", return_value=poses):
        result = await AttentionAnalyzer().analyze(
            np.zeros((480, 640, 3), dtype=np.uint8), [near, far])
    assert result is None
    assert near.attention_samples[-1][1] is True
    assert far.attention_samples[-1][1] is False
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError`
- [ ] **Step 3: Commit red** — `test: attention cone + pose→track matching — red`
- [ ] **Step 4: Install dep + implement**

Run: `.venv/bin/pip install 'mediapipe>=0.10'`; add `mediapipe>=0.10` to `requirements.txt`.

```python
# src/perception/analyzers/attention.py
"""Per-person attention: head orientation toward the display camera.

Honest framing (spec): single webcam → this is HEAD POSE (yaw/pitch within
a cone), the standard kiosk-distance proxy, not true eye-gaze. The default
camera IS the display camera (owner decision 2026-06-12).
"""
import asyncio
import os
import time
from dataclasses import dataclass

import cv2
import numpy as np

_YAW_DEG = float(os.getenv("ATTENTION_YAW_DEG", "25"))
_PITCH_DEG = float(os.getenv("ATTENTION_PITCH_DEG", "20"))

# Canonical 3D face-model points (nose, chin, eye corners, mouth corners)
# matched to MediaPipe FaceMesh landmark indices for solvePnP.
_MODEL_POINTS = np.array([
    (0.0, 0.0, 0.0), (0.0, -330.0, -65.0), (-225.0, 170.0, -135.0),
    (225.0, 170.0, -135.0), (-150.0, -150.0, -125.0), (150.0, -150.0, -125.0),
], dtype=np.float64)
_MESH_IDS = [1, 152, 263, 33, 287, 57]


@dataclass
class HeadPose:
    center: tuple  # (x, y) face center in frame pixels
    yaw: float     # degrees; 0 = facing the camera
    pitch: float


def is_attending(pose: HeadPose) -> bool:
    return abs(pose.yaw) <= _YAW_DEG and abs(pose.pitch) <= _PITCH_DEG


def _in_bbox(point: tuple, bbox: tuple) -> bool:
    px, py = point
    x, y, w, h = bbox
    return x <= px <= x + w and y <= py <= y + h


class AttentionAnalyzer:
    name = "attention"

    def __init__(self) -> None:
        self._mesh = None  # lazy: mediapipe import only on first live frame

    def _ensure_mesh(self):
        if self._mesh is None:
            import mediapipe as mp
            self._mesh = mp.solutions.face_mesh.FaceMesh(
                static_image_mode=False, max_num_faces=10, refine_landmarks=False)
        return self._mesh

    def _estimate_poses(self, frame) -> list:
        """MediaPipe FaceMesh → one HeadPose per face via solvePnP."""
        h, w = frame.shape[:2]
        results = self._ensure_mesh().process(
            cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        poses = []
        for landmarks in (results.multi_face_landmarks or []):
            pts = np.array([(landmarks.landmark[i].x * w,
                             landmarks.landmark[i].y * h)
                            for i in _MESH_IDS], dtype=np.float64)
            cam = np.array([[w, 0, w / 2], [0, w, h / 2], [0, 0, 1]],
                           dtype=np.float64)
            ok, rvec, _ = cv2.solvePnP(_MODEL_POINTS, pts, cam,
                                       np.zeros((4, 1)),
                                       flags=cv2.SOLVEPNP_ITERATIVE)
            if not ok:
                continue
            rot, _ = cv2.Rodrigues(rvec)
            sy = np.sqrt(rot[0, 0] ** 2 + rot[1, 0] ** 2)
            pitch = float(np.degrees(np.arctan2(-rot[2, 0], sy)))
            yaw = float(np.degrees(np.arctan2(rot[1, 0], rot[0, 0])))
            poses.append(HeadPose(center=(float(pts[0][0]), float(pts[0][1])),
                                  yaw=yaw, pitch=pitch))
        return poses

    async def analyze(self, frame, tracks) -> None:
        loop = asyncio.get_running_loop()
        try:
            poses = await loop.run_in_executor(None, self._estimate_poses, frame)
        except Exception:
            return None  # this frame's samples are lost; tracks survive
        now = time.monotonic()
        for pose in poses:
            for track in tracks:
                if _in_bbox(pose.center, track.bbox):
                    track.add_attention_sample(is_attending(pose), now)
                    break
        return None
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: attention analyzer — head-pose cone per track`

---

### Task 10: Gaze flusher → Postgres `gaze` events

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/gaze_log.py`
- Test: `/Users/jn/code/mras-vision/tests/test_gaze_log.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_gaze_log.py
import json
from unittest.mock import AsyncMock
import numpy as np
import pytest
from src.detection.embedder import Face
from src.perception.gaze_log import GazeLogger
from src.perception.tracker import FaceTracker


def _tracker_with_samples(now=10.0):
    tracker = FaceTracker()
    [track] = tracker.update(
        [Face(embedding=np.ones(512, dtype=np.float32), bbox=(0, 0, 50, 50))],
        now=0.0)
    track.bind_uuid("f487f5b0-aaaa")
    for i, a in enumerate([True, True, False]):
        track.add_attention_sample(a, ts=now - 2 + i * 0.5)
    return tracker, track


@pytest.mark.asyncio
async def test_flush_writes_gaze_event_and_advances_watermark():
    db = AsyncMock()
    tracker, track = _tracker_with_samples()
    logger = GazeLogger(db, screen_id="display-1")
    await logger.flush(tracker, now=10.0)
    args = db.execute.call_args.args
    assert "INSERT INTO events" in args[0]
    assert args[3] == "gaze"
    payload = json.loads(args[5])
    assert payload["uuid"] == "f487f5b0-aaaa"
    assert payload["track_id"] == track.track_id
    assert payload["samples"] == 3
    assert abs(payload["attending_fraction"] - 2 / 3) < 1e-9
    assert payload["screen_id"] == "display-1"
    assert track.flushed_through == 10.0
    db.execute.reset_mock()
    await logger.flush(tracker, now=11.0)   # nothing new since watermark
    db.execute.assert_not_called()


@pytest.mark.asyncio
async def test_closed_tracks_get_final_flush():
    db = AsyncMock()
    tracker, track = _tracker_with_samples()
    tracker.update([], now=20.0)            # expiry closes the track
    await GazeLogger(db, screen_id="display-1").flush(tracker, now=20.0)
    assert db.execute.call_count == 1       # final flush from drain_closed()


@pytest.mark.asyncio
async def test_db_failure_is_swallowed():
    db = AsyncMock()
    db.execute.side_effect = RuntimeError("pg down")
    tracker, _ = _tracker_with_samples()
    await GazeLogger(db, screen_id="display-1").flush(tracker, now=10.0)  # no raise
```

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError`
- [ ] **Step 3: Commit red** — `test: gaze flusher — windows, watermark, final flush — red`
- [ ] **Step 4: Implement**

```python
# src/perception/gaze_log.py
"""Periodic per-track attention summaries → events table (`gaze` rows).

"Did X watch the ad" = query-time join of gaze rows against playback rows
(same screen, overlapping window). No new cross-service wiring (spec)."""
import asyncio
import json
import logging
import os
import time
import uuid as uuid_mod
from datetime import datetime, timedelta, timezone

_FLUSH_S = float(os.getenv("GAZE_FLUSH_S", "3.0"))
logger = logging.getLogger(__name__)


class GazeLogger:
    def __init__(self, db_pool, screen_id: str, flush_s: float = _FLUSH_S) -> None:
        self._db = db_pool
        self._screen_id = screen_id
        self._flush_s = flush_s

    async def run(self, tracker) -> None:
        while True:
            await asyncio.sleep(self._flush_s)
            await self.flush(tracker, now=time.monotonic())

    async def flush(self, tracker, now: float) -> None:
        for track in tracker.live_tracks() + tracker.drain_closed():
            fraction, samples = track.attending_fraction_since(track.flushed_through)
            if samples == 0:
                continue
            window_s = now - max(track.flushed_through, track.first_seen)
            wall_end = datetime.now(timezone.utc)
            payload = {
                "track_id": track.track_id,
                "uuid": track.uuid,
                "window_start": (wall_end - timedelta(seconds=window_s)).isoformat(),
                "window_end": wall_end.isoformat(),
                "attending_fraction": round(fraction, 3),
                "samples": samples,
                "screen_id": self._screen_id,
            }
            track.flushed_through = now
            try:
                await self._db.execute(
                    "INSERT INTO events "
                    "(trigger_id, ts, service, event_type, status, payload) "
                    "VALUES ($1, $2, 'mras-vision', $3, $4, $5::jsonb)",
                    str(uuid_mod.uuid4()), wall_end, "gaze", "success",
                    json.dumps(payload),
                )
            except Exception as exc:
                logger.error("gaze flush failed: %s", exc)  # best-effort, like _log_event


async def log_perception_error(db_pool, message: str) -> None:
    """Best-effort perception/error event (tracker fallback path in main.py)."""
    try:
        await db_pool.execute(
            "INSERT INTO events (trigger_id, ts, service, event_type, status, payload) "
            "VALUES ($1, $2, 'mras-vision', 'perception', 'error', $3::jsonb)",
            str(uuid_mod.uuid4()), datetime.now(timezone.utc),
            json.dumps({"error": message}),
        )
    except Exception as exc:
        logger.error("perception error log failed: %s", exc)
```

- [ ] **Step 5: Run, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: gaze flusher — periodic attention windows to events`

---

### Task 11: Resolver returns the resolved uuid (for track binding)

**Files:**
- Modify: `/Users/jn/code/mras-vision/src/identity/resolver.py` (`resolve` signature/returns only)
- Test: `/Users/jn/code/mras-vision/tests/test_resolver.py` (exists — extend)

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_resolver.py (reuse the file's existing fixtures/mocks
# for qdrant/db/http — this mirrors the existing happy-path test setup)
@pytest.mark.asyncio
async def test_resolve_returns_uuid_on_match_and_none_for_stranger(resolver_with_match):
    # resolver_with_match: qdrant mock returns a hit >= threshold with payload uuid "u-1"
    uuid = await resolver_with_match.resolve(np.ones(512, dtype=np.float32))
    assert uuid == "u-1"


@pytest.mark.asyncio
async def test_resolve_returns_uuid_even_when_cooldown_claims(resolver_with_match):
    await resolver_with_match.resolve(np.ones(512, dtype=np.float32))
    uuid = await resolver_with_match.resolve(np.ones(512, dtype=np.float32))
    assert uuid == "u-1"   # cooldown skips DISPATCH, but identity is still known
```

(Adapt fixture names to the actual ones in `tests/test_resolver.py` — the file already builds a resolver with a mocked `query_points` returning an above-threshold hit; if no fixture exists, inline the same mock construction the existing happy-path test uses.)

- [ ] **Step 2: Run, verify fail** — `assert None == "u-1"` (resolve currently returns None)
- [ ] **Step 3: Commit red** — `test: resolve returns matched uuid — red`
- [ ] **Step 4: Implement** — in `resolver.py`, change the signature and the three exit points:

```python
    async def resolve(
        self,
        embedding: np.ndarray,
        faces_in_frame: int = 1,
        scene_context: Optional[dict] = None,
    ) -> Optional[str]:
        ...
        if person_uuid and not await self._cooldown.try_claim(f"{_SCREEN_ID}:{person_uuid}"):
            return person_uuid          # was: return
        ...
        if person_uuid is None:
            return None                 # was: return
        ...
        except asyncio.QueueFull:
            await self._log_event(...)  # unchanged
        return person_uuid              # new final line
```

- [ ] **Step 5: Run full suite, verify green** — ALL PASS
- [ ] **Step 6: Commit** — `feat: resolve returns matched uuid for track binding`

---

### Task 12: Wire it all in main.py + /debug/live + prewarm

**Files:**
- Create: `/Users/jn/code/mras-vision/src/perception/debug_view.py`
- Modify: `/Users/jn/code/mras-vision/main.py`
- Test: `/Users/jn/code/mras-vision/tests/test_debug_view.py`, `/Users/jn/code/mras-vision/tests/test_pipeline.py` (exists — extend)

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_debug_view.py
import numpy as np
from src.detection.embedder import Face
from src.perception.debug_view import DebugView, annotate
from src.perception.tracker import FaceTracker


def test_annotate_draws_on_frame():
    frame = np.zeros((200, 200, 3), dtype=np.uint8)
    tracker = FaceTracker()
    tracks = tracker.update(
        [Face(embedding=np.ones(512, dtype=np.float32), bbox=(20, 20, 60, 60))],
        now=0.0)
    objects = [{"label": "cup", "confidence": 0.9, "color": "red",
                "bbox": [120, 120, 40, 40], "source": "yolo11n"}]
    out = annotate(frame.copy(), tracks, objects)
    assert out.any()                       # something was drawn
    assert not np.array_equal(out, frame)


def test_update_is_noop_when_disabled_or_no_clients(monkeypatch):
    monkeypatch.setenv("PERCEPTION_DEBUG", "0")
    view = DebugView()
    view.update(np.zeros((10, 10, 3), dtype=np.uint8), [], [])
    assert view.latest_jpeg() is None
    monkeypatch.setenv("PERCEPTION_DEBUG", "1")
    view = DebugView()
    view.update(np.zeros((10, 10, 3), dtype=np.uint8), [], [])  # 0 clients
    assert view.latest_jpeg() is None
    view.client_connected()
    view.update(np.zeros((10, 10, 3), dtype=np.uint8), [], [])
    assert view.latest_jpeg() is not None  # JPEG bytes now produced
```

```python
# append to tests/test_pipeline.py — extend the existing process_frame test
# pattern (mocked embedder/resolver) with tracker + analyzers in play:
@pytest.mark.asyncio
async def test_process_frame_tracks_binds_and_ships_viewer_context():
    """2 faces → 2 resolves; matched uuid binds to the track; viewer dict
    appears in scene_context once the dwell gate passes."""
    # Build: embedder mock returning two Faces with distinct bboxes/embeddings;
    # resolver mock whose resolve() returns "u-1" for the first embedding and
    # None for the second; a FaceTracker pre-seeded (first_seen 5s ago) so
    # viewer_summary passes the 3s gate after mood/attention votes are added
    # by stub analyzers. Assert:
    #   - resolver.resolve called twice with faces_in_frame=2
    #   - first call's scene_context contains "viewer" with that track's id
    #   - after the call, tracker's track for face 1 has uuid == "u-1"
```

Write this test fully against the real helper introduced below (`build_pipeline` / `process_frame` signatures) — the existing `tests/test_pipeline.py` mocking style carries over; the three assertions above are the contract.

- [ ] **Step 2: Run, verify fail** — `ModuleNotFoundError: src.perception.debug_view`
- [ ] **Step 3: Commit red** — `test: debug view + tracked pipeline wiring — red`
- [ ] **Step 4: Implement debug_view**

```python
# src/perception/debug_view.py
"""Annotated MJPEG debug stream — only renders when PERCEPTION_DEBUG=1 AND
a client is connected (zero cost during demos)."""
import asyncio
import os

import cv2

_GREEN, _RED, _YELLOW = (0, 200, 0), (0, 0, 220), (0, 220, 220)


def annotate(frame, tracks, objects):
    for obj in objects:
        x, y, w, h = obj["bbox"]
        cv2.rectangle(frame, (x, y), (x + w, y + h), _YELLOW, 2)
        cv2.putText(frame, f'{obj["label"]} {obj["color"]} {obj["confidence"]:.2f}',
                    (x, y - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.5, _YELLOW, 1)
    for tr in tracks:
        x, y, w, h = tr.bbox
        summary = tr.viewer_summary(now=tr.last_seen) or {}
        color = _GREEN if summary.get("attending") else _RED
        cv2.rectangle(frame, (x, y), (x + w, y + h), color, 2)
        label = f'{tr.track_id} {tr.uuid or "?"} {summary.get("mood", "...")}'
        cv2.putText(frame, label, (x, y - 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
    return frame


class DebugView:
    def __init__(self) -> None:
        self._enabled = os.getenv("PERCEPTION_DEBUG", "0") == "1"
        self._clients = 0
        self._jpeg: bytes | None = None

    def client_connected(self) -> None:
        self._clients += 1

    def client_disconnected(self) -> None:
        self._clients = max(0, self._clients - 1)

    def latest_jpeg(self) -> bytes | None:
        return self._jpeg

    def update(self, frame, tracks, objects) -> None:
        if not self._enabled or self._clients == 0:
            return
        ok, buf = cv2.imencode(".jpg", annotate(frame.copy(), tracks, objects))
        if ok:
            self._jpeg = buf.tobytes()

    async def stream(self):
        self.client_connected()
        try:
            while True:
                if self._jpeg is not None:
                    yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n"
                           + self._jpeg + b"\r\n")
                await asyncio.sleep(0.15)
        finally:
            self.client_disconnected()
```

- [ ] **Step 5: Rewire main.py**

```python
# main.py — new/changed pieces (imports added accordingly)
from fastapi.responses import StreamingResponse

from src.perception.analyzers.attention import AttentionAnalyzer
from src.perception.analyzers.mood import MoodAnalyzer
from src.perception.analyzers.objects import ObjectsAnalyzer
from src.perception.debug_view import DebugView
from src.perception.gaze_log import GazeLogger, log_perception_error
from src.perception.objects.gateway import ObjectGateway
from src.perception.objects.yolo_backend import YoloBackend
from src.perception.tracker import FaceTracker

_SCREEN_ID = os.getenv("SCREEN_ID", "screen_0")
_VIEWER_MIN_EVIDENCE_S = float(os.getenv("VIEWER_MIN_EVIDENCE_S", "3.0"))


def build_analyzers() -> list:
    yolo = YoloBackend()
    return [ObjectsAnalyzer(ObjectGateway([yolo])), MoodAnalyzer(),
            AttentionAnalyzer()], yolo


async def process_frame(frame, embedder, resolver, tracker, analyzers,
                        debug_view, db, loop) -> None:
    faces = await loop.run_in_executor(None, embedder.embed_all, frame)
    if not faces:
        return
    try:
        tracks = tracker.update(faces)
    except Exception as exc:
        # Tracker down ≠ ads down: untracked fallback, today's behavior.
        await log_perception_error(db, f"tracker failed: {exc}")
        for face in faces:
            await resolver.resolve(face.embedding, faces_in_frame=len(faces),
                                   scene_context={})
        return
    scene = await gather_scene_context(analyzers, frame, tracks)
    debug_view.update(frame, tracks, scene.get("objects", []))
    now = time.monotonic()
    for face in faces:
        track = tracker.track_for_bbox(face.bbox)
        ctx = {**scene, "faces_tracked": len(tracks)}
        viewer = track and track.viewer_summary(
            now, min_evidence_s=_VIEWER_MIN_EVIDENCE_S)
        if viewer:
            ctx["viewer"] = viewer
        uuid = await resolver.resolve(face.embedding,
                                      faces_in_frame=len(faces),
                                      scene_context=ctx)
        if uuid and track:
            track.bind_uuid(uuid)
```

In `lifespan`: build `tracker = FaceTracker()`, `analyzers, yolo = build_analyzers()`, `debug_view = DebugView()`, prewarm YOLO in the executor next to the embedder prewarm (`await loop.run_in_executor(None, yolo.prewarm)` — best-effort try/except like D13), start `gaze_task = asyncio.create_task(GazeLogger(db, _SCREEN_ID).run(tracker))`, cancel it on shutdown, and pass the new collaborators through `_camera_pipeline` into `process_frame`. Replace the module-level `ANALYZERS: list = []` with `build_analyzers()` (the registry is no longer empty — drop the stale comment). Add the endpoint:

```python
@app.get("/debug/live")
async def debug_live():
    return StreamingResponse(
        app.state.debug_view.stream(),
        media_type="multipart/x-mixed-replace; boundary=frame")
```

- [ ] **Step 6: Run the FULL suite, verify green** — `.venv/bin/python -m pytest -v` → ALL PASS
- [ ] **Step 7: Commit** — `feat: wire tracker+analyzers+gaze+debug into the camera pipeline`

---

### Task 13: Live verification (owner-run camera) + close-out

- [ ] **Step 1: Owner starts the stack** (camera needs the owner's terminal): `mras-ops/start-mras.sh`, vision with `PERCEPTION_DEBUG=1`.
- [ ] **Step 2: Walk-up check** — owner stands in frame holding a colored object, looks at/away from the display. Agent verifies via SQL (`docker exec mras-ops-postgres-1 psql ...`):
  - `SELECT payload FROM events WHERE event_type='detection' ORDER BY ts DESC LIMIT 5;` → `scene_context.objects` non-empty with sane labels/colors; `viewer.mood` populated after ~3s dwell.
  - `SELECT payload FROM events WHERE event_type='gaze' ORDER BY ts DESC LIMIT 10;` → `attending_fraction` high while watching, low while looking away; `uuid` bound for the identified person.
  - "Watched the ad" join: gaze windows overlapping the latest `playback` row's window for the same screen.
- [ ] **Step 3: Debug view check** — browser → `http://localhost:8001/debug/live`: face box with track id/mood, green↔red as the owner looks toward/away, object boxes labeled with color.
- [ ] **Step 4: Latency check** — confirm in vision logs that frame processing stays under the budget with 1–2 people (no constant analyzer-drop warnings) and ad trigger latency is unchanged.
- [ ] **Step 5: Batch 3 close-out** — push `feat/p2p1-mood-attention`, PR "Phase 2 perception 3/3: mood, attention, gaze, debug view", self-review + code review, merge.
- [ ] **Step 6: Journal** — prepend SESSION_LOG entry (repo@sha for all three PRs, learnings, new env knobs + `/debug/live` in Operational Reference), file any deferred findings as GitHub issues (per CLAUDE.md), close the spec/plan PR in minority_report_architecture.

---

## Self-review notes (done at write time)

- **Spec coverage:** tracker (T2), gateway+fusion+LocateAnything slot (T4), yolo11n (T5), color (T6), objects analyzer (T7), DeepFace mood (T8), MediaPipe attention + honest head-pose framing (T9), gaze events + playback join (T10), uuid binding (T2/T11/T12), viewer dwell gate in seconds (T2/T12), `/debug/live` + PERCEPTION_DEBUG gating (T12), perception-never-blocks-dispatch (T3 budget/None, T12 tracker fallback), prewarm/D13 (T12), single-camera display-camera assumption (no multi-camera code — TODO-8). No gaps found.
- **Identity hygiene:** unit tests use synthetic arrays only. The Task 5 smoke uses the existing e2e fixture image offline (object detection only, never enrolled anywhere) — acceptable per the locked rule; live E2E uses the owner in person.
- **Type consistency:** `Face(embedding, bbox)` (T1) used in T2/T8/T9/T10/T12; `Detection(label, confidence, bbox, source)` (T4) in T5/T7; `viewer_summary(now, min_evidence_s, window_s)` (T2) called in T12; `attending_fraction_since` (T2) used in T10; `drain_closed`/`live_tracks`/`track_for_bbox` (T2) used in T10/T12. Consistent.
