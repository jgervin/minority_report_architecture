# Adaptive Enrollment — Plan 2: Gated Auto-Augmentation + Reversibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the gallery self-improve safely — accumulate per-track identification evidence, accept a new embedding only when conservative gates pass, add it `source='auto'` with audit + cap/eviction, and provide a purge-by-uuid to undo mistakes.

**Architecture:** Pure, testable cores — `quality` (per-frame gate scoring), `augment` (evidence → candidate gate evaluation + apply with admission dedup, audit, eviction). The vision loop records an id-sample per resolved frame onto its track; a periodic reporter fires augmentation **once per track** when the dwell gates are first met (avoids racing the gaze drain). A purge CLI reverses `auto` additions.

**Tech Stack:** Python 3.9 (vision venv — `from __future__ import annotations`), numpy, pytest (`asyncio_mode=auto`), `AsyncMock`.

**Depends on:** Plan 1 (`gallery.add_member`, `identity_embeddings`, group-by-uuid resolution).
**Spec:** `2026-06-17-adaptive-enrollment-design.md`.

---

## File Structure

- Create `mras-vision/src/identity/quality.py` — per-frame quality gate + score.
- Create `mras-vision/src/identity/augment.py` — `GateConfig`, `IdSample`, `Candidate`, `evaluate_candidate`, `apply_augmentation`.
- Modify `mras-vision/src/perception/tracker.py` — id-sample buffer + `augmented` flag on `Track`.
- Create `mras-vision/src/perception/augment_reporter.py` — periodic per-track augmentation task.
- Modify `mras-vision/main.py` — record id-samples in `process_frame`; start the reporter; `resolve()` returns `(uuid, confidence)`.
- Create `mras-ops/scripts/purge_auto_embeddings.py` — reversibility CLI.
- Tests: `tests/test_quality.py`, `tests/test_augment.py`, `tests/test_tracker.py` (extend).

---

### Task 1: Per-frame quality gate

**Files:**
- Create: `mras-vision/src/identity/quality.py`
- Test: `mras-vision/tests/test_quality.py`

- [ ] **Step 1: Write the failing test**

```python
# mras-vision/tests/test_quality.py
from src.identity.quality import frame_quality, QualityConfig


def test_quality_passes_when_all_gates_met():
    ok, score = frame_quality(bbox_area=20000, sharpness=300.0, pose_deg=8.0,
                              single_face=True, cfg=QualityConfig())
    assert ok is True
    assert 0.0 < score <= 1.0


def test_quality_fails_small_face():
    ok, _ = frame_quality(5000, 300.0, 8.0, True, QualityConfig())
    assert ok is False


def test_quality_fails_blurry():
    ok, _ = frame_quality(20000, 50.0, 8.0, True, QualityConfig())
    assert ok is False


def test_quality_fails_off_pose_or_multiface():
    assert frame_quality(20000, 300.0, 40.0, True, QualityConfig())[0] is False
    assert frame_quality(20000, 300.0, 8.0, False, QualityConfig())[0] is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_quality.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.identity.quality'`

- [ ] **Step 3: Write minimal implementation**

```python
# mras-vision/src/identity/quality.py
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass
class QualityConfig:
    min_face_px: int = int(os.getenv("AUG_MIN_FACE_PX", "10000"))      # bbox area
    max_pose_deg: float = float(os.getenv("AUG_MAX_POSE_DEG", "20"))
    min_sharpness: float = float(os.getenv("AUG_MIN_SHARPNESS", "100"))


def frame_quality(bbox_area: float, sharpness: float, pose_deg: float,
                  single_face: bool, cfg: QualityConfig) -> tuple:
    """(passes_all_gates, composite_score in [0,1]). Score blends the three
    continuous signals; used to rank the best frame and eviction candidates."""
    ok = (bbox_area >= cfg.min_face_px and sharpness >= cfg.min_sharpness
          and pose_deg <= cfg.max_pose_deg and single_face)
    size_s = min(1.0, bbox_area / (cfg.min_face_px * 4))
    sharp_s = min(1.0, sharpness / (cfg.min_sharpness * 4))
    pose_s = max(0.0, 1.0 - pose_deg / 90.0)
    score = (size_s + sharp_s + pose_s) / 3.0
    return ok, round(score, 3)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_quality.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/identity/quality.py tests/test_quality.py
git commit -m "feat(vision): per-frame quality gate + composite score"
```

