# Phase 0 — Ad Composition, Kiosk Display, and Infrastructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Phase 0 demo loop — mras-composer (P2 backend), mras-display (P2-C5 Electron kiosk), minimal P3-C1 activity feed, and Docker Compose wiring everything together.

**Architecture:** mras-vision (P1, already complete) fires fire-and-forget HTTP POST triggers to mras-composer. Composer selects 3-tier ad (Personalized → Standard), runs TTS (ElevenLabs→MisoOne fallback), assembles video via ffmpeg (Semaphore(1), 10s timeout), pushes video URL via WebSocket to the Electron kiosk. PostgreSQL `events` table logs every step (D19). mras-ops serves a minimal SSE activity feed. Electron kiosk loops a standard ad and interrupts with the personalized clip when it arrives.

**Tech Stack:** Python 3.11 / FastAPI / asyncpg / httpx / ffmpeg (mras-composer), ElevenLabs REST API, React 18 / Electron 31 / TypeScript / Vite / Vitest (mras-display), React / Vite / TypeScript / SSE (mras-ops frontend), pytest + pytest-asyncio (Python tests), PostgreSQL 16, Qdrant v1.9.

**Repos touched:**
- `/Users/jn/code/mras-composer` — primary deliverable
- `/Users/jn/code/mras-display` — new repo (create it)
- `/Users/jn/code/mras-ops` — migrations + Docker Compose + minimal P3-C1
- `/Users/jn/code/mras-vision` — one small addition: `/identity` lookup endpoint for E2E

---

## File Map

### mras-composer (new files)
| File | Responsibility |
|------|---------------|
| `src/db.py` | asyncpg pool factory |
| `src/tts/gateway.py` | ElevenLabs→MisoOne fallback + disk cache |
| `src/assembly/assembler.py` | ffmpeg subprocess with Semaphore(1) + 10s timeout |
| `src/selector/selector.py` | 3-tier ad selection + blocklist check |
| `main.py` | FastAPI app: lifespan, POST /trigger, WebSocket /ws, static mounts |
| `pytest.ini` | asyncio_mode = auto |
| `tests/conftest.py` | semaphore reset fixture |
| `tests/test_tts.py` | TTS cache + fallback chain tests |
| `tests/test_assembly.py` | ffmpeg timeout + Semaphore serialization tests |
| `tests/test_selector.py` | blocklist enforcement tests |

### mras-composer (modified)
| File | Change |
|------|--------|
| `requirements.txt` | Add asyncpg, pytest-asyncio; drop psycopg2-binary |

### mras-vision (modified)
| File | Change |
|------|--------|
| `main.py` | Add `/identity` GET endpoint for E2E UUID lookup |

### mras-display (new repo at `/Users/jn/code/mras-display`)
| File | Responsibility |
|------|---------------|
| `package.json` | Electron + React + Vite + Vitest deps |
| `tsconfig.json` | TypeScript config |
| `vite.config.ts` | Vite + React plugin config |
| `index.html` | Entry HTML |
| `electron/main.js` | Electron BrowserWindow, fullscreen |
| `src/App.tsx` | Video player, WebSocket client, reconnect, fade |
| `src/main.tsx` | React root |
| `.env.example` | VITE_COMPOSER_WS_URL, VITE_STANDARD_VIDEO_URL, VITE_FALLBACK_VIDEO_PATH |
| `src/__tests__/App.test.tsx` | WebSocket reconnect + fallback video tests |

### mras-ops (new/modified files)
| File | Change |
|------|--------|
| `db/migrations/001_initial.sql` | New: identities, events, campaigns tables |
| `docker-compose.yml` | Update: add postgres, qdrant, mras-vision, mras-composer services |
| `api/src/main.py` | Update: lifespan + asyncpg + GET /events/stream SSE endpoint |
| `api/requirements.txt` | Add asyncpg |
| `api/Dockerfile` | New |
| `frontend/src/App.tsx` | New: minimal SSE event table |
| `frontend/src/main.tsx` | New: React root |
| `frontend/index.html` | New |
| `frontend/vite.config.ts` | New |
| `frontend/Dockerfile` | New |
| `tests/e2e/test_phase0_e2e.py` | New: E2E enroll→trigger→assemble |
| `tests/e2e/fixtures/test_face.jpg` | New: real face photo for E2E (add manually) |

---

## Task 1: Database Schema

**Files:**
- Create: `mras-ops/db/migrations/001_initial.sql`

- [ ] **Step 1: Write the migration**

```sql
-- mras-ops/db/migrations/001_initial.sql

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS identities (
  uuid             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text        NOT NULL,
  embedding        float4[],
  embedding_status text        NOT NULL DEFAULT 'pending',
  is_blocked       boolean     NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS identities_name_idx   ON identities (name);
CREATE INDEX IF NOT EXISTS identities_status_idx ON identities (embedding_status);

CREATE TABLE IF NOT EXISTS events (
  id          bigserial   PRIMARY KEY,
  trigger_id  uuid        NOT NULL,
  ts          timestamptz NOT NULL DEFAULT now(),
  service     text        NOT NULL,
  event_type  text        NOT NULL,
  status      text        NOT NULL,
  payload     jsonb       NOT NULL DEFAULT '{}',
  asset_ref   text
);
CREATE INDEX IF NOT EXISTS events_ts_idx         ON events (ts DESC);
CREATE INDEX IF NOT EXISTS events_trigger_id_idx ON events (trigger_id);

CREATE TABLE IF NOT EXISTS campaigns (
  id              serial  PRIMARY KEY,
  name            text    NOT NULL,
  base_video_path text    NOT NULL,
  tts_template    text    NOT NULL DEFAULT 'Welcome, {name}!',
  is_active       boolean NOT NULL DEFAULT true
);
```

- [ ] **Step 2: Verify the SQL runs**

```bash
psql postgresql://mras:mras@localhost:5432/mras -f mras-ops/db/migrations/001_initial.sql
```
Expected: no errors; `\dt` shows three tables.

- [ ] **Step 3: Commit**

```bash
cd /Users/jn/code/mras-ops
git add db/migrations/001_initial.sql
git commit -m "feat: add Phase 0 initial database schema (identities, events, campaigns)"
```

---

## Task 2: mras-composer Project Scaffolding

**Files:**
- Modify: `mras-composer/requirements.txt`
- Create: `mras-composer/pytest.ini`
- Create: `mras-composer/src/db.py`
- Create: `mras-composer/tests/conftest.py`

- [ ] **Step 1: Write requirements.txt**

```
fastapi>=0.111.0
uvicorn[standard]>=0.29.0
httpx>=0.27.0
asyncpg>=0.29.0
python-multipart>=0.0.9
pytest>=8.0.0
pytest-asyncio>=0.23.0
```

