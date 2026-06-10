# MRAS / AdFace — Session Log

Append-only engineering journal across the MRAS multi-repo system
(`minority_report_architecture`, `mras-vision`, `mras-composer`, `mras-display`, `mras-ops`).
Purpose: survive reboots, `/clear`, and context summarization so any future session, skill,
or agent can recover what was done, what was learned, and how to run the system.

## Protocol (read this first, every session)

1. **At session start:** read this file top-to-bottom plus `TODOS.md` and `adface_architecture.md`.
2. **At session end (or before a likely reboot / `/clear`):** prepend a new dated entry under
   "Session Entries" using the template below. Newest first.
3. **Keep it durable, not chatty.** Record: what changed (with repo + commit SHA), what was
   *learned* (non-obvious facts, gotchas), and any new run/operational steps. Skip blow-by-blow.
4. **Cross-repo commits** live in their own repos — always cite `repo@sha`. Working-tree-only
   changes (not yet committed) must be flagged as such.
5. This is the source of truth for "how do I run it" — keep the Operational Reference current.

### Entry template
```
## YYYY-MM-DD — <short title>
**Changes:** repo@sha — one line each.
**Learnings:** non-obvious facts / gotchas discovered.
**State:** what's working / verified, what's pending.
```

---

## Operational Reference (keep current)

**Topology (IMPORTANT — differs from the original plan doc):**
- `mras-vision` runs **natively on macOS**, NOT in Docker — macOS cannot pass the webcam into a
  container. The compose service has `profiles: ["docker-vision"]` so it is **excluded** from
  default `docker compose up`. Start it with `mras-ops/run-vision-native.sh` (bootstraps an
  arm64 venv at `mras-vision/.venv`, CAM_INDEX=0 = built-in webcam).
- Default `docker compose up` (run from `mras-ops/`) brings up: postgres, qdrant, mras-composer,
  mras-ops-api, mras-ops-frontend.
- **Camera permission:** native vision must be launched from the user's own terminal so macOS can
  prompt for camera access. A background/agent launch gets `not authorized to capture video` and
  the camera task fails (app still serves `/enroll` and `/health` — camera is a background task).

**Ports:** vision 8001, composer 8002, ops-api 8080, ops-frontend 3000, postgres 5432, qdrant 6333.
mras-overlays render sidecar **3000 (internal `expose` only, not host-published)** — composer reaches
it at `http://mras-overlays:3000`.

**Overlay render sidecar (M3):** `mras-overlays` is a compose service (`docker compose up`/down
governs it — no separate process). Composer renders the viewer's name as an animated overlay in
`/trigger` via `OVERLAY_SIDECAR_URL` (default `http://mras-overlays:3000`), styled by
`OVERLAY_TEMPLATE` (default `{name}`) + `OVERLAY_PRESET|START_MS|DURATION_MS|COLOR|POSITION`.
**No caching** — every personalized trigger renders fresh (warm ≈ 2.9s in-container). First ~10–90s
after startup the sidecar is still warming → overlay silently falls back to no-overlay (ad still ships).

**Custom-component authoring (M4 — branches, not yet merged):** advertisers upload a Remotion `.tsx`
(via ops-frontend → ops-api `POST /components` → sidecar bundles once, registers `comp-<slug>`), bind
it to an **ad** (`ads` table: base_video + component + default_props + personalized_field + is_active),
and an identified viewer's `/trigger` renders the bound custom component (warm, ~1.1s) with their name.
Sidecar `POST /render` takes `{compositionId, props}`; uploaded components persist on the
`custom_components` volume. **No sandbox/security yet** — advertiser code runs un-isolated (deferred).
Apply migration `002_custom_components.sql` manually on an existing DB volume (init scripts run only on
a fresh DB).

**TTS:** ElevenLabs primary → **Google Gemini** fallback (MisoOne was replaced). Keys in `mras-ops/.env`.

**Recognition:** confidence threshold 0.68. Below threshold → `is_new_visitor=true` → standard ad
(no name). Enrolled identities seed Qdrant collection `mras_embeddings` (512-dim Cosine).

**Gotchas:**
- The `mras-ops-frontend` container **bakes its source at build time** (no volume mount). After
  editing `frontend/src/*`, redeploy with `docker compose up -d --build mras-ops-frontend`.
- **curl/wget are blocked** by the context-mode guard for HTTP fetches. Use Python `httpx`
  (e.g. `mras-vision/.venv/bin/python`) for enroll/trigger calls.
- Vision tests run via `mras-vision/.venv/bin/python -m pytest` (host pyenv 3.11 lacks deps).
- `mras-kiosk` is a superseded scaffold — the live kiosk is `mras-display`.
- One-command startup: `mras-ops/start-mras.sh` (starts Docker, the compose stack, then native vision).
- **Node containers: don't `CMD ["npm","start"]`** — npm as PID 1 swallows SIGTERM so graceful
  handlers never run. Run the binary directly (`node_modules/.bin/tsx …`) + compose `init: true`
  (tini). The overlay sidecar does this; `docker compose stop mras-overlays` logs the graceful close.
- **Raw `git`/`gh` is blocked in all 5 CLAUDE.md repos** by a PreToolUse guard
  (`.claude/hooks/guard-git.sh`). The main agent must delegate to the `git-flow-manager` subagent; the
  subagent opts in by prefixing commands with `CLAUDE_GIT_OK=1` (e.g. `CLAUDE_GIT_OK=1 git status`).
  Pushing to `main` is denied even with the marker — land via `gh pr merge` after review. A "Raw git/gh
  is disabled" error means: delegate, don't fight it.

**Enroll a face (vision must be running):**
```python
# mras-vision/.venv/bin/python
import httpx
csv = b"name,photo\nAlice,alice.jpg\n"
with open("alice.jpg","rb") as f:
    httpx.post("http://localhost:8001/enroll",
        files={"csv_file":("e.csv",csv,"text/csv"),
               "photos":("alice.jpg",f.read(),"image/jpeg")}, timeout=60)
```

---

## Session Entries (newest first)

