# God View Fleet Management — Design Spec (TODO-12)

**Status:** SPEC — plans for Phases 1–2 in `docs/superpowers/plans/2026-07-08-fleet-plan-{a-ops,b-ui}.md`;
Phases 3–4 are specified here but deliberately planned later (after P1/P2 owner review).
**Scope:** mras-ops (registry read/write API) + godview-prototype (Fleet page). No vision/composer changes.

---

## 1. Goal (owner's words, 2026-07-08)

> "Some page where you can get to a list of all locations, and groups. This is where we might do all
> CRUD ops for device (camera, screen/kiosk, etc), a group, a location, etc. Here we might set or
> alter several attributes for each object type (CRUD)."

Distinct from the planned globe/map view. Replaces today's raw-SQL + curl admin reality (the only
write endpoint in the registry is `PATCH /cameras/{id}`).

## 2. External-system grounding (patterns deliberately imported)

| Pattern | Source systems | How it lands here |
|---|---|---|
| **Spec vs status** on every object | Kubernetes | Admin-editable *config* strictly separated from runtime *state* (`last_seen_at`, duty, health). API writes touch config only; state is read-only and rendered separately. TODO-8 already proved this split (desired role vs effective duty). |
| **Lifecycle, never delete** | ServiceNow CMDB / ITAM | No hard DELETE for registry objects. `retired` is the terminal state; history and audit stay coherent forever. |
| **Adoption of seen-but-unregistered devices** | UniFi/Meraki controllers | `unresolved_devices` (3 live rows today: kiosks whose screen_ids appeared in playbacks) get an "adopt" action that creates the proper `displays` row pre-filled. |
| **Identity anchor separate from function** | CMDB CI classes, MDM | `devices.serial_number`/`external_device_key` + `cameras.device_id`/`displays.device_id` are the immutable identity spine; names are labels, roles are config. |
| **Containment guardrails** | Kubernetes finalizers, AD OUs | Cannot retire an object with active children — 409 with the blocking children listed. No cascade in v1. |
| **Controlled re-parenting** | Active Directory | Moving a device between screen_groups (same system) is a config edit; cross-system/location moves are deferred (identity-adjacent, breaks history semantics). |
| **Declarative writes converge** | K8s / UniFi | Registry is admin truth; runtimes poll and converge (TODO-8 cameras already do — role changes apply within one poll tick, no push channel needed). |

## 3. Current reality (verified 2026-07-08)

- **Hierarchy tables (21-table clean-slate schema):** `organizations` (tree via
  `parent_organization_id`; `organization_type`: platform_operator/host/advertiser/…) →
  `locations` (tree via `parent_location_id`; 13-value `location_type` from country down to
  zone/area; geo lat/lng/timezone) → `systems` (org+location FK, zone/floor/geo, `config` jsonb) →
  `screen_groups` (system+location, `group_type`: zone/ad_cluster/custom, `metadata` jsonb) →
  `cameras` / `displays` (system, optional screen_group, `device_id` → `devices` identity row,
  `screen_id` wire key, `calibration` jsonb, `last_seen_at`).
- **Status enums:** `lifecycle_status` (planned/active/inactive/degraded/offline/retired) on
  orgs/locations/systems/screen_groups; `device_status` (active/degraded/offline/retired) on
  cameras/displays/devices.
- **API surface today:** the ONLY registry write is `PATCH /cameras/{camera_id}` (role/status/
  failover_eligible; strict pydantic `extra="forbid"`; identity rejected; `camera_admin` journal
  event in-transaction). Reads: God View endpoints (keyset, server-side counts). Creative-domain
  endpoints (`/ads`, `/components`) have POST/PATCH/DELETE — different domain, untouched.
- **UI today:** God View renders systems → groups → devices (with role/failover_eligible/duty)
  read-only. Established idioms: fetchers in `api.ts`, payload types, selectors keep view logic,
  `usePolling`/`AsyncState`, keyset "Load more".
- **`unresolved_devices`:** `{screen_id, kind, event_id, first/last_seen_at, seen_count}` with
  `UNIQUE(screen_id, kind)` — populated by the projector when playbacks reference unregistered
  screen_ids; surfaced today only as a count banner.
- **`screen_id` is GLOBALLY UNIQUE** (migration 020) across cameras and displays respectively —
  creating/adopting a device with a duplicate screen_id is a 409, not just an immutability rule.

## 4. Decisions (locked; conservative now, growth-shaped)

1. **Spec-vs-status split everywhere.** Every object's payload carries `config` (editable) and
   `state` (read-only: `last_seen_at`, effective duty for cameras, health rollups later). Write
   endpoints accept config fields only; state fields in a write body are schema-rejected
   (`extra="forbid"` — the `CameraPatch` precedent).