- [ ] **Step 2: Write pytest.ini**

```ini
[pytest]
asyncio_mode = auto
```

- [ ] **Step 3: Write src/db.py**

```python
import os

import asyncpg


async def create_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(os.environ["DATABASE_URL"])
```

- [ ] **Step 4: Write tests/conftest.py**

```python
import asyncio
import pytest
import src.assembly.assembler as _asm


@pytest.fixture(autouse=True)
def reset_assembler_semaphore():
    _asm._SEMAPHORE = asyncio.Semaphore(1)
    yield
    _asm._SEMAPHORE = None
```

- [ ] **Step 5: Install deps**

```bash
cd /Users/jn/code/mras-composer
pip install -r requirements.txt
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add requirements.txt pytest.ini src/db.py tests/conftest.py
git commit -m "feat: scaffold mras-composer project (deps, pytest, db pool)"
```

---

## Task 3: TTS Gateway

**Files:**
- Create: `mras-composer/src/tts/gateway.py`

- [ ] **Step 1: Write src/tts/gateway.py**

```python
import hashlib
import os
from pathlib import Path

import httpx

_CACHE_DIR = Path(os.getenv("TTS_CACHE_DIR", "/tmp/tts_cache"))
_EL_API_KEY = os.getenv("ELEVENLABS_API_KEY", "")
_MISO_KEY = os.getenv("MISOONE_API_KEY", "")
_EL_BASE = "https://api.elevenlabs.io/v1"
_MISO_BASE = os.getenv("MISOONE_BASE_URL", "https://api.misoone.com/v1")  # TODO: verify MisoOne endpoint


def _cache_key(person_uuid: str, voice_id: str, text: str) -> str:
    h = hashlib.sha256(text.encode()).hexdigest()[:8]
    return f"{person_uuid}_{voice_id}_{h}"


async def synthesize(
    text: str,
    person_uuid: str,
    voice_id: str,
    http: httpx.AsyncClient,
) -> Path | None:
    key = _cache_key(person_uuid, voice_id, text)
    cached = _CACHE_DIR / f"{key}.mp3"
    if cached.exists():
        return cached

    audio = await _try_elevenlabs(text, voice_id, http)
    if audio is None:
        audio = await _try_misoone(text, http)

    if audio is None:
        return None

    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached.write_bytes(audio)
    return cached


async def _try_elevenlabs(text: str, voice_id: str, http: httpx.AsyncClient) -> bytes | None:
    if not _EL_API_KEY:
        return None
    try:
        resp = await http.post(
            f"{_EL_BASE}/text-to-speech/{voice_id}",
            headers={"xi-api-key": _EL_API_KEY},
            json={"text": text, "model_id": "eleven_turbo_v2"},
            timeout=15.0,
        )
        resp.raise_for_status()
        return resp.content
    except Exception:
        return None


async def _try_misoone(text: str, http: httpx.AsyncClient) -> bytes | None:
    if not _MISO_KEY:
        return None
    try:
        resp = await http.post(
            f"{_MISO_BASE}/synthesize",
            headers={"Authorization": f"Bearer {_MISO_KEY}"},
            json={"text": text},
            timeout=15.0,
        )
        resp.raise_for_status()
        return resp.content
    except Exception:
        return None
```

> **Note:** The MisoOne endpoint `POST /synthesize` with `Authorization: Bearer` is an assumption. Verify with MisoOne docs and update `MISOONE_BASE_URL` env var if the path differs.

- [ ] **Step 2: Commit**

```bash
cd /Users/jn/code/mras-composer
git add src/tts/gateway.py
git commit -m "feat: add TTS gateway (ElevenLabs primary, MisoOne backup, disk cache)"
```

---

## Task 4: TTS Gateway Tests

**Files:**
- Create: `mras-composer/tests/test_tts.py`

- [ ] **Step 1: Write tests/test_tts.py**

```python
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.tts.gateway import synthesize, _cache_key


def _resp(content: bytes) -> MagicMock:
    r = MagicMock()
    r.content = content
    r.raise_for_status = MagicMock()
    return r


async def test_cache_hit_returns_cached_path_no_http(tmp_path):
    key = _cache_key("uuid-1", "v1", "Hello Alice")
    cached = tmp_path / f"{key}.mp3"
    cached.write_bytes(b"cached-audio")

    http = AsyncMock()
    with patch("src.tts.gateway._CACHE_DIR", tmp_path):
        result = await synthesize("Hello Alice", "uuid-1", "v1", http)

    assert result == cached
    http.post.assert_not_called()


async def test_cache_miss_calls_elevenlabs_and_stores_file(tmp_path):
    http = AsyncMock()
    http.post = AsyncMock(return_value=_resp(b"el-audio"))

    with patch("src.tts.gateway._CACHE_DIR", tmp_path), \
         patch("src.tts.gateway._EL_API_KEY", "test-key"):
        result = await synthesize("Hello Bob", "uuid-2", "v1", http)

    assert result is not None
    assert result.read_bytes() == b"el-audio"
    http.post.assert_called_once()
    assert "elevenlabs" in http.post.call_args[0][0]


async def test_elevenlabs_fail_falls_back_to_misoone(tmp_path):
    fail_resp = MagicMock()
    fail_resp.raise_for_status = MagicMock(side_effect=Exception("EL 500"))
    success_resp = _resp(b"miso-audio")

    http = AsyncMock()
    http.post = AsyncMock(side_effect=[fail_resp, success_resp])

    with patch("src.tts.gateway._CACHE_DIR", tmp_path), \
         patch("src.tts.gateway._EL_API_KEY", "el-key"), \
         patch("src.tts.gateway._MISO_KEY", "miso-key"):
        result = await synthesize("Hello Charlie", "uuid-3", "v1", http)

    assert result is not None
    assert result.read_bytes() == b"miso-audio"
    assert http.post.call_count == 2


async def test_all_providers_fail_returns_none(tmp_path):
    http = AsyncMock()
    http.post = AsyncMock(side_effect=Exception("network down"))

    with patch("src.tts.gateway._CACHE_DIR", tmp_path), \
         patch("src.tts.gateway._EL_API_KEY", "el-key"), \
         patch("src.tts.gateway._MISO_KEY", "miso-key"):
        result = await synthesize("Hello Dave", "uuid-4", "v1", http)

    assert result is None


async def test_different_text_produces_different_cache_key():
    k1 = _cache_key("uuid-1", "v1", "Hello Alice")
    k2 = _cache_key("uuid-1", "v1", "Hello Bob")
    assert k1 != k2


async def test_same_inputs_produce_same_cache_key():
    k1 = _cache_key("uuid-1", "v1", "Hello Alice")
    k2 = _cache_key("uuid-1", "v1", "Hello Alice")
    assert k1 == k2
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/jn/code/mras-composer
pytest tests/test_tts.py -v
```
Expected: 6 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_tts.py
git commit -m "test: add TTS gateway tests (cache hit/miss, fallback chain, key collision)"
```

---

## Task 5: Video Assembler

**Files:**
- Create: `mras-composer/src/assembly/assembler.py`

- [ ] **Step 1: Write src/assembly/assembler.py**

```python
import asyncio
import os
import tempfile
from pathlib import Path

