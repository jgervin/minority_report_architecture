# M4 — Custom-Component Ad Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per CLAUDE.md §6: branch/worktree per task, TDD red→green with the failing test committed **separately** from the impl, one PR per task, commit trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`, no self-merge to main without the user's OK.

**Goal:** Let advertisers upload their own Remotion components, bind them to ads (base video × component + props), and run a personalized custom-component ad live per identified viewer — keeping the per-trigger render on the warm (~2–3s) path.

**Architecture:** Slow work (bundling untrusted React) happens once at upload in the warm sidecar; per-trigger renders are warm `selectComposition + renderMedia` by composition id. Security (sandbox/static analysis) is deferred behind a render-backend seam; output-conformance checks guard pipeline correctness. No AWS, no caching.

**Tech Stack:** mras-overlays (Node 22, Remotion 4.0.473, tsx, node:test), mras-composer (Python 3.11, FastAPI, pytest, ffmpeg), mras-ops/api (FastAPI + asyncpg), postgres 16, ops-frontend (React 18 + Vite + vitest).

**Spec:** `docs/superpowers/specs/2026-06-08-m4-custom-component-authoring-design.md`.

---

## Shared contracts (consistent across all tasks)

- **Custom component file** `mras-overlays/src/custom/<slug>.tsx`: `export default` a `React.FC`; `export const schema` a zod object of the component's own props. The base-meta props (`baseWidth`, `baseHeight`, `fps`, `durationMs`) are always injected by the renderer and drive the shared `calculateMetadata`. Registered as composition id **`comp_<slug>`**.
- **Sidecar HTTP** (`mras-overlays`): `POST /components` (multipart `file` + `name`) → `{id, slug, propsSchema, status, error?}`; `POST /render` body `{compositionId, props}` → transparent `.mov` bytes; `GET /health`.
- **DB** (postgres): `components(id, name, slug, status, error, props_schema, created_at)`, `ads(id, name, base_video, component_id, default_props, personalized_field, is_active, created_at)`.
- **ops-api HTTP**: `POST /components` (multipart proxy + persist), `GET /components`, `POST /ads`, `GET /ads`, `PATCH /ads/{id}`.
- **composer**: `render_composition_http(client, sidecar_url, composition_id, props, work_dir) -> Path`; `assert_conformant(mov, base_meta) -> None` (raises `ConformanceError`); `POST /preview`; `/trigger` custom-ad selection.

---

## Task 1 — mras-overlays: dynamic component registry + render-by-id

**Branch:** `feat/m4-dynamic-components` (in `/Users/jn/code/mras-overlays`).

**Files:**
- Create: `src/custom/.gitkeep` (empty dir kept in git)
- Create: `src/customRegistry.ts` (generated-manifest loader)
- Create: `src/components.ts` (write file + regenerate manifest + rebundle)
- Modify: `src/Root.tsx` (register custom compositions from the registry)
- Modify: `src/server.ts` (add `POST /components`; generalize `POST /render` to `compositionId`)
- Test: `src/components.test.ts`, extend `src/server.test.ts`

- [ ] **Step 1: Write the failing test for the manifest generator**

Create `src/components.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { writeComponent, regenerateManifest } from "./components";

test("writeComponent saves the .tsx and slugifies the name", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "custom-"));
  const { slug, file } = writeComponent(dir, "Neon Glow!", "export default () => null;\nexport const schema = {};");
  assert.equal(slug, "neon-glow");
  assert.equal(path.basename(file), "neon-glow.tsx");
  assert.match(fs.readFileSync(file, "utf8"), /export default/);
});

test("regenerateManifest lists every .tsx as comp_<slug>", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "custom-"));
  fs.writeFileSync(path.join(dir, "neon-glow.tsx"), "export default () => null;\nexport const schema = {};");
  fs.writeFileSync(path.join(dir, "kinetic.tsx"), "export default () => null;\nexport const schema = {};");
  const manifest = regenerateManifest(dir);
  assert.match(manifest, /import comp_neon_glow from ".\/neon-glow"/);
  assert.match(manifest, /id: "comp_neon-glow"/);
  assert.match(manifest, /id: "comp_kinetic"/);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/jn/code/mras-overlays && npx tsx --test src/components.test.ts`
Expected: FAIL — `Cannot find module './components'`.

- [ ] **Step 3: Commit the failing test (red)**

```bash
git add src/components.test.ts && git commit -m "test: custom component file write + manifest generation — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Implement `src/components.ts`**

```ts
import fs from "node:fs";
import path from "node:path";

