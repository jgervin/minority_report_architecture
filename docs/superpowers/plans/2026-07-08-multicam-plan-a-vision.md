# Multi-Camera Plan A: mras-vision runtime (Phases A–C, vision side)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one mras-vision OS process per registry camera row (`CAMERA_ID` env), put the existing frame paths behind the `FramePipeline` seam (Detection / Attention / Standby), and add the `RoleManager` state machine with a Redis detection-duty lease, Redis heartbeats, and journaled `camera_duty` transitions — so a dead ID camera fails over to an eligible watcher within one lease TTL, with no renames, no restarts, no steals, and no auto-failback.

**Architecture:** All new role logic lives in a new `src/roles/` package in `/Users/jn/code/mras-vision`. `main.py`'s lifespan keeps building today's components (embedder, resolver, tracker, analyzers, reporters) exactly as it does now, then hands them to pipelines as prebuilt closures/task-factories — existing code is *moved behind* the `FramePipeline` interface, never rewritten. The decision core (`src/roles/core.py::decide`) is a pure function over a `TickInput` snapshot (no I/O, no clock); `RoleManager` is the async shell that polls the registry, holds/renews/releases the lease, writes heartbeats, swaps pipelines, and journals transitions — with an injectable `clock` and an explicit `tick()` seam (mirroring `mras-composer/src/orchestrator/core.py::Orchestrator(clock=time.monotonic)`), so failover is fully tested with fake clocks + fakeredis, no cameras. The launcher extends the real start mechanism (`mras-ops/run-vision-native.sh`), spawning N processes from `cameras` registry rows.

**Tech Stack:** Python 3.9 (`.venv` is 3.9.6 — every new module MUST start with `from __future__ import annotations`; no `X | Y` unions at runtime), FastAPI lifespan, asyncpg (raw SQL), redis.asyncio, pytest with `asyncio_mode = auto` (root `pytest.ini`), `fakeredis[lua]` (already a dependency, used by `tests/test_cooldown.py`).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-08-multicam-roles-failover-design.md` — all 15 decisions are LOCKED.

> **Orchestrator amendments (2026-07-08, from outside review — BINDING, override any conflicting
> code below):**
> 1. **(C1) Heartbeat TTL must be ≤ the lease TTL, NOT `3 × poll`.** In `RoleManager._heartbeat()`
>    use `ttl = max(1, int(DUTY_LEASE_TTL_SECS))` (refresh cadence unchanged: every tick). With
>    heartbeat EX 30s > lease EX 15s, a crashed primary's lingering heartbeat blocks the watcher's
>    claim guard (`healthy_primary_exists`) for up to 30s — doubling the advertised ≤15s failover.
>    Tie heartbeat TTL to the lease TTL so liveness expires no later than the lease. Add/adjust a
>    fake-clock test: primary dies → watcher claims at ≤ lease TTL, not heartbeat TTL.
> 2. **(I1) Canonical camera id everywhere.** The heartbeat key, the lease holder value, the peer
>    set, and the `camera_duty` journal `payload.camera_id` MUST all use the registry row's
>    canonical `id::text` (from `fetch_camera_row`), NEVER the raw `settings.camera_id` env
>    string. A case/format mismatch silently breaks both the anti-steal guard and God View's
>    `effective_duty` match (Plan B I3/I4). Add a test: env value with uppercase/whitespace still
>    produces canonical keys/payloads.
> 3. **(M4)** `/health` gains additive keys (`camera_id`, `duty`, `state`) — the Phase-B gate is
>    "behavior-identical + additive /health", not literally byte-identical for the endpoint.
>    Nothing in-repo reads past `status` (verified); note it in the task's docstring.
> 4. **(M2, doc-only)** The cooperative handback leaves a ≤ one-tick (~5s) no-holder gap that is
>    steal-safe (the returning primary's heartbeat suppresses other watchers). Document in
>    RoleManager's docstring; no code change.

**Dependency on Plan B (mras-ops):** Plan B delivers migration 027 (`ALTER TYPE camera_role ADD VALUE 'standby'`; `ALTER TABLE cameras ADD COLUMN failover_eligible boolean NOT NULL DEFAULT false`) and `PATCH /cameras/{camera_id}`. This plan CONSUMES both and MUST tolerate their absence: a registry read against a pre-027 schema treats `failover_eligible` as `false` (probe-or-degrade, the TODO-7 I2 idiom — try the full SELECT, catch `asyncpg.exceptions.UndefinedColumnError`, retry without the column). Nothing in this plan requires the PATCH endpoint to exist; role changes can be applied with raw `UPDATE cameras ...` until Plan B ships.

## Global Constraints

Spec decisions binding this plan, **verbatim** (§4):

1. "**One OS process per camera** … Crash isolation per camera, no GIL contention, reuses the entire existing codebase; a launcher manages N processes."
2. "**Each process is identified by `CAMERA_ID`** (uuid of its registry row) via env. `CAM_INDEX` stays the local capture device index. `SCREEN_ID` derives from the registry row (fallback to env for Phase-0 compat)."
3. "**Desired role is read from the Postgres registry** (vision polls its own `cameras` row every `ROLE_POLL_SECS`, default 10s, using the pool it already has). No new config service; the unimplemented `REMOTE_CONFIG_URL` stays unimplemented."
4. "**Failover is a Redis duty lease**, reusing the proven TODO-1 claim idiom: `duty:detection:<scope>` with `SET NX EX` + periodic renewal (`DUTY_LEASE_TTL_SECS`, default 15s; renew at TTL/3). Scope = `screen_group_id` when set, else `system_id`. Exactly one detection duty holder per scope, enforced atomically."
5. "**Duty switching happens in-process, not by restart.** The capture loop is permanent; the frame consumer behind it is swappable. A small `RoleManager` selects which pipeline (`DetectionPipeline` | `AttentionPipeline` | `StandbyPipeline`) consumes frames, via one explicit interface (see §5.2) … pipelines don't know about roles, leases, or each other."
6. "**A camera runs ONE duty at a time.** A watcher acting as ID stops watching (attention metrics from that camera pause and the pause is journaled)."
7. "**No automatic failback (anti-flap).** … the acting camera's RoleManager sees its desired role is not `detection` and *gracefully releases* the lease whenever a camera whose desired role IS `detection` is alive — priority returns to the configured primary **only when it is provably healthy** (heartbeat present), never by stealing."
8. "**Leases are released gracefully, never stolen.** Holders release on: shutdown (SIGTERM drain), desired-role change away from detection, or (b) above. Takeover happens only via lease *expiry* (crash) or *release* (cooperative)."
10. "**Heartbeats live in Redis** (`heartbeat:camera:<camera_id>`, value = effective duty, EX ~3× poll interval) and duty *transitions* are journaled to the append-only `events` table (`event_type='camera_duty'`) … Redis = liveness … Postgres = history."
11. "**Redis down ⇒ failover is disabled, not the cameras.** Each process falls back to desired-role-only operation (registry truth), logs a warning, keeps running. … DB down ⇒ keep last-known role (cached)."
15. "**Compute guardrail**: per-role `FRAME_SAMPLE_RATE` overrides (attention cameras can run lighter); a documented two-camera ceiling on the M3 until TODO-2 (GPU rental) for venues."

Plus repo/process constraints:

- Repos: vision code in `/Users/jn/code/mras-vision` (branch `feat/multicam-vision-runtime` off `main`); launcher scripts in `/Users/jn/code/mras-ops` (branch `feat/multicam-fleet-launcher` off `main`). All git work via the git-flow-manager subagent — never raw git as the main agent.
- Run tests from the vision repo root with the repo's own venv: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/<file> -v`. Root `pytest.ini` sets `asyncio_mode = auto` — plain `async def test_*` functions, no decorators.
- **12-factor tripwire** (`tests/test_no_import_time_env.py` AST-walks `main.py` + `src/`): NO `os.environ`/`os.getenv` outside `src/config.py`. All new env vars (`CAMERA_ID`, `ROLE_POLL_SECS`, `DUTY_LEASE_TTL_SECS`, `FRAME_SAMPLE_RATE_DETECTION`, `FRAME_SAMPLE_RATE_ATTENTION`) are parsed in `load_settings()` only; everything downstream receives plain values.
- **Journal tripwire** (`tests/test_journal.py`): `INSERT INTO events` may exist only in `src/journal.py`. All `camera_duty` events go through `log_journal_event(db, "camera_duty", ...)`.
- **Redis hygiene (owner rule):** every new Redis key carries a TTL — `duty:detection:<scope>` EX `DUTY_LEASE_TTL_SECS` (15), `heartbeat:camera:<id>` EX 3×`ROLE_POLL_SECS` (30). Nothing accumulates.
- **Byte-identical single camera through Phases A–B (spec §6):** with `CAMERA_ID` unset, every task in this plan must leave observable behavior unchanged — same tasks spawned, same `process_frame` path, same sampling, same journal rows. The full existing test suite must stay green after every task.
- Python 3.9 runtime: `from __future__ import annotations` at the top of every new module; `typing.Optional`/`Protocol`, no runtime `|` unions.

## Existing-code → pipeline map (what wraps what, nothing rewritten)