_TIMEOUT = int(os.getenv("FFMPEG_TIMEOUT", "10"))
_OUTPUT_DIR = Path(os.getenv("ASSEMBLED_OUTPUT_DIR", "/tmp/assembled"))
_SEMAPHORE: asyncio.Semaphore | None = None


def _sem() -> asyncio.Semaphore:
    global _SEMAPHORE
    if _SEMAPHORE is None:
        _SEMAPHORE = asyncio.Semaphore(1)
    return _SEMAPHORE


async def assemble(base_video: Path, audio: Path, trigger_id: str) -> Path:
    _OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out = _OUTPUT_DIR / f"{trigger_id}.mp4"

    async with _sem():
        tmp = Path(tempfile.mktemp(suffix=".mp4", dir=_OUTPUT_DIR))
        try:
            proc = await asyncio.create_subprocess_exec(
                "ffmpeg", "-y",
                "-i", str(base_video), "-i", str(audio),
                "-filter_complex", "amix=inputs=2:duration=first",
                "-c:v", "libx264", "-preset", "fast",
                "-c:a", "aac",
                str(tmp),
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT)
            if proc.returncode != 0:
                raise RuntimeError(f"ffmpeg exited {proc.returncode}")
            tmp.rename(out)
            return out
        except Exception:
            if tmp.exists():
                tmp.unlink(missing_ok=True)
            raise
```

- [ ] **Step 2: Commit**

```bash
cd /Users/jn/code/mras-composer
git add src/assembly/assembler.py
git commit -m "feat: add ffmpeg video assembler (Semaphore(1), 10s timeout, temp cleanup)"
```

---

## Task 6: Video Assembler Tests

**Files:**
- Create: `mras-composer/tests/test_assembly.py`

- [ ] **Step 1: Write tests/test_assembly.py**

```python
import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import src.assembly.assembler as asm_mod
from src.assembly.assembler import assemble


async def test_ffmpeg_timeout_raises_and_cleans_up_temp_file(tmp_path, monkeypatch):
    monkeypatch.setattr(asm_mod, "_TIMEOUT", 0.05)
    monkeypatch.setattr(asm_mod, "_OUTPUT_DIR", tmp_path)

    slow_proc = MagicMock()
    slow_proc.returncode = None
    slow_proc.kill = MagicMock()

    async def slow_communicate():
        await asyncio.sleep(100)
        return (b"", b"")

    slow_proc.communicate = slow_communicate

    with patch("asyncio.create_subprocess_exec", AsyncMock(return_value=slow_proc)):
        with pytest.raises(asyncio.TimeoutError):
            await assemble(tmp_path / "base.mp4", tmp_path / "audio.mp3", "trig-1")

    assert list(tmp_path.glob("*.mp4")) == []


async def test_ffmpeg_success_returns_named_output(tmp_path, monkeypatch):
    monkeypatch.setattr(asm_mod, "_OUTPUT_DIR", tmp_path)

    async def fake_exec(*args, **kwargs):
        out_path = args[-1]
        proc = MagicMock()
        proc.returncode = 0

        async def communicate():
            Path(out_path).touch()
            return (b"", b"")

        proc.communicate = communicate
        return proc

    with patch("asyncio.create_subprocess_exec", side_effect=fake_exec):
        result = await assemble(tmp_path / "base.mp4", tmp_path / "audio.mp3", "trig-2")

    assert result == tmp_path / "trig-2.mp4"
    assert result.exists()


async def test_ffmpeg_nonzero_exit_raises_and_cleans_up(tmp_path, monkeypatch):
    monkeypatch.setattr(asm_mod, "_OUTPUT_DIR", tmp_path)

    async def fail_exec(*args, **kwargs):
        proc = MagicMock()
        proc.returncode = 1

        async def communicate():
            return (b"", b"")

        proc.communicate = communicate
        return proc

    with patch("asyncio.create_subprocess_exec", side_effect=fail_exec):
        with pytest.raises(RuntimeError, match="ffmpeg exited 1"):
            await assemble(tmp_path / "base.mp4", tmp_path / "audio.mp3", "trig-3")

    assert list(tmp_path.glob("*.mp4")) == []


async def test_semaphore_serializes_concurrent_calls(tmp_path, monkeypatch):
    monkeypatch.setattr(asm_mod, "_OUTPUT_DIR", tmp_path)
    events: list[str] = []

    async def ordered_proc(*args, **kwargs):
        out_path = args[-1]
        proc = MagicMock()
        proc.returncode = 0

        async def communicate():
            events.append("start")
            await asyncio.sleep(0.05)
            Path(out_path).touch()
            events.append("end")
            return (b"", b"")

        proc.communicate = communicate
        return proc

    with patch("asyncio.create_subprocess_exec", side_effect=ordered_proc):
        t1 = asyncio.create_task(
            assemble(tmp_path / "base.mp4", tmp_path / "audio.mp3", "t1")
        )
        t2 = asyncio.create_task(
            assemble(tmp_path / "base.mp4", tmp_path / "audio.mp3", "t2")
        )
        await asyncio.gather(t1, t2)

    assert events == ["start", "end", "start", "end"]
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/jn/code/mras-composer
pytest tests/test_assembly.py -v
```
Expected: 4 passed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_assembly.py
git commit -m "test: add assembler tests (timeout+cleanup, nonzero exit, Semaphore serialization)"
```

---

## Task 7: Ad Selector

**Files:**
- Create: `mras-composer/src/selector/selector.py`

- [ ] **Step 1: Write src/selector/selector.py**

```python
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

_STANDARD_VIDEO = Path(os.getenv("STANDARD_VIDEO_PATH", "/assets/standard.mp4"))
_TTS_TEMPLATE = os.getenv("TTS_TEMPLATE", "Welcome, {name}!")


@dataclass
class AdSelection:
    type: Literal["standard", "personalized"]
    base_video: Path
    tts_text: str | None = None
    person_uuid: str | None = None


async def select(trigger: dict, db) -> AdSelection:
    std = AdSelection(type="standard", base_video=_STANDARD_VIDEO)
    person_uuid = trigger.get("uuid")

    if not person_uuid or trigger.get("is_new_visitor", True):
        return std

    row = await db.fetchrow(
        "SELECT name, is_blocked FROM identities WHERE uuid = $1", person_uuid
    )
    if row is None or row["is_blocked"]:
        return std

    tts_text = _TTS_TEMPLATE.format(name=row["name"])
    return AdSelection(
        type="personalized",
        base_video=_STANDARD_VIDEO,
        tts_text=tts_text,
        person_uuid=person_uuid,
    )
```