2. **Three field classes per object type** (the per-type matrix in §5.1 is the contract):
   **IDENTITY** — immutable via API forever: `id`, `device_id`, `serial_number`,
   `external_device_key`, `screen_id` (the wire key kiosks/vision report — changing it would
   silently orphan history), parent `system_id`/`location_id`/`organization_id` in v1.
   **CONFIG** — editable, journaled: `name` (a label — admin renames are legitimate device
   management and are journaled; *automation never renames*, preserving TODO-8's invariant),
   roles, `screen_group_id` (same-system only), geo/zone/floor/timezone, type enums,
   `failover_eligible`, jsonb blobs (see D12).
   **STATE** — read-only: `last_seen_at`, effective duty, `seen_count`, timestamps.
3. **Lifecycle transitions instead of free status writes.** `status` changes go through the same
   PATCH but are validated against an allowed-transition matrix (e.g. `retired` is terminal —
   nothing leaves it; `planned→active`, `active↔offline/degraded/inactive`, `*→retired`). Invalid
   transition ⇒ 409 with the allowed set. Keeps the door open for transition side-effects later.
4. **No hard DELETE in v1 for any registry object.** No DELETE routes are created. "Remove" in the
   UI = retire (with guardrails). Rationale: journal history references these rows; CMDB practice;
   reversibility. (Creative-domain DELETEs that already exist are out of scope.)
5. **Retire guardrails (containment):** retiring an object with non-retired children is rejected
   with 409 + the first N blocking children (`{type, id, name, status}`). Order of operations is
   explicit: retire/reassign children first. No cascade in v1 (growth: an explicit
   `?cascade=plan` dry-run later).
6. **Re-parenting rules:** `screen_group_id` of a camera/display is editable but the target group
   MUST belong to the same `system_id` (422 otherwise). Cross-system/location moves deferred.
7. **Creation defaults are staged, not live:** new lifecycle-status objects (org/location/system/
   group) start `planned`; new devices (device_status has no `planned`) start **`offline`** —
   visible in the Fleet page but not yet a live participant (the fleet launcher and the TODO-8
   peer query select `active` only). Going live is an explicit lifecycle transition. This mirrors
   staged provisioning in UniFi/MDM and prevents a half-configured camera from being launched or
   counted as a failover peer.
8. **Creating a camera/display also creates its `devices` identity row** (same transaction) when
   `device_id` is not supplied; `serial_number`/`external_device_key` optional at birth, settable
   ONCE while NULL, immutable after (identity hardening, CMDB-style).
9. **API style — extend the existing flat resource routes, no new namespace:**
   `GET/POST /cameras`, `/displays`, `/screen-groups`, `/systems`, `/locations`, `/organizations`;
   `PATCH /{type}/{id}` each. The existing `PATCH /cameras/{camera_id}` contract is preserved
   exactly (its fields become a subset of the camera config PATCH). GET lists are parent-scoped
   (`?location_id=`, `?system_id=`, `?screen_group_id=`) and keyset-paginated (name-keyed cursor,
   the God View systems precedent) with `counts` blocks — never unbounded.
10. **Audit: one generic `registry_admin` journal event** for all new write endpoints:
    `{object_type, object_id, action: create|update|lifecycle|adopt, changes:{field:{from,to}}}`,
    emitted in the same transaction as the write (the `camera_admin` template). Cameras keep
    emitting `camera_admin` for the existing three fields (established consumer contract);
    documented as the one legacy exception, consolidation is a follow-up. A partial expression
    index on `((payload->>'object_id'), id DESC) WHERE event_type='registry_admin'` (migration)
    serves per-object audit trails, same pattern as `events_camera_duty_idx`.
11. **Adopt-unresolved flow (droppable growth item, P2):** `GET /unresolved-devices` (list) and
    `POST /displays/adopt` `{unresolved_id, system_id, name?, screen_group_id?}` → creates the
    display with the unresolved row's `screen_id` pre-filled (status `offline`), deletes the
    unresolved row, journals `action: adopt`. Kills the "3 playbacks reference an unregistered
    screen_id" banner the right way.
12. **jsonb blobs (`metadata`/`config`/`calibration`) are editable as raw JSON** behind an
    "Advanced" disclosure in the UI, validated only as parseable JSON in v1. Typed schemas per
    blob are a growth seam, not a v1 blocker. Exception: `calibration.cam_index` gets a dedicated
    typed field in the camera form (it's operationally load-bearing for the fleet launcher).
13. **UI shape:** one new God View page ("Fleet") using existing idioms — no new framework. Left:
    lazy hierarchy browser (locations tree → systems → groups+devices), each level a bounded,
    keyset-paginated fetch. Right: object detail with three sections — **Config** (form; submit →
    PATCH → refetch; no optimistic updates), **State** (read-only, polled), **History** (latest 20
    `registry_admin`/`camera_admin`/`camera_duty` events for the object). Create/adopt via
    explicit buttons per level. Every API validation error surfaces field-level in the form.
14. **Auth stays out of scope** (single-operator dev posture, consistent with all admin endpoints).
    The API shape reserves the seam: all writes already journal actor `service`; the schema's
    `participant_role`/`role_label` enums are the future RBAC hook. Production gate documented.
15. **Runtime convergence is by polling, never push:** camera config changes apply within one
    TODO-8 poll tick; display/kiosk config consumption is whatever the kiosk already does (no new
    push channel). The Fleet page sets admin truth and shows runtime truth — it never pretends a
    write is instantly live.

## 5. Design

### 5.1 Field-class matrix (the API contract per type)

| Type | IDENTITY (immutable) | CONFIG (PATCHable) | STATE (read-only) |
|---|---|---|---|
| organization | id, parent_organization_id | name, organization_type, metadata, status* | created/updated_at |
| location | id, parent_location_id | name, location_type, country/region/state/city/address, lat/lng, timezone, metadata, status* | created/updated_at |
| system | id, organization_id, location_id | name, system_type, zone, floor, lat/lng, timezone, config, status* | created/updated_at |
| screen_group | id, system_id, location_id | name, group_type, metadata, status* | created/updated_at |
| camera | id, device_id, system_id, location_id, screen_id | name, camera_role, failover_eligible, screen_group_id (same-system), stream_url, calibration (incl. typed cam_index), status* | last_seen_at, effective duty |
| display | id, device_id, system_id, location_id, screen_id | name, display_role, screen_group_id (same-system), resolution_width/height, calibration, status* | last_seen_at |
| device (identity row) | id, device_type, **system_id** (NOT NULL in schema); serial_number/external_device_key once set | name (NOT NULL — creation derives a fallback from screen_id/device_type when omitted), zone/floor/lat/lng, metadata, status* | last_seen_at |

`status*` = via the lifecycle-transition validation (D3), not free-form.

### 5.2 Endpoints (Phases 1–2 planned now; 3–4 spec-only)

**P1 (read):** `GET /locations` (tree level: `?parent_location_id=`|`root`), `GET /systems?location_id=`,
`GET /screen-groups?system_id=`, `GET /cameras?system_id=|screen_group_id=`,
`GET /displays?system_id=|screen_group_id=`, `GET /organizations`, `GET /{type}/{id}` details
(config+state), `GET /registry/audit?object_id=` (latest N via the new index),
`GET /unresolved-devices`. All keyset + counts.
**P2 (device writes):** `POST /cameras`, `POST /displays` (D7/D8 semantics), `PATCH /cameras/{id}`
(existing route extended additively to full camera config per §5.1), `PATCH /displays/{id}`,
lifecycle transitions via the same PATCH (D3), `POST /displays/adopt` (D11, droppable).
**P3 (groups):** `POST/PATCH /screen-groups`, membership = device `screen_group_id` PATCHes (already
in P2); retire guardrail (no non-retired members).
**P4 (containers):** `POST/PATCH /locations`, `/systems`, `/organizations`; retire guardrails down
the tree; tree re-parenting stays deferred.

### 5.3 Phasing & shippability

Each phase is independently shippable and reviewable. P1 alone already replaces "psql to see what
exists". P2 alone turns the TODO-8 owner steps (register camera, cam_index, failover_eligible) into
buttons. Plans are written for **P1+P2 only**; P3/P4 get plans after the owner has used P1/P2
(their shape may change with feedback — writing literal-code plans for them now would be waste).

## 6. Scale posture

Every list is parent-scoped + keyset-paginated (no unbounded fetch anywhere, including the tree —
each level loads on expand). Counts are server-side GROUP BY. Audit trails are latest-N via a
partial expression index (never a journal scan). The UI virtualizes nothing in v1 (bounded pages
make it unnecessary) but the payload contracts don't preclude it. Holds at the God View target
(200k+ event rows, thousands of devices) by construction.

## 7. Risks / failure modes

- **Config drift illusion:** an admin edits a camera while its process is down — the page must not
  imply the change is live. Mitigation: State panel shows `last_seen_at` + duty staleness
  prominently next to Config.
- **Guardrail deadlocks** (can't retire A because of B, can't retire B because of C): mitigated by
  the 409 listing the exact blockers; acceptable at current fleet sizes.
- **jsonb foot-guns:** raw JSON editing can store nonsense; v1 accepts this (parse-validated only,
  Advanced-gated, journaled so reversible by hand). Typed schemas are the follow-up.
- **`screen_id` immutability + global uniqueness** may pinch if a kiosk is re-imaged with a new
  wire id — the adopt flow plus retiring the old display is the supported path (documented in UI
  copy); duplicate screen_id on create/adopt is a 409 (string detail).
- **Audit-noise invariant (outside-review I-1):** journaled `changes` MUST include only fields whose
  value actually changed (`from != to`) — filtered server-side in the patch helpers; creates keep
  `from: null` entries. Otherwise full-form submits flood the History panel with no-op "changes".
- **Two audit event types** (`camera_admin` legacy + `registry_admin`) until consolidated — the
  History panel reads both; documented.

## 8. Out of scope (explicit)

Hard deletes; cross-system/location re-parenting; cascade retire; RBAC/auth; typed jsonb schemas;
bulk operations/CSV import; the globe/map view (separate lane); kiosk config push; automated
device discovery beyond the existing unresolved_devices projector; P3/P4 implementation plans
(spec'd above, planned after P1/P2 feedback).