| Pipeline | `on_frame` internals | background tasks owned (`start()`/`stop()`) |
|---|---|---|
| `DetectionPipeline` | `main.process_frame` — `embedder.embed_all` → `tracker.update` → `gather_scene_context` → `resolver.resolve` (cooldown claim + composer trigger) → `bind_uuid`/`add_id_sample` (unchanged, called via closure) | `GazeLogger.run(tracker)`, `AugmentReporter.run(tracker)`, `PresenceReporter.run(tracker)` (same constructor args as today's lifespan) |
| `AttentionPipeline` | new `src/roles/observe.py::observe_frame` — the tracker+gaze subset: `embedder.embed_all` → `tracker.update` → `gather_scene_context` → `debug_view.update`; **no** `resolver.resolve`, no composer, no cooldown burn | `GazeLogger.run(tracker)` only |
| `StandbyPipeline` | no-op | none |

Stays at lifespan level (process-wide, duty-independent): `run_reconciler`, enrollment router, capture loop, heartbeat task, RoleManager.

---

## Phase A — process-per-camera plumbing

### Task 1: Settings — `CAMERA_ID`, poll/lease knobs, per-role sample-rate overrides

**Files:**
- Modify: `/Users/jn/code/mras-vision/src/config.py`
- Modify: `/Users/jn/code/mras-vision/tests/test_config.py`
- Modify: `/Users/jn/code/mras-vision/.env.example`

**Interfaces (later tasks rely on):**
- `Settings.camera_id: Optional[str]` (None ⇒ single-camera Phase-0 mode, everything else in this plan inert)
- `Settings.role_poll_secs: float = 10.0`, `Settings.duty_lease_ttl_secs: int = 15`
- `Settings.frame_sample_rate_detection: Optional[int]`, `Settings.frame_sample_rate_attention: Optional[int]` (None ⇒ fall back to `frame_sample_rate`)

- [ ] **Step 1: Write the failing tests** — append to `/Users/jn/code/mras-vision/tests/test_config.py`:

```python
# --- multi-camera (TODO-8 Plan A) -------------------------------------------

def test_multicam_defaults_are_inert():
    s = load_settings(BASE_ENV)
    assert s.camera_id is None
    assert s.role_poll_secs == 10.0
    assert s.duty_lease_ttl_secs == 15
    assert s.frame_sample_rate_detection is None
    assert s.frame_sample_rate_attention is None


def test_multicam_env_overrides():
    s = load_settings({
        **BASE_ENV,
        "CAMERA_ID": "9b2d7c1e-0000-0000-0000-000000000001",
        "ROLE_POLL_SECS": "2.5",
        "DUTY_LEASE_TTL_SECS": "6",
        "FRAME_SAMPLE_RATE_DETECTION": "5",
        "FRAME_SAMPLE_RATE_ATTENTION": "15",
    })
    assert s.camera_id == "9b2d7c1e-0000-0000-0000-000000000001"
    assert s.role_poll_secs == 2.5
    assert s.duty_lease_ttl_secs == 6
    assert s.frame_sample_rate_detection == 5
    assert s.frame_sample_rate_attention == 15


def test_empty_camera_id_is_none():
    assert load_settings({**BASE_ENV, "CAMERA_ID": ""}).camera_id is None


def test_malformed_lease_ttl_raises():
    with pytest.raises(ConfigError):
        load_settings({**BASE_ENV, "DUTY_LEASE_TTL_SECS": "soon"})


def test_malformed_role_sample_rate_raises():
    with pytest.raises(ConfigError):
        load_settings({**BASE_ENV, "FRAME_SAMPLE_RATE_ATTENTION": "light"})
```

(`import pytest` already exists at the top of the file.)

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_config.py -v`
Expected: the 5 new tests FAIL — `TypeError: __init__() got an unexpected keyword argument 'camera_id'` / `AttributeError: 'Settings' object has no attribute 'camera_id'`.

- [ ] **Step 3: Implement.** In `/Users/jn/code/mras-vision/src/config.py`:

Add to the `Settings` dataclass, after `perception_debug: bool = False`:

```python
    # -- multi-camera (TODO-8) -------------------------------------------------
    camera_id: Optional[str] = None            # uuid of this process's cameras row
    role_poll_secs: float = 10.0               # registry poll cadence (decision 3)
    duty_lease_ttl_secs: int = 15              # detection duty lease TTL (decision 4)
    frame_sample_rate_detection: Optional[int] = None  # None -> frame_sample_rate
    frame_sample_rate_attention: Optional[int] = None  # None -> frame_sample_rate
```

Add the optional-int helper after `_get_float`:

```python
def _get_opt_int(env: Mapping[str, str], key: str) -> Optional[int]:
    raw = env.get(key)
    if raw is None or raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        raise ConfigError(f"{key} must be an int, got '{raw}'")
```

Add to the `Settings(...)` construction in `load_settings`, after `perception_debug=...`:

```python
        camera_id=env.get("CAMERA_ID") or None,
        role_poll_secs=_get_float(env, "ROLE_POLL_SECS", 10.0),
        duty_lease_ttl_secs=_get_int(env, "DUTY_LEASE_TTL_SECS", 15),
        frame_sample_rate_detection=_get_opt_int(env, "FRAME_SAMPLE_RATE_DETECTION"),
        frame_sample_rate_attention=_get_opt_int(env, "FRAME_SAMPLE_RATE_ATTENTION"),
```

Append to `/Users/jn/code/mras-vision/.env.example`:

```bash
# --- multi-camera (TODO-8) ----------------------------------------------------
# CAMERA_ID binds this process to its cameras registry row (uuid). Unset =
# single-camera Phase-0 mode: no registry poll, no roles, no failover.
# CAMERA_ID=
# ROLE_POLL_SECS=10
# DUTY_LEASE_TTL_SECS=15
# Per-role sampling overrides (decision 15). Unset = FRAME_SAMPLE_RATE.
# Values below FRAME_SAMPLE_RATE clamp to it (capture sampling is the floor).
# FRAME_SAMPLE_RATE_DETECTION=5
# FRAME_SAMPLE_RATE_ATTENTION=15
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_config.py tests/test_no_import_time_env.py -v`
Expected: ALL PASS.

- [ ] **Step 5: Commit** — `feat(config): CAMERA_ID + role poll/lease/sample-rate settings (TODO-8 A)`

---

### Task 2: Registry read — `RegistrySnapshot`, pre-027 tolerance, screen_id derivation

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/__init__.py` (empty)
- Create: `/Users/jn/code/mras-vision/src/roles/registry.py`
- Create: `/Users/jn/code/mras-vision/tests/test_role_registry.py`

**Interfaces (later tasks + RoleManager rely on):**
- `RegistrySnapshot(camera_id, camera_role, status, failover_eligible, screen_id, screen_group_id, system_id)` — frozen dataclass; `failover_eligible: bool`; `screen_id`/`screen_group_id` Optional.
- `async fetch_camera_row(db, camera_id: str) -> Optional[RegistrySnapshot]` — `None` on unknown id; `failover_eligible=False` when the column doesn't exist yet (Plan B migration 027 not applied).
- `resolve_screen_id(env_screen_id: str, snapshot: Optional[RegistrySnapshot]) -> str` — registry wins when set (decision 2), env is Phase-0 fallback.
- `apply_registry_identity(settings, snapshot) -> Settings` — pure; returns a new Settings with the derived screen_id.

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_role_registry.py`:

```python
"""Registry-row read for TODO-8 (decisions 2, 3, 9-consumer).

Pre-027 tolerance is the TODO-7 I2 probe-or-degrade idiom: a schema without
failover_eligible must read as eligible=False, never crash."""
from asyncpg.exceptions import UndefinedColumnError

from src.config import load_settings
from src.roles.registry import (
    RegistrySnapshot,
    apply_registry_identity,
    fetch_camera_row,
    resolve_screen_id,
)

CAM = "9b2d7c1e-0000-0000-0000-000000000001"
ROW = {
    "id": CAM, "camera_role": "audience_measurement", "status": "active",
    "failover_eligible": True, "screen_id": "cam_door",
    "screen_group_id": "5555aaaa-0000-0000-0000-000000000002",
    "system_id": "1111bbbb-0000-0000-0000-000000000003",
}


class FakeDb:
    """fetchrow stub: raises UndefinedColumnError when the SQL names a column
    not in `columns`, else returns the row."""

    def __init__(self, row, columns):
        self._row, self._columns = row, set(columns)
        self.queries = []

    async def fetchrow(self, sql, *args):
        self.queries.append(sql)
        if "failover_eligible" in sql and "failover_eligible" not in self._columns:
            raise UndefinedColumnError('column "failover_eligible" does not exist')
        return self._row


async def test_fetch_full_schema_row():
    db = FakeDb(ROW, ROW.keys())
    snap = await fetch_camera_row(db, CAM)
    assert snap == RegistrySnapshot(
        camera_id=CAM, camera_role="audience_measurement", status="active",
        failover_eligible=True, screen_id="cam_door",
        screen_group_id=ROW["screen_group_id"], system_id=ROW["system_id"])


async def test_pre_027_schema_degrades_eligible_to_false():
    cols = set(ROW) - {"failover_eligible"}
    db = FakeDb({k: ROW[k] for k in cols}, cols)
    snap = await fetch_camera_row(db, CAM)
    assert snap.failover_eligible is False          # decision 9 default posture
    assert len(db.queries) == 2                     # probed, then degraded


async def test_unknown_camera_id_returns_none():
    class Empty:
        async def fetchrow(self, sql, *args):
            return None
    assert await fetch_camera_row(Empty(), CAM) is None


def test_registry_screen_id_wins_over_env_default():
    snap = RegistrySnapshot(CAM, "detection", "active", False,
                            "cam_door", None, ROW["system_id"])
    assert resolve_screen_id("screen_0", snap) == "cam_door"


def test_env_screen_id_is_phase0_fallback_when_registry_blank():
    snap = RegistrySnapshot(CAM, "detection", "active", False,
                            None, None, ROW["system_id"])
    assert resolve_screen_id("cam_lobby", snap) == "cam_lobby"
    assert resolve_screen_id("cam_lobby", None) == "cam_lobby"


def test_apply_registry_identity_rewrites_settings_screen_id():
    s = load_settings({"DATABASE_URL": "postgresql://x/y"})
    snap = RegistrySnapshot(CAM, "detection", "active", False,
                            "cam_door", None, ROW["system_id"])
    s2 = apply_registry_identity(s, snap)
    assert s2.device.screen_id == "cam_door"
    assert s2.device.screen_kind == "camera"
    assert s.device.screen_id == "screen_0"   # original untouched (frozen)
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_registry.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/__init__.py` (empty) and `/Users/jn/code/mras-vision/src/roles/registry.py`:

```python
"""Registry-row reads for TODO-8 (decisions 2 & 3): the cameras row is ADMIN
TRUTH for desired role / lifecycle status / failover eligibility. This module
is the only place vision SELECTs from cameras.

Pre-027 tolerance (Plan B dependency): until mras-ops migration 027 lands,
`failover_eligible` doesn't exist — probe the full SELECT, catch
UndefinedColumnError, degrade to eligible=False (TODO-7 I2 idiom).

12-factor #26: no env reads here; camera_id/screen_id are injected.
"""
from __future__ import annotations

import dataclasses
import logging
from dataclasses import dataclass
from typing import Optional

from asyncpg.exceptions import UndefinedColumnError

logger = logging.getLogger(__name__)

_SQL_FULL = """
SELECT id::text AS id, camera_role::text AS camera_role, status::text AS status,
       failover_eligible, screen_id, screen_group_id::text AS screen_group_id,
       system_id::text AS system_id
FROM cameras WHERE id = $1::uuid
"""

_SQL_PRE_027 = """
SELECT id::text AS id, camera_role::text AS camera_role, status::text AS status,
       screen_id, screen_group_id::text AS screen_group_id,
       system_id::text AS system_id
FROM cameras WHERE id = $1::uuid
"""


@dataclass(frozen=True)
class RegistrySnapshot:
    """One cameras row, as read this poll tick. Identity is permanent;
    desired role is admin truth; effective duty is runtime truth (spec §2)."""
    camera_id: str
    camera_role: str            # incl. 'standby' once migration 027 lands
    status: str                 # device_status lifecycle
    failover_eligible: bool     # False when the column is absent (pre-027)
    screen_id: Optional[str]
    screen_group_id: Optional[str]
    system_id: str


async def fetch_camera_row(db, camera_id: str) -> Optional[RegistrySnapshot]:
    try:
        row = await db.fetchrow(_SQL_FULL, camera_id)
        eligible_known = True
    except UndefinedColumnError:
        logger.warning("cameras.failover_eligible missing (pre-027 schema) — "
                       "treating failover_eligible as false")
        row = await db.fetchrow(_SQL_PRE_027, camera_id)
        eligible_known = False
    if row is None:
        return None
    return RegistrySnapshot(
        camera_id=row["id"],
        camera_role=row["camera_role"],
        status=row["status"],
        failover_eligible=bool(row["failover_eligible"]) if eligible_known else False,
        screen_id=row["screen_id"],
        screen_group_id=row["screen_group_id"],
        system_id=row["system_id"],
    )


def resolve_screen_id(env_screen_id: str,
                      snapshot: Optional[RegistrySnapshot]) -> str:
    """SCREEN_ID derives from the registry row; env is Phase-0 compat
    (decision 2). Registry wins when both are set and disagree."""
    if snapshot is not None and snapshot.screen_id:
        if env_screen_id not in ("screen_0", snapshot.screen_id):
            logger.warning("SCREEN_ID env (%s) != registry screen_id (%s) — "
                           "registry wins", env_screen_id, snapshot.screen_id)
        return snapshot.screen_id
    return env_screen_id


def apply_registry_identity(settings, snapshot: Optional[RegistrySnapshot]):
    """Pure: new Settings with the derived screen_id (frozen dataclasses)."""
    screen_id = resolve_screen_id(settings.device.screen_id, snapshot)
    if screen_id == settings.device.screen_id:
        return settings
    return dataclasses.replace(
        settings, device=dataclasses.replace(settings.device, screen_id=screen_id))
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_registry.py -v`
Expected: 6 test functions PASS.

- [ ] **Step 5: Commit** — `feat(roles): registry-row read with pre-027 failover_eligible degrade (TODO-8 A)`

---

### Task 3: lifespan binds `CAMERA_ID` → registry row; per-camera log prefix

**Files:**
- Modify: `/Users/jn/code/mras-vision/main.py`

**Interfaces:** `app.state.registry_row: Optional[RegistrySnapshot]` (consumed by Tasks 8/12); every log line from a CAMERA_ID-bound process is prefixed `[cam:<first-8>]`.

No new unit test (lifespan is untested in this repo — the logic was made pure and tested in Task 2); the gate is the full suite + import check + byte-identical behavior with `CAMERA_ID` unset.

- [ ] **Step 1: Implement.** In `/Users/jn/code/mras-vision/main.py`:

Add import (with the other `src.` imports):

```python
from src.roles.registry import apply_registry_identity, fetch_camera_row
```

In `lifespan`, immediately AFTER `db = await create_pool(settings.database_url)` and BEFORE `qdrant = ...`, insert:

```python
    # TODO-8 Phase A: CAMERA_ID binds this process to its registry row.
    # Unset CAMERA_ID = Phase-0 single-camera mode, nothing changes.
    registry_row = None
    if settings.camera_id:
        registry_row = await fetch_camera_row(db, settings.camera_id)
        if registry_row is None:
            raise RuntimeError(
                f"CAMERA_ID={settings.camera_id} has no cameras registry row")
        settings = apply_registry_identity(settings, registry_row)
        app.state.settings = settings
        prefix = f"[cam:{settings.camera_id[:8]}] "
        for h in logging.getLogger().handlers:
            h.setFormatter(logging.Formatter(
                prefix + "%(levelname)s:%(name)s:%(message)s"))
        logging.getLogger(__name__).info(
            "bound to registry row: role=%s status=%s screen_id=%s",
            registry_row.camera_role, registry_row.status,
            settings.device.screen_id)
    app.state.registry_row = registry_row
```

NOTE: `settings` is rebound BEFORE any consumer of `settings.device.screen_id` (resolver, GazeLogger, AugmentReporter, PresenceReporter, the camera task are all constructed later in lifespan) — verify by reading the function top-to-bottom after editing. The resolver is currently constructed after `http = httpx.AsyncClient()`, which is after the qdrant block — order holds.

- [ ] **Step 2: Verify**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/ -v`
Expected: full suite PASS (byte-identical: the new block no-ops when `camera_id is None`).
Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Commit** — `feat(main): CAMERA_ID registry binding + per-camera log prefix (TODO-8 A)`

---

### Task 4: Fleet launcher — N processes from registry rows (mras-ops repo)

**Files:**
- Modify: `/Users/jn/code/mras-ops/run-vision-native.sh` (parametrize the port)
- Create: `/Users/jn/code/mras-ops/run-vision-fleet.sh`

**Interfaces:** per-camera process env contract: `CAMERA_ID` (row uuid), `CAM_INDEX` (from `calibration->>'cam_index'` — the registry's only link to the local capture device; the admin sets it once: `UPDATE cameras SET calibration = calibration || '{"cam_index": 1}' WHERE id = ...`), `VISION_PORT` (8001, 8011, 8021, …). Documented two-camera ceiling on the M3 (decision 15).

- [ ] **Step 1:** In `/Users/jn/code/mras-ops/run-vision-native.sh`, change the last line from
`exec "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port 8001` to:

```bash
exec "$VENV/bin/uvicorn" main:app --host 0.0.0.0 --port "${VISION_PORT:-8001}"
```

- [ ] **Step 2:** Create `/Users/jn/code/mras-ops/run-vision-fleet.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
# TODO-8 Phase A: one native mras-vision process per ACTIVE cameras registry row.
#
# Each row must carry calibration->>'cam_index' (the local capture device this
# camera is plugged into); rows without it are skipped with a warning.
# Ports: 8001, 8011, 8021, ... macOS camera permission is PER PROCESS and must
# be granted from the owner's terminal on first run (same as today, xN).
#
# COMPUTE GUARDRAIL (spec decision 15): two-camera ceiling on the M3 until
# TODO-2. Use FRAME_SAMPLE_RATE_ATTENTION to run watcher cameras lighter.
set -euo pipefail

OPS_DIR="$(cd "$(dirname "$0")" && pwd)"
DATABASE_URL="${DATABASE_URL:-postgresql://mras:mras@localhost:5432/mras}"

rows="$(psql "$DATABASE_URL" -At -F'|' -c \
  "SELECT id, COALESCE(screen_id,''), COALESCE(calibration->>'cam_index','')
     FROM cameras WHERE status = 'active' ORDER BY created_at")"

if [[ -z "$rows" ]]; then
  echo "no active cameras rows in the registry — nothing to launch" >&2
  exit 1
fi

pids=()
i=0
while IFS='|' read -r cam_id screen_id cam_index; do
  if [[ -z "$cam_index" ]]; then
    echo "SKIP $cam_id (screen_id=${screen_id:-?}): calibration.cam_index not set" >&2
    continue
  fi
  port=$((8001 + 10 * i))
  echo "launching camera $cam_id (screen_id=$screen_id cam_index=$cam_index port=$port)"
  CAMERA_ID="$cam_id" CAM_INDEX="$cam_index" VISION_PORT="$port" \
    "$OPS_DIR/run-vision-native.sh" 2>&1 | sed -u "s/^/[cam:${cam_id:0:8}] /" &
  pids+=($!)
  i=$((i + 1))
done <<< "$rows"

if [[ $i -eq 0 ]]; then
  echo "no launchable rows (every active camera is missing calibration.cam_index)" >&2
  exit 1
fi

trap 'kill ${pids[*]} 2>/dev/null || true' INT TERM
wait
```

- [ ] **Step 3: Verify (headless):** `bash -n /Users/jn/code/mras-ops/run-vision-fleet.sh && bash -n /Users/jn/code/mras-ops/run-vision-native.sh` → no output (syntax ok). `grep -n 'VISION_PORT:-8001' /Users/jn/code/mras-ops/run-vision-native.sh` → 1 hit. With docker postgres up but zero `cam_index` rows: `./run-vision-fleet.sh` prints SKIP lines and exits 1 (no processes started).
- [ ] **Step 4: Commit (mras-ops)** — `feat(ops): vision fleet launcher — one process per registry camera row (TODO-8 A)`

**PHASE A GATE:** full vision suite green; `./run-vision-native.sh` with no new env behaves exactly as before (port 8001, no prefix, no registry read).

---

## Phase B — pipelines behind the seam + heartbeats (still no failover)

### Task 5: The `FramePipeline` seam — protocol, three pipelines, per-role stride

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/pipeline.py`
- Create: `/Users/jn/code/mras-vision/tests/test_pipelines.py`

**Interfaces (RoleManager + main wiring rely on; Plan B does not touch these):**
- `FramePipeline` Protocol: attr `duty: str`; `async start()`, `async on_frame(frame, ts: float)`, `async stop()` (both idempotent).
- `DUTY_DETECTION = "detection"`, `DUTY_ATTENTION = "attention"`, `DUTY_STANDBY = "standby"` (these strings are the heartbeat values).
- `DetectionPipeline(on_frame_impl, task_factories)`, `AttentionPipeline(...)`, `StandbyPipeline()` — thin lifecycle owners over prebuilt closures.
- `duty_for_role(camera_role: Optional[str], status: str = "active") -> str` — the static Phase-B mapping.
- `stride_for(role_rate: Optional[int], base_rate: int) -> int` and `StridedConsumer(pipeline, stride)` with `async on_frame(frame, ts)` (decision 15).

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_pipelines.py`:

```python
"""FramePipeline seam (TODO-8 spec §5.2): pipelines own frame-impl + task
lifecycles and know NOTHING about roles or leases."""
import asyncio

from src.roles.pipeline import (
    DUTY_ATTENTION,
    DUTY_DETECTION,
    DUTY_STANDBY,
    AttentionPipeline,
    DetectionPipeline,
    StandbyPipeline,
    StridedConsumer,
    duty_for_role,
    stride_for,
)


async def test_detection_pipeline_forwards_frames_and_owns_tasks():
    frames, ran = [], asyncio.Event()

    async def impl(frame, ts):
        frames.append((frame, ts))

    async def bg():
        ran.set()
        await asyncio.sleep(3600)

    p = DetectionPipeline(on_frame_impl=impl, task_factories=[bg])
    assert p.duty == DUTY_DETECTION
    await p.start()
    await asyncio.wait_for(ran.wait(), 1.0)
    await p.on_frame("F", 1.5)
    assert frames == [("F", 1.5)]
    await p.stop()
    await asyncio.sleep(0)          # let cancellation land
    await p.stop()                  # idempotent (spec §5.2 MUST)


async def test_stop_cancels_background_tasks():
    cancelled = asyncio.Event()

    async def bg():
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            cancelled.set()
            raise

    p = AttentionPipeline(task_factories=[bg])
    await p.start()
    await asyncio.sleep(0)
    await p.stop()
    await asyncio.wait_for(cancelled.wait(), 1.0)


async def test_start_is_idempotent_no_duplicate_tasks():
    starts = []

    async def bg():
        starts.append(1)
        await asyncio.sleep(3600)

    p = DetectionPipeline(task_factories=[bg])
    await p.start()
    await p.start()
    await asyncio.sleep(0)
    assert starts == [1]
    await p.stop()


async def test_standby_is_a_no_op():
    p = StandbyPipeline()
    assert p.duty == DUTY_STANDBY
    await p.start()
    await p.on_frame("F", 0.0)      # must not raise
    await p.stop()


def test_duty_for_role_static_mapping():
    assert duty_for_role(None) == DUTY_DETECTION            # Phase-0 compat
    assert duty_for_role("detection") == DUTY_DETECTION
    assert duty_for_role("enrollment") == DUTY_DETECTION    # full path today
    assert duty_for_role("audience_measurement") == DUTY_ATTENTION
    assert duty_for_role("standby") == DUTY_STANDBY         # migration 027 value
    assert duty_for_role("security_context") == DUTY_STANDBY  # no pipeline yet
    for status in ("offline", "retired", "inactive"):
        assert duty_for_role("detection", status) == DUTY_STANDBY


def test_stride_for_defaults_are_byte_identical():
    assert stride_for(None, 5) == 1
    assert stride_for(5, 5) == 1
    assert stride_for(3, 5) == 1     # can't go denser than the capture loop
    assert stride_for(15, 5) == 3
    assert stride_for(10, 5) == 2


async def test_strided_consumer_forwards_every_nth_frame():
    seen = []

    async def impl(frame, ts):
        seen.append(frame)

    c = StridedConsumer(DetectionPipeline(on_frame_impl=impl), stride=3)
    for i in range(9):
        await c.on_frame(i, float(i))
    assert seen == [2, 5, 8]
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_pipelines.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.pipeline'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/pipeline.py`:

```python
"""The FramePipeline seam (TODO-8 spec §5.2) — the "no spaghetti" contract.

One camera duty per pipeline. Pipelines are stateless w.r.t. roles/leases —
RoleManager owns those. Existing frame paths are MOVED BEHIND this interface,
not rewritten: main.py builds `on_frame_impl` closures and background-task
factories from the exact constructors it uses today and hands them in.

Growth seam: a future role (e.g. security_context) = one new pipeline class +
one enum value; RoleManager and the other pipelines don't change.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable, List, Optional, Protocol, Sequence

logger = logging.getLogger(__name__)

DUTY_DETECTION = "detection"
DUTY_ATTENTION = "attention"
DUTY_STANDBY = "standby"

_OFFLINE_STATUSES = ("offline", "retired", "inactive")


class FramePipeline(Protocol):
    """One camera duty. start/stop MUST be idempotent."""
    duty: str

    async def start(self) -> None: ...
    async def on_frame(self, frame, ts: float) -> None: ...
    async def stop(self) -> None: ...


class _BasePipeline:
    """Owns the lifecycle of a frame-impl + its background tasks."""
    duty = DUTY_STANDBY

    def __init__(
        self,
        on_frame_impl: Optional[Callable[..., Awaitable[None]]] = None,
        task_factories: Sequence[Callable[[], Awaitable[None]]] = (),
    ) -> None:
        self._impl = on_frame_impl
        self._factories = tuple(task_factories)
        self._tasks: List[asyncio.Task] = []

    async def start(self) -> None:
        if self._tasks:          # idempotent: never double-spawn
            return
        self._tasks = [asyncio.create_task(f()) for f in self._factories]

    async def on_frame(self, frame, ts: float) -> None:
        if self._impl is not None:
            await self._impl(frame, ts)

    async def stop(self) -> None:
        for t in self._tasks:
            t.cancel()
        self._tasks = []


class DetectionPipeline(_BasePipeline):
    """Today's detect→identify→cooldown→trigger path (main.process_frame)
    plus GazeLogger/AugmentReporter/PresenceReporter background tasks."""
    duty = DUTY_DETECTION


class AttentionPipeline(_BasePipeline):
    """tracker+gaze only (src/roles/observe.observe_frame) + GazeLogger.
    Never resolves identities, never triggers ads, never burns cooldowns."""
    duty = DUTY_ATTENTION


class StandbyPipeline(_BasePipeline):
    """No-op consumer: process healthy, heartbeating, doing nothing."""
    duty = DUTY_STANDBY


def duty_for_role(camera_role: Optional[str], status: str = "active") -> str:
    """Static Phase-B mapping: desired role → duty. No lease logic here —
    Phase C's decision core supersedes this for CAMERA_ID processes."""
    if status in _OFFLINE_STATUSES:
        return DUTY_STANDBY
    if camera_role in (None, "detection", "enrollment"):
        return DUTY_DETECTION
    if camera_role == "audience_measurement":
        return DUTY_ATTENTION
    return DUTY_STANDBY      # 'standby' (027) and roles without a pipeline yet


def stride_for(role_rate: Optional[int], base_rate: int) -> int:
    """Per-role FRAME_SAMPLE_RATE override (decision 15) expressed as an extra
    stride on top of the capture loop's base sampling. None → 1 (identical)."""
    if role_rate is None or role_rate <= base_rate:
        return 1
    return max(1, round(role_rate / base_rate))


class StridedConsumer:
    """Forwards every Nth sampled frame to the wrapped pipeline."""

    def __init__(self, pipeline: FramePipeline, stride: int = 1) -> None:
        self.pipeline = pipeline
        self._stride = max(1, stride)
        self._count = 0

    async def on_frame(self, frame, ts: float) -> None:
        self._count += 1
        if self._count % self._stride == 0:
            await self.pipeline.on_frame(frame, ts)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_pipelines.py -v`
Expected: 8 PASS.

- [ ] **Step 5: Commit** — `feat(roles): FramePipeline seam — detection/attention/standby + per-role stride (TODO-8 B)`

---

### Task 6: `observe_frame` — the AttentionPipeline internals

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/observe.py`
- Create: `/Users/jn/code/mras-vision/tests/test_observe.py`

**Interfaces:** `async observe_frame(frame, *, embedder, tracker, analyzers, debug_view, db, screen_id: str) -> None` — the watcher duty's per-frame path.

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_observe.py` (mirrors `tests/test_multiface.py` stub idioms):

```python
"""AttentionPipeline internals: perception spine WITHOUT identity dispatch."""
from unittest.mock import AsyncMock, MagicMock

import numpy as np

from src.roles.observe import observe_frame

FRAME = np.zeros((480, 640, 3), dtype=np.uint8)


def _face(bbox=(10, 10, 50, 50)):
    f = MagicMock()
    f.bbox = bbox
    f.embedding = np.zeros(512, dtype=np.float32)
    return f


def _embedder(faces):
    e = MagicMock()
    e.embed_all = MagicMock(return_value=faces)
    return e


async def test_updates_tracker_and_scene_no_resolver_anywhere():
    tracker = MagicMock()
    tracker.update = MagicMock(return_value=["t1"])
    analyzer = MagicMock()
    analyzer.name = "objects"
    analyzer.analyze = AsyncMock(return_value=[{"label": "cup"}])
    debug_view = MagicMock()

    await observe_frame(FRAME, embedder=_embedder([_face()]), tracker=tracker,
                        analyzers=[analyzer], debug_view=debug_view,
                        db=AsyncMock(), screen_id="cam_door")

    tracker.update.assert_called_once()
    debug_view.update.assert_called_once()
    args = debug_view.update.call_args[0]
    assert args[2] == [{"label": "cup"}]


async def test_no_faces_is_a_fast_no_op():
    tracker = MagicMock()
    await observe_frame(FRAME, embedder=_embedder([]), tracker=tracker,
                        analyzers=[], debug_view=MagicMock(),
                        db=AsyncMock(), screen_id="cam_door")
    tracker.update.assert_not_called()


async def test_tracker_failure_logs_perception_error_and_survives():
    tracker = MagicMock()
    tracker.update = MagicMock(side_effect=RuntimeError("boom"))
    db = AsyncMock()
    await observe_frame(FRAME, embedder=_embedder([_face()]), tracker=tracker,
                        analyzers=[], debug_view=MagicMock(),
                        db=db, screen_id="cam_door")
    assert db.execute.await_count == 1        # the perception/error journal row
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_observe.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.observe'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/observe.py`:

```python
"""AttentionPipeline internals (TODO-8 Phase B, spec §5.2).

The watcher duty runs the perception spine WITHOUT identity dispatch:
embed → track → scene analyzers (attention/mood/objects) → debug view.
Gaze evidence accumulates on tracks exactly as today and is flushed by the
same GazeLogger; the resolver/composer are never touched, so a watcher can't
trigger ads or burn TODO-1 cooldown claims. Same code path as
main.process_frame minus resolve — moved behind the seam, not rewritten.
"""
from __future__ import annotations

from src.perception.aggregator import gather_scene_context
from src.perception.gaze_log import log_perception_error
from src.perception.infer import run_inference


async def observe_frame(frame, *, embedder, tracker, analyzers, debug_view,
                        db, screen_id: str) -> None:
    faces = await run_inference(embedder.embed_all, frame)
    if not faces:
        return
    try:
        tracks = tracker.update(faces)
    except Exception as exc:
        await log_perception_error(db, f"tracker failed: {exc}",
                                   screen_id=screen_id)
        return
    scene = await gather_scene_context(analyzers, frame, tracks)
    debug_view.update(frame, tracks, scene.get("objects", []))
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_observe.py -v`
Expected: 3 PASS.

- [ ] **Step 5: Commit** — `feat(roles): observe_frame — watcher duty perception path (TODO-8 B)`

---

### Task 7: Redis heartbeats

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/heartbeat.py`
- Create: `/Users/jn/code/mras-vision/tests/test_heartbeat.py`

**Interfaces (RoleManager + Plan B/God View rely on the KEY SHAPE):**
- Key `heartbeat:camera:<camera_id>`, value = effective duty string, `EX = 3 × ROLE_POLL_SECS` (decision 10). This exact shape is what a peer checks for "healthy desired-detection camera exists".
- `make_role_redis(redis_url: Optional[str])` → async client or `None` (decision 11 posture, same idiom as `make_cooldown_store`).
- `heartbeat_key(camera_id) -> str`; `async write_heartbeat(redis, camera_id, duty, ttl_secs)`; `async any_alive(redis, camera_ids) -> bool`.

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_heartbeat.py`:

```python
"""Camera heartbeats (decision 10): Redis = liveness, TTL'd, never history."""
from fakeredis import aioredis as fakeaioredis

from src.roles.heartbeat import (
    any_alive,
    heartbeat_key,
    make_role_redis,
    write_heartbeat,
)

CAM_A = "aaaaaaaa-0000-0000-0000-000000000001"
CAM_B = "bbbbbbbb-0000-0000-0000-000000000002"


def test_key_shape_is_the_spec_contract():
    assert heartbeat_key(CAM_A) == f"heartbeat:camera:{CAM_A}"


async def test_heartbeat_carries_duty_and_ttl():
    r = fakeaioredis.FakeRedis()
    await write_heartbeat(r, CAM_A, "detection", ttl_secs=30)
    assert (await r.get(heartbeat_key(CAM_A))) == b"detection"
    ttl = await r.ttl(heartbeat_key(CAM_A))
    assert 0 < ttl <= 30            # owner rule: nothing un-TTL'd


async def test_any_alive_true_only_for_present_heartbeats():
    r = fakeaioredis.FakeRedis()
    assert await any_alive(r, [CAM_A, CAM_B]) is False
    await write_heartbeat(r, CAM_B, "attention", ttl_secs=30)
    assert await any_alive(r, [CAM_A, CAM_B]) is True
    assert await any_alive(r, [CAM_A]) is False
    assert await any_alive(r, []) is False


def test_make_role_redis_none_url_disables_coordination():
    assert make_role_redis(None) is None
    assert make_role_redis("") is None
    assert make_role_redis("redis://localhost:6379/0") is not None
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_heartbeat.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.heartbeat'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/heartbeat.py`:

```python
"""Camera heartbeats (TODO-8 decision 10). Redis = liveness ONLY: value is
the effective duty, EX ~3x the poll interval, so a dead process vanishes
within one heartbeat TTL. History lives in the events journal, never here
(owner rule: nothing accumulates in Redis)."""
from __future__ import annotations

from typing import Iterable, Optional


def heartbeat_key(camera_id: str) -> str:
    return f"heartbeat:camera:{camera_id}"


def make_role_redis(redis_url: Optional[str]):
    """None/empty URL → None: failover coordination disabled, cameras keep
    running on desired role (decision 11). Same idiom as make_cooldown_store."""
    if not redis_url:
        return None
    import redis.asyncio as aioredis

    return aioredis.from_url(redis_url, socket_connect_timeout=1.0,
                             socket_timeout=1.0)


async def write_heartbeat(redis, camera_id: str, duty: str,
                          ttl_secs: int) -> None:
    await redis.set(heartbeat_key(camera_id), duty, ex=ttl_secs)


async def any_alive(redis, camera_ids: Iterable[str]) -> bool:
    keys = [heartbeat_key(c) for c in camera_ids]
    if not keys:
        return False
    return (await redis.exists(*keys)) > 0
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_heartbeat.py -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit** — `feat(roles): Redis camera heartbeats, TTL'd duty liveness (TODO-8 B)`

---

### Task 8: Wire the seam into main.py — static duty from desired role + heartbeat task

**Files:**
- Modify: `/Users/jn/code/mras-vision/main.py`

**Interfaces:** `app.state.duty_provider: Callable[[], str]` (read by `/health`); `/health` gains additive keys `camera_id` and `duty` — `{"status": "ok", "camera_id": null, "duty": "detection"}` for a Phase-0 process (existing consumers only read `status`).

This is the byte-identical-critical refactor: the three background reporters MOVE from bare `asyncio.create_task(...)` calls into `DetectionPipeline.start()` via factories built with the SAME constructor arguments; `process_frame` itself does not move or change (`tests/test_multiface.py` imports `main.process_frame`).

- [ ] **Step 1: Implement.** In `/Users/jn/code/mras-vision/main.py`:

Add imports:

```python
from src.roles.heartbeat import make_role_redis, write_heartbeat
from src.roles.observe import observe_frame
from src.roles.pipeline import (
    DUTY_ATTENTION,
    DUTY_DETECTION,
    DUTY_STANDBY,
    AttentionPipeline,
    DetectionPipeline,
    StandbyPipeline,
    StridedConsumer,
    duty_for_role,
    stride_for,
)
```

Move the two mid-lifespan deferred imports (`from src.identity.augment import GateConfig`, `from src.perception.augment_reporter import AugmentReporter`, `from src.perception.presence import PresenceReporter`) up into the module import block.

In `lifespan`, REPLACE the block from `cam_task = asyncio.create_task(` through the `presence_task = asyncio.create_task(...)` statement (keep `rec_task = asyncio.create_task(run_reconciler(...))` as-is) with:

```python
    # ── TODO-8 Phase B: existing paths behind the FramePipeline seam ─────────
    # Detection duty == today's byte-identical behavior: same process_frame
    # closure, same three background reporters, spawned on pipeline.start().
    async def _detection_impl(frame, ts):
        await process_frame(frame, embedder, resolver, tracker, analyzers,
                            debug_view, db, loop,
                            screen_id=settings.device.screen_id,
                            viewer_min_evidence_s=settings.viewer_min_evidence_s,
                            quality_cfg=quality_cfg)

    async def _attention_impl(frame, ts):
        await observe_frame(frame, embedder=embedder, tracker=tracker,
                            analyzers=analyzers, debug_view=debug_view,
                            db=db, screen_id=settings.device.screen_id)

    def _gaze_factory():
        return GazeLogger(db, settings.device.screen_id,
                          flush_s=settings.gaze_flush_s).run(tracker)

    def _augment_factory():
        return AugmentReporter(
            db, qdrant,
            interval_s=settings.aug_report_s,
            gate=GateConfig(min_conf=settings.aug_min_conf,
                            min_dwell_s=settings.aug_min_dwell_s,
                            min_frames=settings.aug_min_frames),
            screen_id=settings.device.screen_id,
            screen_kind=settings.device.screen_kind,
            collection=settings.qdrant_collection,
            max_redundancy=settings.aug_max_redundancy,
            gallery_cap=settings.aug_gallery_cap,
            model_version=settings.arcface_model_version).run(tracker)

    def _presence_factory():
        return PresenceReporter(
            http,
            screen_id=settings.device.screen_id,
            composer_url=settings.composer_url,
            interval_s=settings.presence_report_s).run(tracker)

    consumers = {
        DUTY_DETECTION: StridedConsumer(
            DetectionPipeline(
                on_frame_impl=_detection_impl,
                task_factories=[_gaze_factory, _augment_factory,
                                _presence_factory]),
            stride_for(settings.frame_sample_rate_detection,
                       settings.frame_sample_rate)),
        DUTY_ATTENTION: StridedConsumer(
            AttentionPipeline(on_frame_impl=_attention_impl,
                              task_factories=[_gaze_factory]),
            stride_for(settings.frame_sample_rate_attention,
                       settings.frame_sample_rate)),
        DUTY_STANDBY: StridedConsumer(StandbyPipeline()),
    }

    # Static duty from desired role (Phase B — no lease yet, spec §6).
    duty = duty_for_role(registry_row.camera_role if registry_row else None,
                         registry_row.status if registry_row else "active")
    active = consumers[duty]
    await active.pipeline.start()
    app.state.duty_provider = lambda: active.pipeline.duty

    async def _consume(frame):
        try:
            await active.on_frame(frame, time.monotonic())
        except Exception:
            pass  # no face or embed error — skip frame (today's posture)

    cam_task = asyncio.create_task(
        run_capture_loop(_consume, cam_index=settings.cam_index,
                         sample_rate=settings.frame_sample_rate))

    # Heartbeat (decision 10): only a CAMERA_ID-bound process announces duty.
    role_redis = make_role_redis(settings.redis_url) if settings.camera_id else None
    hb_task = None
    if role_redis is not None:
        async def _heartbeat_loop():
            ttl = max(1, int(3 * settings.role_poll_secs))
            while True:
                try:
                    await write_heartbeat(role_redis, settings.camera_id,
                                          app.state.duty_provider(), ttl)
                except Exception as exc:
                    logging.getLogger(__name__).warning(
                        "heartbeat write failed (%s) — continuing", exc)
                await asyncio.sleep(settings.role_poll_secs)

        hb_task = asyncio.create_task(_heartbeat_loop())
```

Update the shutdown block after `yield` — replace the five `*.cancel()` lines with:

```python
    cam_task.cancel()
    rec_task.cancel()
    if hb_task is not None:
        hb_task.cancel()
    await active.pipeline.stop()   # cancels gaze/augment/presence tasks
```

Delete the now-unused `_camera_pipeline` function. `process_frame` stays in `main.py` untouched.

Replace the `/health` handler:

```python
@app.get("/health")
def health():
    duty = getattr(app.state, "duty_provider", None)
    settings = getattr(app.state, "settings", None)
    return {"status": "ok",
            "camera_id": getattr(settings, "camera_id", None),
            "duty": duty() if duty else DUTY_DETECTION}
```

- [ ] **Step 2: Verify byte-identical + green**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/ -v`
Expected: full suite PASS (notably `test_multiface.py`, `test_journal.py`, `test_no_import_time_env.py`).
Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"` → `ok`.
Manual review checklist (byte-identical): with `CAMERA_ID` unset → `registry_row is None` → `duty == DUTY_DETECTION`, stride 1, same three reporters constructed with identical arguments, `process_frame` called with identical arguments, no Redis client created, `/health` still returns `"status": "ok"`.

- [ ] **Step 3: Commit** — `refactor(main): frame paths behind the FramePipeline seam; static duty + heartbeats (TODO-8 B)`

**PHASE B GATE:** full suite green; single camera byte-identical (spec §6). Failover does not exist yet.

---

## Phase C — duty lease + RoleManager failover

### Task 9: `DutyLease` — SET NX EX claim, holder-checked renew/release, never stolen

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/lease.py`
- Create: `/Users/jn/code/mras-vision/tests/test_duty_lease.py`

**Interfaces (RoleManager relies on; Plan B/God View rely on the KEY SHAPE):**
- Key `duty:detection:<scope>` where `scope = screen_group_id or system_id` (decision 4); helpers `lease_scope(screen_group_id, system_id) -> str`, `lease_key(scope) -> str`.
- `DutyLease(redis, scope, holder, ttl_secs=15)` with `async try_claim() -> bool`, `async renew() -> bool` (False = lease lost/not ours), `async release() -> bool`, `async is_free() -> bool`, `async holder() -> Optional[str]`. Redis errors PROPAGATE (RoleManager owns the degrade decision).

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_duty_lease.py`:

```python
"""Detection duty lease (decisions 4, 7, 8) — the TODO-1 claim idiom.
fakeredis[lua] runs the holder-checked renew/release scripts for real."""
import asyncio

from fakeredis import aioredis as fakeaioredis

from src.roles.lease import DutyLease, lease_key, lease_scope

SCOPE = "5555aaaa-0000-0000-0000-000000000002"
CAM_A = "aaaaaaaa-0000-0000-0000-000000000001"
CAM_B = "bbbbbbbb-0000-0000-0000-000000000002"


def test_scope_prefers_screen_group_then_system():
    assert lease_scope("group-1", "sys-1") == "group-1"
    assert lease_scope(None, "sys-1") == "sys-1"
    assert lease_key("sys-1") == "duty:detection:sys-1"


async def test_exactly_one_claimant_wins():
    r = fakeaioredis.FakeRedis()
    a = DutyLease(r, SCOPE, CAM_A)
    b = DutyLease(r, SCOPE, CAM_B)
    assert await a.try_claim() is True
    assert await b.try_claim() is False        # held → no steal
    assert await a.holder() == CAM_A
    assert await a.is_free() is False


async def test_lease_key_carries_the_ttl():
    r = fakeaioredis.FakeRedis()
    await DutyLease(r, SCOPE, CAM_A, ttl_secs=15).try_claim()
    ttl = await r.ttl(lease_key(SCOPE))
    assert 0 < ttl <= 15                        # owner rule: TTL'd


async def test_renew_only_by_the_holder():
    r = fakeaioredis.FakeRedis()
    a = DutyLease(r, SCOPE, CAM_A, ttl_secs=15)
    b = DutyLease(r, SCOPE, CAM_B, ttl_secs=15)
    await a.try_claim()
    assert await a.renew() is True
    assert await b.renew() is False             # can't renew a lease you lost
    assert await a.holder() == CAM_A


async def test_release_only_by_the_holder_then_claimable():
    r = fakeaioredis.FakeRedis()
    a = DutyLease(r, SCOPE, CAM_A)
    b = DutyLease(r, SCOPE, CAM_B)
    await a.try_claim()
    assert await b.release() is False           # non-holder release is a no-op
    assert await a.is_free() is False
    assert await a.release() is True            # graceful (decision 8)
    assert await b.try_claim() is True          # cooperative takeover


async def test_expiry_means_takeover_without_stealing():
    r = fakeaioredis.FakeRedis()
    a = DutyLease(r, SCOPE, CAM_A, ttl_secs=1)
    b = DutyLease(r, SCOPE, CAM_B, ttl_secs=1)
    await a.try_claim()
    assert await b.try_claim() is False
    await asyncio.sleep(1.1)                    # crash simulation: TTL lapse
    assert await b.try_claim() is True
    assert await b.holder() == CAM_B
    assert await a.renew() is False             # the returned primary lost it
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_duty_lease.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.lease'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/lease.py`:

```python
"""Detection duty lease (TODO-8 decisions 4, 7, 8) — reuses the proven TODO-1
atomic-claim idiom (src/identity/cooldown.py).

Claim = SET NX EX (exactly one winner per scope, TTL lands with the key).
Renew/release are holder-checked Lua so a process can never renew or delete a
lease it no longer holds. NEVER stolen: takeover happens only via expiry
(crash) or release (cooperative). Redis errors propagate — RoleManager owns
the decision-11 degrade (desired-role-only), this module stays dumb."""
from __future__ import annotations

from typing import Optional

_RENEW_LUA = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
  return 1
end
return 0
"""

_RELEASE_LUA = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
  redis.call('DEL', KEYS[1])
  return 1
end
return 0
"""


def lease_scope(screen_group_id: Optional[str], system_id: str) -> str:
    """Scope = screen_group_id when set, else system_id (decision 4)."""
    return screen_group_id or system_id


def lease_key(scope: str) -> str:
    return f"duty:detection:{scope}"


class DutyLease:
    def __init__(self, redis, scope: str, holder: str,
                 ttl_secs: int = 15) -> None:
        self._redis = redis
        self._key = lease_key(scope)
        self._holder = holder
        self._ttl = ttl_secs

    async def try_claim(self) -> bool:
        return bool(await self._redis.set(
            self._key, self._holder, nx=True, ex=self._ttl))

    async def renew(self) -> bool:
        """True while we still hold it; False = lost (expired + reclaimed)."""
        return bool(await self._redis.eval(
            _RENEW_LUA, 1, self._key, self._holder, self._ttl))

    async def release(self) -> bool:
        return bool(await self._redis.eval(
            _RELEASE_LUA, 1, self._key, self._holder))

    async def is_free(self) -> bool:
        return (await self._redis.exists(self._key)) == 0

    async def holder(self) -> Optional[str]:
        raw = await self._redis.get(self._key)
        if raw is None:
            return None
        return raw.decode() if isinstance(raw, bytes) else raw
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_duty_lease.py -v`
Expected: 6 PASS.

- [ ] **Step 5: Commit** — `feat(roles): duty:detection lease — SET NX EX + holder-checked renew/release (TODO-8 C)`

---

### Task 10: The pure decision core — spec §5.3 state machine

**Files:**
- Create: `/Users/jn/code/mras-vision/src/roles/core.py`
- Create: `/Users/jn/code/mras-vision/tests/test_role_core.py`

**Interfaces (RoleManager executes exactly this):**
- `RoleState` str-Enum: `STANDBY, WATCHING, PRIMARY_ID, ACTING_ID, IDLE_OFFLINE` (values `"standby"`, `"watching"`, `"primary_id"`, `"acting_id"`, `"idle_offline"` — these strings appear in `camera_duty` journal payloads and God View).
- `TickInput(desired_role, lifecycle_status, failover_eligible, holds_lease, lease_free, healthy_primary_exists, redis_ok)` — frozen; a complete observation, gathered by RoleManager each tick.
- `Decision(state, duty, claim=False, release=False)` — frozen; `duty` is one of the Task-5 constants; `claim`/`release` are the ONLY lease side-effects the shell may perform.
- `decide(prev: RoleState, inp: TickInput) -> Decision` — pure, clockless (all timing lives in the shell; that is what makes fake-clock testing trivial).
- Claim protocol: `decide` returns `claim=True` with the pessimistic state; the shell attempts the claim and on success calls `decide` again with `holds_lease=True, lease_free=False` — two pure evaluations, no hidden state.

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_role_core.py`:

```python
"""Spec §5.3 state machine, table-driven and pure — no I/O, no clock."""
import dataclasses

from src.roles.core import Decision, RoleState, TickInput, decide
from src.roles.pipeline import DUTY_ATTENTION, DUTY_DETECTION, DUTY_STANDBY

BASE = TickInput(desired_role="detection", lifecycle_status="active",
                 failover_eligible=False, holds_lease=False, lease_free=True,
                 healthy_primary_exists=False, redis_ok=True)


def _inp(**kw):
    return dataclasses.replace(BASE, **kw)


# desired detection ----------------------------------------------------------

def test_desired_detection_lease_free_attempts_claim():
    d = decide(RoleState.STANDBY, _inp())
    assert d == Decision(RoleState.STANDBY, DUTY_STANDBY, claim=True)


def test_desired_detection_claim_won_is_primary():
    d = decide(RoleState.STANDBY, _inp(holds_lease=True, lease_free=False))
    assert d == Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)


def test_returned_primary_finds_lease_held_enters_standby_no_steal():
    # decision 7: no automatic failback; retry claim only when free
    d = decide(RoleState.STANDBY, _inp(lease_free=False))
    assert d == Decision(RoleState.STANDBY, DUTY_STANDBY)
    assert d.claim is False


# desired audience_measurement ------------------------------------------------

def test_watcher_default_is_watching():
    d = decide(RoleState.STANDBY, _inp(desired_role="audience_measurement",
                                       healthy_primary_exists=True,
                                       lease_free=False))
    assert d == Decision(RoleState.WATCHING, DUTY_ATTENTION)


def test_eligible_watcher_claims_when_lease_free_and_no_healthy_primary():
    d = decide(RoleState.WATCHING, _inp(desired_role="audience_measurement",
                                        failover_eligible=True))
    assert d.claim is True and d.duty == DUTY_ATTENTION   # pessimistic until won


def test_eligible_watcher_becomes_acting_id_after_winning():
    d = decide(RoleState.WATCHING, _inp(desired_role="audience_measurement",
                                        failover_eligible=True,
                                        holds_lease=True, lease_free=False))
    assert d == Decision(RoleState.ACTING_ID, DUTY_DETECTION)


def test_ineligible_watcher_never_claims():
    d = decide(RoleState.WATCHING, _inp(desired_role="audience_measurement"))
    assert d.claim is False and d.state == RoleState.WATCHING


def test_watcher_does_not_claim_while_healthy_primary_exists():
    d = decide(RoleState.WATCHING, _inp(desired_role="audience_measurement",
                                        failover_eligible=True,
                                        healthy_primary_exists=True))
    assert d.claim is False


def test_acting_id_hands_back_when_healthy_primary_reappears():
    # decision 7b: cooperative handback, never a steal
    d = decide(RoleState.ACTING_ID, _inp(desired_role="audience_measurement",
                                         failover_eligible=True,
                                         holds_lease=True, lease_free=False,
                                         healthy_primary_exists=True))
    assert d == Decision(RoleState.WATCHING, DUTY_ATTENTION, release=True)


def test_acting_id_keeps_duty_while_primary_still_dead():
    d = decide(RoleState.ACTING_ID, _inp(desired_role="audience_measurement",
                                         failover_eligible=True,
                                         holds_lease=True, lease_free=False))
    assert d == Decision(RoleState.ACTING_ID, DUTY_DETECTION)


# role changed away from detection while holding (decision 8) -----------------

def test_holder_releases_when_desired_role_moves_to_standby():
    d = decide(RoleState.PRIMARY_ID, _inp(desired_role="standby",
                                          holds_lease=True, lease_free=False))
    assert d == Decision(RoleState.STANDBY, DUTY_STANDBY, release=True)


# lifecycle (decision 12 consumer) --------------------------------------------

def test_lifecycle_offline_parks_and_releases():
    for status in ("offline", "retired", "inactive"):
        d = decide(RoleState.PRIMARY_ID, _inp(lifecycle_status=status,
                                              holds_lease=True,
                                              lease_free=False))
        assert d == Decision(RoleState.IDLE_OFFLINE, DUTY_STANDBY, release=True)


# Redis down (decision 11) -----------------------------------------------------

def test_redis_down_pins_to_desired_role_no_lease_ops():
    d = decide(RoleState.STANDBY, _inp(redis_ok=False))
    assert d == Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)
    d = decide(RoleState.ACTING_ID, _inp(desired_role="audience_measurement",
                                         redis_ok=False))
    assert d == Decision(RoleState.WATCHING, DUTY_ATTENTION)
    d = decide(RoleState.STANDBY, _inp(desired_role="standby", redis_ok=False))
    assert d == Decision(RoleState.STANDBY, DUTY_STANDBY)
    assert d.claim is False and d.release is False