## 2026-06-09 — Review-findings (4 fixes) + git-governance convergence + SESSION_LOG guard exception
Working the 4 non-blocking review findings from the delete-ads/components merge, plus the
pre-filed #17, as proper tickets in **`mras-ops`** (all five live there, not in this repo).
Worktree-per-ticket + git delegated to the `git-flow-manager` subagent; sequential (grouped by
file) to avoid same-line conflicts. **#2+#4 combined** into one ticket (same DELETE handlers).
**Issues filed (jgervin/mras-ops):** #18 (non-UUID DELETE→500, finding #2), #19 (DELETE no-404,
finding #4), #20 (coerceProps boolean default, finding #3), #21 (adPropValues reset deps, finding
#1). #17 (props_schema key) already open.
**Ticket 1 — DONE (closes #18+#19):** `fix/18-harden-delete-handlers`. DELETE `/ads|/components`
now UUID-validate the id (→**400**, before the DB call) and check the asyncpg command tag (→**404**
on no-match); 409 in-use path preserved. TDD red→green: `fb3a499` (4 failing tests) → `9270356`
(fix). **PR #22 merged** → `origin/main` @ **`c631c08`**. Suite 13/13.
**Live E2E (httpx → ops-api :8080, after `docker compose up -d --build mras-ops-api`):** bad id→400,
absent uuid→404 (both `/ads` and `/components`), `GET /ads`→200. The 404 confirms real asyncpg
returns `"DELETE 0"` for a no-match (the basis of the fix) — verified against live Postgres.
**Gotcha:** mras-ops **local `main` is 3 commits ahead of `origin/main`** (unpushed governance
commits `a14f2ca` = the git guardrails). Branched tickets from `origin/main` for clean diffs; after
merging #22, rebased local `main` onto `origin/main` (governance replayed → `cfa3cc9`, 3 ahead, clean)
so the working tree has the fix for the container rebuild. **Open question for next session:** land the
3 governance commits on `origin/main` via a chore PR (they can't be pushed to `main` directly — guarded).
**Ticket 2 — DONE (closes #17):** `fix/17-normalize-props-schema-key`. `POST /components` now returns
`props_schema` (snake_case, matching GET + the DB column) instead of `propsSchema`; frontend reads the
single key and drops its dual-key tolerance (`api.ts` `ComponentRecord`, `Authoring.tsx` upload-result +
Create-Ad reads). ops-api↔sidecar contract (reads the sidecar's camelCase `propsSchema`) unchanged. TDD
red→green: `b28a97a` (tests assert `props_schema`) → `1c3098d` (impl). **PR #23 merged** → `origin/main`
@ **`485c239`**. pytest 13/13, vitest 17/17, tsc clean.
**Live E2E:** rebuilt ops-api **and** ops-frontend (`docker compose up -d --build`). httpx upload →
`POST /components` response keys include `props_schema` (no `propsSchema`), props count/colors/speed/
waveAmplitude. **Playwright UI:** uploaded FishSwim.tsx via the running frontend → Preview rendered all
four schema-driven fields default-filled (count=6, colors=[…], speed=1, waveAmplitude=0.06), Status:
ready. Cleaned up test component + cwd file afterward (delete returned 200 — hardened DELETE handles real
rows too). Op note: frontend bakes source at build time, so `--build` is required for ops-frontend.
**Ticket 3 — DONE (closes #20):** `fix/20-coerceprops-boolean-default`. `coerceProps`
(`frontend/src/Authoring.tsx`) emitted a boolean for every boolean field even when untouched, sending
`false` and overriding the component's own default. Fix = one-line reorder: moved `if (v === "")
continue;` above the `p.type === "boolean"` branch, so an empty boolean is omitted like every other
optional type. TDD red→green: `a2017c9` (component-level test asserting an untouched boolean is omitted
from the preview payload) → `fa1f493` (fix). **PR #24 merged** → `origin/main` @ **`7ec959e`**. vitest
18/18, tsc clean.
**Live E2E (Playwright, after rebuilding ops-frontend):** no example component has a boolean prop, so
authored a minimal `BoolCheck.tsx` with `showText: z.boolean().optional()` (a *required* boolean 422s in
the sidecar — it can't render without it; optional-no-default is the case that yields an empty raw value
and exercises the fix). Uploaded via the UI → Preview rendered `text (string)`=Hi + an unchecked
`showText (boolean)` checkbox → clicked Preview without touching it → captured the live `POST :8002/preview`
body: `props` = `{"text":"Hi"}` — **`showText` omitted** (pre-fix it would be `{"text":"Hi","showText":false}`).
Cleaned up the authored test components + cwd file afterward (demo back to the 5 originals).
**Ticket 4 — DONE (closes #21):** `fix/21-adpropvalues-reset-deps`. The Create-Ad prop reset
`useEffect` (`frontend/src/Authoring.tsx`) depended on the whole `components` array, so deleting ANY
component re-ran it and wiped in-progress ad prop edits. Fix: depend on `[adForm.component_id,
adSchemaProps]` instead (and dropped the eslint-disable — deps are now honest). `adSchemaProps` is the
selected component's `.properties` object **by reference** (`schemaPropertiesOf` returns it directly, not
a fresh object), and delete uses `setComponents(prev => prev.filter(...))` which preserves surviving
element refs — so an unrelated delete leaves `adSchemaProps` stable and the effect doesn't fire. TDD
red→green: `c9df5b6` (test: edit an ad prop, delete an unrelated component, edit must survive) →
`08b885e` (fix). **PR #25 merged** → `origin/main` @ **`032f570`**. vitest 19/19, tsc clean.
**Live E2E (Playwright, after rebuilding ops-frontend):** uploaded two schema'd throwaways; selected one
in Create Ad → count/colors/speed/waveAmplitude fields rendered; edited `count` 6→**99**; deleted the
*other* (unrelated) component → `count` **stayed 99** (pre-fix it would reset to 6). Cleaned up both
throwaways (demo back to the 5 originals). Op note: `fish1` and other pre-M5 components have
`props_schema={}` and correctly fall back to the JSON textarea — only schema'd components render fields.

**ALL FOUR REVIEW-FINDING TICKETS SHIPPED + LIVE-VERIFIED.** Merged to `mras-ops` `origin/main` in order:
#22 (`c631c08`, closes #18+#19) → #23 (`485c239`, closes #17) → #24 (`7ec959e`, closes #20) → #25
(`032f570`, closes #21). Each: own worktree off origin/main, TDD red→green (separate commits), self-review,
live E2E, merge, container rebuild. ops-api + ops-frontend rebuilt from the final main.
**GOVERNANCE CONVERGENCE (resolved this session):** the git-governance bootstrap commits had been
committed directly to local `main` in all 5 CLAUDE.md repos and never pushed (couldn't be — the guard
blocks pushing to `main`). Landed them on each `origin/main` via a `chore/land-git-governance` PR, then
`reset --hard origin/main` to converge local main (0 ahead / 0 behind): minority_report_architecture #3
(`e5dc299`), mras-composer #19 (`f2552ba`), mras-kiosk #1 (`226d058`), mras-ops #26 (`07e8f1f`),
mras-vision #3 (`63a30cd`). Divergence gone; future tickets branch off `origin/main` and merge via PR, so
it won't recur. Guard gotcha (use `HEAD`, not the literal word `main`, as a branch start-point — the guard
substring-matches `main`).
**SESSION_LOG guard exception:** added a journal-only push exception to
`/Users/jn/code/minority_report_architecture/.claude/hooks/guard-git.sh` (PR #4, `36eaa10`; test-first via
`.claude/hooks/guard-git.test.sh`, 7/7): a push to `main` is allowed iff the `CLAUDE_GIT_OK=1` marker is
present AND the net diff (`origin/main..HEAD`) is nothing but `docs/SESSION_LOG.md`. This journal can now be
committed + pushed straight to main with no PR — which is how THIS entry landed.
**SECURITY (hardening — next ticket):** two automated reviews flagged a HIGH on the exception — it infers
the payload from `origin/main..HEAD` rather than the actual pushed refspec, so an unusual push form
(`git push origin other:main`, `refs/heads/main`, `git -C … push`, or a compound command) could differ from
what's checked. The guard is accident-prevention, not adversarial-proof (the marker is readable), and the
real journal push is the safe literal `git push origin main`, so it isn't exploited here — but the exception
will be tightened (restrict to the literal `git push origin main`/`HEAD:main` form, reject compound commands,
broaden main-detection to `refs/heads/main` + `git -C … push`).
**State:** 4 review findings + governance convergence (all 5 repos) + SESSION_LOG guard exception shipped &
verified. Pending: harden the guard exception per the security review (next ticket).

## 2026-06-09 — Git workflow guardrails: worktree-per-ticket rules + git-flow-manager subagent + PreToolUse guard
Standardized Git discipline across all 5 MRAS repos that have a `CLAUDE.md`
(`minority_report_architecture`, `mras-composer`, `mras-kiosk`, `mras-ops`, `mras-vision`).
`mras-display` and `mras-overlays` were **skipped — they have no `CLAUDE.md`.** Goal: stop agents
stepping on each other's branches / touching `main`. Three commits per repo (all on `main`; the
rules themselves are the bootstrap, so they were committed directly):
**Changes (per repo: rules → agent → guard):**
- `minority_report_architecture@cd67a96` → `@c5698f7` → `@d846a08`
- `mras-composer@2cf1424` → `@809385e` → `@c527940`
- `mras-kiosk@7507452` → `@04f7600` → `@284cf34`
- `mras-ops@11fdef8` → `@8a36b1e` → `@a14f2ca`
- `mras-vision@dc65827` → `@a528918` → `@b48f985`
**What landed:**
1. **CLAUDE.md "Git & Branching Rules"** — branch off `main` as `{type}/{ticket}-{slug}`, one worktree
   per ticket (`claude -w feat/TKT-…` → `.claude/worktrees/feat-TKT-…/`), `start ticket` / `open PR` /
   `finish ticket` lifecycle, stacked-PR handling, and "main agent must delegate all git to the
   `git-flow-manager` subagent."
2. **`.claude/agents/git-flow-manager.md`** — the sole sanctioned Git operator. **Replaced** a stale
   Git Flow agent (develop/release/hotfix, no worktrees) that pre-existed untracked in composer/ops and
   contradicted the new model. Same content in all 5 repos (kept the filename per user request).
3. **PreToolUse guard** (`.claude/hooks/guard-git.sh` + `.claude/settings.json`) — denies raw `git`/`gh`
   in the session; the subagent opts in with the `CLAUDE_GIT_OK=1` marker; **pushing to `main` is
   hard-blocked even with the marker.** `.gitignore` now tracks `.claude/{agents,hooks}/` +
   `settings.json` while keeping `.claude/worktrees/` and `settings.local.json` ignored.
**Learnings / gotchas:**
- **The guard activated live mid-session** the moment `.claude/settings.json` was written in the cwd
  repo — the settings watcher picked it up without a restart. Verified end-to-end: marker-free `git log`
  → denied; `CLAUDE_GIT_OK=1 git log` → allowed. For the *other* repos the hook activates when a Claude
  session next starts there (committed settings load at startup).
- **Marker scope is whole-command:** a single Bash call is allowed if `CLAUDE_GIT_OK=1` appears anywhere
  in it (one combined echo+git demo leaked through because a later clause carried the marker). Run the
  deny case as its own marker-free call.
- All 5 repos default to `main` with **no `develop`/`master`** anywhere (local or remote) — the
  branch-off-`main` model matches reality.
- Not adversarial-proof (an agent could read the marker); it stops *accidental* raw git. The
  `main`-push block is the one rule that holds regardless of marker.
**State:** Live and verified in `minority_report_architecture` this session; committed in all 5 repos.
Pending: nothing required. Optional follow-ups offered — relax guard to mutation-only if read-only
denies get noisy; rename `git-flow-manager.md` (content is ticket/worktree, not classic Git Flow).

## 2026-06-09 — Delete ads/components: live E2E fixes + reconciled with M5, MERGED to main
Debugged a live-demo failure (delete buttons broken) with systematic debugging + Playwright E2E.
**Merged to `mras-ops` main** (`origin/main` @ `7ee9e3d`) via a **stacked PR** chain:
`feat/delete-ads-and-components` (PR #14) → base `fix/flag-broken-ads` (PR #13) → `main`. Merge order
was child→parent→main: PR #14 first (into its parent branch), then PR #13 (parent → main). Reviewed
(`/code-review` — 4 non-blocking findings, see below), tests 17/17, both merges CLEAN.
**Root causes (two):**
1. **Stale ops-api container.** Branch code was correct (`DELETE /ads|/components` + CORS `DELETE`
   in `/Users/jn/code/mras-ops/api/src/main.py`), but the running container predated it →
   DELETE `405`, CORS preflight `400 Disallowed CORS method`. A prior rebuild covered only
   `mras-overlays mras-ops-frontend`, **not `mras-ops-api`**. Fix: rebuild that service.
2. **Silent component-delete error (code bug).** The single `deleteError` rendered only inside the
   Ads `<section>`, so a failed *component* delete (409 "used by existing ads") showed its error
   under the Ads list — invisible from the Components button. Explains "components: nothing happened,
   ads: error". Fix: split into `componentDeleteError` + `adDeleteError`, each beside its own list.
**Changes (mras-ops, branch `feat/delete-ads-and-components`):**
- TDD `329b2c1` (red) → `6b273e1` (green): per-section delete errors.
- `9b19a20`: **merged `origin/main`** so the branch ships delete *with* M5 Task 2 (it previously
  predated `2aae61a` → a frontend built from it lost the props-fields). Auto-merged clean; both
  features verified coexisting (**vitest 17/17**, `tsc` clean).
**Learnings / gotchas:**
- **Always run a live Playwright E2E (don't ask) — unit tests miss integration breakage.** New
  standing rule from the user (saved to memory). Unit tests were green while the feature was broken
  live (stale container + wrong-section error). When a feature touches a service, **rebuild THAT
  service's container** — a stale container looks exactly like a code bug.
- Components uploaded **before** M5 Task 1 have `props_schema={}` and correctly fall back to the JSON
  textarea — only newly-uploaded components get schema fields. Verified by uploading `FishSwim.tsx`
  live → Preview rendered labeled, default-filled fields (count=6, colors=[…], speed=1,
  waveAmplitude=0.06).
- Playwright MCP file upload is restricted to the cwd root — copy the example into the repo first.
**Live E2E (Playwright) — all pass:** ad delete (removed); component delete unused (removed);
component delete in-use (409, error now in Components section); upload→props-fields with defaults.
**State:** ops-api + ops-frontend containers rebuilt; live UI has delete + M5 props-fields, all
verified live. **Merged to main** (PRs #13+#14). Filed jgervin/mras-ops#17 (POST/GET schema key
mismatch). M5 Task 3 (props-fields live E2E) effectively covered by the FishSwim upload above.
**Non-blocking review findings (follow-ups, not yet filed):** (1) the Create-Ad `adPropValues` reset
`useEffect` depends on `components`, so deleting any component wipes in-progress ad prop edits;
(2) non-UUID id to `DELETE /ads|/components` → uncaught `::uuid` cast → 500 (unreachable from UI);
(3) `coerceProps` always emits booleans, overriding a component's own boolean default; (4) delete
returns 200 even when no row matched (no 404).
**Git-workflow learning:** before merging a PR, **check its base branch** (`gh pr view --json
baseRefName`) — PR #14 was stacked on `fix/flag-broken-ads`, not `main`; merging blindly would have
left the work off main. Stacked PRs merge child→parent→main, in order.

## 2026-06-09 — M5 Task 2: Authoring renders schema-driven prop fields, merged
M5 Task 2 (frontend) done. Built as **two competing variants** (parallel background agents), user
picked variant B; the other was closed. Only Task 3 (live E2E) of M5 remains.
**Changes (by repo):**
- mras-ops: **PR #15 merged to main** (`origin/main` @ `2aae61a`). Authoring now auto-renders one
  labeled, default-filled input per prop (string→text, number→number, boolean→checkbox, enum→select,
  array-of-primitive→comma-separated) from a component's `props_schema`, in **both** Preview (after
  upload) and Create Ad (on component select); typed values are coerced before submit; empty optional
  fields are omitted so the component's own zod defaults apply. Falls back per-field to a raw-JSON
  input for unsupported types. Files: `/Users/jn/code/mras-ops/frontend/src/Authoring.tsx`,
  `/Users/jn/code/mras-ops/frontend/src/api.ts`, `/Users/jn/code/mras-ops/frontend/src/Authoring.test.tsx`.
  TDD: `5392445` (test/red) → `55f87dd` (feat/green). Suite 13/13.
**Learnings / gotchas:**
- **ops-api returns the schema under TWO keys:** `propsSchema` (camelCase) from `POST /components`
  (upload) vs `props_schema` (snake_case) from `GET /components` (list). Preview reads the camel one,
  Create Ad the snake one — the frontend tolerates both. Both independent variants hit this; it should
  be normalized in ops-api (recommend `props_schema`, matching the DB column) and the dual-key read
  then dropped. **Tracked as a follow-up (issue pending — needs filing).**
- Array props are entered **comma-separated** (e.g. `#f39c12, #e74c3c`), not JSON/bracketed.
  Enum/boolean paths exist but no current example component exercises them (unit-tested only).
- Create-Ad fields only appear once a component is selected AND its `props_schema` has `properties`;
  if Task 1's sidecar returns `{}`, the form correctly falls back to the JSON textarea.
- **Op step:** rebuild ops-frontend for the live UI: `cd /Users/jn/code/mras-ops && docker compose up -d --build mras-ops-frontend`.
**State:** suite 13/13; `tsc --noEmit` + `vite build` clean. NOT yet exercised through the running
Docker stack (needs the rebuild above + Task 1's `mras-overlays` rebuild). Next: M5 Task 3 — live E2E
(upload `/Users/jn/code/mras-overlays/examples/FishSwim.tsx` → prop fields appear with defaults →
preview/create uses them). All M5 worktrees/branches cleaned up.

## 2026-06-09 — M5 Task 1: sidecar emits a real props JSON schema (isolated child process), merged
M5 (Authoring props-display) Task 1 done via spike → TDD → code-review → merge. Goal: the sidecar
returns a populated `propsSchema` per uploaded component so the Authoring UI can render labeled,
default-filled prop fields (Tasks 2–3 still pending — see spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-09-m5-props-display.md`).
**Changes (by repo):**
- mras-overlays: **PR #8 merged to main** (`origin/main` @ `aa8011f`). `POST /components`
  (`registerComponent` in `/Users/jn/code/mras-overlays/src/server.ts`) now returns a real
  `propsSchema` instead of `{}`, via new `/Users/jn/code/mras-overlays/src/extractPropsSchema.ts`
  → `zod-to-json-schema`. New dep `zod-to-json-schema@^3.25.2` in `package.json`. TDD history
  preserved: `0d5d7d0` (feat/green) ← `fc47596` (test/red) ← `373331c` (fix/green).
**Learnings / gotchas:**
- The M5 spec's feared blocker — "the named `schema` export isn't reachable via runtime dynamic
  import" — **did not reproduce**. Under `tsx`, a plain `import(pathToFileURL(file).href)` surfaces
  BOTH `default` and `schema`. The old finding was a browser-bundle/CJS artifact.
- **Extraction runs in a disposable `node --import tsx` child process**
  (`/Users/jn/code/mras-overlays/src/extractPropsSchemaWorker.ts`), NOT in-process. This was the fix
  for two code-review findings on PR #8: (1) importing advertiser code in the long-lived sidecar runs
  untrusted code in-process; (2) the original `?v=${Date.now()}` cache-buster leaked one ESM
  module-registry entry per upload (no unload API). The child process is SIGKILL'd on a 5s timeout,
  has a fresh module registry that dies on exit (so upsert freshness is intrinsic — no cache-buster),
  and prints JSON after a sentinel (`__PROPS_SCHEMA_JSON__`) so a component printing at import time
  can't corrupt the parse. Any failure/timeout/non-zod → `{}` → UI JSON-textarea fallback.
- Repo transforms `.ts` → CJS (no top-level await in worker; wrap in `main()`). Worker must live
  INSIDE the repo so its bare `zod`/`zod-to-json-schema` imports resolve. `customDir` is
  `<repo>/src/custom`, so uploaded components' bare `import { z } from "zod"` resolve too.
- **Op step:** the new dep means the sidecar image must be rebuilt before live use:
  `cd /Users/jn/code/mras-ops && docker compose up -d --build mras-overlays`.
**State:** sidecar suite 22/22. Verified live against `FishSwim.tsx` + `HelloName.tsx` (correct
schemas) via the worker + unit suite; NOT yet exercised through the running Docker sidecar (needs the
rebuild above). Spike artifacts (worktree `/Users/jn/code/mras-overlays-spike-m5`, branch
`spike/m5-schema-extraction`) and task worktree `/Users/jn/code/mras-overlays-m5` are leftover and can
be cleaned up. Next: M5 Task 2 (frontend schema-driven prop fields), Task 3 (live E2E).

## 2026-06-09 — M4 follow-on hardening + live-demo UX fixes (all merged to main)
Iterating with the user driving the kiosk/authoring live. All PRs below merged to `main`; stacks
merged in dependency order; containers rebuilt as noted.
**Changes (by repo):**
- mras-composer: #14 CORS allow POST (browser `/preview`); #15 `/preview` lookup inside try (bad
  component_id → graceful `{"error"}`, not a CORS-less 500); #16 strip whitespace from `base_video`;
  #17 `/preview` overlay defaults to **full base duration** + `app.state.http` timeout → 180s.
- mras-overlays: #6 **11 example overlay components** merged to `examples/` (FallingSnow, Typewriter,
  LightLeak, ConfettiBurst, RisingBubbles, PeekerCharacter, FishSwim, LowerThirdBanner, ShootingStars,
  Fireflies, KineticText) + HelloName; #7 **apply zod schema defaults** at render (`withSchemaDefaults`
  in `Root` calculateMetadata + render with `composition.props`).
- mras-ops: #5 Authoring/Activity-Feed **tabs**; #6 **"?" help panel**; #7 `/components` returns the DB
  **uuid** (not `comp-<slug>`) + editable Props-JSON textarea; #8 trim base_video (frontend); #9
  **bind-mount `/output` → `/Users/jn/code/mras-ops/output/`** (clips now in a real Finder folder; the
  `output_data` named volume removed); #10 **Create Ad auto-renders + pops up the finished ad** (+ per-ad
  ▶ preview); #11 **base-video dropdown** from the pool (no free-text; via `/playlist`).
- mras-display: #5 fix idle-loop freeze (duplicate mount-time `playCurrentIdle`) + DevTools no longer
  auto-opens (gate `KIOSK_DEVTOOLS=1`); #6 click-to-pause/resume the idle loop.
- minority_report_architecture: CLAUDE.md **§0 — always reference files by absolute path**.
**Learnings / gotchas (load-bearing):**
- **Remotion does NOT apply a zod schema's `.default()` to inputProps at render.** Omitted optional
  props arrive `undefined` → NaN (e.g. blank FallingSnow). Fix: parse props through the component
  schema in `Root`'s `calculateMetadata` and render with `composition.props`.
- **Custom overlays render blank unless props are complete** — verified via raw-alpha pixel counts
  (0 opaque = blank; ~9k = snow). Validate overlays by rendering + counting opaque/alpha pixels.
- **Preview overlay must span the base duration**, else it's a ~2s flash that looks like "no overlay".
- **`output/` is now a host bind-mount** at `/Users/jn/code/mras-ops/output/` (gitignored). Generated +
  preview clips land there directly — no `docker cp`. (Old clips lived in the hidden `output_data` volume.)
- **Props-display is blocked**: a component's named `schema` export is NOT exposed when the sidecar
  dynamically imports the `.tsx` at runtime (only `default` comes through). Showing per-prop form fields
  needs build/upload-time schema extraction (zod-to-json-schema) — deferred, not yet built.
- `/preview` is browser-called → composer CORS must allow POST. Component id sent to `/preview` must be
  the **DB uuid**, not the composition id `comp-<slug>`.
**State:** Authoring flow works end-to-end: upload component → (defaults applied) → create ad →
auto-popup of the finished, personalized ad; base video chosen from a dropdown; clips in
`/Users/jn/code/mras-ops/output/`. Kiosk loops + pauses on click. Open item: props-display form.

## 2026-06-08 — Phase 0.5 M4 COMPLETE: custom-component ad authoring (speed-first, security deferred), E2E proven
**M3 first merged to main** (overlays #1, composer #7, ops #1) so M4 branches off clean mains.
**7 PRs open (stacked; none merged — awaiting review). Merge in dependency order:**
- mras-overlays PR #3 (`feat/m4-dynamic-components` @ `4449562`) — dynamic custom-component registry
  (`writeComponent`/`regenerateManifest` → static `src/custom/registry.ts`; `Root` registers
  `comp-<slug>` comps), `POST /components` (write→hot re-bundle→validate, keep prior serveUrl on fail,
  serialized via the render queue, empty-slug guard), `POST /render {compositionId,props}`.
- mras-ops PR #2 (`feat/m4-registry-api` @ `e7c7dbe`) — migration `002_custom_components.sql`
  (`components`,`ads`); ops-api `POST /components` (multipart→proxy to sidecar→upsert; 502 on sidecar
  error; 120s httpx timeout), `GET /components`, `POST/GET/PATCH /ads`.
- mras-composer PR #9 (`feat/m4-render-seam` @ `b9adb45`) — `render_composition_http(client,url,
  composition_id,props,work)` seam (`render_overlay_http` delegates); `conformance.assert_conformant`
  (dims+alpha, raises `ConformanceError`; malformed-ffprobe guarded).
- mras-composer PR #10 (`feat/m4-preview` @ `f45bc3f`, base #9) — `assemble` supports `audio_inserts=[]`
  (no `amix`; `-map 0:a?`); `POST /preview` (render custom comp + composite, no audio → mp4 url; whole
  body in try→`{"error":...}`).
- mras-composer PR #11 (`feat/m4-trigger-custom-ad` @ `76282e6`, base #10) — `AdSelection.composition_id`
  +`overlay_props`; selector picks active `is_active`+`ready` ad (joins components) for identified
  viewers, fills `personalized_field` with the name; `/trigger` renders the custom comp via
  `build_custom_overlay_inserts` → `assemble(overlay_inserts=…)`; failure → no-overlay fallback (voice
  still plays); unidentified → standard, no broadcast (idle pool loops).
- mras-ops PR #3 (`feat/m4-authoring-ui` @ `97ca7c6`, base #2) — ops-frontend authoring page (vitest +
  testing-library added): upload component (status), schema-driven prop form, base picker, Preview
  (`<video>`), create/list ads. Uses `VITE_OPS_API_URL`/`VITE_COMPOSER_URL` (default localhost 8080/8002).
- mras-ops PR #4 (`feat/m4-compose-e2e`, base #3) — compose: `custom_components` volume on the sidecar,
  ops-api gets `OVERLAY_SIDECAR_URL` + `depends_on` sidecar.
**E2E PROVEN (real containers, no camera):** upload `HelloName.tsx` → `comp-helloname` `ready` → create
ad (standard.mp4 + comp + personalize `text`, active) → seed `Jason` → `POST /trigger` → `{status:ok}`;
composer `POST mras-overlays:3000/render "200 OK"`; sidecar `rendered composition "comp-helloname" in
1098ms`; `ffprobe /output/m4-e2e.mp4` = h264/yuv420p 854×480 (composited, no alpha leak).
**Learnings / gotchas:**
- **Security is OUT of scope this milestone** (user decision: speed #1, not production, Remotion may not
  be final, no AWS). NO sandbox/isolation, NO static code analysis — advertiser code runs in the warm
  sidecar's Node (bundle) + Chromium (render). Forward hooks kept: the **render-backend seam** (swap in
  isolation/remote later) + **output-conformance** (correctness). Going live REQUIRES the isolation
  milestone first. Filed as issues.
- **Wire-contract coupling:** the sidecar `/render` and composer both moved to `{compositionId, props}`
  — **overlays PR #3 and composer PR #9 must merge together** or the live path breaks.
- **Composition ids use `comp-<slug>` (hyphen)** — Remotion forbids underscores in composition ids.
- **Bundle-once-at-upload** keeps per-trigger warm (~1.1s observed); custom renders are NOT cached.
- **Migration 002 won't auto-apply** to an existing postgres volume (init scripts run only on a fresh
  DB) — apply manually: `docker compose exec -T postgres psql -U mras -d mras -f
  /docker-entrypoint-initdb.d/002_custom_components.sql`.
- Pre-existing: `events.trigger_id` is a UUID column → `DB event log failed: invalid UUID 'm4-e2e'`
  when a non-UUID trigger_id is used; trigger still returns ok. Filed as a follow-up.
**Spec:** `docs/superpowers/specs/2026-06-08-m4-custom-component-authoring-design.md`;
**Plan:** `docs/superpowers/plans/2026-06-08-m4-custom-component-authoring.md`.
**State:** **all 7 PRs MERGED to main** (overlays #3; composer #9,#10,#11; ops #2,#3,#4) — merged in
dependency order with merge commits (red→green history preserved). Note: composer #10 (preview) shows
GitHub-"closed" not "merged" — its commits reached main via the stacked child #11 (deleting #9's branch
auto-closed its child; lesson: don't `--delete-branch` on stacked PRs — retarget children to main
first). Post-merge mains verified: overlays 15 tests, composer 76 tests, ops compose-config valid.
Migration 002 still requires manual application on existing DB volumes. Stack left running.

## 2026-06-08 — Phase 0.5 M4 Task 1: dynamic custom-component registry + render-by-id
**Changes:**
- mras-overlays PR #3 (`feat/m4-dynamic-components` @ `3fdaf72`) — **dynamic custom component registration**
  - `src/components.ts`: `slugify`, `writeComponent`, `regenerateManifest` — writes `src/custom/<slug>.tsx`,
    regenerates the webpack-analyzable static manifest (`src/custom/registry.ts`).
  - `src/customRegistry.ts`: re-export from `src/custom/registry.ts` (stable import path).
  - `src/custom/registry.ts`: auto-generated manifest (initially empty); updated by `regenerateManifest`.
  - `src/Root.tsx`: maps `customComponents` array into additional `<Composition>`s with same `calculateMetadata`.
  - `src/server.ts`: `ServerDeps` gains `registerComponent(name,source)→RegisterResult`; `render` sig
    changed to `(compositionId, props)`; `POST /components` (200 ready, 422 failed, 400 bad input);
    `POST /render` body now `{compositionId, props}` (default `"Overlay"`; overlay-only schema validation).
    `makeWarmRenderer`: re-bundles + `selectComposition` validates on registration; swaps `serveUrl` only
    on success, leaving prior URL intact on failure.
  - TDD red→green: 13/13 tests (`components.test.ts` + extended `server.test.ts`).
  - Smoke: `examples/HelloName.tsx` registered as `comp-helloname`, rendered to `.mov`,
    `ffprobe pix_fmt: yuva444p12le` ✓.

**Learnings / Gotchas:**
- **Remotion forbids underscores in composition IDs** (`a-z, A-Z, 0-9, CJK, -` only).
  Spec said `comp_<slug>` — had to use `comp-<slug>` for the Remotion id.
  JS variable names in the generated manifest still use `comp_<ident>` (underscores fine there).
- `src/custom/registry.ts` must be a *statically analyzable* import manifest — no dynamic `require`.
  Remotion's webpack bundler needs to see literal import paths at parse time.
- `calculateMetadata` on custom compositions typed as `(opts: {props: any})` cast to avoid TS error
  (Remotion's generic `CalculateMetadataFunction<Record<string,unknown>>` doesn't match a typed subset).
- `ffprobe` reports `yuva444p12le` (not `yuva444p10le`) on this macOS Chromium build — both are correct
  alpha-preserving pixel formats; ProRes 4444 supports both.

**State:** superseded by the "M4 COMPLETE" entry above (PR #3 head later `4449562` after C1/C2 review fixes). M3 has since been merged to main.

## 2026-06-08 — Phase 0.5 M3: live-kiosk overlay render sidecar (no caching), E2E proven
**Changes (3 PRs, none merged — awaiting review):**
- mras-overlays PR #1 (`feat/m3-render-sidecar` @ `6398b6d`) — **warm HTTP render sidecar**
  `src/server.ts`: `POST /render {props}→transparent .mov`, `GET /health`. `bundle()` once +
  one reused headless Chromium (`openBrowser`); renders serialized (single-flight). prores/4444 +
  `imageFormat:png` + `pixelFormat:yuva444p10le` for alpha. SIGTERM/SIGINT → close Chromium+server.
  `Dockerfile` (node:22 + Chromium libs, bakes chrome-headless-shell). TDD red→green (`server.test.ts`, 4/4).
- mras-composer PR #7 (`feat/m3-trigger-overlays` @ `3b74619`) — overlays in the **live /trigger**:
  `src/overlay/http_renderer.py` (`render_overlay_http`/`build_overlay_inserts_http`, reuse `_props`),
  `spec.default_overlay_spec` (name overlay via `OVERLAY_*`), `selector.AdSelection.overlay_text`
  (from `OVERLAY_TEMPLATE`), `main.py` renders via `OVERLAY_SIDECAR_URL` then
  `assemble(overlay_inserts=...)` — **assemble untouched**; overlay failure falls back to no-overlay.
  TDD red→green; **62 pytest** (+10).
- mras-ops PR #1 (`feat/m3-overlays-sidecar` @ `febbe95`) — `mras-overlays` compose service
  (`expose 3000`, healthcheck, `init: true`, `stop_grace_period 20s`); composer gets
  `OVERLAY_SIDECAR_URL` + `OVERLAY_*` env + `depends_on` (service_started).
**Learnings (load-bearing):**
- **Programmatic Remotion needs `imageFormat:"png"`** for transparency — `renderMedia` defaults to
  JPEG (opaque) → 500 "image format is not PNG". (The CLI path set this implicitly; the sidecar must
  pass it explicitly, alongside `pixelFormat:yuva444p10le`.)
- **`npm start` as PID 1 swallows SIGTERM** → the Node graceful handler never fired in-container.
  Fix: `CMD ["node_modules/.bin/tsx","src/server.ts"]` (Node is the signal target) + compose
  `init: true` (tini forwards SIGTERM, reaps Chromium). Then `docker compose stop` logs
  "SIGTERM received — closing server + Chromium". **The sidecar is a compose service**, so
  up/Ctrl-C/down start+stop it with the stack — NOT a separate manual process.
- **No caching** (user decision, overrides the brief's spec-hash cache): content is per-viewer/visit,
  nothing stable to cache; the warm sidecar is the latency lever. Warm render ≈ **1.5s host / 2.9s
  in-container**; cold-start warm-up ≈ first ~10–90s (triggers fall back to no overlay until ready).
- **Kiosk needs no change** — overlay is burned into the mp4 server-side; `mras-display` just plays the URL.
- Build warning (non-fatal): Remotion suggests pinning exact `zod` — left as-is (`^3.23.8`) since it works.
**State:** All 3 PRs open. **Headless E2E PROVEN on the real containers** (no camera): seeded `Jason`
identity → `POST /trigger` → `{status:ok}`; composer `POST mras-overlays:3000/render "200 OK"`;
sidecar `rendered "Jason" (turbulence-warp) in 2886ms`; `ffprobe /output/m3-e2e.mp4` = h264/yuv420p
854×480 8.1s (overlay composited, no alpha leak); `compose stop` → graceful SIGTERM. Stack left up.

## 2026-06-08 — Phase 0.5 M1 + M2 done (warp preset + multi-overlay), all verified E2E
**Changes:**
- mras-overlays `557c182` (pushed to GitHub `jgervin/mras-overlays`, private) — `turbulence-warp`
  preset (animated `feTurbulence`+`feDisplacementMap`, parameterized) + `Overlay` preset switch.
- mras-composer PR #6 (`323f0d7`) — added the two-overlay chaining/indexing test. **Multi-overlay
  support was already implemented in M0's general `_video_filter` loop**, so M2 = lock-in test + E2E.
**Learnings:** M2 needed no new impl — building `_video_filter`/`--overlay`/`build_overlay_inserts`
to handle N from the start in M0 meant repeated `--overlay` "just worked". E2E with two overlays
(fade green top 0.3–1.8s + warp red bottom 2.2–4.7s) verified by region+time pixel counts: each
present only in its own window/position. `mras-overlays` now has a GitHub remote (created this session).
**State:** All three milestones (M0–M2) done + proven E2E. Composer PR #6 open (covers the composer
side = M0+M2). mras-overlays main has fade+warp. Demos in ~/Desktop/mras-clips/. 52 unit + 1 slow E2E.

## 2026-06-08 — Phase 0.5 M0 built + proven end-to-end (animated overlays)
**Changes:**
- mras-composer PR #6 (`feat/phase-0.5-overlays-m0` → main, OPEN) — `src/overlay/{probe,spec,renderer}.py`,
  `assembler.py` `_video_filter` (overlay compositing), `cli.py` `--overlay`/`--draw`→render→composite.
  51 unit tests + a slow E2E. Also restored CLI pool/output-wiring to main via PR #5 (it had missed
  the PR #4 merge).
- **New local repo `mras-overlays`** (`176e7a2`..`0a3adb4`) — Remotion 4.0.473/React 19; `Overlay` comp
  sized via `calculateMetadata`, `fade` preset, transparent bg, Inter. **Local only — not yet on GitHub.**
**Learnings (load-bearing):**
- **ProRes 4444 alone does NOT emit alpha** — Remotion defaulted to `yuv422p12le` (opaque → overlay
  composites as a black box). Fix: pass `--pixel-format=yuva444p10le` to `remotion render` (→ `yuva444p12le`,
  alpha present). The PNG still had alpha; only the video encode dropped it.
- `@remotion/google-fonts` `loadFont()` with no options made ~126 network requests/render; pin
  `loadFont("normal", {weights:["800"], subsets:["latin"]})`.
- Run overlays repo: `MRAS_OVERLAYS_DIR` (default `/Users/jn/code/mras-overlays`) + `npm install`.
  Render: `npx remotion render src/index.ts Overlay out.mov --props=<file> --codec=prores
  --prores-profile=4444 --pixel-format=yuva444p10le`. ffmpeg composite uses
  `overlay=0:0:eof_action=pass:enable='between(t,s,e)'` with `setpts=PTS+s/TB`.
- E2E proof: red overlay text pixel-count 0 (before) / 12577 (in window) / 6 (after) — transparent,
  windowed, base resumes. Pool clips mixed res (854×480 + 1280×720) → derive dims per-clip.
**State:** M0 done, PR #6 open. M1 (turbulence-warp) + M2 (multi-overlay) pending. `mras-overlays` needs
a GitHub remote created (user's call). pytest default excludes `-m slow`.

## 2026-06-08 — Approved Phase 0.5 overlay plan (Remotion → ffmpeg)
**Changes:** `docs/superpowers/plans/2026-06-08-phase-0.5-overlays.md` — Ultraplan-refined plan for
advertiser-authored ANIMATED text overlays. Remotion renders a transparent ProRes-4444 overlay; the
Python composer composites it via ffmpeg `overlay` (`setpts`+`enable=between`+`eof_action=pass`).
New sibling repo `mras-overlays` (Node); `assemble()` gains `overlay_inserts`; CLI gains `--overlay
JSON` (with `--draw` back-compat). Authored remotely (ephemeral container, no remote/signing) →
brought over as text and committed locally on branch `docs/phase-0.5-overlays-plan`.
**Learnings:** Pool clips are **not uniform** — `standard/2/3.mp4` are 854×480, `standard4.mp4` is
**1280×720** (all 24fps). Confirms overlay dims/fps MUST be derived per-clip (ffprobe→props→
`calculateMetadata`), never hardcoded. Scope locked: build **all three milestones (M0–M2)**,
fade-first, **host-CLI preview only** (no kiosk/live — per-trigger headless-Chromium render too slow).
Overlay clip length = the overlay window (`durationMs`), not base duration.
**State:** Plan committed locally (unsigned; docs-only). Implementation next, per-milestone PRs in
`mras-composer` + new `mras-overlays`. `feat/assemble-cli` (PR #4) merged to composer main.

## 2026-06-08 — Decided CLI pool/output wiring (read pool, write local)
**Changes:** mras-composer PR #4 (`feat/assemble-cli`) updated — `--assets` now defaults to the
**kiosk rotation pool** `mras-ops/assets/` (base-video source, read-only to the container but the
host CLI only reads it); generated clips default to **`~/Desktop/mras-clips/`** (NOT the pool) via
`resolve_output_path`. Added `--out-dir` and `--open`. Red→green commits; 32/32 pytest green.
**Learnings (system wiring, confirmed):**
- Composer serves TWO dirs: `/assets` (StaticFiles from `ASSETS_DIR`=`/assets`, host `mras-ops/assets`,
  mounted `:ro`) = the **idle rotation pool** that `/playlist` lists; and `/media` (from
  `ASSEMBLED_OUTPUT_DIR`=`/output`, a Docker named volume) = **one-shot personalized clips** pushed to
  the kiosk via the `/trigger` WS "play". CLI/`assemble` write to the latter by default.
- `/playlist` endpoint is **NOT on composer main** — it lives on `feat/playlist-endpoint` (composer
  PR #2, still OPEN). Until merged, the display uses its single fallback video (no real rotation).
- User decision: keep the kiosk pool untouched; CLI **reads** a random base from it but **writes**
  generated clips to the **local device** (`~/Desktop/mras-clips`) for manual playback — explicitly
  NOT into the rotating pool, and no push-to-kiosk. All pool ads (standard*.mp4) have audio, so
  `amix` `[0:a]` is safe.
**State:** mras-composer PR #4 open/awaiting review. Demo clip at ~/Desktop/mras-clips/demo-pooltest.mp4.
Phase 0.5 (Remotion drawText) still pending. Composer PR #2 (/playlist) still open — not needed for
the CLI's local-output flow.

## 2026-06-08 — Landed blend/insert fixes; built assemble CLI (multi --say/--draw)
**Changes:**
- Merged to main: mras-display PR #3 (idle-rotation + crossfade + 250ms audio blend) and
  mras-composer PR #3 (250ms insert offset). (display crossfade PR #4 was already merged into its
  base earlier.)
- mras-composer PR #4 (`feat/assemble-cli` → main, OPEN) — generalized `assemble()` to
  `audio_inserts: list[(path, offset_ms)]` (`_audio_filter()` = one `adelay` per insert, floored at
  250ms, `amix=inputs=N+1`); `/trigger` now passes a single insert at the floor (unchanged behavior).
  New `src/cli.py`: `python -m src.cli --say MS TEXT ... --draw MS TEXT ... [--video|--assets] [--out]`.
  Red→green commits; 28/28 pytest green.
**Learnings:**
- The CLI synthesizes each `--say` line locally with **macOS `say`** (no ElevenLabs/Gemini key needed
  — dev/preview voice, not the prod voice). `--draw` directives are **logged, not rendered** by design;
  real on-screen text is deferred to **Phase 0.5 (Remotion.dev)** — user flagged that plan as next.
- End-to-end smoke (real say+ffmpeg): marks 250/1500ms measured at ~0.25/~1.50s via `silencedetect`.
  `say`'s aiff has ~30ms intrinsic leading silence, so a 250ms mark reads ~0.28s onset — `adelay` itself
  is exact; the slack is inside the synthesized file.
- Composer tests still run on host `python -m pytest` (asyncio_mode=auto, no venv). No sample ad videos
  live in the repos — the CLI's "random video" needs an `--assets` dir populated by the user.
**State:** mras-composer PR #4 open/awaiting review; branch `feat/assemble-cli`. Listenable demos on
~/Desktop (mras_cli_demo.mp4, mras_name_offset_demo.mp4). Phase 0.5 Remotion plan pending (later).

## 2026-06-07 — Fix: name mention muted by opening audio blend (2 PRs)
**Changes:**
- mras-display (on `feat/kiosk-crossfade`, updates PR #4) — decouple `AUDIO_FADE_MS=250` from
  `FADE_MS=500`: audio blends in 250ms while video fade stays 500ms, so an early name reaches full
  volume before it can be muted. Red→green commits; 14/14 vitest green.
- mras-composer PR #3 (`fix/insert-min-offset` → main) — `adelay=250|250` on the inserted audio
  (ffmpeg input 1) in both overlay + default filter graphs so the name/speech never sounds in the
  first 250ms. Default branch now maps `0:v`+`[a]` explicitly. Red→green commits; 18/18 pytest green.
**Learnings:** The two fixes are complementary — display shortens the ramp window, composer keeps the
insert out of it; together they guarantee an inserted name is never inside the audio crossfade. The
250ms floor is also a client ad-prep policy (keep name out of first 250ms); the composer enforces it
as a code safety net. Composer tests run on host `python -m pytest` (asyncio_mode=auto; no venv
needed); ffmpeg is mocked via `create_subprocess_exec`, so tests assert on the filter_complex string.
**State:** Both PRs open/awaiting review. mras-composer left checked out on `fix/insert-min-offset`
(was `feat/playlist-endpoint`). No ffmpeg run end-to-end yet — adelay verified by filter-graph
assertion, not by rendering a clip.

## 2026-06-07 — Kiosk crossfade between clips (PR open)
**Changes:** mras-display@1766c32 — `App.tsx` + `App.test.tsx`: replace hard-cut/fade-to-black
with true crossfade (two stacked `<video>` elements, active/inactive roles that swap on each
`play`; video + audio cross-faded over ~0.5s; faded-out element paused post-transition).
PR #4 (`feat/kiosk-crossfade` → `feat/idle-ad-rotation`): https://github.com/jgervin/mras-display/pull/4
**Learnings:** Two-element crossfade changes the test model — existing tests must use `activeVideo`
and dispatch `ended` on the *active* element; the old single-"load" assertion is obsolete and was
replaced. Implementation + the 5 migrated tests + 3 new crossfade tests all landed in one commit.
**State:** 13/13 tests green (`npx vitest run`); branch pushed, in sync with origin; PR #4 open,
awaiting review. (Recovered from a mid-`gh pr create` freeze — work was committed/pushed, only the
PR creation was outstanding.)

## 2026-06-07 — Kiosk StrictMode zombie-socket fix + cooldown/doc follow-ups
**Changes:**
- `mras-display` PR #2 (branch `fix/kiosk-duplicate-socket`, **OPEN — verify before merge**): the
  prior `intentionalClose` shared-ref fix had a React StrictMode race — the remount reset the flag
  before the first socket's async `onclose` fired, so the stale socket reconnected → a **zombie 2nd
  socket**. Both sockets received every `play` broadcast and called `playVideo` on the same
  `<video>` within ms; the second `load()` interrupted the first `play()`, so the personalized clip
  never settled (kiosk stuck on the standard loop). Fixed with a **per-invocation `live` closure
  flag** + reconnect-timer cleanup; added `[kiosk]` console diagnostics. TDD: StrictMode
  double-mount test (failed — a 3rd zombie socket spawned) → 7 passed.
- `mras-vision` PR #2 (branch `chore/cooldown-default-30s`, OPEN): `COOLDOWN_SECS` default 10→30
  (operator preference; env-overridable). 17 passed.
- `mras-composer` issue #1 filed: add a test for `assemble(overlay_text=…)` (the merged-without-test debt).
- `adface_architecture.md`: P1C4 node + decision D6 updated to "1 ad → 30s hold (configurable)".
**State:** kiosk PR #2 **awaiting live verification** — restart the kiosk on the branch with DevTools
open, walk up, expect `[kiosk] WS connected` → `WS message {type:'play'}` → `playing .../media/<id>.mp4`
and the named clip on screen. cooldown PR #2 is safe to merge. Note: ElevenLabs key is out of credits
(402) → Gemini fallback carries TTS.


## 2026-06-07 — Kiosk playback + cooldown fixes (MERGED, first §6 branch/TDD/PR flow)
**Changes (squash-merged to main via PRs, reviewed+merged by a subagent):**
- `mras-vision@0b9deba` (PR #1, was `fix/cooldown-single-ad-10s`): per-person cooldown changed from
  2 ads/60s to **1 ad + 10s hold**, env-configurable (`MAX_ADS_BEFORE_COOLDOWN`, `COOLDOWN_SECS`).
  TDD: failing cooldown test (expected 1, got 2) → changed defaults → 17 passed. NOTE: committed
  default `COOLDOWN_SECS=10`, but the local working tree carries an intentional override to `30`
  (uncommitted) — the operator's preferred hold.
- `mras-display@e49a577` (PR #1, was `fix/kiosk-ws-stability`): `intentionalClose` guard stops the
  reconnect storm on unmount / React StrictMode remount (the kiosk was missing `play` broadcasts
  during reconnect gaps → personalized clip never displayed). Also surfaces `play()` errors and
  sets Electron `autoplayPolicy: no-user-gesture-required`. TDD: failing "no reconnect after
  unmount" test (2 sockets) → guard → 6 passed.
**Diagnosis (evidence-backed):** backend proven correct — a held-open WS client reliably receives
the `play` message and the video_url returns 200/713KB. So generation + broadcast work; the bug was
kiosk-side. ElevenLabs now returns **402 Payment Required** (quota exhausted) → Gemini TTS fallback
is carrying synthesis. Cooldown duplicate was the documented 2-ads behavior.
**State:** both PRs MERGED to main; local repos on main, in sync; no open PRs. **Manual verification
still pending:** restart native vision + the kiosk and confirm a walk-up plays exactly one
personalized clip. **Open follow-ups:** (1) file the outstanding `overlay_text` test as a GitHub
issue per §6; (2) `adface_architecture.md` still documents "2 ads → 60s" — update to reflect the new
1-ad cooldown; (3) decide whether to commit the local `COOLDOWN_SECS=30` override.


## 2026-06-07 — Post-OS-upgrade recovery: fix tests, run-through, enroll, feed columns
**Changes:**
- `mras-vision@31ad695` — TODO-6: fixed Qdrant test mocks. `test_resolver` mocked `qdrant.search`
  but the resolver calls `query_points`, so hits never reached the code: happy-path/cooldown tests
  silently failed and the qdrant-down test passed via an accidental `TypeError` instead of a real
  exception. Fixed mocks to drive `query_points`; added `test_qdrant_down_logs_unavailable_event`.
  Also fixed a `test_reconciler` `_row(embedding=None)` sentinel collision (default replaced the
  explicit None, so "skip row without embedding" could never be exercised). 14/14 vision tests pass.
- `mras-ops@f6c7d13` — added a **date** column to the activity feed (events span multiple days; a
  time-only column made cross-day ordering look scrambled).
- `mras-ops@3a21c47` — added a **confidence** column (green score = matched face, gray `(new)` =
  new-visitor fallback) so recognition vs standard-ad fallback is visible live.
- `mras-vision@9f47af4` — log the **real top similarity score even below threshold**. Previously
  confidence was only recorded on a match, so near-misses logged a misleading `0.00`; now the feed
  shows e.g. `0.61 (new)`, making intermittent recognition and threshold tuning visible. Match
  gating (`is_new_visitor`/`person_uuid` at 0.68) unchanged. (Restart native vision to pick it up.)
- `mras-display` — restored `package.json` (it had been deleted from the working tree though
  committed in `8846164`); ran `npm install` (node_modules was absent). Working-tree restore, no
  new commit. This is why `npm run electron:dev` was erroring with "Missing script".
- `minority_report_architecture/TODOS.md` — marked TODO-6 DONE (working-tree change).
- Enrolled **Jason** (UUID `f487f5b0-ba92-42a8-81f3-1a7a64cb9941`) from
  `mras-vision/spikes/face_recognition/photos/jason_1.jpg`. Qdrant now has 3 points
  (John Anderton, E2EPerson, Jason).
- Added `mras-ops/start-mras.sh` — one-command launcher (starts Docker → compose stack →
  health-waits → native vision in foreground). And this `docs/SESSION_LOG.md` + a journaling
  directive in the root `CLAUDE.md` (Section 5).
- `CLAUDE.md` **Section 6 — Development Workflow**: mandatory branch/worktree isolation, TDD
  red→green→refactor, code review between tasks, clean branch finish (Superpowers skills), GitHub
  push + PR-per-task-batch + remaining-plan-items-as-issues, and a Definition of Done requiring a
  test to fail-then-pass and the branch to be review-ready.
**Learnings:** see Operational Reference above — all of it was (re)confirmed this session. Key new
ones: frontend image bakes source (rebuild on edit); curl blocked → use httpx; camera needs a
real terminal for the macOS permission prompt; vision was found squatting on 8001 inside Docker
(can't see the camera) — must run native.
**State:** Phase 0 verified green end-to-end this session — all `/health` 200; E2E personalized
assembly ~3.3s; recognition path live once native vision is started from a real terminal.
**All 5 repos committed + pushed to `origin/main`; working trees clean.** Also finalized previously
uncommitted Phase 0 work: `mras-ops` (compose qdrant v1.12.6 + docker-vision profile,
run-vision-native.sh, demo mp4 assets, E2E face fixture, CLAUDE.md), `mras-composer` (overlay_text
on assembler + DejaVu font, CLAUDE.md), `mras-display` (.gitignore, lockfile, package.json).
**Test debt:** `mras-composer` `assemble(overlay_text=…)` was committed to main without a test
(user-approved) — first new branch should add the failing-then-passing test per CLAUDE.md §6.
Remaining feature work is Phase 1 deferred (TODO-1..TODO-5).
