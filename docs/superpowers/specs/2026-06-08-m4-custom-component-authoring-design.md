# M4 — Custom-Component Ad Authoring (speed-first, security deferred)

## Context

Phase 0.5 (M0–M3) gave advertisers **two fixed overlay presets** (`fade`, `turbulence-warp`),
parameterized via JSON, rendered by the Remotion sidecar and composited by the Python composer. M3
wired a personalized name overlay into the **live `/trigger`** path via a **warm** render sidecar
(bundle once + one reused headless Chromium; ~2–3s per render, no caching).

M4's goal: let advertisers supply **their own Remotion/React components** for arbitrary animation,
beyond the two presets — and run a bound custom-component ad **live per viewer**.

### Why this design (the constraints that decided it)
- **Speed is priority #1.** The real-time loop (recognize a face → synthesize voice → render overlay
  → composite → play *before they walk away*) means the **per-trigger render path must stay warm**
  (~2–3s). Anything that bundles or cold-starts per trigger is disqualified.
- **Security is explicitly out of scope this milestone** (not production; Remotion may not be the
  final engine — don't over-invest). **No sandbox/isolation and no static code analysis.** We accept
  running advertiser code in the warm sidecar's Node process (bundle time) and Chromium (render time).
- **Don't build into a corner.** Two cheap, non-"security" hooks are kept so isolation or a remote
  renderer can be added later without rework: a **render-backend seam** and **output-conformance
  checks** (the latter is correctness — a malformed component must not silently break the composite,
  the M3 black-box failure mode).
- **No AWS** anywhere (no setup/maintenance).

The key mechanic that satisfies speed: **do the slow/risky work (bundling untrusted React) once at
upload/registration**, not per trigger. A viewer only ever pays the warm render.

## Goals
- Advertisers upload a custom Remotion component; it is validated-for-compile, **bundled once**, and
  registered as a renderable composition.
- A minimal web authoring page (ops-frontend): upload a component, see ready/failed, enter sample
  props, pick a base video, **preview** the composited result; create/list **ads**.
- An **ad** binds `{ base_video, component, default_props, personalized_field }`; the same base can use
  many components (many styles per product) and many bases can reuse a component (many products).
- **Live `/trigger`** selects a bound custom-component ad for the viewer, fills the personalized field
  with their name, renders the overlay warm, composites, and plays — reusing
  `assemble(overlay_inserts=…)` unchanged.

## Non-goals (deferred to later milestones)
- Sandbox/isolation of untrusted code; static analysis / import allowlists.
- Remote/horizontally-scaled rendering (slots into the render-backend seam later).
- Rich authoring UX (code editor, versioning, multi-tenant auth, rotation/targeting beyond "active").
- Caching of renders (M3 decision stands: every personalized trigger renders fresh).

## Architecture & responsibilities

```
ops-frontend ──upload .tsx / create ad──► ops-api ──proxy upload──► mras-overlays (sidecar)
     │  preview / list                       │  (postgres CRUD)        - POST /components (bundle+register)
     │                                        ▼                         - POST /render (by composition id)
     └──preview──► mras-composer ──render(composition_id, props)──► mras-overlays
                        │  (reads ads/components from postgres)
                        └──/trigger: select custom ad → render → ffmpeg composite → WS play
```

- **mras-overlays (sidecar) — the component authority + renderer.**
  - `POST /components` (multipart `.tsx`): write into `src/custom/<slug>.tsx`, **hot re-bundle** the
    warm project so the component registers as composition `comp_<slug>`, return
    `{ id, propsSchema, status: "ready" | "failed", error? }`. Re-bundle swaps the warm `serveUrl`;
    the reused Chromium stays warm. Components persist on a mounted volume (survive restarts).
  - `POST /render` generalized: accept `{ compositionId, props }` and render **any** registered
    composition (not just `Overlay`) with the existing alpha settings (`prores`/`4444`,
    `imageFormat:png`, `pixelFormat:yuva444p10le`). Renders remain serialized (single-flight) and warm.
  - **Component contract** (documented + a scaffold template): default export = the React component;
    named export `schema` = a zod object for the component's own props. The standard base-meta props
    (`baseWidth`, `baseHeight`, `fps`, `durationMs`) are always injected so the shared
    `calculateMetadata` sizes the composition (same contract as `Overlay`). `Root.tsx` enumerates
    `src/custom/*.tsx` at bundle time and registers one `<Composition>` per file.

- **ops-api + postgres — admin CRUD (the ops-frontend backend).**
  - DB migration adds two tables:
    - `components(id, name, slug, status, error, props_schema jsonb, created_at)` — metadata mirror;
      the `.tsx` itself lives on the sidecar volume.
    - `ads(id, name, base_video, component_id fk, default_props jsonb, personalized_field, is_active,
      created_at)`.
  - `POST /components` (multipart): forward file to sidecar `/components`, persist returned metadata.
  - `GET /components`; `POST/GET/PATCH /ads`.

- **mras-composer — runtime (render seam, preview, trigger).**
  - **Render-backend seam:** generalize `render_overlay_http(spec, …)` → `render(composition_id,
    props, base_meta, …)` behind a small interface, so the backend (warm-sidecar-HTTP now) can later
    be swapped for an isolated/remote renderer without touching callers.
  - `POST /preview` (authoring): given `{ component_id, props, base_video }`, ffprobe the base →
    inject base-meta → render via sidecar → **output-conformance check** → composite (reuse the
    `assemble` video path, no audio) → return an mp4 URL. Conformance failure → structured error to UI.
  - `/trigger`: selector picks the active custom-component ad for the viewer; merge
    `default_props + { personalized_field: name } + base-meta`; render warm via the seam;
    output-conformance check; `assemble(base, [(audio,250)], trigger_id, overlay_inserts=…)`.
    **On any overlay failure, fall back to a no-overlay clip** (M3 behavior — never drop the ad).

- **selector — custom-ad selection.** Known/unblocked visitor → the `is_active` custom-component ad
  with `personalized_field` filled from the name; new/unknown visitor → standard (`standard.mp4`,
  no overlay), unchanged. Rotation/targeting beyond "active" is deferred.

- **ops-frontend — minimal authoring page.** Upload `.tsx` (poll status ready/failed + show bundle
  error); a prop form driven by the returned `propsSchema`; base-video picker; **Preview** (calls
  composer `/preview`, shows the mp4); create/list ads (calls ops-api).

## Output-conformance (correctness, not security)
After a render, the composer ffprobes the returned `.mov`: `width==baseWidth`, `height==baseHeight`,
alpha present (`yuva*` pix_fmt), `duration≈durationMs` (small tolerance). Mismatch → log + (trigger)
fall back to no-overlay / (preview) return the specific error. This stops a bad custom component from
producing the M3 "black box" composite.

## Data flow — advertiser journey
1. **Author** locally from a provided scaffold (stripped `turbulence-warp`): component + `schema`.
2. **Upload** on the authoring page → ops-api → sidecar bundles + registers → `ready`/`failed`.
   *(The once-per-style slow step.)*
3. **Preview** with sample props + a base video → composer `/preview` → see the composite; iterate.
4. **Create an ad** = base × component + default props + which prop personalizes (e.g. `name`).
5. **Run live**: a recognized viewer triggers selection of the active custom ad → warm render with the
   viewer's name → composite → kiosk plays.

## Implementation plan (one PR per task, TDD red→green, failing test committed separately)
1. **mras-overlays**: dynamic `src/custom/` registry + `Root` enumeration; `POST /components`
   (write + hot re-bundle + return schema/status); generalize `POST /render` to `compositionId`;
   component-contract scaffold + docs. Tests: register→composition appears; render by id; bad
   component → `failed` + error (no crash, warm browser survives).
2. **mras-ops**: DB migration (`components`, `ads`); ops-api component upload proxy + metadata persist;
   ad CRUD. Tests: upload persists metadata; ad CRUD round-trips.
3. **mras-composer**: render-backend seam (generalize `render_overlay_http`) + output-conformance
   helper. Tests: seam renders by composition id; conformance pass/fail (mock ffprobe).
4. **mras-composer**: `POST /preview` (render+composite, no audio) returning an mp4. Tests: preview
   happy path (mocked sidecar/assemble); conformance failure surfaces an error.
5. **mras-composer**: `/trigger` custom-ad selection wiring (selector reads ads; merge props; render;
   fallback). Tests: known visitor → assemble called with the custom overlay; conformance/sidecar
   failure → no-overlay fallback; new visitor → standard.
6. **ops-frontend**: authoring/preview page (upload, schema-driven prop form, base picker, preview,
   ad create/list). Tests: component/UI tests per the repo's vitest pattern.
7. **mras-ops compose / env**: any new env (e.g. `OPS_API`↔sidecar URL, custom-components volume) +
   live E2E (upload a sample component → create an ad → trigger → kiosk shows the custom overlay).

## Risks & mitigations
- **Re-bundle cost on upload** (seconds–tens): acceptable — it's authoring-time, off the trigger path;
  surface a "bundling…" status in the UI.
- **A bad component hangs/crashes the shared warm browser** (no isolation): mitigate cheaply with the
  per-render timeout (M3 `OVERLAY_RENDER_TIMEOUT`) and **restart the browser on render error** in the
  sidecar; full isolation is the deferred follow-up behind the seam.
- **No security** is a conscious, documented choice for this milestone — the seam + output checks are
  the only forward hooks. Going live requires the isolation milestone first.
- **Speed regressions**: keep per-trigger to warm render only; never bundle per trigger. Verify the
  warm render stays ~2–3s after generalizing `/render`.

## Verification
- Unit per repo (pytest / node:test / vitest), TDD red→green per task.
- **Live E2E** (headless, like M3): upload the scaffold component → bundle `ready` → create an ad
  (Nike base + component + personalize `name`) → seed `Jason` → `POST /trigger` → composer renders the
  custom composition warm → ffprobe output `h264/yuv420p` (overlay composited, no alpha leak) →
  optionally pixel-diff the overlay window. `docker compose stop` stays graceful (M3 fix).