export function slugify(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

export function writeComponent(customDir: string, name: string, source: string): { slug: string; file: string } {
  const slug = slugify(name);
  if (!slug) throw new Error("name produced an empty slug");
  fs.mkdirSync(customDir, { recursive: true });
  const file = path.join(customDir, `${slug}.tsx`);
  fs.writeFileSync(file, source);
  return { slug, file };
}

// Generated manifest imports each custom component + its schema and lists it for Root to register.
export function regenerateManifest(customDir: string): string {
  const files = fs.readdirSync(customDir).filter((f) => f.endsWith(".tsx"));
  const imports = files
    .map((f) => {
      const slug = f.replace(/\.tsx$/, "");
      const ident = slug.replace(/-/g, "_");
      return `import comp_${ident}, { schema as schema_${ident} } from "./${slug}";`;
    })
    .join("\n");
  const entries = files
    .map((f) => {
      const slug = f.replace(/\.tsx$/, "");
      const ident = slug.replace(/-/g, "_");
      return `  { id: "comp_${slug}", component: comp_${ident}, schema: schema_${ident} },`;
    })
    .join("\n");
  const manifest = `// AUTO-GENERATED by components.ts — do not edit.\n${imports}\n\nexport const customComponents = [\n${entries}\n];\n`;
  fs.writeFileSync(path.join(customDir, "registry.ts"), manifest);
  return manifest;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/jn/code/mras-overlays && npx tsx --test src/components.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 6: Wire custom compositions into `Root.tsx` + create the empty registry**

Create `src/custom/.gitkeep` (empty) and `src/custom/registry.ts`:
```ts
// AUTO-GENERATED by components.ts — do not edit.

export const customComponents = [];
```
Create `src/customRegistry.ts`:
```ts
import { customComponents } from "./custom/registry";
export { customComponents };
```
Modify `src/Root.tsx` — after the existing `Overlay` `<Composition>`, register one per custom component (same base-meta `calculateMetadata`):
```tsx
import { customComponents } from "./customRegistry";
// ...inside RemotionRoot return, wrap existing Composition + this in a <>...</>:
{customComponents.map(({ id, component, schema }) => (
  <Composition
    key={id}
    id={id}
    component={component as React.FC<any>}
    schema={schema as any}
    defaultProps={{ baseWidth: 854, baseHeight: 480, fps: 24, durationMs: 2000 } as any}
    width={854}
    height={480}
    fps={24}
    durationInFrames={48}
    calculateMetadata={({ props }: any) => ({
      width: props.baseWidth,
      height: props.baseHeight,
      fps: props.fps,
      durationInFrames: Math.max(1, Math.round((props.durationMs / 1000) * props.fps)),
    })}
  />
))}
```

- [ ] **Step 7: Write the failing server test for register + render-by-id**

Extend `src/server.test.ts` — the server factory gains a `registerComponent` dep and `/render` takes `compositionId`:
```ts
test("POST /components registers and returns ready + schema", async () => {
  const fakeRegister = async (_name: string, _source: string) => ({
    id: "comp_neon-glow", slug: "neon-glow", propsSchema: { type: "object" }, status: "ready" as const,
  });
  const server = createServer({ render: async () => Buffer.alloc(0), registerComponent: fakeRegister });
  await new Promise<void>((r) => server.listen(0, r));
  const { port } = server.address() as import("node:net").AddressInfo;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/components`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Neon Glow", source: "export default () => null; export const schema = {};" }),
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.id, "comp_neon-glow");
    assert.equal(body.status, "ready");
  } finally {
    await new Promise<void>((r) => server.close(() => r()));
  }
});