# unknown/parked roles ---------------------------------------------------------

def test_standby_and_security_context_idle_without_claiming():
    for role in ("standby", "security_context"):
        d = decide(RoleState.STANDBY, _inp(desired_role=role))
        assert d == Decision(RoleState.STANDBY, DUTY_STANDBY)


def test_enrollment_keeps_full_detection_path_without_lease():
    d = decide(RoleState.STANDBY, _inp(desired_role="enrollment"))
    assert d == Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)
    assert d.claim is False
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_core.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.core'`.

- [ ] **Step 3: Implement.** Create `/Users/jn/code/mras-vision/src/roles/core.py`:

```python
"""Pure failover decision core (TODO-8 spec §5.3).

`decide` is a pure function over one tick's complete observation — no I/O,
no clock, no hidden state (mirrors mras-composer's Orchestrator purity; the
shell owns timing). RoleManager gathers TickInput, executes the returned
claim/release, and on a won claim re-decides with holds_lease=True.

Invariants encoded here:
 - never steal: claim only when the lease is observably FREE;
 - no auto-failback: a returned primary waits for expiry/release (dec. 7);
 - cooperative handback: ACTING_ID releases the moment a healthy
   desired-detection heartbeat exists (dec. 7b);
 - graceful release on lifecycle-park or role change away (dec. 8, 12);
 - Redis down => desired-role pinning, zero lease ops (dec. 11).
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from src.roles.pipeline import DUTY_ATTENTION, DUTY_DETECTION, DUTY_STANDBY

_OFFLINE = ("offline", "retired", "inactive")
# enrollment keeps today's full detect->identify path (Phase-B parity);
# it does NOT participate in the detection duty lease.
_DETECTION_LIKE_NO_LEASE = ("enrollment",)


class RoleState(str, Enum):
    STANDBY = "standby"
    WATCHING = "watching"
    PRIMARY_ID = "primary_id"
    ACTING_ID = "acting_id"
    IDLE_OFFLINE = "idle_offline"


@dataclass(frozen=True)
class TickInput:
    desired_role: str            # cameras.camera_role (admin truth)
    lifecycle_status: str        # cameras.status
    failover_eligible: bool      # False pre-migration-027
    holds_lease: bool            # our holder-checked renew succeeded
    lease_free: bool             # duty key absent in Redis
    healthy_primary_exists: bool # a desired-detection peer heartbeat is alive
    redis_ok: bool               # False => decision-11 degrade


@dataclass(frozen=True)
class Decision:
    state: RoleState
    duty: str                    # DUTY_DETECTION | DUTY_ATTENTION | DUTY_STANDBY
    claim: bool = False          # shell should attempt try_claim() now
    release: bool = False        # shell should release() now


def decide(prev: RoleState, inp: TickInput) -> Decision:
    if inp.lifecycle_status in _OFFLINE:
        return Decision(RoleState.IDLE_OFFLINE, DUTY_STANDBY,
                        release=inp.holds_lease and inp.redis_ok)

    if not inp.redis_ok:
        # Decision 11: failover disabled, not the camera. Desired role only.
        if inp.desired_role in ("detection",) + _DETECTION_LIKE_NO_LEASE:
            return Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)
        if inp.desired_role == "audience_measurement":
            return Decision(RoleState.WATCHING, DUTY_ATTENTION)
        return Decision(RoleState.STANDBY, DUTY_STANDBY)

    if inp.desired_role in _DETECTION_LIKE_NO_LEASE:
        return Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)

    if inp.desired_role == "detection":
        if inp.holds_lease:
            return Decision(RoleState.PRIMARY_ID, DUTY_DETECTION)
        if inp.lease_free:
            # Pessimistic until the atomic claim is actually won.
            return Decision(RoleState.STANDBY, DUTY_STANDBY, claim=True)
        # Held by someone else (e.g. the actor after our crash): decision 7 —
        # no steal, no auto-failback; park and retry when it frees.
        return Decision(RoleState.STANDBY, DUTY_STANDBY)

    if inp.desired_role == "audience_measurement":
        if inp.holds_lease:
            if inp.healthy_primary_exists:
                # Decision 7b: cooperative handback to the healthy primary.
                return Decision(RoleState.WATCHING, DUTY_ATTENTION,
                                release=True)
            return Decision(RoleState.ACTING_ID, DUTY_DETECTION)
        if (inp.failover_eligible and inp.lease_free
                and not inp.healthy_primary_exists):
            return Decision(RoleState.WATCHING, DUTY_ATTENTION, claim=True)
        return Decision(RoleState.WATCHING, DUTY_ATTENTION)

    # 'standby' (027), 'security_context' (no pipeline yet), anything unknown.
    if inp.holds_lease:
        # Desired role moved away from detection while holding: decision 8.
        return Decision(RoleState.STANDBY, DUTY_STANDBY, release=True)
    return Decision(RoleState.STANDBY, DUTY_STANDBY)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_core.py -v`