- [ ] **Step 2: Commit**

```bash
cd /Users/jn/code/mras-composer
git add src/selector/selector.py
git commit -m "feat: add ad selector (3-tier: personalized/standard, blocklist check)"
```

---

## Task 8: Ad Selector Tests

**Files:**
- Create: `mras-composer/tests/test_selector.py`

- [ ] **Step 1: Write tests/test_selector.py**

```python
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from src.selector.selector import select, AdSelection

_FAKE_VIDEO = Path("/fake/standard.mp4")


def _db(name: str = "Alice", is_blocked: bool = False, found: bool = True) -> AsyncMock:
    db = AsyncMock()
    db.fetchrow = AsyncMock(
        return_value={"name": name, "is_blocked": is_blocked} if found else None
    )
    return db


async def test_new_visitor_returns_standard_without_db_query():
    db = _db()
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": None, "is_new_visitor": True}, db)
    assert result.type == "standard"
    db.fetchrow.assert_not_called()


async def test_uuid_with_is_new_visitor_true_returns_standard():
    db = _db()
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": "some-uuid", "is_new_visitor": True}, db)
    assert result.type == "standard"
    db.fetchrow.assert_not_called()


async def test_known_unblocked_visitor_returns_personalized():
    db = _db(name="Alice", is_blocked=False)
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": "uuid-abc", "is_new_visitor": False}, db)
    assert result.type == "personalized"
    assert result.person_uuid == "uuid-abc"
    assert "Alice" in result.tts_text


async def test_blocklisted_uuid_returns_standard():
    db = _db(name="Alice", is_blocked=True)
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": "uuid-abc", "is_new_visitor": False}, db)
    assert result.type == "standard"


async def test_uuid_not_in_db_returns_standard():
    db = _db(found=False)
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": "unknown", "is_new_visitor": False}, db)
    assert result.type == "standard"


async def test_tts_text_uses_person_name():
    db = _db(name="Jason")
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO), \
         patch("src.selector.selector._TTS_TEMPLATE", "Hey {name}, welcome!"):
        result = await select({"uuid": "uuid-xyz", "is_new_visitor": False}, db)
    assert result.tts_text == "Hey Jason, welcome!"
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/jn/code/mras-composer
pytest tests/test_selector.py -v
```
Expected: 6 passed.

- [ ] **Step 3: Run all composer tests**

```bash
pytest -v
```
Expected: 16 passed (6 TTS + 4 assembly + 6 selector).

- [ ] **Step 4: Commit**

```bash
git add tests/test_selector.py
git commit -m "test: add selector tests (blocklist enforcement, new visitor, known visitor)"
```

---

## Task 9: mras-composer POST /trigger Endpoint and WebSocket

**Files:**
- Modify: `mras-composer/main.py` (full rewrite)

- [ ] **Step 1: Write main.py**

```python
import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Set

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from src.assembly.assembler import assemble
from src.db import create_pool
from src.selector.selector import select
from src.tts.gateway import synthesize

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

_ASSETS_DIR = Path(os.getenv("ASSETS_DIR", "/assets"))
_OUTPUT_DIR = Path(os.getenv("ASSEMBLED_OUTPUT_DIR", "/tmp/assembled"))
_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "")
_HOST = os.getenv("HOST", "localhost")
_PORT = int(os.getenv("PORT", "8002"))


class WSManager:
    def __init__(self) -> None:
        self._clients: Set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self._clients.add(ws)

    def disconnect(self, ws: WebSocket) -> None:
        self._clients.discard(ws)

    async def broadcast(self, msg: dict) -> None:
        dead: Set[WebSocket] = set()
        for ws in list(self._clients):
            try:
                await ws.send_json(msg)
            except Exception:
                dead.add(ws)
        self._clients -= dead


@asynccontextmanager
async def lifespan(app: FastAPI):
    _OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    app.state.db = await create_pool()
    app.state.http = httpx.AsyncClient()
    app.state.ws = WSManager()
    yield
    await app.state.http.aclose()
    await app.state.db.close()


_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="mras-composer", lifespan=lifespan)
app.mount("/media", StaticFiles(directory=str(_OUTPUT_DIR)), name="media")
if _ASSETS_DIR.exists():
    app.mount("/assets", StaticFiles(directory=str(_ASSETS_DIR)), name="assets")


class TriggerPayload(BaseModel):
    trigger_id: str
    uuid: str | None = None
    confidence: float = 0.0
    is_new_visitor: bool = True
    scene_context: dict = {}
    screen_id: str = "screen_0"


@app.post("/trigger")
async def trigger_endpoint(body: TriggerPayload):
    selection = await select(body.model_dump(), app.state.db)

    if selection.type == "standard":
        await _log(app.state.db, body.trigger_id, "composition", "standard_selected", {})
        return {"status": "standard"}

    audio_path = await synthesize(
        selection.tts_text,
        selection.person_uuid,
        _VOICE_ID,
        app.state.http,
    )
    if audio_path is None:
        await _log(app.state.db, body.trigger_id, "tts_attempt", "error",
                   {"error": "TTS_UNAVAILABLE"})
        return {"status": "tts_failed"}

    await _log(app.state.db, body.trigger_id, "tts_attempt", "success", {})

    try:
        video_path = await assemble(selection.base_video, audio_path, body.trigger_id)
    except Exception as exc:
        await _log(app.state.db, body.trigger_id, "assembly", "error", {"error": str(exc)})
        return {"status": "assembly_failed"}

    video_url = f"http://{_HOST}:{_PORT}/media/{video_path.name}"
    await app.state.ws.broadcast({
        "type": "play",
        "trigger_id": body.trigger_id,
        "video_url": video_url,
    })
    await _log(app.state.db, body.trigger_id, "playback", "dispatched",
               {"video": video_path.name})
    return {"status": "ok"}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await app.state.ws.connect(ws)
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        app.state.ws.disconnect(ws)


@app.get("/health")
def health():
    return {"status": "ok"}


async def _log(db, trigger_id: str, event_type: str, status: str, payload: dict) -> None:
    try:
        await db.execute(
            "INSERT INTO events (trigger_id, ts, service, event_type, status, payload) "
            "VALUES ($1, $2, 'mras-composer', $3, $4, $5::jsonb)",
            trigger_id,
            datetime.now(timezone.utc),
            event_type,
            status,
            json.dumps(payload),
        )
    except Exception as exc:
        logger.error("DB event log failed: %s", exc)
```

- [ ] **Step 2: Verify the app starts**