---

### Task 2: Candidate gate evaluation (pure)

**Files:**
- Create: `mras-vision/src/identity/augment.py`
- Test: `mras-vision/tests/test_augment.py`

**Design note:** `evaluate_candidate` takes the track's id-samples (only quality-passing frames count
toward agreement) and the dwell seconds. It finds the majority uuid among quality-passing samples;
accepts iff dwell ≥ `min_dwell_s`, agreeing count ≥ `min_frames`, and the best agreeing sample's
confidence ≥ `min_conf`. Returns that best sample as the `Candidate` (its embedding is what gets
stored), else `None`.

- [ ] **Step 1: Write the failing test**

```python
# mras-vision/tests/test_augment.py
import numpy as np
from src.identity.augment import IdSample, GateConfig, evaluate_candidate


def _s(uuid, conf, q_ok=True, quality=0.9):
    return IdSample(uuid=uuid, confidence=conf, quality=quality,
                    quality_ok=q_ok, embedding=np.ones(512, dtype=np.float32))


def test_accepts_when_all_gates_pass():
    samples = [_s("jason", 0.93) for _ in range(12)]
    c = evaluate_candidate(samples, dwell_s=6.0, cfg=GateConfig())
    assert c is not None and c.uuid == "jason" and c.frames == 12


def test_rejects_low_confidence():
    samples = [_s("jason", 0.80) for _ in range(12)]  # best < 0.90
    assert evaluate_candidate(samples, dwell_s=6.0, cfg=GateConfig()) is None


def test_rejects_short_dwell():
    samples = [_s("jason", 0.95) for _ in range(12)]
    assert evaluate_candidate(samples, dwell_s=3.0, cfg=GateConfig()) is None


def test_rejects_too_few_agreeing_frames():
    samples = [_s("jason", 0.95) for _ in range(5)]
    assert evaluate_candidate(samples, dwell_s=6.0, cfg=GateConfig()) is None


def test_rejects_uuid_disagreement_no_majority_reaching_min_frames():
    samples = [_s("jason", 0.95) for _ in range(6)] + [_s("ragnar", 0.95) for _ in range(6)]
    assert evaluate_candidate(samples, dwell_s=6.0, cfg=GateConfig()) is None


def test_quality_failing_frames_dont_count_toward_agreement():
    samples = [_s("jason", 0.95, q_ok=False) for _ in range(12)]
    assert evaluate_candidate(samples, dwell_s=6.0, cfg=GateConfig()) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_augment.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.identity.augment'`

- [ ] **Step 3: Write minimal implementation**

```python
# mras-vision/src/identity/augment.py
from __future__ import annotations

import os
from collections import Counter
from dataclasses import dataclass

import numpy as np


@dataclass
class GateConfig:
    min_conf: float = float(os.getenv("AUG_MIN_CONF", "0.90"))
    min_dwell_s: float = float(os.getenv("AUG_MIN_DWELL_S", "5.0"))
    min_frames: int = int(os.getenv("AUG_MIN_FRAMES", "10"))


@dataclass
class IdSample:
    uuid: str
    confidence: float
    quality: float
    quality_ok: bool
    embedding: np.ndarray


@dataclass
class Candidate:
    uuid: str
    embedding: np.ndarray
    quality: float
    confidence: float
    frames: int


def evaluate_candidate(samples, dwell_s: float, cfg: GateConfig):
    eligible = [s for s in samples if s.quality_ok]
    if not eligible or dwell_s < cfg.min_dwell_s:
        return None
    uuid, count = Counter(s.uuid for s in eligible).most_common(1)[0]
    if count < cfg.min_frames:
        return None
    agreeing = [s for s in eligible if s.uuid == uuid]
    best = max(agreeing, key=lambda s: (s.confidence, s.quality))
    if best.confidence < cfg.min_conf:
        return None
    return Candidate(uuid=uuid, embedding=best.embedding, quality=best.quality,
                     confidence=best.confidence, frames=count)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_augment.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/identity/augment.py tests/test_augment.py
git commit -m "feat(vision): conservative candidate gate evaluation"
```

