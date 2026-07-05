# MRAS Service Configuration Convention

*Adopted 2026-07-05 (owner-approved, from the mras-vision#26 architecture debate). First
implementation: `mras-vision` PR #27 (`/Users/jn/code/mras-vision/src/config.py`). All MRAS
services (`mras-vision`, `mras-composer`, `mras-display`, `mras-ops` api/projector) adopt this
convention as they are next touched; `mras-composer` migration is its own future ticket.*

## The rules

1. **No module-level `os.getenv` / `os.environ` — anywhere.** That includes the sneaky forms:
   dataclass **field defaults**, class-body constants, and **keyword-argument defaults** — all of
   these evaluate at import time. Import-time env reads are the hazard class that produced the
   silent `screen_0` mislabeling risk: anything loaded before the environment is fully populated
   (e.g. a later-added `load_dotenv()`) silently bakes stale values.
2. **One frozen `Settings` dataclass per service** (stdlib `dataclasses`, `frozen=True`) with
   **literal defaults** on every field. Flat by default; a nested group is allowed **only when a
   consumer takes the group whole** (mras-vision earns exactly two: `DeviceIdentity`,
   `IdentityTuning`). No pydantic-settings — the coercion it buys is ~40 lines of stdlib.
3. **One pure loader:** `load_settings(env: Mapping[str, str] = os.environ) -> Settings` — the
   **only** place environment is read. Coercion failures raise a `ConfigError` naming the
   variable and the bad value. Required values (e.g. `DATABASE_URL`) fail fast here with a clear
   message. Tests pass a plain dict; never `monkeypatch.setenv` for new code.
4. **Build once at process startup** — the first statement of the FastAPI `lifespan()` (there is
   no literal `main()` under uvicorn) or the equivalent entrypoint — and store on
   `app.state.settings`. Config change = process restart (12-factor). Device identity must never
   change mid-process, or journal events straddle scopes.
5. **Inject the narrowest thing:** leaf values or small slices via constructor/function
   parameters, with literal defaults so test constructions stay stable. Passing whole `Settings`
   is permitted only where a consumer genuinely uses ~5+ fields. Never reach into
   `app.state.settings` from library code.
6. **Enforce with an AST tripwire test** (`tests/test_no_import_time_env.py` pattern from
   mras-vision): walks `src/` + `main.py`, fails on any `os.getenv`/`os.environ` reference outside
   the loader module — including class bodies and defaults. A convention without a tripwire decays.
7. **Device identity warning:** when `SCREEN_ID` (or a service's equivalent identity var) resolves
   to its default, the loader logs one prominent startup warning. Two devices silently sharing
   `screen_0` cross-contaminates every God View join.
8. **The remote-config seam is the loader signature, nothing more.** Registry-era config
   (God View device registry supplying identity + overrides) arrives as
   `load_settings(env, overrides=fetch_from_registry(...))` — a second pure merge step. No
   provider objects, no hot-reload, no config clients until that day.

## Known idiomatic exception

Values that are **policy read at evaluation time** (e.g. the composer's
`PROGRAM_ABANDON_TTL_S` / `CLIP_SECONDS` watchdog lambdas wired in `main.py`) read env inside a
callable injected at startup. That is deliberate — the read still happens post-startup and the
core stays env-free; the AST tripwire should allowlist the entrypoint wiring module or the
lambdas should live in the loader module.