```bash
cd /Users/jn/code/mras-composer
DATABASE_URL=postgresql://mras:mras@localhost:5432/mras \
ASSETS_DIR=/tmp \
uvicorn main:app --host 0.0.0.0 --port 8002 --reload
```
Expected: `Application startup complete.`

- [ ] **Step 3: Smoke-test the trigger endpoint**

```bash
curl -s -X POST http://localhost:8002/trigger \
  -H "Content-Type: application/json" \
  -d '{"trigger_id":"smoke-1","uuid":null,"confidence":0,"is_new_visitor":true,"screen_id":"screen_0"}' \
  | python3 -m json.tool
```
Expected: `{"status": "standard"}`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jn/code/mras-composer
git add main.py
git commit -m "feat: add POST /trigger endpoint, WebSocket /ws, static file serving"
```

---

## Task 10: Add Identity Lookup Endpoint to mras-vision

**Files:**
- Modify: `mras-vision/main.py`

- [ ] **Step 1: Add the `/identity` route**

After `app.include_router(enroll_router)` in `mras-vision/main.py`, add:

```python
from fastapi import HTTPException

@app.get("/identity")
async def get_identity_by_name(name: str):
    row = await app.state.db.fetchrow(
        "SELECT uuid FROM identities WHERE name = $1", name
    )
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    return {"uuid": str(row["uuid"])}
```

- [ ] **Step 2: Smoke-test**

With mras-vision running:
```bash
curl "http://localhost:8001/identity?name=TestPerson"
```
Expected: `{"uuid": "..."}` or 404.

- [ ] **Step 3: Commit**

```bash
cd /Users/jn/code/mras-vision
git add main.py
git commit -m "feat: add /identity endpoint for E2E UUID lookup"
```

---

## Task 11: mras-display Electron Kiosk — Project Setup

**Files (new repo at `/Users/jn/code/mras-display`):**

- [ ] **Step 1: Initialize the repo**

```bash
mkdir -p /Users/jn/code/mras-display/electron /Users/jn/code/mras-display/src/__tests__
cd /Users/jn/code/mras-display
git init
```

- [ ] **Step 2: Write package.json**

```json
{
  "name": "mras-display",
  "version": "0.1.0",
  "main": "electron/main.js",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "electron:dev": "concurrently \"vite\" \"wait-on http://localhost:5173 && electron .\"",
    "test": "vitest run"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.1",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.4.5",
    "vite": "^5.3.1",
    "electron": "^31.0.0",
    "concurrently": "^8.0.0",
    "wait-on": "^8.0.0",
    "vitest": "^1.6.0",
    "@testing-library/react": "^16.0.0",
    "@testing-library/user-event": "^14.0.0",
    "jsdom": "^24.0.0"
  }
}
```

- [ ] **Step 3: Write tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

- [ ] **Step 4: Write vite.config.ts**

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
  test: {
    environment: 'jsdom',
    globals: true,
  },
})
```

- [ ] **Step 5: Write index.html**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>MRAS Display</title>
    <style>* { margin: 0; padding: 0; box-sizing: border-box; } body { background: #000; overflow: hidden; }</style>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 6: Write electron/main.js**

```js
const { app, BrowserWindow } = require('electron')
const path = require('path')

function createWindow() {
  const win = new BrowserWindow({
    fullscreen: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  })
  if (process.env.NODE_ENV === 'development') {
    win.loadURL('http://localhost:5173')
  } else {
    win.loadFile(path.join(__dirname, '../dist/index.html'))
  }
}

app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())
```

- [ ] **Step 7: Write electron/preload.js**

```js
// No bridge needed — renderer uses standard WebSocket API
```

- [ ] **Step 8: Write .env.example**

```
VITE_COMPOSER_WS_URL=ws://localhost:8002/ws
VITE_STANDARD_VIDEO_URL=http://localhost:8002/assets/standard.mp4
VITE_FALLBACK_VIDEO_PATH=/path/to/local/fallback.mp4
```

- [ ] **Step 9: Install deps**

```bash
cd /Users/jn/code/mras-display
npm install
```
Expected: no errors.

- [ ] **Step 10: Commit**

```bash
git add .
git commit -m "feat: initialize mras-display Electron kiosk project"
```

---

## Task 12: mras-display React Kiosk App

**Files:**
- Create: `mras-display/src/main.tsx`
- Create: `mras-display/src/App.tsx`

- [ ] **Step 1: Write src/main.tsx**

```tsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
```

- [ ] **Step 2: Write src/App.tsx**

```tsx
import { useEffect, useRef } from 'react'

const WS_URL = import.meta.env.VITE_COMPOSER_WS_URL ?? 'ws://localhost:8002/ws'
const STANDARD_VIDEO_URL = import.meta.env.VITE_STANDARD_VIDEO_URL ?? 'http://localhost:8002/assets/standard.mp4'
const FALLBACK_VIDEO_PATH = import.meta.env.VITE_FALLBACK_VIDEO_PATH ?? ''
const MAX_RETRY_ATTEMPTS = 5

export default function App() {
  const videoRef = useRef<HTMLVideoElement>(null)
  const retryDelay = useRef(1000)
  const retryCount = useRef(0)
  const inFallback = useRef(false)
  const wsRef = useRef<WebSocket | null>(null)

  const playVideo = (url: string, loop: boolean = false) => {
    const video = videoRef.current
    if (!video) return
    video.style.opacity = '0'
    setTimeout(() => {
      video.src = url
      video.loop = loop
      video.load()
      video.play().catch(() => {})
      video.style.opacity = '1'
    }, 500)
  }

  const startFallback = () => {
    if (FALLBACK_VIDEO_PATH && !inFallback.current) {
      inFallback.current = true
      playVideo(`file://${FALLBACK_VIDEO_PATH}`, true)
    }
  }

  const connect = () => {
    const ws = new WebSocket(WS_URL)
    wsRef.current = ws

    ws.onopen = () => {
      retryDelay.current = 1000
      retryCount.current = 0
      if (inFallback.current) {
        inFallback.current = false
        playVideo(STANDARD_VIDEO_URL, true)
      }
    }

    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data) as { type: string; video_url: string }
      if (msg.type === 'play') {
        playVideo(msg.video_url, false)
      }
    }

    ws.onclose = () => {
      retryCount.current += 1
      if (retryCount.current >= MAX_RETRY_ATTEMPTS) {
        startFallback()
      }
      const delay = retryDelay.current
      retryDelay.current = Math.min(delay * 2, 30000)
      setTimeout(connect, delay)
    }
  }

  const handleEnded = () => {
    if (!inFallback.current) {
      playVideo(STANDARD_VIDEO_URL, true)
    }
  }

  useEffect(() => {
    playVideo(STANDARD_VIDEO_URL, true)
    connect()
    return () => wsRef.current?.close()
  }, [])

  return (
    <div style={{ width: '100vw', height: '100vh', background: '#000' }}>
      <video
        ref={videoRef}
        style={{ width: '100%', height: '100%', objectFit: 'cover', transition: 'opacity 0.5s' }}
        autoPlay
        playsInline
        onEnded={handleEnded}
      />
    </div>
  )
}
```

- [ ] **Step 3: Verify the dev server starts**

```bash
cd /Users/jn/code/mras-display
npm run dev
```
Expected: Vite dev server at `http://localhost:5173`. Open browser — black page with video element in DevTools inspector.