---

### Task 3: Track id-sample buffer + augmented flag

**Files:**
- Modify: `mras-vision/src/perception/tracker.py` (the `Track` dataclass)
- Test: `mras-vision/tests/test_tracker.py`

- [ ] **Step 1: Write the failing test**

```python
# add to mras-vision/tests/test_tracker.py
import numpy as np  # already imported at top
from src.identity.augment import IdSample  # noqa: E402


def test_track_accumulates_id_samples_and_augmented_flag_defaults_false():
    from src.perception.tracker import FaceTracker
    t = FaceTracker()
    [tr] = t.update([_face(100, 100)], now=0.0)
    assert tr.augmented is False
    tr.add_id_sample(IdSample("jason", 0.95, 0.9, True, np.ones(512, dtype=np.float32)))
    assert len(tr.id_samples) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_tracker.py -k id_samples -v`
Expected: FAIL — `AttributeError: 'Track' object has no attribute 'augmented'`

- [ ] **Step 3: Write minimal implementation**

In `tracker.py`, add to the `Track` dataclass fields (near `mood_votes`/`attention_samples`):
```python
    id_samples: deque = field(default_factory=lambda: deque(maxlen=120))
    augmented: bool = False
```
And a method on `Track`:
```python
    def add_id_sample(self, sample) -> None:
        self.id_samples.append(sample)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_tracker.py -v`
Expected: PASS (all tracker tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/perception/tracker.py tests/test_tracker.py
git commit -m "feat(vision): per-track id-sample buffer + augmented flag"
```

---

### Task 4: Apply augmentation — dedup, add, audit, eviction

**Files:**
- Modify: `mras-vision/src/identity/augment.py`
- Test: `mras-vision/tests/test_augment.py`

**Design note:** `apply_augmentation` fetches the uuid's existing gallery (embeddings + ids +
sources) from Postgres; **admission dedup** skips if the candidate's max cosine similarity to the
gallery ≥ `AUG_MAX_REDUNDANCY`; else `gallery.add_member(source='auto', provenance=...)`, log an
`augment/success` event, and if the gallery now exceeds `AUG_GALLERY_CAP` evict the most-redundant
`source='auto'` member (never an `enroll` anchor) from Postgres + Qdrant. Returns whether it added.

- [ ] **Step 1: Write the failing test**

```python
# add to mras-vision/tests/test_augment.py
from unittest.mock import AsyncMock, patch


def _cand(uuid="jason"):
    return Candidate(uuid=uuid, embedding=np.ones(512, dtype=np.float32),
                     quality=0.9, confidence=0.95, frames=12)


async def test_apply_skips_when_candidate_is_redundant():
    from src.identity.augment import apply_augmentation
    db = AsyncMock()
    # existing gallery has a near-identical vector (cosine ~1.0)
    db.fetch = AsyncMock(return_value=[
        {"id": "e1", "source": "enroll", "embedding": [1.0] * 512}])
    qdrant = AsyncMock()
    with patch("src.identity.augment.add_member", AsyncMock()) as add:
        added = await apply_augmentation(db, qdrant, _cand(), "Jason")
    assert added is False
    add.assert_not_awaited()


async def test_apply_adds_when_diverse_and_logs_audit():
    from src.identity.augment import apply_augmentation
    db = AsyncMock()
    ortho = [0.0] * 512
    ortho[7] = 1.0
    db.fetch = AsyncMock(return_value=[{"id": "e1", "source": "enroll", "embedding": ortho}])
    qdrant = AsyncMock()
    with patch("src.identity.augment.add_member", AsyncMock(return_value="new")) as add:
        added = await apply_augmentation(db, qdrant, _cand(), "Jason")
    assert added is True
    assert add.await_args.kwargs["source"] == "auto"
    # an augment/success audit event was logged
    assert any("augment" in str(c.args) for c in db.execute.await_args_list)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_augment.py -k apply -v`
Expected: FAIL — `ImportError: cannot import name 'apply_augmentation'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/identity/augment.py
import json
import uuid as uuid_mod
from datetime import datetime, timezone

from src.identity.gallery import add_member

_MAX_REDUNDANCY = float(os.getenv("AUG_MAX_REDUNDANCY", "0.95"))
_GALLERY_CAP = int(os.getenv("AUG_GALLERY_CAP", "12"))


def _cos(a, b) -> float:
    a, b = np.asarray(a, dtype=np.float32), np.asarray(b, dtype=np.float32)
    d = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b)) / d if d else 0.0


