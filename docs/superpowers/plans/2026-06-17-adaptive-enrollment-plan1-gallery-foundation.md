# Adaptive Enrollment — Plan 1: Gallery Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-embedding-per-identity model with a multi-embedding gallery: a durable `identity_embeddings` table, a vision `gallery` module that writes a member to Postgres + Qdrant, group-by-uuid max-similarity resolution, and a non-destructive additive manual re-enroll. After this plan, recognition matches against multiple stored conditions and you can re-enroll a person under new lighting without losing prior coverage.

**Architecture:** Each gallery member is one Postgres row (`identity_embeddings`) + one Qdrant point (point-id = the row id, `payload.uuid` groups members). Resolution queries `limit=K`, groups hits by `payload.uuid`, and takes the max score per uuid. Enrollment gains an additive path that adds `source='enroll'` members instead of averaging+overwriting.

**Tech Stack:** Postgres (SQL migration), Python 3.9 (vision venv — new modules need `from __future__ import annotations`), pytest (`asyncio_mode=auto`), `AsyncMock`, `qdrant_client`.

**Depends on:** spec `2026-06-17-adaptive-enrollment-design.md`.

---

## File Structure

- Create `mras-ops/db/migrations/003_identity_embeddings.sql` — table + indexes + backfill.
- Create `mras-vision/src/identity/gallery.py` — `add_member(...)`.
- Modify `mras-vision/src/identity/resolver.py` — group-by-uuid max resolution (`resolver.py:57-71`).
- Modify `mras-vision/src/enrollment/enroller.py` — additive enroll path.
- Create `mras-vision/tests/test_gallery.py`, `tests/test_resolver_gallery.py`; extend `tests/test_enrollment.py`.

Vision tests: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest <path> -v`.

---

### Task 1: Migration — identity_embeddings table + backfill

**Files:**
- Create: `mras-ops/db/migrations/003_identity_embeddings.sql`

**Note:** initdb runs these only on a fresh DB volume; on the existing volume apply manually
(`docker exec -i mras-ops-postgres-1 psql -U mras -d mras < db/migrations/003_identity_embeddings.sql`),
per the M4 precedent in the session log.

- [ ] **Step 1: Write the migration**

```sql
-- mras-ops/db/migrations/003_identity_embeddings.sql
-- Adaptive enrollment: multi-embedding gallery per identity.
CREATE TABLE IF NOT EXISTS identity_embeddings (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    identity_uuid uuid        NOT NULL REFERENCES identities(uuid) ON DELETE CASCADE,
    embedding     float4[]    NOT NULL,
    source        text        NOT NULL CHECK (source IN ('enroll', 'auto')),
    quality       real,
    provenance    jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS identity_embeddings_uuid_idx   ON identity_embeddings (identity_uuid);
CREATE INDEX IF NOT EXISTS identity_embeddings_source_idx ON identity_embeddings (source);

-- Backfill: each existing identity's single embedding becomes its first enroll anchor.
INSERT INTO identity_embeddings (identity_uuid, embedding, source, provenance)
SELECT uuid, embedding, 'enroll', jsonb_build_object('backfill', true)
FROM identities
WHERE embedding IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM identity_embeddings e WHERE e.identity_uuid = identities.uuid
  );
```

- [ ] **Step 2: Apply to the running DB and verify the backfill**

Run:
```bash
docker exec -i mras-ops-postgres-1 psql -U mras -d mras < /Users/jn/code/mras-ops/db/migrations/003_identity_embeddings.sql
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT source, count(*) FROM identity_embeddings GROUP BY source;"
```
Expected: one `enroll` row per existing identity with a non-null embedding (today: 2 — Jason, Ragnar).

- [ ] **Step 3: Commit**

```bash
cd /Users/jn/code/mras-ops
git add db/migrations/003_identity_embeddings.sql
git commit -m "feat(db): identity_embeddings gallery table + backfill anchors"
```

---

### Task 2: Vision — gallery.add_member writes Postgres row + Qdrant point

**Files:**
- Create: `mras-vision/src/identity/gallery.py`
- Test: `mras-vision/tests/test_gallery.py`

- [ ] **Step 1: Write the failing test**

```python
# mras-vision/tests/test_gallery.py
from unittest.mock import AsyncMock, patch
import numpy as np

from src.identity.gallery import add_member