Expected: 15 PASS.

- [ ] **Step 5: Commit** — `feat(roles): pure spec-§5.3 decision core (TODO-8 C)`

---

### Task 11: `RoleManager` — the async shell (tick/run/shutdown, journaling, degrade)

**Files:**
- Modify: `/Users/jn/code/mras-vision/src/roles/registry.py` (add `fetch_detection_peers`)
- Create: `/Users/jn/code/mras-vision/src/roles/manager.py`
- Create: `/Users/jn/code/mras-vision/tests/test_role_manager.py`

**Interfaces (main.py Task 12 + live ops rely on):**
- `async fetch_detection_peers(db, snapshot: RegistrySnapshot) -> list[str]` — ids of OTHER active cameras with `camera_role='detection'` in the same scope (`screen_group_id` match when set, else `system_id` match with NULL group).
- `RoleManager(*, camera_id, screen_id, db, redis, consumers, initial_snapshot, poll_secs=10.0, lease_ttl_secs=15, clock=time.monotonic, journal=log_journal_event, fetch_row=fetch_camera_row, fetch_peers=fetch_detection_peers, sleep=asyncio.sleep)` — every collaborator injectable; `redis` may be `None` (permanent decision-11 degrade).
- `manager.duty -> str`, `manager.state -> RoleState`, `async on_frame(frame, ts)` (routes to the active StridedConsumer), `async start()`, `async tick()` (ONE evaluation — the test seam), `async run()` (loop: tick every `min(poll_secs, lease_ttl/3)` so renewal cadence ≤ TTL/3; registry re-read gated to `poll_secs` via `clock`), `async shutdown()` (graceful release + journal + pipeline stop — SIGTERM drain, decision 8).
- Journal contract (decision 10): `log_journal_event(db, "camera_duty", "success", {"camera_id", "from", "to", "reason", "lease_scope"}, screen_id=...)` on EVERY state transition; reasons: `"claimed_lease" | "released_lease" | "lifecycle" | "redis_down" | "poll" | "shutdown"`.