async def apply_augmentation(db, qdrant, candidate: Candidate, name: str) -> bool:
    rows = await db.fetch(
        "SELECT id::text, source, embedding FROM identity_embeddings WHERE identity_uuid = $1",
        candidate.uuid)
    gallery = [(r["id"], r["source"], r["embedding"]) for r in rows]
    if any(_cos(candidate.embedding, emb) >= _MAX_REDUNDANCY for _, _, emb in gallery):
        return False  # admission dedup: too similar to an existing member
    provenance = {"track": candidate.frames, "confidence": candidate.confidence,
                  "ts": datetime.now(timezone.utc).isoformat()}
    await add_member(db, qdrant, candidate.uuid, name, candidate.embedding,
                     source="auto", quality=candidate.quality, provenance=provenance)
    await db.execute(
        "INSERT INTO events (trigger_id, ts, service, event_type, status, payload) "
        "VALUES ($1, $2, 'mras-vision', 'augment', 'success', $3::jsonb)",
        str(uuid_mod.uuid4()), datetime.now(timezone.utc),
        json.dumps({"uuid": candidate.uuid, **provenance}))
    await _evict_if_over_cap(db, qdrant, candidate.uuid, gallery, candidate.embedding)
    return True


async def _evict_if_over_cap(db, qdrant, uuid, prior_gallery, added_emb) -> None:
    members = prior_gallery + [("__new__", "auto", added_emb)]
    if len(members) <= _GALLERY_CAP:
        return
    autos = [(mid, emb) for mid, src, emb in members if src == "auto" and mid != "__new__"]
    if not autos:
        return
    # most-redundant auto = highest max-similarity to the rest
    def redundancy(mid_emb):
        mid, emb = mid_emb
        return max(_cos(emb, o) for omid, _, o in members if omid != mid)
    victim_id, _ = max(autos, key=redundancy)
    await db.execute("DELETE FROM identity_embeddings WHERE id = $1", victim_id)
    from qdrant_client.http.models import PointIdsList
    from src.qdrant import COLLECTION
    await qdrant.delete(collection_name=COLLECTION,
                        points_selector=PointIdsList(points=[victim_id]))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_augment.py -v`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/identity/augment.py tests/test_augment.py
git commit -m "feat(vision): apply augmentation with dedup, audit, diversity eviction"
```

---

### Task 5: Wire into vision — record id-samples + augment reporter

