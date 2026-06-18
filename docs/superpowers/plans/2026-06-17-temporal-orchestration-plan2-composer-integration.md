# Temporal Orchestration — Plan 2: Composer Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the pure `Orchestrator` core (Plan 1) into the running `mras-composer` FastAPI app — map its `Play`/`Idle`/`RenderAhead` commands to real renders + WebSocket sends, feed it identification / presence / clip-ended events, and add the duration watchdog.

**Architecture:** A thin async `OrchestratorRuntime` owns the core plus a render cache and injected I/O deps (`render`, `send_play`, `send_idle`, `arm_watchdog`, `cancel_watchdog`). Every command becomes an I/O action; a `Play` with no cached render idles the display and resumes it when the render lands (the spec's render-gap fallback). Endpoints (`/trigger`, new `/presence`, `/ws` inbound) call core handlers and `await runtime.apply(commands)`.

**Tech Stack:** Python 3.11, FastAPI, asyncio, pytest (`asyncio_mode=auto`), `unittest.mock.AsyncMock`.

**Depends on:** Plan 1 (`src/orchestrator/{model,commands,core}.py`).
**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-17-temporal-display-orchestration-design.md`

---

## File Structure

- Create `src/orchestrator/runtime.py` — `OrchestratorRuntime` (command → I/O mapping + render cache).
- Create `src/orchestrator/renderer.py` — `render_round(owner_uuid, round, db, http, ...) -> list[str]` wrapping the existing `select`/`select_variants` + `synthesize` + `_compose_variant`.
- Modify `main.py` — add `/presence` endpoint + model; parse inbound `clip_ended` on `/ws`; route `/trigger` through the orchestrator; add a periodic `tick` task and watchdog; wire `app.state`.
- Create `tests/test_orchestrator_runtime.py` — runtime apply() tests with fakes.
- Create `tests/test_presence_endpoint.py` — `/presence` + `clip_ended` wiring tests.

All paths relative to `/Users/jn/code/mras-composer`. Tests: `cd /Users/jn/code/mras-composer && python -m pytest <path> -v`.

---

### Task 1: Runtime — RenderAhead caches, Idle sends idle + cancels watchdog

**Files:**
- Create: `src/orchestrator/runtime.py`
- Test: `tests/test_orchestrator_runtime.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_orchestrator_runtime.py
from unittest.mock import AsyncMock, Mock
import pytest

from src.orchestrator.runtime import OrchestratorRuntime
from src.orchestrator.commands import Idle, Play, RenderAhead
from src.orchestrator.model import Round


def _runtime(render=None):
    return OrchestratorRuntime(
        render=render or AsyncMock(return_value=["urlA", "urlB"]),
        send_play=AsyncMock(),
        send_idle=AsyncMock(),
        arm_watchdog=Mock(),
        cancel_watchdog=Mock(),
    )


async def test_render_ahead_populates_cache_without_sending():
    rt = _runtime(render=AsyncMock(return_value=["a", "b"]))
    await rt.apply([RenderAhead("jason", Round.ROUND2)])
    # the render task is in-flight; await it to settle
    await rt.drain()
    assert rt._cache[("jason", Round.ROUND2)] == ["a", "b"]
    rt._send_play.assert_not_awaited()


async def test_idle_sends_idle_and_cancels_watchdog():
    rt = _runtime()
    await rt.apply([Idle("display-1")])
    rt._send_idle.assert_awaited_once_with("display-1")
    rt._cancel_watchdog.assert_called_once_with("display-1")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_runtime.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator.runtime'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/runtime.py
import asyncio

from src.orchestrator.commands import Idle, Play, RenderAhead
from src.orchestrator.model import Round


class OrchestratorRuntime:
    """Maps the pure core's commands to real I/O. Injected deps:
      render(owner, round) -> awaitable[list[str]]  (opener: 1 URL, round2: 2 URLs)
      send_play(display, url, owner, round) -> awaitable
      send_idle(display) -> awaitable
      arm_watchdog(display) / cancel_watchdog(display) -> None
    """

    def __init__(self, render, send_play, send_idle, arm_watchdog, cancel_watchdog):
        self._render = render
        self._send_play = send_play
        self._send_idle = send_idle
        self._arm_watchdog = arm_watchdog
        self._cancel_watchdog = cancel_watchdog
        self._cache: dict[tuple, list] = {}
        self._inflight: dict[tuple, asyncio.Task] = {}
        self._pending: dict[str, tuple] = {}  # display -> (owner, round, slot)

    async def apply(self, commands) -> None:
        for c in commands:
            if isinstance(c, RenderAhead):
                self._ensure_render(c.owner, c.round)
            elif isinstance(c, Idle):
                self._pending.pop(c.display, None)
                self._cancel_watchdog(c.display)
                await self._send_idle(c.display)
            elif isinstance(c, Play):
                await self._play(c)

    def _ensure_render(self, owner, rnd) -> None:
        key = (owner, rnd)
        if key in self._cache or key in self._inflight:
            return

        async def run():
            try:
                self._cache[key] = await self._render(owner, rnd)
                await self._resume_pending(owner, rnd)
            finally:
                self._inflight.pop(key, None)

        self._inflight[key] = asyncio.create_task(run())

    async def _play(self, c: Play) -> None:
        raise NotImplementedError  # Task 2

    async def _resume_pending(self, owner, rnd) -> None:
        raise NotImplementedError  # Task 3

    async def drain(self) -> None:
        """Test/shutdown helper: await all in-flight render tasks."""
        while self._inflight:
            await asyncio.gather(*list(self._inflight.values()))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_runtime.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/runtime.py tests/test_orchestrator_runtime.py
git commit -m "feat(orchestrator): runtime RenderAhead caches, Idle sends idle"
```

---

### Task 2: Runtime — Play from cache sends play + arms watchdog

**Files:**
- Modify: `src/orchestrator/runtime.py`
- Test: `tests/test_orchestrator_runtime.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_runtime.py
async def test_play_with_cached_render_sends_play_and_arms_watchdog():
    rt = _runtime()
    rt._cache[("jason", Round.ROUND2)] = ["urlA", "urlB"]
    await rt.apply([Play("display-3", "jason", Round.ROUND2, 1)])  # slot 1 → urlB
    rt._send_play.assert_awaited_once_with("display-3", "urlB", "jason", Round.ROUND2)
    rt._arm_watchdog.assert_called_once_with("display-3")
    rt._send_idle.assert_not_awaited()


async def test_play_opener_uses_single_cached_url_regardless_of_slot():
    rt = _runtime()
    rt._cache[("jason", Round.OPENER)] = ["opener_url"]
    await rt.apply([Play("display-1", "jason", Round.OPENER, 0)])
    rt._send_play.assert_awaited_once_with("display-1", "opener_url", "jason", Round.OPENER)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_runtime.py -k play_with_cached -v`
Expected: FAIL — `NotImplementedError`

- [ ] **Step 3: Write minimal implementation**

```python
# replace the _play stub in src/orchestrator/runtime.py
    async def _play(self, c: Play) -> None:
        urls = self._cache.get((c.owner, c.round))
        if urls is not None:
            self._pending.pop(c.display, None)
            url = urls[min(c.pair_slot, len(urls) - 1)]
            await self._send_play(c.display, url, c.owner, c.round)
            self._arm_watchdog(c.display)
        else:
            # render-gap: idle now, resume this display when the render lands
            self._pending[c.display] = (c.owner, c.round, c.pair_slot)
            await self._send_idle(c.display)
            self._ensure_render(c.owner, c.round)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_runtime.py -k play -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/runtime.py tests/test_orchestrator_runtime.py
git commit -m "feat(orchestrator): runtime Play from cache sends play + arms watchdog"
```

---

### Task 3: Runtime — Play on cache miss idles, then resumes when render lands

**Files:**
- Modify: `src/orchestrator/runtime.py`
- Test: `tests/test_orchestrator_runtime.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_runtime.py
async def test_play_on_miss_idles_then_resumes_when_render_completes():
    render = AsyncMock(return_value=["renderedA", "renderedB"])
    rt = _runtime(render=render)
    await rt.apply([Play("display-2", "jason", Round.ROUND2, 0)])
    # no cache yet → idle now, render kicked off
    rt._send_idle.assert_awaited_once_with("display-2")
    rt._send_play.assert_not_awaited()
    await rt.drain()  # let the render task finish → it resumes the pending display
    rt._send_play.assert_awaited_once_with("display-2", "renderedA", "jason", Round.ROUND2)
    rt._arm_watchdog.assert_called_once_with("display-2")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_runtime.py -k on_miss -v`
Expected: FAIL — `NotImplementedError` (from `_resume_pending`)

- [ ] **Step 3: Write minimal implementation**

```python
# replace the _resume_pending stub in src/orchestrator/runtime.py
    async def _resume_pending(self, owner, rnd) -> None:
        urls = self._cache[(owner, rnd)]
        for display, (o, r, slot) in list(self._pending.items()):
            if (o, r) == (owner, rnd):
                del self._pending[display]
                await self._send_play(display, urls[min(slot, len(urls) - 1)],
                                      owner, rnd)
                self._arm_watchdog(display)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_runtime.py -v`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/runtime.py tests/test_orchestrator_runtime.py
git commit -m "feat(orchestrator): runtime resumes idled display when render lands"
```

---

### Task 4: Renderer — map (owner, round) to real composed clip URLs

**Files:**
- Create: `src/orchestrator/renderer.py`
- Test: `tests/test_orchestrator_renderer.py`

**Design note:** The renderer reuses the existing pipeline. It builds a minimal trigger dict
`{"uuid": owner, "is_new_visitor": False}` so `select()` / `select_variants()` resolve the
person's name and ads, synthesizes one shared TTS clip, composes the variant(s), and returns the
served `/media/<name>.mp4` URL(s). Opener → `select()` (1 URL); round 2 → `select_variants(count=2)`
(2 URLs, A then B). Compose + TTS + URL-building are injected so the unit test stays fast; the real
wiring is exercised by the Plan 3 live E2E (and may carry the `slow` marker if rendered for real).

- [ ] **Step 1: Write the failing test**

```python
# tests/test_orchestrator_renderer.py
from pathlib import Path
from unittest.mock import AsyncMock, patch

from src.orchestrator.model import Round
from src.orchestrator.renderer import Renderer
from src.selector.selector import AdSelection


def _sel(name="Jason"):
    return AdSelection(type="personalized", base_video=Path("/assets/standard.mp4"),
                       tts_text=f"Welcome, {name}!", person_uuid="jason",
                       overlay_text=name, person_name=name)


async def test_round2_renders_two_variants_in_order():
    db, http = AsyncMock(), AsyncMock()
    compose = AsyncMock(side_effect=[Path("/tmp/x-0.mp4"), Path("/tmp/x-1.mp4")])
    url = lambda p: f"http://c/media/{p.name}"
    r = Renderer(db, http, compose=compose, url_for=url,
                 synthesize=AsyncMock(return_value=Path("/tmp/a.wav")))
    with patch("src.orchestrator.renderer.select_variants",
               AsyncMock(return_value=[_sel(), _sel()])):
        urls = await r.render("jason", Round.ROUND2)
    assert urls == ["http://c/media/x-0.mp4", "http://c/media/x-1.mp4"]
    assert compose.await_count == 2


async def test_opener_renders_single_variant():
    db, http = AsyncMock(), AsyncMock()
    compose = AsyncMock(return_value=Path("/tmp/op.mp4"))
    r = Renderer(db, http, compose=compose, url_for=lambda p: f"u/{p.name}",
                 synthesize=AsyncMock(return_value=Path("/tmp/a.wav")))
    with patch("src.orchestrator.renderer.select", AsyncMock(return_value=_sel())):
        urls = await r.render("jason", Round.OPENER)
    assert urls == ["u/op.mp4"]
    assert compose.await_count == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_renderer.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator.renderer'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/renderer.py
import asyncio
import os

from src.orchestrator.model import Round
from src.selector.selector import select, select_variants

_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "")


class Renderer:
    """Compose the clip URL(s) for one (owner, round). Deps injected for tests;
    main.py wires them to the real compose/synthesize/url helpers."""

    def __init__(self, db, http, compose, url_for, synthesize):
        self._db = db
        self._http = http
        self._compose = compose          # (selection, audio_path, trigger_id, variant_id) -> Path
        self._url_for = url_for          # Path -> str
        self._synthesize = synthesize    # (text, uuid, voice_id, http) -> Path | None

    async def render(self, owner: str, rnd: Round) -> list:
        trigger = {"uuid": owner, "is_new_visitor": False}
        if rnd == Round.OPENER:
            selections = [await select(trigger, self._db)]
        else:
            selections = await select_variants(trigger, self._db, 2)
        audio = await self._synthesize(
            selections[0].tts_text, selections[0].person_uuid, _VOICE_ID, self._http)
        tid = f"orch-{owner}-{int(rnd)}"
        paths = await asyncio.gather(*[
            self._compose(sel, audio, tid, f"{tid}-{i}")
            for i, sel in enumerate(selections)
        ])
        return [self._url_for(p) for p in paths]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_renderer.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/renderer.py tests/test_orchestrator_renderer.py
git commit -m "feat(orchestrator): Renderer maps (owner,round) to composed clip URLs"
```

---

### Task 5: FastAPI wiring — /presence endpoint + inbound clip_ended on /ws

**Files:**
- Modify: `main.py` (add `PresencePayload`, `/presence`, parse inbound WS JSON; wire `app.state.orchestrator` + `app.state.runtime` in `lifespan`)
- Test: `tests/test_presence_endpoint.py`

**Design note:** `lifespan` builds one `Orchestrator(displays=app.state.ws.screen_ids() or [...])`
and an `OrchestratorRuntime`. For v1 there is a single screen-group (`screen_0`). The `/ws` handler,
instead of discarding inbound text (today's `await ws.receive_text()` at `main.py:367-368`), parses
JSON and, on `{"type":"clip_ended","screen_id":"display-N"}`, calls
`orchestrator.on_clip_ended(...)` then `runtime.apply(...)`. The watchdog and the periodic `tick`
task are added in Task 6.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_presence_endpoint.py
from unittest.mock import AsyncMock, Mock
import pytest
from fastapi.testclient import TestClient

import main as composer_main
from src.orchestrator.commands import Play
from src.orchestrator.model import Round


@pytest.fixture
def client_with_fakes(monkeypatch):
    orch = Mock()
    orch.on_presence = Mock(return_value=[Play("display-1", "jason", Round.OPENER, 0)])
    orch.on_clip_ended = Mock(return_value=[])
    runtime = Mock()
    runtime.apply = AsyncMock()
    composer_main.app.state.orchestrator = orch
    composer_main.app.state.runtime = runtime
    return TestClient(composer_main.app), orch, runtime


def test_presence_endpoint_feeds_orchestrator_and_applies(client_with_fakes):
    client, orch, runtime = client_with_fakes
    resp = client.post("/presence", json={
        "screen_id": "screen_0",
        "present": [{"uuid": "jason", "first_seen": "2026-06-17T00:00:00Z"}],
    })
    assert resp.status_code == 200
    orch.on_presence.assert_called_once_with(["jason"])
    runtime.apply.assert_awaited_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_presence_endpoint.py -v`
Expected: FAIL — `404` (no `/presence` route) or AttributeError on `app.state.orchestrator`.

- [ ] **Step 3: Write minimal implementation**

```python
# add near the other Pydantic models in main.py
class PresencePerson(BaseModel):
    uuid: str
    first_seen: str | None = None


class PresencePayload(BaseModel):
    screen_id: str = "screen_0"
    present: list[PresencePerson] = []


# add a new endpoint in main.py
@app.post("/presence")
async def presence_endpoint(body: PresencePayload):
    uuids = [p.uuid for p in body.present]
    cmds = app.state.orchestrator.on_presence(uuids)
    await app.state.runtime.apply(cmds)
    return {"status": "ok", "present": len(uuids)}
```

```python
# replace the /ws receive loop body in main.py (currently `await ws.receive_text()`)
@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await app.state.ws.connect(ws, ws.query_params.get("screen_id"))
    try:
        while True:
            raw = await ws.receive_text()
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if msg.get("type") == "clip_ended" and msg.get("screen_id"):
                cmds = app.state.orchestrator.on_clip_ended(msg["screen_id"])
                await app.state.runtime.apply(cmds)
    except WebSocketDisconnect:
        app.state.ws.disconnect(ws)
```

```python
# in lifespan(), after app.state.ws / app.state.assigner are created, add:
    from src.orchestrator.core import Orchestrator
    from src.orchestrator.runtime import OrchestratorRuntime
    from src.orchestrator.renderer import Renderer
    displays = [f"display-{i}" for i in range(1, int(os.getenv("DISPLAY_COUNT", "4")) + 1)]
    app.state.orchestrator = Orchestrator(displays)
    renderer = Renderer(
        app.state.db, app.state.http,
        compose=lambda sel, audio, tid, vid: _compose_variant(sel, audio, tid, vid),
        url_for=lambda p: f"http://{_HOST}:{_PORT}/media/{p.name}",
        synthesize=synthesize,
    )

    async def _send_play(display, url, owner, rnd):
        await app.state.ws.send_to(display, {"type": "play", "video_url": url, "person": owner})

    async def _send_idle(display):
        await app.state.ws.send_to(display, {"type": "idle"})

    app.state.runtime = OrchestratorRuntime(
        render=renderer.render, send_play=_send_play, send_idle=_send_idle,
        arm_watchdog=lambda d: None, cancel_watchdog=lambda d: None,  # Task 6
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_presence_endpoint.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_presence_endpoint.py
git commit -m "feat(composer): /presence endpoint + inbound clip_ended drive orchestrator"
```

---

### Task 6: Watchdog + periodic tick; route /trigger through the orchestrator

**Files:**
- Modify: `main.py`
- Test: `tests/test_presence_endpoint.py` (clip_ended path), `tests/test_watchdog.py`

**Design note:** The watchdog ensures a display advances even if `clip_ended` never arrives (dropped
WS). When a clip is played, `arm_watchdog(display)` schedules a task that, after
`clip_seconds + grace`, synthesizes a `clip_ended` for that display (same path as the real event).
`cancel_watchdog` cancels it (a real `clip_ended` or `Idle` arrived first). A periodic `tick` task
expires presence TTLs. `/trigger` now calls `orchestrator.on_identify(uuid)` for identified people
(non-standard) instead of the one-shot compose path; the legacy single-broadcast path
(`_trigger_single_broadcast`) stays for the no-screen-id case.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_watchdog.py
import asyncio
from unittest.mock import AsyncMock, Mock
import pytest

from src.orchestrator.watchdog import Watchdog


async def test_watchdog_fires_clip_ended_after_duration():
    on_timeout = AsyncMock()
    wd = Watchdog(on_timeout=on_timeout, grace_s=0.0, clip_seconds=lambda d: 0.01)
    wd.arm("display-1")
    await asyncio.sleep(0.05)
    on_timeout.assert_awaited_once_with("display-1")


async def test_watchdog_cancel_prevents_fire():
    on_timeout = AsyncMock()
    wd = Watchdog(on_timeout=on_timeout, grace_s=0.0, clip_seconds=lambda d: 0.05)
    wd.arm("display-1")
    wd.cancel("display-1")
    await asyncio.sleep(0.1)
    on_timeout.assert_not_awaited()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_watchdog.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator.watchdog'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/watchdog.py
import asyncio


class Watchdog:
    """Per-display timer that fires on_timeout(display) if not cancelled in time.
    clip_seconds(display) gives the expected clip length; grace_s is slack."""

    def __init__(self, on_timeout, clip_seconds, grace_s: float = 2.0):
        self._on_timeout = on_timeout
        self._clip_seconds = clip_seconds
        self._grace = grace_s
        self._timers: dict[str, asyncio.Task] = {}

    def arm(self, display: str) -> None:
        self.cancel(display)

        async def run():
            try:
                await asyncio.sleep(self._clip_seconds(display) + self._grace)
                await self._on_timeout(display)
            except asyncio.CancelledError:
                pass
            finally:
                self._timers.pop(display, None)

        self._timers[display] = asyncio.create_task(run())

    def cancel(self, display: str) -> None:
        t = self._timers.pop(display, None)
        if t is not None:
            t.cancel()
```

```python
# in main.py lifespan: replace the arm/cancel placeholders and start the tick + wire trigger.
# After building runtime, create the watchdog wired to the same clip_ended path:
    async def _fire_clip_ended(display):
        cmds = app.state.orchestrator.on_clip_ended(display)
        await app.state.runtime.apply(cmds)

    watchdog = Watchdog(on_timeout=_fire_clip_ended,
                        clip_seconds=lambda d: float(os.getenv("CLIP_SECONDS", "12")))
    app.state.runtime._arm_watchdog = watchdog.arm      # wire real watchdog
    app.state.runtime._cancel_watchdog = watchdog.cancel

    async def _tick_loop():
        while True:
            await asyncio.sleep(float(os.getenv("PRESENCE_TICK_S", "1.0")))
            await app.state.runtime.apply(app.state.orchestrator.tick())

    app.state.tick_task = asyncio.create_task(_tick_loop())
```
Add `from src.orchestrator.watchdog import Watchdog` to imports, and cancel `app.state.tick_task`
in the lifespan shutdown (after `yield`).

```python
# in trigger_endpoint(), replace the personalized branch so identified people go to the
# orchestrator. Keep the standard gate and the no-screen-id legacy path. After the
# `gate = await select(...)` standard check, replace everything from the `assign(...)` call
# down to the return with:
    cmds = app.state.orchestrator.on_identify(body.uuid)
    await app.state.runtime.apply(cmds)
    await _log(app.state.db, body.trigger_id, "composition", "orchestrated",
               {"uuid": body.uuid})
    return {"status": "orchestrated"}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_watchdog.py tests/test_presence_endpoint.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/watchdog.py main.py tests/test_watchdog.py
git commit -m "feat(composer): watchdog + tick loop; /trigger routes through orchestrator"
```

---

## Plan 2 self-review (run before handing off)

- [ ] Full composer suite green: `python -m pytest -q` (existing tests + new; the legacy
  `_trigger_single_broadcast` no-screen-id path must still pass its tests).
- [ ] Manual reasoning check: a `Play(ROUND2)` after a `RenderAhead(ROUND2)` hits the cache (no
  idle); a `Play(OPENER)` with no prior render idles ~render-time then resumes.
- [ ] `grep -n "assign(" main.py` — confirm the one-shot `DisplayAssigner.assign` personalized path
  is replaced by the orchestrator (the legacy broadcast path is the only remaining direct compose).

## What Plan 2 leaves to Plan 3

- Vision emitting `POST /presence` (currently nothing calls it).
- Kiosk emitting `{"type":"clip_ended",...}` and handling `{"type":"idle"}`.
- Live end-to-end walk-up verification (camera + 4 displays) and the events-table trace.