- [ ] **Step 1: Write the failing tests** — create `/Users/jn/code/mras-vision/tests/test_role_manager.py`:

```python
"""RoleManager failover, tested with fake clock + fakeredis + stub pipelines —
no cameras, no Postgres, no real time (spec §5.3 scenarios end-to-end)."""
from unittest.mock import AsyncMock

from fakeredis import aioredis as fakeaioredis

from src.roles.core import RoleState
from src.roles.heartbeat import heartbeat_key, write_heartbeat
from src.roles.lease import DutyLease, lease_key
from src.roles.manager import RoleManager
from src.roles.pipeline import (
    DUTY_ATTENTION,
    DUTY_DETECTION,
    DUTY_STANDBY,
    StridedConsumer,
)
from src.roles.registry import RegistrySnapshot

CAM_A = "aaaaaaaa-0000-0000-0000-000000000001"   # configured primary
CAM_B = "bbbbbbbb-0000-0000-0000-000000000002"   # eligible watcher
SCOPE = "5555aaaa-0000-0000-0000-000000000002"   # screen_group_id
SYS = "1111bbbb-0000-0000-0000-000000000003"


def snap(cam, role, status="active", eligible=False):
    return RegistrySnapshot(camera_id=cam, camera_role=role, status=status,
                            failover_eligible=eligible, screen_id="cam_x",
                            screen_group_id=SCOPE, system_id=SYS)


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class StubPipe:
    def __init__(self, duty):
        self.duty = duty
        self.started = 0
        self.stopped = 0

    async def start(self):
        self.started += 1

    async def on_frame(self, frame, ts):
        pass

    async def stop(self):
        self.stopped += 1


def consumers():
    return {d: StridedConsumer(StubPipe(d))
            for d in (DUTY_DETECTION, DUTY_ATTENTION, DUTY_STANDBY)}


def manager(redis, snapshot, peers, journal=None):
    row = {"value": snapshot}
    peer_ids = {"value": list(peers)}

    async def fetch_row(db, camera_id):
        return row["value"]

    async def fetch_peers(db, s):
        return peer_ids["value"]

    clock = FakeClock()
    m = RoleManager(
        camera_id=snapshot.camera_id, screen_id="cam_x", db=AsyncMock(),
        redis=redis, consumers=consumers(), initial_snapshot=snapshot,
        poll_secs=10.0, lease_ttl_secs=15, clock=clock,
        journal=journal or AsyncMock(),
        fetch_row=fetch_row, fetch_peers=fetch_peers)
    return m, row, clock


async def test_primary_claims_and_runs_detection():
    r = fakeaioredis.FakeRedis()
    journal = AsyncMock()
    m, _, _ = manager(r, snap(CAM_A, "detection"), [], journal)
    await m.start()
    await m.tick()
    assert m.state == RoleState.PRIMARY_ID
    assert m.duty == DUTY_DETECTION
    assert (await r.get(lease_key(SCOPE))) == CAM_A.encode()
    assert (await r.get(heartbeat_key(CAM_A))) == b"detection"
    calls = [c for c in journal.await_args_list if c.args[1] == "camera_duty"]
    assert calls, "camera_duty transition must be journaled"
    payload = calls[-1].args[3]
    assert payload["to"] == "primary_id" and payload["lease_scope"] == SCOPE
    assert payload["reason"] == "claimed_lease"


async def test_watcher_watches_while_primary_healthy_never_claims():
    r = fakeaioredis.FakeRedis()
    await DutyLease(r, SCOPE, CAM_A).try_claim()
    await write_heartbeat(r, CAM_A, "detection", 30)
    m, _, _ = manager(r, snap(CAM_B, "audience_measurement",
                              eligible=True), [CAM_A])
    await m.start()
    await m.tick()
    assert m.state == RoleState.WATCHING and m.duty == DUTY_ATTENTION
    assert (await r.get(lease_key(SCOPE))) == CAM_A.encode()   # untouched


async def test_crash_failover_watcher_becomes_acting_id():
    r = fakeaioredis.FakeRedis()
    m, _, _ = manager(r, snap(CAM_B, "audience_measurement",
                              eligible=True), [CAM_A])
    await m.start()
    # primary dead: no lease key, no heartbeat (TTL lapsed)
    await m.tick()
    assert m.state == RoleState.ACTING_ID
    assert m.duty == DUTY_DETECTION
    assert (await r.get(lease_key(SCOPE))) == CAM_B.encode()


async def test_acting_id_hands_back_when_primary_heartbeat_returns():
    r = fakeaioredis.FakeRedis()
    journal = AsyncMock()
    m, _, _ = manager(r, snap(CAM_B, "audience_measurement",
                              eligible=True), [CAM_A], journal)
    await m.start()
    await m.tick()
    assert m.state == RoleState.ACTING_ID
    await write_heartbeat(r, CAM_A, "standby", 30)   # primary process is back
    await m.tick()
    assert m.state == RoleState.WATCHING and m.duty == DUTY_ATTENTION
    assert await DutyLease(r, SCOPE, CAM_B).is_free() is True   # released
    reasons = [c.args[3]["reason"] for c in journal.await_args_list
               if c.args[1] == "camera_duty"]
    assert "released_lease" in reasons


async def test_ineligible_watcher_never_acts():
    r = fakeaioredis.FakeRedis()
    m, _, _ = manager(r, snap(CAM_B, "audience_measurement",
                              eligible=False), [CAM_A])
    await m.start()
    await m.tick()
    assert m.state == RoleState.WATCHING
    assert await DutyLease(r, SCOPE, CAM_B).is_free() is True


async def test_role_change_away_releases_gracefully():
    r = fakeaioredis.FakeRedis()
    m, row, clock = manager(r, snap(CAM_A, "detection"), [])
    await m.start()
    await m.tick()
    assert m.state == RoleState.PRIMARY_ID
    row["value"] = snap(CAM_A, "standby")            # admin PATCH landed
    clock.t += 10.0                                  # next registry poll due
    await m.tick()
    assert m.state == RoleState.STANDBY and m.duty == DUTY_STANDBY
    assert await DutyLease(r, SCOPE, CAM_A).is_free() is True


async def test_lifecycle_offline_parks_but_keeps_heartbeating():
    r = fakeaioredis.FakeRedis()
    m, row, clock = manager(r, snap(CAM_A, "detection"), [])
    await m.start()
    await m.tick()
    row["value"] = snap(CAM_A, "detection", status="offline")
    clock.t += 10.0
    await m.tick()
    assert m.state == RoleState.IDLE_OFFLINE and m.duty == DUTY_STANDBY
    assert (await r.get(heartbeat_key(CAM_A))) == b"standby"


async def test_redis_down_degrades_to_desired_role():
    dead = AsyncMock()
    dead.set = AsyncMock(side_effect=ConnectionError("down"))
    dead.eval = AsyncMock(side_effect=ConnectionError("down"))
    dead.exists = AsyncMock(side_effect=ConnectionError("down"))
    dead.get = AsyncMock(side_effect=ConnectionError("down"))
    m, _, _ = manager(dead, snap(CAM_A, "detection"), [])
    await m.start()
    await m.tick()                                   # must not raise
    assert m.state == RoleState.PRIMARY_ID and m.duty == DUTY_DETECTION


async def test_db_down_keeps_last_known_role():
    r = fakeaioredis.FakeRedis()
    m, row, clock = manager(r, snap(CAM_A, "detection"), [])
    await m.start()
    await m.tick()

    async def boom(db, camera_id):
        raise ConnectionError("pg down")

    m._fetch_row = boom
    clock.t += 10.0
    await m.tick()                                   # must not raise
    assert m.state == RoleState.PRIMARY_ID           # cached (decision 11)


async def test_renewal_keeps_ttl_fresh_at_ttl_over_three():
    r = fakeaioredis.FakeRedis()
    m, _, clock = manager(r, snap(CAM_A, "detection"), [])
    await m.start()
    await m.tick()
    clock.t += 5.0                                   # ttl/3 cadence
    await m.tick()
    ttl = await r.ttl(lease_key(SCOPE))
    assert 10 < ttl <= 15                            # renewed, not expiring


async def test_shutdown_releases_and_stops_pipeline():
    r = fakeaioredis.FakeRedis()
    journal = AsyncMock()
    m, _, _ = manager(r, snap(CAM_A, "detection"), [], journal)
    await m.start()
    await m.tick()
    await m.shutdown()
    assert await DutyLease(r, SCOPE, CAM_A).is_free() is True
    reasons = [c.args[3]["reason"] for c in journal.await_args_list
               if c.args[1] == "camera_duty"]
    assert reasons[-1] == "shutdown"
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_manager.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.roles.manager'`.

