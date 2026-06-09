# M5 — Authoring props-display (auto-render a component's prop fields)

## Context
In the Authoring tool, when an advertiser selects/uploads a custom Remotion component there is **no
indication of what props it accepts** — they get a raw "Props (JSON)" textarea and must guess. The
component already declares its inputs via a zod `schema` export, but that schema never reaches the UI.

Root cause (investigated 2026-06-09): the sidecar's `POST /components` returns `propsSchema: {}` — it
never extracts the schema. A runtime probe showed that dynamically importing a component's `.tsx` in
the sidecar exposes **only the `default` export** (the named `schema` export is not surfaced), so the
schema can't be read at runtime as-is. The frontend therefore falls back to the JSON textarea
(`schemaProps` is null because `propsSchema.properties` is absent).

## Goal
When a component is uploaded (and when selected in Create Ad), the Authoring form **auto-renders one
labeled input per prop, pre-filled with the prop's default**, so an advertiser never guesses. Falls
back to the existing editable JSON textarea if a component's schema can't be parsed.

## Approach
1. **Sidecar (`mras-overlays`) — emit a real JSON schema at registration.** Add `zod-to-json-schema`.
   In `registerComponent`, obtain the component's zod `schema` object and return
   `propsSchema = zodToJsonSchema(schema)` (shape `{ type:"object", properties:{ <prop>:{type,default,...} } }`),
   instead of `{}`. Persisted by ops-api (`components.props_schema`) and returned on upload.
   - **Technical risk to solve first:** reliably get the `schema` object. The runtime dynamic import
     only exposed `default`. Options to evaluate: (a) fix the tsx/esbuild ESM interop so the named
     `schema` export is importable (check `tsconfig` module settings / use `import * as` or import the
     generated `src/custom/registry.ts`, which uses static `import { schema as … }`); (b) read the
     schema inside the bundle (it's already in `customComponents`) and surface it via a tiny endpoint
     or a build step. Spike this before committing to the path.
2. **ops-api** — no change beyond already persisting/returning `props_schema` (now non-empty).
3. **Frontend (`mras-ops/frontend`)** — the existing schema-driven path already renders a field per
   `propsSchema.properties` key. Extend it to: pre-fill each field with its `default`, label with the
   prop name + type, and use it in **both** Preview (after upload) and **Create Ad** (driven by the
   selected component's `props_schema`). Keep the JSON textarea as the fallback when there are no
   parseable properties.

## Out of scope (v1)
- Complex zod types (unions, refinements, nested objects). Handle primitives first:
  string / number / boolean / enum / array-of-primitive. Anything else → JSON textarea fallback.
- Required-vs-optional validation UI (nice-to-have later).

## Tasks (TDD, one PR each)
1. **mras-overlays**: spike + implement schema → JSON (zod-to-json-schema); `registerComponent` returns
   a populated `propsSchema`. Test: registering a component with a known zod schema returns
   `properties` with names + defaults. Rebuild the sidecar image (new dep).
2. **mras-ops/frontend**: render schema-driven prop fields (Preview + Create Ad) pre-filled with
   defaults; JSON-textarea fallback. Tests: fields render from `propsSchema.properties`; defaults
   pre-filled; values flow to `preview`/`createAd`.
3. **Live E2E**: upload `/Users/jn/code/mras-overlays/examples/FishSwim.tsx` → its props
   (count, colors, speed, waveAmplitude) appear as labeled fields with defaults → preview/create uses them.

## Verification
- Unit per repo (node:test / vitest). Live: upload an example, confirm prop fields appear with
  defaults, create an ad, watch the auto-popup. No more guessing prop names in a blank JSON box.

## References
- Current authoring code: `/Users/jn/code/mras-ops/frontend/src/Authoring.tsx`,
  `/Users/jn/code/mras-overlays/src/server.ts` (`registerComponent`, returns `propsSchema:{}` today),
  `/Users/jn/code/mras-overlays/src/applyDefaults.ts` (schema-defaults helper from M4).
- Example components with schemas: `/Users/jn/code/mras-overlays/examples/*.tsx`.