**Files:**
- Modify: `mras-vision/src/identity/resolver.py` (`resolve` returns `(uuid, confidence)`)
- Modify: `mras-vision/main.py` (record id-samples in `process_frame`; start reporter)
- Create: `mras-vision/src/perception/augment_reporter.py`
- Test: covered by Tasks 1-4 units + the live E2E (Task 6 of Plan 1's E2E pattern)

**Design note:** Augmentation fires **once per track** when the dwell gates are first met (a periodic
reporter over `tracker.live_tracks()`), which avoids competing with `GazeLogger` for
`drain_closed()`. `resolve()` now returns `(uuid, confidence)`; update its two call sites in
`main.py` and the affected assertions in `tests/test_resolver.py` (unwrap the tuple).

- [ ] **Step 1: Change `resolve` to return `(uuid, confidence)`**

In `resolver.py`, change the final `return person_uuid` (and the early cooldown `return person_uuid`)
to `return person_uuid, confidence`, and the `return None` (stranger) path to `return None,
confidence`. Update `tests/test_resolver.py` call sites to unpack `uuid, _ = await resolver.resolve(...)`.
Run `python -m pytest tests/test_resolver.py -v` → green before moving on.

- [ ] **Step 2: Record id-samples in `process_frame`**

In `main.py` `process_frame`, where it currently does
`uuid = await resolver.resolve(...)` then `track.bind_uuid(uuid)`, change to:
```python
        uuid, confidence = await resolver.resolve(
            face.embedding, faces_in_frame=len(faces), scene_context=ctx)
        if uuid and track:
            track.bind_uuid(uuid)
            area = face.bbox[2] * face.bbox[3]
            sharp = float(cv2.Laplacian(
                cv2.cvtColor(frame[face.bbox[1]:face.bbox[1]+face.bbox[3],
                                   face.bbox[0]:face.bbox[0]+face.bbox[2]],
                             cv2.COLOR_BGR2GRAY), cv2.CV_64F).var()) if area else 0.0
            pose_deg = 0.0  # near-frontal proxy; refine from head-pose if exposed
            ok, q = frame_quality(area, sharp, pose_deg, len(faces) == 1, _QUALITY_CFG)
            track.add_id_sample(IdSample(uuid, confidence, q, ok, face.embedding))
```
Add imports: `import cv2`, `from src.identity.quality import frame_quality, QualityConfig`,
`from src.identity.augment import IdSample`, and `_QUALITY_CFG = QualityConfig()`.

- [ ] **Step 3: Create the augment reporter**

```python
# mras-vision/src/perception/augment_reporter.py
from __future__ import annotations

import asyncio
import logging
import os
import time

from src.identity.augment import GateConfig, evaluate_candidate, apply_augmentation

logger = logging.getLogger(__name__)
_INTERVAL_S = float(os.getenv("AUG_REPORT_S", "2.0"))


class AugmentReporter:
    def __init__(self, db, qdrant, interval_s: float = _INTERVAL_S) -> None:
        self._db, self._qdrant, self._interval = db, qdrant, interval_s
        self._cfg = GateConfig()

    async def run(self, tracker) -> None:
        while True:
            await asyncio.sleep(self._interval)
            await self.evaluate(tracker)

    async def evaluate(self, tracker) -> None:
        now = time.monotonic()
        for tr in tracker.live_tracks():
            if tr.augmented or not tr.id_samples:
                continue
            cand = evaluate_candidate(list(tr.id_samples), now - tr.first_seen, self._cfg)
            if cand is None:
                continue
            name = await self._name_for(cand.uuid)
            try:
                if await apply_augmentation(self._db, self._qdrant, cand, name):
                    tr.augmented = True
            except Exception as exc:  # best-effort; never crash perception
                logger.warning("augment failed for %s: %s", cand.uuid, exc)

    async def _name_for(self, uuid: str) -> str:
        row = await self._db.fetchrow("SELECT name FROM identities WHERE uuid = $1", uuid)
        return row["name"] if row else ""
```

- [ ] **Step 4: Start the reporter in `main.py` lifespan**

Next to `gaze_task = ...`:
```python
    from src.perception.augment_reporter import AugmentReporter
    augment_task = asyncio.create_task(AugmentReporter(db, qdrant).run(tracker))
```
Cancel it in the shutdown block (`augment_task.cancel()`).

- [ ] **Step 5: Verify import + full suite**

Run:
```bash
cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"
.venv/bin/python -m pytest -q
```
Expected: `ok` then all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/identity/resolver.py main.py src/perception/augment_reporter.py tests/test_resolver.py
git commit -m "feat(vision): record id-samples + periodic gated auto-augmentation"
```

---

### Task 6: Purge CLI — reversibility

**Files:**
- Create: `mras-ops/scripts/purge_auto_embeddings.py`
- Test: `mras-ops/tests/test_purge.py` (or a manual verification if mras-ops has no test harness)

**Design note:** `purge(uuid, since=None)` deletes `source='auto'` rows for the uuid (optionally
`created_at >= since`) from Postgres and the matching Qdrant points by id; `enroll` anchors untouched.

- [ ] **Step 1: Write the failing test (or skip to Step 3 if mras-ops has no pytest harness — then verify manually)**

```python
# mras-ops/tests/test_purge.py
from unittest.mock import AsyncMock
from scripts.purge_auto_embeddings import purge


async def test_purge_deletes_auto_ids_from_both_stores():
    db = AsyncMock()
    db.fetch = AsyncMock(return_value=[{"id": "a1"}, {"id": "a2"}])
    qdrant = AsyncMock()
    n = await purge(db, qdrant, "jason-uuid")
    assert n == 2
    # selected only source='auto'
    assert "source = 'auto'" in db.fetch.call_args.args[0]
    qdrant.delete.assert_awaited_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-ops && python -m pytest tests/test_purge.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'scripts.purge_auto_embeddings'`

- [ ] **Step 3: Write minimal implementation**

```python
# mras-ops/scripts/purge_auto_embeddings.py
"""Reversibility: remove auto-augmented gallery embeddings for an identity.
Usage: python -m scripts.purge_auto_embeddings <identity_uuid> [since_iso8601]"""
import asyncio
import os
import sys


async def purge(db, qdrant, identity_uuid: str, since: str | None = None) -> int:
    q = "SELECT id::text FROM identity_embeddings WHERE identity_uuid = $1 AND source = 'auto'"
    args = [identity_uuid]
    if since:
        q += " AND created_at >= $2"
        args.append(since)
    rows = await db.fetch(q, *args)
    ids = [r["id"] for r in rows]
    if not ids:
        return 0
    await db.execute("DELETE FROM identity_embeddings WHERE id = ANY($1::uuid[])", ids)
    from qdrant_client.http.models import PointIdsList
    await qdrant.delete(
        collection_name=os.getenv("QDRANT_COLLECTION", "mras_embeddings"),
        points_selector=PointIdsList(points=ids))
    return len(ids)


async def _main():
    import asyncpg
    from qdrant_client import AsyncQdrantClient
    uuid = sys.argv[1]
    since = sys.argv[2] if len(sys.argv) > 2 else None
    db = await asyncpg.create_pool(os.getenv("DATABASE_URL", "postgresql://mras:mras@localhost:5432/mras"))
    qdrant = AsyncQdrantClient(url=os.getenv("QDRANT_URL", "http://localhost:6333"))
    n = await purge(db, qdrant, uuid, since)
    print(f"purged {n} auto embeddings for {uuid}")
    await db.close()


if __name__ == "__main__":
    asyncio.run(_main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-ops && python -m pytest tests/test_purge.py -v`
Expected: PASS (if no harness, manually run `python -m scripts.purge_auto_embeddings <uuid>` against a test row and confirm deletion).

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-ops
git add scripts/purge_auto_embeddings.py tests/test_purge.py
git commit -m "feat(ops): purge-by-uuid CLI to reverse auto-augmentation"
```

---

## Plan 2 self-review (run before handing off)

- [ ] Vision suite green (`.venv/bin/python -m pytest -q`); `import main` ok.
- [ ] **Live E2E:** enroll Jason; walk up under good lighting for ≥5s several times; confirm an
  `augment/success` event appears and a new `source='auto'` row exists; confirm recognition
  confidence rises across conditions over subsequent walk-ups. Then run the purge CLI for Jason and
  confirm the `auto` rows + Qdrant points are gone and `enroll` anchors remain. Record in
  `docs/SESSION_LOG.md`.
- [ ] Confirm `pose_deg` proxy (Task 5 Step 2) — if head-pose yaw/pitch is exposed by the attention
  analyzer, wire the real value; otherwise the near-frontal proxy + size/sharpness gates still
  protect quality. Note this as a follow-up if left as a proxy.