- [ ] **Step 4: Commit**

```bash
git add src/
git commit -m "feat: add kiosk React app — WebSocket playback, reconnect backoff, fade transition"
```

---

## Task 13: mras-display WebSocket Reconnect Tests

**Files:**
- Create: `mras-display/src/__tests__/App.test.tsx`

- [ ] **Step 1: Write src/__tests__/App.test.tsx**

```tsx
import { render, act } from '@testing-library/react'
import { vi, describe, it, expect, beforeEach, afterEach } from 'vitest'
import App from '../App'

interface MockWSInstance {
  onopen: (() => void) | null
  onclose: (() => void) | null
  onmessage: ((e: { data: string }) => void) | null
  close: ReturnType<typeof vi.fn>
  simulateOpen: () => void
  simulateClose: () => void
  simulateMessage: (data: object) => void
}

let mockWS: MockWSInstance
const MockWebSocket = vi.fn(() => {
  mockWS = {
    onopen: null, onclose: null, onmessage: null,
    close: vi.fn(),
    simulateOpen() { this.onopen?.() },
    simulateClose() { this.onclose?.() },
    simulateMessage(data) { this.onmessage?.({ data: JSON.stringify(data) }) },
  }
  return mockWS
})

beforeEach(() => {
  vi.stubGlobal('WebSocket', MockWebSocket)
  MockWebSocket.mockClear()
  Object.defineProperty(HTMLMediaElement.prototype, 'play', {
    writable: true,
    value: vi.fn().mockResolvedValue(undefined),
  })
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('WebSocket reconnect backoff', () => {
  it('reconnects after 1s on first disconnect', async () => {
    vi.useFakeTimers()
    render(<App />)
    expect(MockWebSocket).toHaveBeenCalledTimes(1)

    await act(async () => { mockWS.simulateClose() })
    await act(async () => { vi.advanceTimersByTime(1000) })

    expect(MockWebSocket).toHaveBeenCalledTimes(2)
  })

  it('doubles retry delay on each disconnect', async () => {
    vi.useFakeTimers()
    render(<App />)

    // Close 1 → retry at 1s
    await act(async () => { mockWS.simulateClose() })
    await act(async () => { vi.advanceTimersByTime(1000) })
    expect(MockWebSocket).toHaveBeenCalledTimes(2)

    // Close 2 → retry at 2s
    await act(async () => { mockWS.simulateClose() })
    await act(async () => { vi.advanceTimersByTime(1999) })
    expect(MockWebSocket).toHaveBeenCalledTimes(2)  // not yet
    await act(async () => { vi.advanceTimersByTime(1) })
    expect(MockWebSocket).toHaveBeenCalledTimes(3)
  })

  it('plays fallback video after 5 failed attempts', async () => {
    vi.useFakeTimers()
    vi.stubEnv('VITE_FALLBACK_VIDEO_PATH', '/local/fallback.mp4')

    const { container } = render(<App />)
    const video = container.querySelector('video')!

    let delay = 1000
    for (let i = 0; i < 5; i++) {
      await act(async () => { mockWS.simulateClose() })
      await act(async () => { vi.advanceTimersByTime(delay) })
      delay = Math.min(delay * 2, 30000)
    }

    expect(video.src).toContain('fallback.mp4')
  })

  it('restores standard video on successful reconnect after fallback', async () => {
    vi.useFakeTimers()
    vi.stubEnv('VITE_FALLBACK_VIDEO_PATH', '/local/fallback.mp4')
    vi.stubEnv('VITE_STANDARD_VIDEO_URL', 'http://localhost:8002/assets/standard.mp4')

    const { container } = render(<App />)
    const video = container.querySelector('video')!

    let delay = 1000
    for (let i = 0; i < 5; i++) {
      await act(async () => { mockWS.simulateClose() })
      await act(async () => { vi.advanceTimersByTime(delay) })
      delay = Math.min(delay * 2, 30000)
    }

    await act(async () => { mockWS.simulateOpen() })

    expect(video.src).toContain('standard.mp4')
  })
})
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/jn/code/mras-display
npm test
```
Expected: 4 passed.

- [ ] **Step 3: Commit**

```bash
git add src/__tests__/
git commit -m "test: add WebSocket reconnect tests (backoff, fallback, restore on reconnect)"
```

---

## Task 14: P3-C1 Minimal Activity Feed (mras-ops)

**Files:**

- [ ] **Step 1: Write api/Dockerfile**

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 2: Update api/requirements.txt**

```
fastapi>=0.111.0
uvicorn[standard]>=0.29.0
asyncpg>=0.29.0
```

- [ ] **Step 3: Write api/src/main.py**

```python
import asyncio
import json
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import asyncpg
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

_db: asyncpg.Pool | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _db
    _db = await asyncpg.create_pool(os.environ["DATABASE_URL"])
    yield
    await _db.close()


app = FastAPI(title="mras-ops", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["GET"], allow_headers=["*"]
)


@app.get("/events/stream")
async def events_stream():
    async def generate():
        rows = await _db.fetch(
            "SELECT trigger_id, ts, service, event_type, status, payload "
            "FROM events ORDER BY ts DESC LIMIT 20"
        )
        for row in reversed(rows):
            yield f"data: {json.dumps(dict(row), default=str)}\n\n"

        last_ts = rows[0]["ts"] if rows else datetime.now(timezone.utc)
        while True:
            await asyncio.sleep(1)
            new_rows = await _db.fetch(
                "SELECT trigger_id, ts, service, event_type, status, payload "
                "FROM events WHERE ts > $1 ORDER BY ts ASC",
                last_ts,
            )
            for row in new_rows:
                yield f"data: {json.dumps(dict(row), default=str)}\n\n"
                last_ts = row["ts"]

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.get("/health")
def health():
    return {"status": "ok"}
```

- [ ] **Step 4: Write frontend/Dockerfile**

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install
COPY . .
EXPOSE 3000
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "3000"]
```

- [ ] **Step 5: Update frontend/package.json**

Replace with (preserve existing react/react-dom deps, add vite and types):
```json
{
  "name": "mras-ops-frontend",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.1",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.4.5",
    "vite": "^5.3.1"
  }
}
```

- [ ] **Step 6: Write frontend/vite.config.ts**

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({ plugins: [react()] })
```