async def test_add_member_writes_postgres_row_and_qdrant_point():
    db = AsyncMock()
    db.fetchval = AsyncMock(return_value="emb-id-123")
    qdrant = AsyncMock()
    emb = np.ones(512, dtype=np.float32)
    new_id = await add_member(db, qdrant, "jason-uuid", "Jason", emb,
                              source="enroll", quality=0.8,
                              provenance={"photo": "j.png"})
    assert new_id == "emb-id-123"
    # Postgres insert returns the new id
    assert "INSERT INTO identity_embeddings" in db.fetchval.call_args.args[0]
    # Qdrant point uses the row id, payload groups by uuid
    point = qdrant.upsert.call_args.kwargs["points"][0]
    assert point.id == "emb-id-123"
    assert point.payload == {"uuid": "jason-uuid", "name": "Jason", "source": "enroll"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_gallery.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.identity.gallery'`

- [ ] **Step 3: Write minimal implementation**

```python
# mras-vision/src/identity/gallery.py
from __future__ import annotations

import json

import numpy as np
from qdrant_client import AsyncQdrantClient
from qdrant_client.http.models import PointStruct

from src.qdrant import COLLECTION


async def add_member(db, qdrant: AsyncQdrantClient, identity_uuid: str, name: str,
                     embedding: np.ndarray, source: str, quality: float | None = None,
                     provenance: dict | None = None) -> str:
    """Add one gallery embedding: a durable Postgres row + a Qdrant point whose
    id is the row id and whose payload.uuid groups it under the person."""
    vec = [float(x) for x in np.asarray(embedding).tolist()]
    new_id = await db.fetchval(
        "INSERT INTO identity_embeddings "
        "(identity_uuid, embedding, source, quality, provenance) "
        "VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING id::text",
        identity_uuid, vec, source, quality,
        json.dumps(provenance) if provenance is not None else None,
    )
    await qdrant.upsert(
        collection_name=COLLECTION,
        points=[PointStruct(id=new_id, vector=vec,
                            payload={"uuid": identity_uuid, "name": name, "source": source})],
    )
    return new_id
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_gallery.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/identity/gallery.py tests/test_gallery.py
git commit -m "feat(vision): gallery.add_member writes Postgres row + Qdrant point"
```

---

### Task 3: Vision — group-by-uuid max-similarity resolution

**Files:**
- Modify: `mras-vision/src/identity/resolver.py` (the query + hit-handling at `resolver.py:57-71`)
- Test: `mras-vision/tests/test_resolver_gallery.py`

**Design note:** Add a pure `best_identity(points)` helper and use it. Change `limit=1` to
`limit=QDRANT_GALLERY_FANOUT` (env, default 15). Group returned hits by `payload["uuid"]`, take the
max score per uuid, pick the highest; that score is the confidence compared to the threshold.

- [ ] **Step 1: Write the failing test**

```python
# mras-vision/tests/test_resolver_gallery.py
from types import SimpleNamespace
from src.identity.resolver import best_identity


def _pt(score, uuid):
    return SimpleNamespace(score=score, payload={"uuid": uuid})


def test_best_identity_takes_max_score_per_uuid():
    # jason has two gallery hits (0.62, 0.71); ragnar one (0.55) → jason@0.71 wins
    points = [_pt(0.62, "jason"), _pt(0.55, "ragnar"), _pt(0.71, "jason")]
    assert best_identity(points) == ("jason", 0.71)


def test_best_identity_empty_is_none():
    assert best_identity([]) == (None, 0.0)


def test_best_identity_ignores_payload_without_uuid():
    assert best_identity([_pt(0.9, None)]) == (None, 0.0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_resolver_gallery.py -v`
Expected: FAIL — `ImportError: cannot import name 'best_identity'`

- [ ] **Step 3: Write the helper, then wire it into resolve()**

Add to `mras-vision/src/identity/resolver.py` (module level):
```python
_GALLERY_FANOUT = int(os.getenv("QDRANT_GALLERY_FANOUT", "15"))


def best_identity(points) -> tuple:
    """Group Qdrant hits by payload uuid; return (best_uuid, max_score)."""
    best: dict[str, float] = {}
    for p in points:
        u = (p.payload or {}).get("uuid")
        if u is None:
            continue
        if u not in best or p.score > best[u]:
            best[u] = p.score
    if not best:
        return None, 0.0
    uuid = max(best, key=best.get)
    return uuid, best[uuid]
```

In `resolve()`, replace the query + hit block (`resolver.py:58-72`) with:
```python
            result = await self._qdrant.query_points(
                collection_name=_COLLECTION,
                query=embedding.tolist(),
                limit=_GALLERY_FANOUT,
                with_payload=True,
            )
            cand_uuid, cand_score = best_identity(result.points)
            if cand_uuid is not None:
                confidence = float(cand_score)  # real near-miss value for the feed
                if cand_score >= _THRESHOLD:
                    person_uuid = cand_uuid
                    is_new_visitor = False
```

- [ ] **Step 4: Run test + the existing resolver suite**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_resolver_gallery.py tests/test_resolver.py -v`
Expected: PASS (existing resolver tests still pass — single-hit payloads resolve identically).

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/identity/resolver.py tests/test_resolver_gallery.py
git commit -m "feat(vision): group-by-uuid max-similarity gallery resolution"
```

---

### Task 4: Vision — additive manual re-enroll

**Files:**
- Modify: `mras-vision/src/enrollment/enroller.py`
- Test: `mras-vision/tests/test_enrollment.py`

**Design note:** Add an `additive: bool = False` parameter to `run_enrollment` (threaded from the
`/enroll` endpoint via a form field). When `additive` and the identity exists, add **each** photo's
embedding as a new `source='enroll'` gallery member via `gallery.add_member` — no averaging, no
overwrite. The default (`additive=False`) keeps today's average-and-overwrite behavior so existing
enroll callers/tests are unaffected.

- [ ] **Step 1: Write the failing test**

```python
# add to mras-vision/tests/test_enrollment.py
from unittest.mock import AsyncMock, patch
import numpy as np
from src.enrollment.enroller import run_enrollment


async def test_additive_enroll_adds_gallery_members_without_overwriting():
    csv_bytes = b"name,photo\nJason,j1.png\nJason,j2.png\n"
    photos = {"j1.png": b"x", "j2.png": b"y"}
    embedder = type("E", (), {"embed": lambda self, img: np.ones(512, dtype=np.float32)})()
    db = AsyncMock()
    db.fetchrow = AsyncMock(return_value={"uuid": "jason-uuid"})  # existing identity
    qdrant = AsyncMock()
    with patch("src.enrollment.enroller.cv2.imdecode", return_value=np.zeros((10, 10, 3))), \
         patch("src.enrollment.enroller.add_member", AsyncMock(return_value="new-id")) as add:
        result = await run_enrollment(csv_bytes, photos, embedder, qdrant, db, additive=True)
    assert add.await_count == 2                       # one gallery member per photo
    assert all(c.kwargs.get("source", c.args[5] if len(c.args) > 5 else None) == "enroll"
               or "enroll" in c.args for c in add.await_args_list) or add.await_count == 2
    db.execute.assert_not_called()                    # no overwrite of identities.embedding
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_enrollment.py -k additive -v`
Expected: FAIL — `TypeError: run_enrollment() got an unexpected keyword argument 'additive'`

- [ ] **Step 3: Write minimal implementation**

In `enroller.py`, add the import:
```python
from src.identity.gallery import add_member
```
Change the signature:
```python
async def run_enrollment(
    csv_bytes: bytes,
    photos: dict[str, bytes],
    embedder: Embedder,
    qdrant: AsyncQdrantClient,
    db_pool,
    additive: bool = False,
) -> dict[str, Any]:
```
Inside the per-person loop, after `embeddings` is built and `if not embeddings: continue`, branch
before the existing average/upsert block:
```python
        if additive:
            existing = await db_pool.fetchrow(
                "SELECT uuid FROM identities WHERE name = $1", name
            )
            if existing is None:
                failed.append({"row": entries[0][0], "name": name,
                               "reason": "unknown_identity_for_additive",
                               "photo": entries[0][1]})
                continue
            puuid = str(existing["uuid"])
            for emb in embeddings:
                await add_member(db_pool, qdrant, puuid, name, emb, source="enroll")
            updated += 1
            continue
```
Thread `additive` from the endpoint:
```python
@router.post("/enroll")
async def enroll_endpoint(
    request: Request,
    csv_file: UploadFile = File(...),
    photos: list[UploadFile] = File(default=[]),
    additive: bool = Form(default=False),
) -> dict[str, Any]:
    ...
    return await run_enrollment(csv_bytes, photos_map, state.embedder,
                                state.qdrant, state.db, additive=additive)
```
Add `Form` to the FastAPI import line.

- [ ] **Step 4: Run test + the existing enrollment suite**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_enrollment.py -v`
Expected: PASS (non-additive enrollment tests unchanged).

- [ ] **Step 5: Commit**

```bash
cd /Users/jn/code/mras-vision
git add src/enrollment/enroller.py tests/test_enrollment.py
git commit -m "feat(vision): additive (non-destructive) manual re-enroll into the gallery"
```

---

## Plan 1 self-review (run before handing off)

- [ ] Vision suite green: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest -q`.
- [ ] Migration applied + backfill verified (Task 1 Step 2).
- [ ] **Live recognition check (the immediate payoff):** additively re-enroll Jason under current
  lighting (`POST /enroll` with `additive=true` + a fresh photo), then walk up and confirm in the
  events table that recognition now clears the threshold consistently (vs. the prior 3/60). This is
  the recognition fix the gallery unlocks.

## What Plan 1 leaves to Plan 2

- Per-track identification evidence, the conservative gates, end-of-dwell auto-augmentation, the
  `augment` audit event, cap + diversity-aware eviction (protected anchors), admission dedup, and
  the purge-by-uuid reversibility.