- [ ] **Step 3a: Add `fetch_detection_peers`** to `/Users/jn/code/mras-vision/src/roles/registry.py`:

```python
_SQL_PEERS = """
SELECT id::text AS id FROM cameras
WHERE camera_role = 'detection' AND status = 'active' AND id <> $1::uuid
  AND ( ($2::uuid IS NOT NULL AND screen_group_id = $2::uuid)
     OR ($2::uuid IS NULL AND screen_group_id IS NULL AND system_id = $3::uuid) )
"""


async def fetch_detection_peers(db, snapshot: RegistrySnapshot) -> "list[str]":
    """Other ACTIVE desired-detection cameras in this camera's lease scope —
    the set whose heartbeats mean 'a healthy primary exists' (decision 7b)."""
    rows = await db.fetch(_SQL_PEERS, snapshot.camera_id,
                          snapshot.screen_group_id, snapshot.system_id)
    return [r["id"] for r in rows]
```

- [ ] **Step 3b: Implement.** Create `/Users/jn/code/mras-vision/src/roles/manager.py`:

```python
"""RoleManager (TODO-8 spec §5.2/§5.3) — the ONLY role-aware component.

Owns: registry polling (cached across DB outages — decision 11), the duty
lease (claim / renew-at-≤TTL/3 / release — decisions 4, 7, 8), heartbeats
(decision 10), pipeline switching (one duty at a time — decision 6), and
camera_duty journaling. Pipelines stay ignorant of all of this.

Testability: pure `decide` core + injectable clock/sleep/journal/fetchers +
an explicit `tick()` seam — failover is proven with fake clocks and
fakeredis, no cameras (same posture as the composer's Orchestrator)."""
from __future__ import annotations

import asyncio
import dataclasses
import logging
import time
from typing import Callable, Dict

from src.journal import log_journal_event
from src.roles.core import Decision, RoleState, TickInput, decide
from src.roles.heartbeat import any_alive, write_heartbeat
from src.roles.lease import DutyLease, lease_scope
from src.roles.pipeline import DUTY_STANDBY, StridedConsumer
from src.roles.registry import (RegistrySnapshot, fetch_camera_row,
                                fetch_detection_peers)

logger = logging.getLogger(__name__)


class RoleManager:
    def __init__(
        self, *,
        camera_id: str,
        screen_id: str,
        db,
        redis,                                  # None => permanent degrade
        consumers: Dict[str, StridedConsumer],
        initial_snapshot: RegistrySnapshot,
        poll_secs: float = 10.0,
        lease_ttl_secs: int = 15,
        clock: Callable[[], float] = time.monotonic,
        journal=log_journal_event,
        fetch_row=fetch_camera_row,
        fetch_peers=fetch_detection_peers,
        sleep=asyncio.sleep,
    ) -> None:
        self._camera_id = camera_id
        self._screen_id = screen_id
        self._db = db
        self._redis = redis
        self._consumers = consumers
        self._snapshot = initial_snapshot
        self._poll_secs = poll_secs
        self._ttl = lease_ttl_secs
        self._clock = clock
        self._journal = journal
        self._fetch_row = fetch_row
        self._fetch_peers = fetch_peers
        self._sleep = sleep

        self._scope = lease_scope(initial_snapshot.screen_group_id,
                                  initial_snapshot.system_id)
        self._lease = (DutyLease(redis, self._scope, camera_id, lease_ttl_secs)
                       if redis is not None else None)
        self._holds_lease = False
        self._state = RoleState.STANDBY
        self._active = consumers[DUTY_STANDBY]
        self._last_poll = float("-inf")

    # -- what main.py consumes ------------------------------------------------
    @property
    def duty(self) -> str:
        return self._active.pipeline.duty

    @property
    def state(self) -> RoleState:
        return self._state

    async def on_frame(self, frame, ts: float) -> None:
        await self._active.on_frame(frame, ts)

    async def start(self) -> None:
        await self._active.pipeline.start()

    async def run(self) -> None:
        # Tick at min(poll, TTL/3): renewal cadence ≤ TTL/3 (decision 4);
        # registry reads are gated to poll_secs inside tick().
        interval = min(self._poll_secs, self._ttl / 3.0)
        while True:
            try:
                await self.tick()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.error("role tick failed (%s: %s) — continuing",
                             type(exc).__name__, exc)
            await self._sleep(interval)

    # -- one evaluation (the test seam) ---------------------------------------
    async def tick(self) -> None:
        snapshot = await self._poll_registry()
        inp, redis_ok = await self._observe(snapshot)
        decision = decide(self._state, inp)
        reason = "poll"

        if decision.release and self._lease is not None and redis_ok:
            try:
                await self._lease.release()
            except Exception as exc:
                logger.warning("lease release failed (%s) — TTL will expire it",
                               exc)
            self._holds_lease = False
            reason = "released_lease"

        if decision.claim and self._lease is not None and redis_ok:
            try:
                won = await self._lease.try_claim()
            except Exception as exc:
                logger.warning("lease claim failed (%s) — degrading", exc)
                won = False
            if won:
                self._holds_lease = True
                decision = decide(self._state, dataclasses.replace(
                    inp, holds_lease=True, lease_free=False))
                reason = "claimed_lease"

        if not redis_ok and self._redis is not None:
            reason = "redis_down"
        if inp.lifecycle_status in ("offline", "retired", "inactive"):
            reason = "lifecycle"

        await self._apply(decision, reason)
        await self._heartbeat()

    async def shutdown(self) -> None:
        """SIGTERM drain (decision 8): release before dying, park, journal."""
        if self._holds_lease and self._lease is not None:
            try:
                await self._lease.release()
            except Exception:
                pass  # TTL expiry covers us
            self._holds_lease = False
        await self._transition(RoleState.IDLE_OFFLINE, "shutdown")
        await self._active.pipeline.stop()

    # -- internals -------------------------------------------------------------
    async def _poll_registry(self) -> RegistrySnapshot:
        now = self._clock()
        if now - self._last_poll >= self._poll_secs:
            try:
                fresh = await self._fetch_row(self._db, self._camera_id)
                if fresh is not None:
                    self._snapshot = fresh
                self._last_poll = now
            except Exception as exc:
                # Decision 11: DB down => keep last-known role (cached).
                logger.warning("registry poll failed (%s: %s) — keeping "
                               "last-known role %s", type(exc).__name__, exc,
                               self._snapshot.camera_role)
        return self._snapshot

    async def _observe(self, snapshot: RegistrySnapshot):
        redis_ok = self._redis is not None
        holds = False
        free = False
        healthy = False
        if redis_ok:
            try:
                if self._holds_lease:
                    holds = await self._lease.renew()  # renew doubles as check
                    self._holds_lease = holds
                free = await self._lease.is_free()
                peers = await self._fetch_peers(self._db, snapshot)
                healthy = await any_alive(self._redis, peers)
            except Exception as exc:
                logger.warning("Redis unavailable (%s: %s) — desired-role-only "
                               "operation (failover disabled)",
                               type(exc).__name__, exc)
                redis_ok = False
        inp = TickInput(
            desired_role=snapshot.camera_role,
            lifecycle_status=snapshot.status,
            failover_eligible=snapshot.failover_eligible,
            holds_lease=holds,
            lease_free=free,
            healthy_primary_exists=healthy,
            redis_ok=redis_ok,
        )
        return inp, redis_ok

    async def _apply(self, decision: Decision, reason: str) -> None:
        target = self._consumers[decision.duty]
        if target is not self._active:
            await self._active.pipeline.stop()   # one duty at a time (dec. 6)
            self._active = target
            await target.pipeline.start()
        if decision.state != self._state:
            await self._transition(decision.state, reason)

    async def _transition(self, to: RoleState, reason: str) -> None:
        old, self._state = self._state, to
        logger.info("duty transition %s → %s (%s)", old.value, to.value, reason)
        await self._journal(
            self._db, "camera_duty", "success",
            {"camera_id": self._camera_id, "from": old.value, "to": to.value,
             "reason": reason, "lease_scope": self._scope},
            screen_id=self._screen_id)

    async def _heartbeat(self) -> None:
        if self._redis is None:
            return
        try:
            ttl = max(1, int(3 * self._poll_secs))
            await write_heartbeat(self._redis, self._camera_id, self.duty, ttl)
        except Exception as exc:
            logger.warning("heartbeat write failed (%s) — continuing", exc)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_role_manager.py tests/test_role_core.py tests/test_duty_lease.py -v`