- [ ] **Step 7: Write frontend/index.html**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>MRAS Activity Feed</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 8: Write frontend/src/main.tsx**

```tsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode><App /></React.StrictMode>
)
```

- [ ] **Step 9: Write frontend/src/App.tsx**

```tsx
import { useEffect, useState } from 'react'

const OPS_API = import.meta.env.VITE_OPS_API_URL ?? 'http://localhost:8080'

interface MRASEvent {
  trigger_id: string
  ts: string
  service: string
  event_type: string
  status: string
  payload: Record<string, unknown>
}

export default function App() {
  const [events, setEvents] = useState<MRASEvent[]>([])

  useEffect(() => {
    const es = new EventSource(`${OPS_API}/events/stream`)
    es.onmessage = (e) => {
      const ev = JSON.parse(e.data) as MRASEvent
      setEvents(prev => [ev, ...prev].slice(0, 200))
    }
    return () => es.close()
  }, [])

  return (
    <div style={{ fontFamily: 'monospace', padding: 16, background: '#111', color: '#eee', minHeight: '100vh' }}>
      <h2 style={{ marginBottom: 12 }}>MRAS Activity Feed</h2>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
        <thead>
          <tr>
            {['time', 'service', 'type', 'status', 'trigger_id'].map(h => (
              <th key={h} style={{ textAlign: 'left', padding: '4px 8px', borderBottom: '1px solid #333' }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {events.map((ev, i) => (
            <tr key={i} style={{ color: ev.status === 'error' ? '#f88' : '#eee' }}>
              <td style={{ padding: '2px 8px' }}>{new Date(ev.ts).toLocaleTimeString()}</td>
              <td style={{ padding: '2px 8px' }}>{ev.service}</td>
              <td style={{ padding: '2px 8px' }}>{ev.event_type}</td>
              <td style={{ padding: '2px 8px' }}>{ev.status}</td>
              <td style={{ padding: '2px 8px', color: '#888' }}>{ev.trigger_id?.slice(0, 8)}…</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
```

- [ ] **Step 10: Commit**

```bash
cd /Users/jn/code/mras-ops
git add api/ frontend/
git commit -m "feat: add P3-C1 minimal activity feed (SSE stream + React event table)"
```

---

## Task 15: Docker Compose — Full Phase 0 Stack

**Files:**
- Modify: `mras-ops/docker-compose.yml`
- Create: `mras-ops/.env.example`
- Create: `mras-ops/assets/.gitkeep`

- [ ] **Step 1: Write docker-compose.yml**

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: mras
      POSTGRES_USER: mras
      POSTGRES_PASSWORD: mras
    ports:
      - "5432:5432"
    volumes:
      - ./db/migrations:/docker-entrypoint-initdb.d:ro
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mras"]
      interval: 5s
      timeout: 5s
      retries: 10

  qdrant:
    image: qdrant/qdrant:v1.9.0
    ports:
      - "6333:6333"
    volumes:
      - qdrant_data:/qdrant/storage

  mras-vision:
    build: ../../mras-vision
    ports:
      - "8001:8001"
    environment:
      DATABASE_URL: postgresql://mras:mras@postgres:5432/mras
      QDRANT_URL: http://qdrant:6333
      COMPOSER_URL: http://mras-composer:8002
      DEEPFACE_BACKEND: ${DEEPFACE_BACKEND:-cpu}
      FRAME_SAMPLE_RATE: ${FRAME_SAMPLE_RATE:-5}
      CONFIDENCE_THRESHOLD: ${CONFIDENCE_THRESHOLD:-0.68}
      SCREEN_ID: ${SCREEN_ID:-screen_0}
    depends_on:
      postgres:
        condition: service_healthy
      qdrant:
        condition: service_started
    command: uvicorn main:app --host 0.0.0.0 --port 8001

  mras-composer:
    build: ../../mras-composer
    ports:
      - "8002:8002"
    environment:
      DATABASE_URL: postgresql://mras:mras@postgres:5432/mras
      ELEVENLABS_API_KEY: ${ELEVENLABS_API_KEY}
      ELEVENLABS_VOICE_ID: ${ELEVENLABS_VOICE_ID}
      MISOONE_API_KEY: ${MISOONE_API_KEY:-}
      ASSETS_DIR: /assets
      ASSEMBLED_OUTPUT_DIR: /output
      STANDARD_VIDEO_PATH: /assets/standard.mp4
      FFMPEG_TIMEOUT: ${FFMPEG_TIMEOUT:-10}
    volumes:
      - ./assets:/assets:ro
      - output_data:/output
    depends_on:
      postgres:
        condition: service_healthy

  mras-ops-api:
    build: ./api
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgresql://mras:mras@postgres:5432/mras
    depends_on:
      postgres:
        condition: service_healthy

  mras-ops-frontend:
    build: ./frontend
    ports:
      - "3000:3000"

volumes:
  postgres_data:
  qdrant_data:
  output_data:
```

- [ ] **Step 2: Write .env.example**

```bash
# TTS providers
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=
MISOONE_API_KEY=

# Runtime tuning
DEEPFACE_BACKEND=mps        # mps (M3 dev), cuda (AWS), cpu (fallback)
FRAME_SAMPLE_RATE=5
CONFIDENCE_THRESHOLD=0.68
FFMPEG_TIMEOUT=10
SCREEN_ID=screen_0
```

- [ ] **Step 3: Create the assets directory and add a base video**

```bash
mkdir -p /Users/jn/code/mras-ops/assets
touch /Users/jn/code/mras-ops/assets/.gitkeep
```

Then copy your base ad video:
```bash
cp /path/to/your/base_ad.mp4 /Users/jn/code/mras-ops/assets/standard.mp4
```
**This file is required.** Without it, mras-composer will 404 on every standard ad request and the kiosk will hang.

- [ ] **Step 4: Add a Dockerfile to mras-vision if missing**

Check if `mras-vision/Dockerfile` exists (it does — confirmed in repo listing). If missing, create:
```dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
```

- [ ] **Step 5: Bring up the stack**

```bash
cd /Users/jn/code/mras-ops
cp .env.example .env
# Edit .env — fill in ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID
docker compose up --build
```
Expected: all services start. Verify:
```bash
curl http://localhost:8001/health   # {"status":"ok"}
curl http://localhost:8002/health   # {"status":"ok"}
curl http://localhost:8080/health   # {"status":"ok"}
```
Open `http://localhost:3000` — activity feed table visible.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml .env.example assets/.gitkeep
git commit -m "feat: add full Phase 0 Docker Compose stack (postgres, qdrant, vision, composer, ops)"
```

---

## Task 16: E2E Test

**Files:**
- Create: `mras-ops/tests/e2e/test_phase0_e2e.py`
- Create: `mras-ops/tests/e2e/requirements.txt`
- Add manually: `mras-ops/tests/e2e/fixtures/test_face.jpg`

> **Prerequisite:** Full stack running (`docker compose up`). A real single-face JPEG at `tests/e2e/fixtures/test_face.jpg` — use a photo of any person for demo enrollment.

- [ ] **Step 1: Write tests/e2e/requirements.txt**

```
httpx>=0.27.0
pytest>=8.0.0
pytest-asyncio>=0.23.0
```

- [ ] **Step 2: Write tests/e2e/test_phase0_e2e.py**

```python
"""
Phase 0 end-to-end test. Requires docker compose up.

    cd mras-ops
    pip install -r tests/e2e/requirements.txt
    pytest tests/e2e/test_phase0_e2e.py -v -s
"""
import asyncio
import csv
import io
import time
import uuid
from pathlib import Path