test("POST /render uses the provided compositionId", async () => {
  let renderedId: string | undefined;
  const server = createServer({
    render: async (id: string, _props: unknown) => { renderedId = id; return Buffer.from("MOV"); },
    registerComponent: async () => ({ id: "x", slug: "x", propsSchema: {}, status: "ready" as const }),
  });
  await new Promise<void>((r) => server.listen(0, r));
  const { port } = server.address() as import("node:net").AddressInfo;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/render`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ compositionId: "comp_neon-glow", props: { baseWidth: 854, baseHeight: 480, fps: 24, durationMs: 600 } }),
    });
    assert.equal(res.status, 200);
    assert.equal(renderedId, "comp_neon-glow");
  } finally {
    await new Promise<void>((r) => server.close(() => r()));
  }
});
```
NOTE: the existing `/render` tests must be updated to send `{compositionId:"Overlay", props:{...}}` and the fake `render` signature becomes `(compositionId, props)`.

- [ ] **Step 8: Run to verify the new tests fail**

Run: `cd /Users/jn/code/mras-overlays && npx tsx --test src/server.test.ts`
Expected: FAIL — `createServer` doesn't accept `registerComponent`; `/render` ignores `compositionId`.

- [ ] **Step 9: Commit the failing tests (red)**

```bash
git add src/server.test.ts && git commit -m "test: sidecar register component + render by compositionId — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 10: Generalize `server.ts` (createServer + warm renderer + register)**

In `src/server.ts`:
- `ServerDeps` becomes `{ render: (compositionId: string, props: OverlayProps | Record<string, unknown>) => Promise<Buffer>; registerComponent: (name: string, source: string) => Promise<{id:string;slug:string;propsSchema:unknown;status:"ready"|"failed";error?:string}> }`.
- In the `POST /render` handler, parse `{ compositionId, props }` (default `compositionId="Overlay"`, validate `Overlay` props with `overlaySchema`; for custom ids skip the `overlaySchema` parse) and call `render(compositionId, props)`.
- Add `POST /components` handler: parse `{ name, source }`, call `registerComponent(name, source)`, return JSON (200 on `ready`, 422 on `failed`).
- `makeWarmRenderer().render` signature becomes `(compositionId, props)` and passes `id: compositionId` to `selectComposition`.
- Add `registerComponent(name, source)`: `writeComponent(customDir, name, source)`, `regenerateManifest(customDir)`, **re-bundle** (`bundle()` again → swap the module-level `serveUrl`), then `selectComposition({ serveUrl, id: comp_<slug>, inputProps: {baseWidth:854,baseHeight:480,fps:24,durationMs:600} })` to validate it compiles/registers; on throw return `{status:"failed", error}` and leave the prior `serveUrl` intact. `customDir = path.resolve(process.cwd(), "src/custom")`.

(Use `multipart` only at the ops-api boundary; the sidecar accepts JSON `{name, source}` to keep it simple — ops-api reads the uploaded file and forwards its text.)

- [ ] **Step 11: Run all sidecar tests to verify green**

Run: `cd /Users/jn/code/mras-overlays && npm test && npx tsc --noEmit`
Expected: PASS (all), tsc clean.

- [ ] **Step 12: Manual smoke — register a sample component + render it**

Provide `examples/HelloName.tsx` (scaffold: a component using `interpolate`/`spring` that renders `props.text`, plus `export const schema = z.object({ text: z.string(), color: z.string().default("#fff") })`). Start the sidecar; `POST /components` with its source; `POST /render {compositionId:"comp_helloname", props:{text:"Jason", baseWidth:854,baseHeight:480,fps:24,durationMs:600}}`; `ffprobe` the `.mov` → `yuva444*` (alpha present).

- [ ] **Step 13: Commit impl (green) + push + PR**

```bash
git add -A && git commit -m "feat: dynamic custom-component registry + render by compositionId — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-dynamic-components && gh pr create --fill
```

---

## Task 2 — mras-ops: DB migration + ops-api component/ad CRUD

**Branch:** `feat/m4-registry-api` (in `/Users/jn/code/mras-ops`).

**Files:**
- Create: `db/migrations/002_custom_components.sql`
- Modify: `api/requirements.txt` (add `httpx>=0.27.0`, `python-multipart>=0.0.9`)
- Modify: `api/src/main.py` (component upload proxy + ad CRUD; widen CORS methods)
- Test: `api/tests/test_registry.py` (+ `api/tests/__init__.py`, `api/tests/conftest.py` if missing)

- [ ] **Step 1: Write the migration**

Create `db/migrations/002_custom_components.sql`:
```sql
CREATE TABLE IF NOT EXISTS components (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text        NOT NULL,
    slug         text        NOT NULL UNIQUE,
    status       text        NOT NULL DEFAULT 'bundling' CHECK (status IN ('bundling','ready','failed')),
    error        text,
    props_schema jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ads (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name              text        NOT NULL,
    base_video        text        NOT NULL,
    component_id      uuid        NOT NULL REFERENCES components(id),
    default_props     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    personalized_field text       NOT NULL DEFAULT 'text',
    is_active         boolean     NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ads_is_active_idx ON ads (is_active);
```

- [ ] **Step 2: Write the failing CRUD test**

Create `api/tests/test_registry.py` (uses FastAPI TestClient + a fake asyncpg pool + a fake sidecar via monkeypatched httpx):
```python
from unittest.mock import AsyncMock, patch
from fastapi.testclient import TestClient
import src.main as m

def _fake_pool(rows=None, row=None):
    pool = AsyncMock()
    pool.fetch = AsyncMock(return_value=rows or [])
    pool.fetchrow = AsyncMock(return_value=row)
    pool.execute = AsyncMock()
    pool.close = AsyncMock()
    return pool

def test_create_ad_persists_and_returns_id():
    pool = _fake_pool(row={"id": "ad-1", "name": "Nike", "base_video": "/assets/standard.mp4",
                           "component_id": "c-1", "default_props": {}, "personalized_field": "text",
                           "is_active": True, "created_at": "2026-06-08T00:00:00Z"})
    with patch("src.main.asyncpg.create_pool", AsyncMock(return_value=pool)):
        with TestClient(m.app) as client:
            res = client.post("/ads", json={"name": "Nike", "base_video": "/assets/standard.mp4",
                                            "component_id": "c-1", "default_props": {},
                                            "personalized_field": "text", "is_active": True})
    assert res.status_code == 200
    assert res.json()["id"] == "ad-1"
    pool.fetchrow.assert_awaited()

def test_upload_component_forwards_to_sidecar_and_persists():
    pool = _fake_pool(row={"id": "c-1"})
    sidecar_resp = AsyncMock()
    sidecar_resp.status_code = 200
    sidecar_resp.json = lambda: {"id": "comp_neon", "slug": "neon", "propsSchema": {"type": "object"}, "status": "ready"}
    http = AsyncMock(); http.post = AsyncMock(return_value=sidecar_resp)
    with patch("src.main.asyncpg.create_pool", AsyncMock(return_value=pool)), \
         patch("src.main.httpx.AsyncClient", return_value=http):
        with TestClient(m.app) as client:
            res = client.post("/components",
                              data={"name": "Neon"},
                              files={"file": ("neon.tsx", b"export default ()=>null; export const schema={};", "text/plain")})
    assert res.status_code == 200
    assert res.json()["slug"] == "neon"
    http.post.assert_awaited()         # forwarded to sidecar
    pool.execute.assert_awaited()      # metadata persisted
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd /Users/jn/code/mras-ops/api && python -m pytest tests/test_registry.py -q`
Expected: FAIL — routes `/ads` and `/components` don't exist (404) / import errors.

- [ ] **Step 4: Commit failing test (red)**

```bash
git add db/migrations/002_custom_components.sql api/tests/test_registry.py api/requirements.txt
git commit -m "test: ops-api component upload + ad CRUD; add registry migration — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Implement the endpoints in `api/src/main.py`**

- Add imports: `import httpx`; `from fastapi import UploadFile, File, Form`; `from pydantic import BaseModel`.
- Widen CORS: `allow_methods=["GET", "POST", "PATCH"]`.
- Add `_SIDECAR_URL = os.getenv("OVERLAY_SIDECAR_URL", "http://mras-overlays:3000")`.
- `POST /components`:
```python
@app.post("/components")
async def upload_component(name: str = Form(...), file: UploadFile = File(...)):
    source = (await file.read()).decode("utf-8")
    async with httpx.AsyncClient(timeout=120) as http:
        r = await http.post(f"{_SIDECAR_URL}/components", json={"name": name, "source": source})
    body = r.json()
    await _db.execute(
        "INSERT INTO components (name, slug, status, error, props_schema) "
        "VALUES ($1,$2,$3,$4,$5::jsonb) ON CONFLICT (slug) DO UPDATE SET "
        "status=EXCLUDED.status, error=EXCLUDED.error, props_schema=EXCLUDED.props_schema",
        name, body["slug"], body["status"], body.get("error"), json.dumps(body.get("propsSchema")),
    )
    return body
```
- `GET /components`: `SELECT id,name,slug,status,error,props_schema,created_at FROM components ORDER BY created_at DESC` → list of dicts.
- Ad model + CRUD:
```python
class AdIn(BaseModel):
    name: str; base_video: str; component_id: str
    default_props: dict = {}; personalized_field: str = "text"; is_active: bool = False

@app.post("/ads")
async def create_ad(ad: AdIn):
    row = await _db.fetchrow(
        "INSERT INTO ads (name, base_video, component_id, default_props, personalized_field, is_active) "
        "VALUES ($1,$2,$3,$4::jsonb,$5,$6) RETURNING id,name,base_video,component_id,default_props,personalized_field,is_active,created_at",
        ad.name, ad.base_video, ad.component_id, json.dumps(ad.default_props), ad.personalized_field, ad.is_active)
    return dict(row)

@app.get("/ads")
async def list_ads():
    rows = await _db.fetch("SELECT id,name,base_video,component_id,default_props,personalized_field,is_active,created_at FROM ads ORDER BY created_at DESC")
    return [dict(r) for r in rows]

@app.patch("/ads/{ad_id}")
async def update_ad(ad_id: str, patch: dict):
    # only is_active toggling needed for the demo
    await _db.execute("UPDATE ads SET is_active=$2 WHERE id=$1", ad_id, bool(patch.get("is_active", False)))
    return {"status": "ok"}
```
(Serialize `default_props`/`props_schema` with `json.dumps`; asyncpg returns jsonb as str — `json.loads` in GET responses or return as-is. For the demo, return `dict(row)`; FastAPI will JSON-encode. If jsonb comes back as str, wrap with `json.loads`.)

- [ ] **Step 6: Run tests to verify green**

Run: `cd /Users/jn/code/mras-ops/api && python -m pytest tests/test_registry.py -q`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit + push + PR**

```bash
git add -A && git commit -m "feat: ops-api custom-component upload proxy + ad CRUD; registry migration — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-registry-api && gh pr create --fill
```

---

## Task 3 — mras-composer: render-backend seam + output-conformance

**Branch:** `feat/m4-render-seam` (in `/Users/jn/code/mras-composer`).

**Files:**
- Modify: `src/overlay/http_renderer.py` (generalize to `render_composition_http`)
- Create: `src/overlay/conformance.py` (`assert_conformant`, `ConformanceError`)
- Test: `tests/test_overlay_http.py` (extend), `tests/test_conformance.py`

- [ ] **Step 1: Write failing test for `render_composition_http`**

Add to `tests/test_overlay_http.py`:
```python
from src.overlay.http_renderer import render_composition_http

async def test_render_composition_http_posts_compositionId_and_props(tmp_path):
    client = FakeClient(FakeResp(200, content=b"MOV"))
    props = {"text": "Jason", "baseWidth": 854, "baseHeight": 480, "fps": 24, "durationMs": 600}
    out = await render_composition_http(client, "http://sidecar:3000", "comp_neon", props, tmp_path)
    assert client.calls == [("http://sidecar:3000/render", {"compositionId": "comp_neon", "props": props})]
    assert out.read_bytes() == b"MOV"
```
(Reuse `FakeResp`/`FakeClient` already in this file. Note `FakeClient.post(url, json=...)` must capture `json`.)

- [ ] **Step 2: Write failing test for conformance**

Create `tests/test_conformance.py`:
```python
import pytest
from src.overlay.conformance import assert_conformant, ConformanceError
from src.overlay.probe import VideoMeta

def _meta(w=854, h=480): return VideoMeta(w, h, 24.0, 600)

def test_conformant_passes_for_matching_alpha_clip(tmp_path):
    f = tmp_path / "ov.mov"; f.write_bytes(b"x")
    assert_conformant(f, _meta(), probe=lambda _p: (854, 480, "yuva444p10le"))  # no raise

def test_nonalpha_raises(tmp_path):
    f = tmp_path / "ov.mov"; f.write_bytes(b"x")
    with pytest.raises(ConformanceError):
        assert_conformant(f, _meta(), probe=lambda _p: (854, 480, "yuv420p"))

def test_wrong_dims_raises(tmp_path):
    f = tmp_path / "ov.mov"; f.write_bytes(b"x")
    with pytest.raises(ConformanceError):
        assert_conformant(f, _meta(), probe=lambda _p: (640, 360, "yuva444p10le"))
```

- [ ] **Step 3: Run both to verify they fail**

Run: `cd /Users/jn/code/mras-composer && python -m pytest tests/test_overlay_http.py::test_render_composition_http_posts_compositionId_and_props tests/test_conformance.py -q`
Expected: FAIL — `render_composition_http` / `conformance` not defined.

- [ ] **Step 4: Commit failing tests (red)**

```bash
git add tests/test_overlay_http.py tests/test_conformance.py
git commit -m "test: composer render seam (by compositionId) + output-conformance — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Implement the seam in `http_renderer.py`**

```python
async def render_composition_http(client, sidecar_url, composition_id, props, work_dir) -> Path:
    resp = await client.post(f"{sidecar_url}/render", json={"compositionId": composition_id, "props": props})
    if resp.status_code != 200:
        raise RuntimeError(f"overlay sidecar returned {resp.status_code}: {resp.text}")
    out = Path(tempfile.mktemp(prefix="overlay-", suffix=".mov", dir=work_dir))
    out.write_bytes(resp.content)
    return out
```
Refactor `render_overlay_http` to delegate: `return await render_composition_http(client, sidecar_url, "Overlay", _props(spec, base_meta), work_dir)`. Keep `build_overlay_inserts_http` working (it calls `render_overlay_http`).

- [ ] **Step 6: Implement `conformance.py`**

```python
"""Reject overlay clips that won't composite correctly (wrong dims or no alpha) — pipeline correctness."""
import subprocess
from pathlib import Path

class ConformanceError(Exception):
    pass

def _probe_dims_pixfmt(path: Path):
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,pix_fmt", "-of", "csv=p=0:s=,", str(path)],
        capture_output=True, text=True, check=True)
    w, h, pix = proc.stdout.strip().split(",")
    return int(w), int(h), pix

def assert_conformant(mov: Path, base_meta, probe=_probe_dims_pixfmt) -> None:
    w, h, pix = probe(mov)
    if w != base_meta.width or h != base_meta.height:
        raise ConformanceError(f"overlay {w}x{h} != base {base_meta.width}x{base_meta.height}")
    if not pix.startswith("yuva"):
        raise ConformanceError(f"overlay pix_fmt {pix!r} has no alpha")
```

- [ ] **Step 7: Run tests to verify green**

Run: `cd /Users/jn/code/mras-composer && python -m pytest -q`
Expected: PASS (existing 62 + new). `render_overlay_http`/`build_overlay_inserts_http` still green.

- [ ] **Step 8: Commit + push + PR**

```bash
git add -A && git commit -m "feat: render-by-compositionId seam + output-conformance check — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-render-seam && gh pr create --fill
```

---

## Task 4 — mras-composer: `POST /preview` (render + composite, no audio)

**Branch:** `feat/m4-preview` (in `/Users/jn/code/mras-composer`).

**Files:**
- Modify: `main.py` (add `/preview`; helper to look up a component's composition id + ad base)
- Modify: `src/assembly/assembler.py` (allow `audio_inserts=[]` → video-only map) — only if needed
- Test: `tests/test_preview.py`

- [ ] **Step 1: Verify assemble handles no-audio (read + decide)**

Read `assembler.py` `_audio_filter`/`assemble`. If `audio_inserts=[]` produces an invalid `amix=inputs=1`, add an early branch: when `not audio_inserts`, map `0:a?` straight through (`-map 0:v -map 0:a?`) with the video filter. Capture this as a sub-step with a test in Step 2.

- [ ] **Step 2: Write the failing `/preview` test**

Create `tests/test_preview.py`:
```python
from pathlib import Path
from unittest.mock import AsyncMock, patch
from fastapi.testclient import TestClient
import main

def _setup(assemble_ret=Path("/output/preview-x.mp4")):
    db = AsyncMock(); db.execute = AsyncMock(); db.close = AsyncMock()
    db.fetchrow = AsyncMock(return_value={"slug": "neon"})  # component lookup
    assemble = AsyncMock(return_value=assemble_ret)
    render = AsyncMock(return_value=Path("/tmp/ov.mov"))
    patches = [
        patch("main.create_pool", AsyncMock(return_value=db)),
        patch("main.assemble", assemble),
        patch("main.render_composition_http", render),
        patch("main.probe_video", lambda _p: main_VideoMeta()),
        patch("main.assert_conformant", lambda *_a, **_k: None),
    ]
    for p in patches: p.start()
    return TestClient(main.app), {"assemble": assemble, "render": render, "patches": patches}

def main_VideoMeta():
    from src.overlay.probe import VideoMeta
    return VideoMeta(854, 480, 24.0, 8000)

def test_preview_renders_and_composites():
    client, mocks = _setup()
    try:
        with client:
            res = client.post("/preview", json={"component_id": "c-1",
                                                 "props": {"text": "Jason"},
                                                 "base_video": "/assets/standard.mp4"})
        assert res.status_code == 200
        assert "preview-x.mp4" in res.json()["url"]
        mocks["render"].assert_awaited_once()
        _, kwargs = mocks["assemble"].call_args
        assert kwargs["overlay_inserts"] is not None
    finally:
        for p in mocks["patches"]: p.stop()
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd /Users/jn/code/mras-composer && python -m pytest tests/test_preview.py -q`
Expected: FAIL — `/preview` route missing.

- [ ] **Step 4: Commit failing test (red)**

```bash
git add tests/test_preview.py
git commit -m "test: composer /preview renders custom component + composites — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Implement `/preview` in `main.py`**

Add imports: `from src.overlay.http_renderer import render_composition_http`, `from src.overlay.conformance import assert_conformant, ConformanceError`, `from src.overlay.probe import probe_video`. Add a Pydantic `PreviewPayload(component_id:str, props:dict, base_video:str)`. Look up the component slug from DB (`SELECT slug FROM components WHERE id=$1`), composition id = `f"comp_{slug}"`. Then:
```python
@app.post("/preview")
async def preview(body: PreviewPayload):
    row = await app.state.db.fetchrow("SELECT slug FROM components WHERE id=$1", body.component_id)
    if row is None:
        return {"error": "unknown component"}
    base = Path(body.base_video)
    meta = probe_video(base)
    props = {**body.props, "baseWidth": meta.width, "baseHeight": meta.height,
             "fps": meta.fps, "durationMs": int(body.props.get("durationMs", 2000))}
    work = Path(tempfile.mkdtemp(prefix="preview_", dir=_OUTPUT_DIR))
    try:
        clip = await render_composition_http(app.state.http, _OVERLAY_SIDECAR_URL, f"comp_{row['slug']}", props, work)
        assert_conformant(clip, meta)
    except (ConformanceError, Exception) as exc:
        return {"error": str(exc)}
    start_ms = int(props.get("startMs", 0))
    inserts = [(clip, start_ms, min(start_ms + props["durationMs"], meta.duration_ms))]
    out = await assemble(base, [], f"preview-{int(time.time())}", overlay_inserts=inserts)
    return {"url": f"http://{_HOST}:{_PORT}/media/{out.name}"}
```
(Add `import tempfile, time` if missing. Implement the assemble no-audio branch from Step 1 so `audio_inserts=[]` works.)

- [ ] **Step 6: Run tests to verify green**

Run: `cd /Users/jn/code/mras-composer && python -m pytest -q`
Expected: PASS (all).

- [ ] **Step 7: Commit + push + PR**

```bash
git add -A && git commit -m "feat: composer /preview (render custom component + composite, no audio) — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-preview && gh pr create --fill
```

---

## Task 5 — mras-composer: `/trigger` custom-ad selection wiring

**Branch:** `feat/m4-trigger-custom-ad` (in `/Users/jn/code/mras-composer`).

**Files:**
- Modify: `src/selector/selector.py` (return active custom ad for identified viewers)
- Modify: `main.py` (`/trigger` builds custom props, renders by composition id, conformance + fallback)
- Test: `tests/test_selector.py` (extend), `tests/test_trigger_overlay.py` (extend)

- [ ] **Step 1: Write failing selector test**

Add to `tests/test_selector.py`:
```python
async def test_identified_visitor_gets_active_custom_ad():
    db = _db(name="Jason")
    # active custom ad joined with its component slug
    db.fetchrow = AsyncMock(side_effect=[
        {"name": "Jason", "is_blocked": False},  # identity lookup
        {"base_video": "/assets/standard.mp4", "slug": "neon",
         "default_props": {"color": "#ff2d2d"}, "personalized_field": "text"},  # active ad
    ])
    with patch("src.selector.selector._STANDARD_VIDEO", _FAKE_VIDEO):
        result = await select({"uuid": "uuid-abc", "is_new_visitor": False}, db)
    assert result.type == "personalized"
    assert result.composition_id == "comp_neon"
    assert result.overlay_props["text"] == "Jason"        # personalized field filled
    assert result.overlay_props["color"] == "#ff2d2d"     # default prop preserved
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/jn/code/mras-composer && python -m pytest tests/test_selector.py -q`
Expected: FAIL — `AdSelection` has no `composition_id`/`overlay_props`.

- [ ] **Step 3: Commit failing test (red)**

```bash
git add tests/test_selector.py
git commit -m "test: selector returns active custom-component ad for identified viewer — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Implement selector changes**

In `selector.py`: add `composition_id: str | None = None` and `overlay_props: dict | None = None` to `AdSelection`. In the personalized branch, query the active custom ad:
```python
ad = await db.fetchrow(
    "SELECT a.base_video, c.slug, a.default_props, a.personalized_field "
    "FROM ads a JOIN components c ON c.id = a.component_id "
    "WHERE a.is_active = true AND c.status = 'ready' ORDER BY a.created_at DESC LIMIT 1")
if ad is not None:
    props = dict(ad["default_props"] or {})
    props[ad["personalized_field"]] = row["name"]
    return AdSelection(type="personalized", base_video=Path(ad["base_video"]),
                       tts_text=tts_text, person_uuid=person_uuid,
                       composition_id=f"comp_{ad['slug']}", overlay_props=props)
# else fall back to existing M3 name-overlay behavior (overlay_text)
return AdSelection(type="personalized", base_video=_STANDARD_VIDEO, tts_text=tts_text,
                   person_uuid=person_uuid, overlay_text=_OVERLAY_TEMPLATE.format(name=row["name"]))
```
(`default_props` from asyncpg jsonb may be a str — `json.loads` if so.)

- [ ] **Step 5: Write failing `/trigger` test**

Add to `tests/test_trigger_overlay.py`:
```python
def test_identified_custom_ad_renders_by_composition_id():
    sel = AdSelection(type="personalized", base_video=Path("/assets/standard.mp4"),
                      tts_text="Welcome, Jason!", person_uuid="u1",
                      composition_id="comp_neon", overlay_props={"text": "Jason", "color": "#ff2d2d"})
    inserts = [(Path("/tmp/ov.mov"), 500, 2000)]
    db = AsyncMock(); db.execute = AsyncMock(); db.close = AsyncMock()
    assemble = AsyncMock(return_value=Path("/output/t1.mp4"))
    build = AsyncMock(return_value=inserts)
    patches = [
        patch("main.create_pool", AsyncMock(return_value=db)),
        patch("main.select", AsyncMock(return_value=sel)),
        patch("main.synthesize", AsyncMock(return_value=Path("/tmp/a.aiff"))),
        patch("main.assemble", assemble),
        patch("main.build_custom_overlay_inserts", build),
    ]
    for p in patches: p.start()
    try:
        with TestClient(main.app) as client:
            res = client.post("/trigger", json={"trigger_id": "t1", "uuid": "u1", "is_new_visitor": False})
        assert res.json()["status"] == "ok"
        build.assert_awaited_once()
        _, kwargs = assemble.call_args
        assert kwargs["overlay_inserts"] == inserts
    finally:
        for p in patches: p.stop()
```

- [ ] **Step 6: Run to verify it fails**

Run: `cd /Users/jn/code/mras-composer && python -m pytest tests/test_trigger_overlay.py -q`
Expected: FAIL — `build_custom_overlay_inserts` not defined / trigger doesn't use composition_id.

- [ ] **Step 7: Commit failing test (red)**

```bash
git add tests/test_trigger_overlay.py
git commit -m "test: /trigger renders identified viewer's custom-component ad — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 8: Implement `/trigger` wiring**

Add a helper `build_custom_overlay_inserts(client, sidecar_url, composition_id, props, base, work)` in `main.py` (probe base, inject base-meta into props, `render_composition_http`, `assert_conformant`, return `[(clip,start,end)]`). In `/trigger`, replace the M3 `selection.overlay_text` block with: if `selection.composition_id`: try `build_custom_overlay_inserts(...)`; except → log `overlay/error`, `overlay_inserts=None` (fallback). Else keep the M3 `overlay_text` path. Then `assemble(..., overlay_inserts=overlay_inserts)` (unchanged). Standard branch unchanged (no broadcast).

- [ ] **Step 9: Run full suite to verify green**

Run: `cd /Users/jn/code/mras-composer && python -m pytest -q`
Expected: PASS (all).

- [ ] **Step 10: Commit + push + PR**

```bash
git add -A && git commit -m "feat: /trigger renders identified viewer's bound custom-component ad — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-trigger-custom-ad && gh pr create --fill
```

---

## Task 6 — ops-frontend: authoring + preview page

**Branch:** `feat/m4-authoring-ui` (in `/Users/jn/code/mras-ops`, `frontend/`).

**Files:**
- Modify: `frontend/package.json` (add `vitest`, `@testing-library/react`, `jsdom`, test script)
- Create: `frontend/vitest.config.ts`
- Create: `frontend/src/Authoring.tsx` (upload, schema-driven prop form, base picker, preview, ad create/list)
- Create: `frontend/src/api.ts` (typed fetch wrappers to ops-api + composer)
- Modify: `frontend/src/App.tsx` (mount `<Authoring/>`)
- Test: `frontend/src/Authoring.test.tsx`

- [ ] **Step 1: Add the test toolchain**

Add to `frontend/package.json` devDeps: `vitest`, `@testing-library/react`, `@testing-library/jest-dom`, `jsdom`; script `"test": "vitest run"`. Create `frontend/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
export default defineConfig({ plugins: [react()], test: { environment: "jsdom", globals: true } });
```
Run `npm install` in `frontend/`.

- [ ] **Step 2: Write the failing component test**

Create `frontend/src/Authoring.test.tsx`:
```tsx
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { describe, it, expect, vi } from "vitest";
import { Authoring } from "./Authoring";

describe("Authoring", () => {
  it("uploads a component and shows its status", async () => {
    const api = {
      uploadComponent: vi.fn().mockResolvedValue({ id: "c-1", slug: "neon", status: "ready", propsSchema: {} }),
      listComponents: vi.fn().mockResolvedValue([]),
      listAds: vi.fn().mockResolvedValue([]),
      createAd: vi.fn(), preview: vi.fn(),
    };
    render(<Authoring api={api} />);
    const file = new File(["export default ()=>null; export const schema={};"], "neon.tsx");
    fireEvent.change(screen.getByLabelText(/component file/i), { target: { files: [file] } });
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: "Neon" } });
    fireEvent.click(screen.getByRole("button", { name: /upload/i }));
    await waitFor(() => expect(api.uploadComponent).toHaveBeenCalledWith("Neon", file));
    await screen.findByText(/ready/i);
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd /Users/jn/code/mras-ops/frontend && npm test`
Expected: FAIL — `./Authoring` not found.

- [ ] **Step 4: Commit failing test (red)**

```bash
git add frontend/package.json frontend/package-lock.json frontend/vitest.config.ts frontend/src/Authoring.test.tsx
git commit -m "test: ops-frontend authoring page uploads component + shows status — red

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: Implement `api.ts` + `Authoring.tsx`**

`frontend/src/api.ts` — wrappers: `uploadComponent(name, file)` → `POST {OPS_API}/components` (FormData), `listComponents()`, `listAds()`, `createAd(ad)` → ops-api; `preview(component_id, props, base_video)` → `POST {COMPOSER}/preview`. Base URLs from `import.meta.env.VITE_OPS_API` / `VITE_COMPOSER` with localhost defaults.
`frontend/src/Authoring.tsx` — an `Authoring({api})` component: file input (`aria-label="component file"`), name input, Upload button (calls `api.uploadComponent`, shows returned `status`); a props form rendered from the selected component's `propsSchema` keys; a base-video text/select input; Preview button (calls `api.preview`, shows the returned `url` in a `<video>`); a "Create ad" form (base + component + default props + personalized field + is_active) calling `api.createAd`; lists components and ads. Keep it minimal and unstyled — function over form.

- [ ] **Step 6: Mount in `App.tsx` + run tests green**

Modify `App.tsx` to import the real `api` (from `api.ts`) and render `<Authoring api={api} />`.
Run: `cd /Users/jn/code/mras-ops/frontend && npm test && npx tsc --noEmit`
Expected: PASS, tsc clean.

- [ ] **Step 7: Commit + push + PR**

```bash
git add -A && git commit -m "feat: ops-frontend custom-component authoring + preview page — green

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feat/m4-authoring-ui && gh pr create --fill
```

---

## Task 7 — mras-ops: compose/env wiring + live E2E

**Branch:** `feat/m4-compose-e2e` (in `/Users/jn/code/mras-ops`).

**Files:**
- Modify: `docker-compose.yml` (custom-components volume on sidecar; ops-api gets `OVERLAY_SIDECAR_URL`; frontend gets `VITE_OPS_API`/`VITE_COMPOSER` build args; ops-api depends_on sidecar)
- Modify: `mras-overlays/Dockerfile` (ensure `src/custom` is writable / on a volume) — only if needed

- [ ] **Step 1: Add the components volume + env**

In `docker-compose.yml`:
- `mras-overlays`: add `volumes: [ custom_components:/app/src/custom ]`.
- `mras-ops-api`: add `environment: OVERLAY_SIDECAR_URL: http://mras-overlays:3000` and `depends_on: [postgres (healthy), mras-overlays (service_started)]`.
- `mras-ops-frontend`: pass `VITE_OPS_API`/`VITE_COMPOSER` (build args or runtime) so the UI reaches ops-api:8080 and composer:8002 from the browser (use host-published URLs `http://localhost:8080` / `http://localhost:8002`).
- Add `custom_components:` under top-level `volumes:`.

- [ ] **Step 2: Validate compose**

Run: `cd /Users/jn/code/mras-ops && docker compose config --quiet && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit compose wiring**

```bash
git add docker-compose.yml
git commit -m "feat: M4 compose wiring (custom-components volume, ops-api sidecar URL, frontend API URLs)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Live E2E (headless, no camera)**

1. `docker compose up -d --build postgres mras-overlays mras-composer mras-ops-api` (apply migration 002 via fresh DB or psql).
2. Upload the scaffold component: `POST ops-api:8080/components` (multipart `examples/HelloName.tsx`) → expect `status: ready`.
3. Create an ad: `POST /ads {base_video:/assets/standard.mp4, component_id, default_props:{}, personalized_field:"text", is_active:true}`.
4. Seed `Jason` identity (SESSION_LOG recipe); `POST composer:8002/trigger {uuid, is_new_visitor:false}` → `{status:"ok"}`.
5. Composer log shows `POST mras-overlays:3000/render "200 OK"` with `compositionId: comp_helloname`; sidecar log shows the render.
6. `ffprobe /output/<trigger>.mp4` → `h264 / yuv420p` at the base dims (overlay composited, no alpha leak). Optionally pixel-diff the overlay window.
7. `docker compose stop mras-overlays` → graceful `SIGTERM received` (M3 fix intact).

- [ ] **Step 5: Push + PR**

```bash
git push -u origin feat/m4-compose-e2e && gh pr create --fill
```

---

## Closing checklist (per CLAUDE.md §5/§6)
- Branch per task; TDD red→green with the failing test committed separately; one PR per task (7 PRs across mras-overlays / mras-composer / mras-ops); commit trailer on every commit; **no self-merge to main without the user's OK**.
- Prepend a dated `SESSION_LOG.md` entry citing each `repo@sha`, the new endpoints (`/components`, `/render {compositionId}`, `/preview`, ad CRUD), the component contract + scaffold, the `custom_components` volume, and the live-E2E result. Update the Operational Reference.
- File follow-up issues for the deferred items: **sandbox/isolation of untrusted code** (the going-live blocker, slots into the render seam), static code analysis, and rotation/targeting beyond `is_active`.

## Self-review notes (coverage vs spec)
- Spec "component authority + render by id" → Task 1. "ops-api CRUD + migration" → Task 2. "render seam + conformance" → Task 3. "/preview" → Task 4. "/trigger identified→custom ad; unidentified→idle (no broadcast)" → Task 5 (standard branch unchanged = no broadcast). "authoring/preview UI" → Task 6. "compose/env + E2E" → Task 7.
- Deferred (sandbox, static analysis, remote render, rich UX, caching) → not built; filed as issues in the closing checklist.
- Type consistency: `render_composition_http(client, sidecar_url, composition_id, props, work_dir)`, sidecar `/render {compositionId, props}`, composition id `comp_<slug>`, `AdSelection.composition_id`/`overlay_props`, `assert_conformant(mov, base_meta, probe=…)` used consistently across Tasks 1/3/4/5.