Expected: ALL PASS (11 + 15 + 6).

- [ ] **Step 5: Commit** — `feat(roles): RoleManager — lease-driven failover shell with injectable clock (TODO-8 C)`

---

### Task 12: Wire `RoleManager` into main.py (supersedes Phase-B static duty when CAMERA_ID is set)

**Files:**
- Modify: `/Users/jn/code/mras-vision/main.py`

**Interfaces:** `/health` for a CAMERA_ID-bound process gains additive `state` (RoleState value) — Plan B's God View `effective_duty` still comes from `camera_duty` journal events (spec §5.5), NOT this endpoint; `state` here is for the launcher/operator only.

- [ ] **Step 1: Implement.** In `/Users/jn/code/mras-vision/main.py`:

Add import: `from src.roles.manager import RoleManager`.

In `lifespan`, replace the Phase-B block from `# Static duty from desired role ...` down through the `hb_task` creation (static selection, `_consume`, `cam_task`, and the standalone heartbeat loop — RoleManager's tick now writes heartbeats itself, so the standalone loop is deleted; the key/value/TTL contract is identical, one writer instead of two) with:

```python
    role_redis = make_role_redis(settings.redis_url) if settings.camera_id else None
    role_manager = None
    role_task = None
    active = None

    if settings.camera_id:
        # TODO-8 Phase C: RoleManager owns duty (lease-driven; degrades to
        # desired-role-only when Redis is absent/unreachable — decision 11).
        role_manager = RoleManager(
            camera_id=settings.camera_id,
            screen_id=settings.device.screen_id,
            db=db, redis=role_redis, consumers=consumers,
            initial_snapshot=registry_row,
            poll_secs=settings.role_poll_secs,
            lease_ttl_secs=settings.duty_lease_ttl_secs)
        await role_manager.start()
        await role_manager.tick()          # converge before the first frame
        role_task = asyncio.create_task(role_manager.run())
        app.state.duty_provider = lambda: role_manager.duty
        app.state.state_provider = lambda: role_manager.state.value
        frame_sink = role_manager.on_frame
    else:
        # Phase-0/single-camera: byte-identical static detection duty.
        active = consumers[duty_for_role(None, "active")]
        await active.pipeline.start()
        app.state.duty_provider = lambda: active.pipeline.duty
        app.state.state_provider = lambda: None
        frame_sink = active.on_frame

    async def _consume(frame):
        try:
            await frame_sink(frame, time.monotonic())
        except Exception:
            pass  # no face or embed error — skip frame (today's posture)

    cam_task = asyncio.create_task(
        run_capture_loop(_consume, cam_index=settings.cam_index,
                         sample_rate=settings.frame_sample_rate))
```

Update the shutdown block after `yield`:

```python
    cam_task.cancel()
    rec_task.cancel()
    if role_task is not None:
        role_task.cancel()
    if role_manager is not None:
        await role_manager.shutdown()      # graceful lease release (dec. 8)
    else:
        await active.pipeline.stop()
```

Extend `/health`:

```python
@app.get("/health")
def health():
    duty = getattr(app.state, "duty_provider", None)
    state = getattr(app.state, "state_provider", None)
    settings = getattr(app.state, "settings", None)
    return {"status": "ok",
            "camera_id": getattr(settings, "camera_id", None),
            "duty": duty() if duty else DUTY_DETECTION,
            "state": state() if state else None}
```

- [ ] **Step 2: Verify**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/ -v`
Expected: full suite PASS.
Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"` → `ok`.

- [ ] **Step 3: Commit** — `feat(main): RoleManager wiring — lease-driven duty for CAMERA_ID processes (TODO-8 C)`

---

### Task 13: Live verification

**Headless (implementer can do all of this — no camera, no owner):**

- [ ] Full suite: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/ -v` → green (this already proves every failover scenario via fakeredis + fake clock).
- [ ] Byte-identical single camera: review the branch diff of `main.py` confirming the `CAMERA_ID`-unset path constructs exactly today's objects; `.venv/bin/python -c "import main"` clean.
- [ ] Launcher: `bash -n run-vision-*.sh`; with docker postgres up and rows lacking `calibration.cam_index`, `./run-vision-fleet.sh` prints SKIP and exits 1 without starting anything.
- [ ] Seed a second camera row (registry only; safe, additive):
  ```sql
  INSERT INTO cameras (system_id, name, camera_role, screen_id, status, calibration)
  SELECT system_id, 'watcher-1', 'audience_measurement', 'cam_watcher_1', 'active',
         '{"cam_index": 1}'::jsonb
  FROM cameras LIMIT 1;
  ```
  (Post-Plan-B: `UPDATE cameras SET failover_eligible = true WHERE name = 'watcher-1';` — pre-027 the process runs with eligible=false and simply never acts, by design.)
- [ ] Redis key hygiene after any live run: `redis-cli --scan --pattern 'duty:*' | xargs -n1 redis-cli ttl` and the same for `heartbeat:camera:*` → every key TTL'd.
- [ ] Journal check: `psql "$DATABASE_URL" -c "SELECT ts, payload->>'from' AS f, payload->>'to' AS t, payload->>'reason' AS r FROM events WHERE event_type='camera_duty' ORDER BY ts DESC LIMIT 10;"`

**Needs the owner's terminal + hardware (macOS camera permission is per-process; two physical cameras for the full drill):**

- [ ] Single-camera smoke (1 camera): `cd /Users/jn/code/mras-ops && CAMERA_ID=<primary-row-uuid> ./run-vision-native.sh`; grant camera permission; `curl localhost:8001/health` → `{"status":"ok","camera_id":"<uuid>","duty":"detection","state":"primary_id"}`; enroll/detect/ad flow unchanged.
- [ ] Fleet start (2 cameras): `./run-vision-fleet.sh` → two prefixed log streams; `curl localhost:8001/health` (primary → `primary_id`) and `curl localhost:8011/health` (watcher → `watching`).
- [ ] **Crash failover drill:** `kill -9` the primary's uvicorn → within `DUTY_LEASE_TTL_SECS` (≤15s) + one tick, the watcher's `/health` shows `"state":"acting_id","duty":"detection"`; ads keep flowing; journal shows `watching → acting_id, reason=claimed_lease`.
- [ ] **No-failback drill:** restart the dead primary → its `/health` shows `standby` (lease held, decision 7); journal shows NO steal.
- [ ] **Cooperative handback (decision 7b):** with the primary back and heartbeating, the acting watcher releases within one tick → journal `acting_id → watching, reason=released_lease`; the primary claims on its next tick → `primary_id`. Verify order: release strictly before the primary's claim.
- [ ] **Permanent reassignment (Plan B PATCH when shipped, else raw `UPDATE cameras SET camera_role=...`):** swap roles on the two rows → within one `ROLE_POLL_SECS` both processes converge; journal shows the released/claimed pair; names and ids unchanged.
- [ ] **Redis-down degrade:** `docker stop` the stack's redis → both processes log the desired-role-only warning and keep their desired-role duty; detection keeps working (cooldown already degrades in-memory per TODO-1); restart redis → coordination resumes without operator action.
- [ ] Watch M3 load with two live processes (decision 15): if strained, set `FRAME_SAMPLE_RATE_ATTENTION=15` on the watcher and re-check.

- [ ] **Final:** hand both branches to the git-flow-manager subagent for PR creation (vision `feat/multicam-vision-runtime`, ops `feat/multicam-fleet-launcher`).

---

## Deviations / notes

- `stride_for` never densifies below the base capture rate (an override smaller than `FRAME_SAMPLE_RATE` clamps to 1) — the capture loop's base sampling is the floor; documented in `.env.example`.
- `enrollment` desired role maps to the full detection path WITHOUT lease participation (it isn't in the spec's failover cast; parking it would break today's enrollment flow — conservative reading of decision 5's "pipelines wrap existing paths").
- The Phase-B standalone heartbeat loop is intentionally replaced by RoleManager's heartbeat in Phase C (identical key/value/TTL contract, one writer instead of two).
- `CAM_INDEX` → registry mapping uses `calibration->>'cam_index'` (existing jsonb column, no migration needed); the fleet launcher skips rows without it rather than guessing device indexes.