import httpx
import pytest

VISION = "http://localhost:8001"
COMPOSER = "http://localhost:8002"
TIMEOUT = 30.0
ASSEMBLE_BUDGET = 8.0
FIXTURE = Path(__file__).parent / "fixtures" / "test_face.jpg"
PERSON_NAME = "E2EPerson"


async def _wait_healthy(http: httpx.AsyncClient) -> None:
    for url in [f"{VISION}/health", f"{COMPOSER}/health"]:
        for _ in range(20):
            try:
                r = await http.get(url, timeout=2.0)
                if r.status_code == 200:
                    break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            pytest.fail(f"Service not healthy: {url}")


async def test_enroll_and_standard_trigger():
    """Enroll a face; fire a new-visitor trigger; verify standard response."""
    assert FIXTURE.exists(), (
        f"Missing test fixture: {FIXTURE}\n"
        "Add a JPEG with a single clear face to tests/e2e/fixtures/test_face.jpg"
    )
    async with httpx.AsyncClient(timeout=TIMEOUT) as http:
        await _wait_healthy(http)

        csv_buf = io.StringIO()
        csv.writer(csv_buf).writerows([["name", "photo"], [PERSON_NAME, "test_face.jpg"]])
        resp = await http.post(
            f"{VISION}/enroll",
            files={
                "csv_file": ("enroll.csv", csv_buf.getvalue().encode(), "text/csv"),
                "photos": ("test_face.jpg", FIXTURE.read_bytes(), "image/jpeg"),
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body.get("enrolled") == 1 or body.get("updated") == 1, body

        resp = await http.post(
            f"{COMPOSER}/trigger",
            json={
                "trigger_id": str(uuid.uuid4()),
                "uuid": None,
                "confidence": 0.0,
                "is_new_visitor": True,
                "scene_context": {},
                "screen_id": "screen_e2e",
            },
        )
        assert resp.status_code == 200
        assert resp.json()["status"] == "standard"


async def test_personalized_trigger_assembles_video_within_budget():
    """Known-UUID trigger → assembled video accessible within ASSEMBLE_BUDGET seconds."""
    assert FIXTURE.exists(), f"Missing fixture: {FIXTURE}"

    async with httpx.AsyncClient(timeout=TIMEOUT) as http:
        await _wait_healthy(http)

        resp = await http.get(f"{VISION}/identity", params={"name": PERSON_NAME})
        if resp.status_code == 404:
            pytest.skip(f"{PERSON_NAME} not enrolled — run test_enroll_and_standard_trigger first")
        person_uuid = resp.json()["uuid"]

        trigger_id = str(uuid.uuid4())
        t0 = time.monotonic()

        resp = await http.post(
            f"{COMPOSER}/trigger",
            json={
                "trigger_id": trigger_id,
                "uuid": person_uuid,
                "confidence": 0.90,
                "is_new_visitor": False,
                "scene_context": {},
                "screen_id": "screen_e2e",
            },
        )
        assert resp.status_code == 200
        result = resp.json()
        elapsed = time.monotonic() - t0

        print(f"\n  status={result['status']}  elapsed={elapsed:.2f}s")

        if result["status"] == "tts_failed":
            pytest.skip("TTS providers unavailable — check ELEVENLABS_API_KEY in .env")

        assert result["status"] == "ok", result

        video_resp = await http.get(f"{COMPOSER}/media/{trigger_id}.mp4", timeout=5.0)
        assert video_resp.status_code == 200, f"Video not found at /media/{trigger_id}.mp4"
        assert elapsed < ASSEMBLE_BUDGET, (
            f"Assembly took {elapsed:.2f}s, budget is {ASSEMBLE_BUDGET}s"
        )
        print(f"  video={len(video_resp.content)} bytes  latency={elapsed:.2f}s ✓")
```

- [ ] **Step 3: Add the fixture photo**

```bash
mkdir -p /Users/jn/code/mras-ops/tests/e2e/fixtures
# Copy a real single-face JPEG:
cp /path/to/photo.jpg /Users/jn/code/mras-ops/tests/e2e/fixtures/test_face.jpg
```

- [ ] **Step 4: Run the E2E tests**

```bash
cd /Users/jn/code/mras-ops
pip install -r tests/e2e/requirements.txt
pytest tests/e2e/test_phase0_e2e.py -v -s
```
Expected:
- `test_enroll_and_standard_trigger` PASSED
- `test_personalized_trigger_assembles_video_within_budget` PASSED (or SKIPPED if TTS keys missing)

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/
git commit -m "test: add Phase 0 E2E (enroll, standard trigger, personalized assembly within budget)"
```

---

## Demo Checklist

Before the first live demo:

- [ ] `mras-ops/assets/standard.mp4` is in place (15-30s loop video)
- [ ] `.env` has real `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID`
- [ ] `docker compose up` succeeds; all three `/health` endpoints return OK
- [ ] mras-display running: `cd /Users/jn/code/mras-display && NODE_ENV=development npm run electron:dev`
- [ ] At least one person enrolled via `POST http://localhost:8001/enroll`
- [ ] E2E test passes end-to-end (`pytest tests/e2e/ -v -s`)
- [ ] Camera visible to mras-vision (set `CAM_INDEX=0` or RTSP URL in compose env)
- [ ] Walk in front of camera → personalized ad appears on kiosk within ~5s

## Known Gaps for Phase 1 (TODOS.md)

| Item | Ref |
|------|-----|
| Qdrant exception handling in detection loop | TODO-6 (P0 critical) |
| Redis-backed cooldown store | TODO-1 |
| P1→P2 burst handling / asyncio queue | TODO-3 |
| Electron kiosk watchdog (launchd / restart policy) | TODO-4 |
| AWS GPU rental profile | TODO-2 |
| Validate ffmpeg software latency <3s empirically | TODO-5 |
| MisoOne API endpoint verification | Task 3 note |
