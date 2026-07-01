# God View Domain Model and Planning Context

**Project:** Minority Report Advertising System (MRAS) / Minority Report Project  
**Target file:** `docs/god-view-domain-model.md`  
**Intended consumer:** Gstack `/plan-eng-review`, Claude/Gstack architecture agents, Superpowers planning workflow, engineering pre-spec review  
**Updated:** 2026-06-28  

---

## 1. Purpose

This document consolidates the domain-model thinking for the MRAS **God View** and the broader SaaS/control-plane data model.

It is intended to give Gstack and future engineering agents enough context to:

1. Understand the current shipped architecture.
2. Understand how the proposed normalized SaaS domain model emerged.
3. Distinguish current runtime tables from recommended future canonical tables.
4. Plan the migration from single-location prototype to multi-location managed SaaS.
5. Identify gaps before writing specs, migrations, APIs, or UI code.
6. Support `/plan-eng-review` before implementation.

This document should be read together with:

- `CLAUDE.md`
- `docs/SESSION_LOG.md`
- `docs/superpowers/specs/*`
- `docs/superpowers/plans/*`
- Existing repo migrations in `mras-ops`, especially the current `events`, `identities`, `identity_embeddings`, `ads`, and `components` tables.

---

## 1.1 Source Recency, Authority, and Conflict Handling

This document intentionally combines three layers of planning context:

1. **Current runtime reality** from the God View handoff document: existing repos, current `events` table, current event types, current relational tables, current SSE path, and known instrumentation gaps.
2. **Earlier product/ecosystem assumptions** from the MRAS Ecosystem and User Model: actor groups, access surfaces, fully managed operating model, v1.0 exclusions, and role/scope assumptions. This document was written earlier and should be treated as important context, not necessarily final authority.
3. **Most recent domain-model planning from the current chat:** normalized SaaS model direction for organizations, locations, participants, systems, cameras, displays, ad runs, composition, playback, known/anonymous subjects, Qdrant/Postgres split, anonymous-to-known merges, and viewer exposure history. This is the newest planning layer and should be evaluated by Gstack as the latest proposed model direction.

The latest chat planning **may override or refine** parts of the older God View and ecosystem/user documents, but it should not be treated as automatically final. Gstack should explicitly compare the three layers and decide which assumptions survive into the implementation plan.

Recommended conflict rule for `/plan-eng-review`:

```txt
Current shipped schema/runtime behavior beats all planning assumptions.
The pasted God View handoff explains current runtime reality and known gaps.
The ecosystem/user model explains earlier v1.0 product assumptions and access boundaries.
The current-chat domain model is the newest proposed normalized SaaS direction.
Where these conflict, Gstack should identify the conflict, choose a direction, and document the decision before migrations or API changes.
```

Specific note: the six deployment models below are part of the newest planning direction and are expected to be reviewed carefully against the current single-location prototype:

```txt
organizations
locations
location_participants
systems
cameras
displays
```

The central architectural question is not whether these concepts are needed. They are needed for a multi-location SaaS God View. The question for Gstack is the implementation cutline: which tables become canonical immediately, which are compatibility shims over existing runtime fields, and which are deferred until the system moves beyond the current single-location prototype.

---

## 2. Executive Summary

The God View is the internal operator control plane for MRAS. It needs to show, across all locations:

- who is currently identified or anonymously detected;
- the detected person’s signals, such as attention, gaze, mood, evidence frames, and confidence;
- what advertisers or agencies have uploaded and bound to ads;
- what is being composed or rendered in real time;
- what is currently playing on each display;
- what was played historically;
- why each ad was selected;
- whether the intended person watched it;
- who else may have watched it;
- system, camera, display, model, rendering, and playback health.

The current prototype already has an important backbone:

```txt
Postgres events table = append-only source of truth for what happened
```

Current events are correlated with `trigger_id`, which ties a detection, dispatch, composition, TTS, and playback together. This is enough to build a first God View activity feed, but not enough for a durable multi-location SaaS domain model.

The recommended model direction below reflects the **newest planning from the current chat**. It should be treated as the latest proposal for Gstack to evaluate against the older God View handoff and ecosystem/user model, not as an automatic override of shipped behavior.

The recommended model direction is:

1. **Keep `events` as the append-only runtime journal.**
2. **Add normalized canonical tables for long-lived SaaS concepts.**
3. **Treat locations as physical/geographic places, not ownership containers.**
4. **Treat systems as operational deployments installed at locations and owned/operated by organizations.**
5. **Model cameras and displays as devices under systems.**
6. **Separate ad decision, composition, ad run, playback, and viewer exposure.**
7. **Use one subject/person profile model for known, anonymous, and later-merged people.**
8. **Keep Qdrant as the vector index, not the business source of truth.**
9. **Add explicit role, account, and scope boundaries for Platform Operator, Agency of Record, Advertisers, Hosts, and Customers.**
10. **Plan location-awareness early because the current system is effectively single-location.**

The most important missing areas are:

- multi-location domain model;
- people/subject/exposure history model;
- playback lifecycle acknowledgement;
- richer composition lifecycle events;
- scoped RBAC/account model;
- blocklist/suppression logic as a first-class domain concern;
- reporting projections derived from events and relational tables.

---

## 3. Current Runtime Architecture Context

### 3.1 Repos and services

Current MRAS is split across five primary repos plus infrastructure.

| Repo | Role | Runtime | Port |
|---|---|---:|---:|
| `mras-vision` | Camera capture, face detection, embeddings, tracking, identity resolution, perception, mood, attention, gaze, enrollment | native macOS; not Docker because webcam and MPS/Metal access are needed | 8001 |
| `mras-composer` | Ad selection, TTS, overlay/clip assembly, sends clips to kiosk over WebSocket | Docker | 8002 |
| `mras-overlays` | Remotion render sidecar for advertiser components to overlay video | Docker internal | 3000 internal |
| `mras-ops` | FastAPI ops API, event stream, React/Vite dashboard, advertiser authoring | Docker | API 8080, frontend 3000 |
| `mras-display` | Electron kiosk with fullscreen display windows, clip playback, idle shuffle | Electron native | 8003 health |
| infra | Postgres, Qdrant, Redis | Docker | Postgres 5432, Qdrant 6333 |

Run path currently documented:

```bash
cd /Users/jn/code/mras-ops && PERCEPTION_DEBUG=1 ./start-mras.sh
```

Kiosk separately:

```bash
cd /Users/jn/code/mras-display && NODE_ENV=development npm run electron:dev
```

Important operational note: `start-mras.sh` already starts native vision. `run-vision-native.sh` is only for the case where Docker is up and vision is down. Running both collides on port `8001`.

### 3.2 Current source of truth

Current architectural invariant:

```txt
Postgres events table is the append-only durable source of truth for what happened.
Redis is transient only.
```

Redis should hold TTL flags, cooldowns, and transient state only. It should not hold durable reporting or history.

---

## 4. Current Data Model Reality

This section describes what exists today and why it matters.

### 4.1 `events`

The current God View backbone is the append-only `events` table.

```sql
id bigserial
trigger_id uuid
ts timestamptz
service text
event_type text
status text
payload jsonb
asset_ref text
```

Important indexes:

```txt
(trigger_id)
(ts DESC)
```

`trigger_id` is the correlation key for a single interaction:

```txt
detection -> dispatch -> composition -> tts_attempt -> playback
```

The God View should use `events` for live activity and historical reconstruction, but long-term SaaS planning should not force every query to parse JSON payloads forever. Use `events` as the journal and build normalized tables/projections for durable product concepts.

### 4.2 Current event types

| Service | Event type | Statuses | Meaning for God View |
|---|---|---|---|
| `mras-vision` | `detection` | `success`, `error` | Person or subject was seen. Payload may include `uuid`, confidence, `is_new_visitor`, and `scene_context`. |
| `mras-vision` | `gaze` | `success` | Attention over a short window. Join with playback by screen and overlapping time to estimate watched/not watched. |
| `mras-vision` | `dispatch` | `error`, `dropped` | Trigger to composer failed or was dropped under load. |
| `mras-vision` | `perception` | `error` | Tracker/perception fault. |
| `mras-vision` | `augment` | `success`, `rejected` | Planned adaptive enrollment/gallery augmentation event. Not yet fully built. |
| `mras-composer` | `composition` | `standard_selected`, `no_display`, `orchestrated` | Composer decision. Currently too coarse for a rich live composition view. |
| `mras-composer` | `tts_attempt` | `success`, `error` | Name voiceover synthesis success/failure. |
| `mras-composer` | `playback` | `dispatched` | Clip sent to a display. Current gap: no confirmed started/ended acknowledgement. |

Example `detection` payload shape:

```json
{
  "uuid": "f487...",
  "confidence": 0.897,
  "is_new_visitor": false,
  "scene_context": {
    "viewer": {
      "mood": "sad",
      "track_id": "t-1",
      "attending": true,
      "evidence_frames": 41,
      "mood_confidence": 0.55
    },
    "objects": [
      {
        "bbox": [0, 0, 100, 100],
        "color": "black",
        "label": "person",
        "source": "yolo11n",
        "confidence": 0.7
      }
    ],
    "faces_tracked": 1
  }
}
```

Example `gaze` payload shape:

```json
{
  "uuid": "f487...",
  "track_id": "t-1",
  "screen_id": "screen_0",
  "window_start": "...",
  "window_end": "...",
  "attending_fraction": 0.8,
  "samples": 5
}
```

Example `playback` payload shape:

```json
{
  "video": "<uuid>.mp4",
  "screen_id": "display-2"
}
```

### 4.3 Current relational tables

Current important relational tables:

```txt
identities
identity_embeddings
ads
components
```

Current meanings:

- `identities`: enrolled people. Contains `uuid`, `name`, `embedding`, `embedding_status`, `is_blocked`, `created_at`, `updated_at`.
- `identity_embeddings`: multi-embedding gallery. A person can have many embeddings under different pose/lighting/quality conditions. Recognition uses max cosine similarity across embeddings.
- `ads`: advertiser-bound ads. Contains `base_video`, `component_id`, `default_props`, `personalized_field`, `is_active`, and `created_at`.
- `components`: Remotion/advertiser components with `slug` and `status`.

Current vector database:

```txt
Qdrant collection: mras_embeddings
Dimension: 512
Distance: cosine
Payload: uuid groups gallery embeddings
```

### 4.4 Current real-time APIs

Current event stream:

```http
GET http://localhost:8080/events/stream
```

Behavior:

- Replays the last 20 events.
- Polls `events` every 1 second.
- Streams new rows as Server-Sent Events.
- Current `mras-ops/frontend` activity feed consumes it.

This is usable for the first God View, but multi-location God View will need:

- filters by organization/location/system/display/camera/event type;
- cursor-based history;
- aggregation endpoints;
- possibly projections/materialized views;
- stronger event schema contracts.

---

## 5. Ecosystem and User Model

This section summarizes the older ecosystem/user document. It remains important context for v1.0 scope, roles, and access boundaries. However, it predates the current-chat domain-model planning by several weeks. Gstack should use it as product and governance context, then reconcile it against the newer normalized model recommendations in later sections.

MRAS v1.0 is a fully managed digital out-of-home advertising platform. The platform detects nearby people, selects personalized or non-personalized content, and plays media on connected on-site display systems.

### 5.1 Product scope

V1.0 includes:

- sensing hardware;
- playback hardware;
- local control/playback runtime;
- back-office reporting;
- platform administration;
- Agency-of-Record mediated advertiser demand.

V1.0 excludes:

- DSP integrations;
- SSP integrations;
- programmatic demand paths;
- consumer dashboards;
- consumer account login;
- consumer self-service opt-out management inside the product;
- regulator/public-interest access to internal systems;
- host administration of platform infrastructure.

### 5.2 Actor groups

Canonical actor groups:

```txt
Customer.OptInIdentified
Customer.Anonymous
Customer.Blocklisted
Host.IT
Advertiser.ReadOnly
AgencyOfRecord.Standard
Operator.SystemAdmin
Operator.SeniorSystemAdmin
```

### 5.3 System surfaces

Canonical system surfaces:

```txt
Surface.OnSiteControlPlayback
Surface.ReportingDashboard
Surface.Administration
```

The God View belongs primarily to:

```txt
Surface.Administration
```

Selected read-only slices may later feed:

```txt
Surface.ReportingDashboard
```

### 5.4 Access model implications

The data model must support strict scoping:

| Actor | Access |
|---|---|
| Customers | No product access in v1.0. Privacy/deletion requests handled externally. |
| Host IT | Local status visibility only; no platform administration. Optional scoped read-only reporting. |
| Agency of Record | Primary advertiser-side operating user; scoped campaign/reporting access. |
| Advertiser | Optional read-only sub-account scoped only to own campaigns. |
| Operator System Admin | Full operational access. |
| Operator Senior System Admin | Full operational access plus elevated authority for global/high-risk actions. |

This means domain tables should be designed with scope fields and RBAC in mind, especially:

- `organization_id`
- `agency_id` or organization relationship role
- `advertiser_id`
- `host_id`
- `location_id`
- `campaign_id`
- `system_id`

### 5.5 Identity and personalization rules

V1.0 must support three customer states:

| Customer state | Required behavior |
|---|---|
| Opt-in identified | Identity resolution and personalized delivery allowed if campaign/account/rules permit. |
| Anonymous passer-by | Presence and anonymous metrics allowed; no identity claim. Contextual or demographic ad path allowed. |
| Blocklisted customer | Suppress identity resolution and suppress personalization. May fallback to non-personalized/default ad path. Reporting should preserve suppression fact without exposing prohibited identity detail. |

This pushes the model toward explicit suppression/blocklist entities and explicit personalization-decision records.

---

## 6. How We Arrived at the Core SaaS Domain Model

### 6.1 Starting point: physical deployment

The first stable domain area was the physical hierarchy:

```txt
organizations
locations
location_participants
systems
cameras
displays
```

The original question was whether `locations` should directly belong to one `organization`. That was rejected because real-world places are shared and nested:

- a mall contains many stores;
- an airport contains many terminals, tenants, advertisers, display networks, and systems;
- an office building contains many tenants;
- a city-level map dot may represent many buildings or systems;
- one building may contain several MRAS systems;
- one system may contain multiple cameras and displays.

Therefore:

```txt
locations = physical/geographic places
organizations = legal/business/account/actor entities
systems = operational deployments
location_participants = relationship between organizations and physical places
```

### 6.2 God View map changed the model

The desired God View map is semantic zoom:

- zoomed out: one dot may represent an entire city with multiple systems;
- building zoom: multiple dots may represent systems in one building;
- system zoom: dots may represent individual displays and cameras;
- activity density/status should roll up from device to system to building to city.

This requires:

- hierarchical `locations.parent_location_id`;
- `systems.location_id`;
- optional `lat/lng` on systems, cameras, and displays;
- event/activity rollups by location/system/device;
- clear distinction between camera group IDs and display IDs.

### 6.3 Single ad run analysis changed the model

The best UI/product starting point is a single ad run detail view. That view needs to answer:

- What happened?
- Who or what triggered it?
- Was the trigger identity-based, demographic, contextual, scheduled, manual, fallback, or error recovery?
- What ad was selected?
- What was composed/rendered?
- What was actually dispatched?
- Did the kiosk start playback?
- Did playback end?
- Did the target watch?
- Who else watched?
- What confidence and evidence supported the decision?
- Which model/service/component failed, if any?

That drove separation between:

```txt
personalization_decisions
composition_runs
ad_runs
playbacks
viewer_exposures
model_runs
media_assets
activity_events/events
```

### 6.4 People and anonymous profiles became necessary

The system has to handle people at several certainty levels:

1. Known opt-in person with name/photo/customer linkage.
2. Anonymous but repeat-detected subject matched by embedding.
3. One-time observation with no durable profile.
4. Demographic/contextual audience only.
5. Anonymous profile later merged into a known profile after enrollment.
6. Blocklisted person whose identity/personalization must be suppressed.

Conclusion:

```txt
Use one subject profile model for known and anonymous people.
```

Do not create a totally separate anonymous-person structure that cannot later merge into known identity history.

### 6.5 Qdrant is not the source of truth

Qdrant can answer vector similarity questions. It should not own business identity, exposure history, merge history, deletion state, blocklist state, or reporting scope.

Recommended split:

```txt
Postgres = durable source of truth
Qdrant = vector index with references back to Postgres IDs
Redis = transient TTL runtime state only
```

---

## 7. Final Suggested Domain Model Inventory

This inventory reflects the **most recent planning layer from the current chat**. It is intentionally more normalized and SaaS-oriented than the current runtime schema and may refine earlier assumptions from the God View handoff and ecosystem/user document. Gstack should review it, compare it to current code and migrations, then decide the implementation cutline.

The following is the recommended planning inventory. Some models exist today under simpler names; others are proposed canonical V1/V1.5 models.

### 7.1 Account, actor, and access models

```txt
organizations
organization_relationships
users
user_memberships
roles
permissions
```

Minimum V1 could collapse roles/permissions into enum-based memberships, but Gstack should review the access model carefully because reporting and administration scopes are central to the product.

### 7.2 Physical deployment models

```txt
locations
location_participants
systems
devices
cameras
displays
device_health_events
system_health_events
```

`devices` may be a generalized parent table for cameras, displays, edge nodes, players, and sensors. Cameras/displays can either be specialized tables or device subtypes.

### 7.3 Campaign, advertiser, and creative models

```txt
campaigns
campaign_rules
ads
ad_creatives
ad_templates
components
media_assets
creative_approvals
```

Current `ads` and `components` already exist and should be mapped into the canonical creative model.

### 7.4 Ad decision, generation, and playback models

```txt
personalization_decisions
composition_runs
ad_runs
playbacks
viewer_exposures
model_runs
```

These separate the decision from media generation from actual display playback from observed viewing.

### 7.5 Person, identity, and observation models

```txt
subject_profiles
identity_enrollments
subject_embeddings
subject_observations
identity_matches
observation_tracks
viewer_exposures
subject_profile_merges
blocklist_entries
```

These are the largest missing canonical area relative to the current prototype.

### 7.6 Event, audit, and projection models

```txt
events
activity_events or event_projections
audit_logs
reporting_snapshots
```

Do not duplicate `events` casually. Decide whether `activity_events` is:

1. the existing `events` table renamed/expanded;
2. a normalized projection of `events`;
3. a UI-specific materialized view; or
4. unnecessary because `events` plus canonical tables are enough.

---

## 8. Core Model Details

### 8.1 `organizations`

Represents business/legal/account actors.

Examples:

- platform operator;
- host organization;
- advertiser;
- Agency of Record;
- brand partner;
- mall operator;
- retail chain;
- installation partner, if later needed.

Suggested fields:

```txt
organizations
- id uuid primary key
- name text not null
- organization_type enum: platform_operator, host, advertiser, agency_of_record, partner, vendor
- status enum: active, inactive, suspended
- parent_organization_id uuid nullable
- metadata jsonb
- created_at timestamptz
- updated_at timestamptz
```

Why it exists:

- MRAS is multi-actor even in V1.
- Advertisers may be read-only under an Agency of Record.
- Hosts own/operate locations but do not administer MRAS.
- Platform operator owns system administration.
- Future reporting needs account boundaries.

### 8.2 `locations`

Represents physical/geographic places.

Suggested fields:

```txt
locations
- id uuid primary key
- parent_location_id uuid nullable references locations(id)
- name text not null
- location_type enum: country, region, city, district, campus, building, mall, airport, venue, store, floor, zone, area
- country text nullable
- region text nullable
- state text nullable
- city text nullable
- address text nullable
- lat numeric nullable
- lng numeric nullable
- timezone text nullable
- status enum: planned, active, inactive, retired
- metadata jsonb
- created_at timestamptz
- updated_at timestamptz
```

Why `locations` should not simply belong to one organization:

- shared physical spaces are common;
- semantic map zoom needs nested geography;
- one physical place may have host, agency, advertiser, operator, and system relationships;
- ownership and physical containment are separate concepts.

### 8.3 `location_participants`

Models many-to-many relationships between organizations and locations.

Suggested fields:

```txt
location_participants
- id uuid primary key
- location_id uuid references locations(id)
- organization_id uuid references organizations(id)
- role enum: host, tenant, operator, advertiser, agency, maintenance_partner, reporting_viewer
- status enum: active, inactive
- starts_at timestamptz nullable
- ends_at timestamptz nullable
- metadata jsonb
- created_at timestamptz
- updated_at timestamptz
```

Why it exists:

- avoids forcing `locations.organization_id` as the only owner;
- supports malls, airports, trade shows, buildings, and multi-tenant venues;
- supports read-only host reporting without granting administration;
- supports future commercial relationships.

### 8.4 `systems`

Represents an installed MRAS operational deployment.

Suggested fields:

```txt
systems
- id uuid primary key
- organization_id uuid references organizations(id) -- operator or owning org
- location_id uuid references locations(id)
- name text not null
- system_type enum: onsite_mras, demo, lab, kiosk_cluster, edge_node
- zone text nullable
- floor text nullable
- lat numeric nullable
- lng numeric nullable
- timezone text nullable
- status enum: planned, active, degraded, offline, retired
- config jsonb
- created_at timestamptz
- updated_at timestamptz
```

Why it exists:

- God View needs to aggregate by operational deployment;
- one location can contain multiple systems;
- one system can contain many cameras/displays;
- events need a stable deployment scope.

### 8.5 `devices`, `cameras`, and `displays`

Recommended pattern:

```txt
devices
- id uuid primary key
- system_id uuid references systems(id)
- location_id uuid references locations(id)
- device_type enum: camera, display, edge_node, player, sensor
- name text not null
- external_device_key text nullable
- serial_number text nullable
- status enum: active, degraded, offline, retired
- last_seen_at timestamptz nullable
- lat numeric nullable
- lng numeric nullable
- zone text nullable
- floor text nullable
- metadata jsonb
- created_at timestamptz
- updated_at timestamptz
```

Then specialized tables:

```txt
cameras
- id uuid primary key
- device_id uuid references devices(id)
- system_id uuid references systems(id)
- location_id uuid references locations(id)
- name text
- camera_role enum: detection, enrollment, audience_measurement, security_context
- stream_url text nullable
- screen_group_id text nullable
- status enum: active, degraded, offline, retired
- last_seen_at timestamptz nullable
- calibration jsonb
- created_at timestamptz
- updated_at timestamptz
```

```txt
displays
- id uuid primary key
- device_id uuid references devices(id)
- system_id uuid references systems(id)
- location_id uuid references locations(id)
- name text
- screen_id text not null
- display_role enum: primary_ad, secondary_ad, ambient, status
- resolution_width int nullable
- resolution_height int nullable
- status enum: active, degraded, offline, retired
- last_seen_at timestamptz nullable
- calibration jsonb
- created_at timestamptz
- updated_at timestamptz
```

Important current gotcha:

```txt
screen_0 = camera group

display-1..display-4 = kiosk displays
```

Do not treat `screen_id` as globally unambiguous without a namespace/type/scope.

### 8.6 `subject_profiles`

Canonical person/subject profile for known and anonymous people.

Suggested fields:

```txt
subject_profiles
- id uuid primary key
- organization_id uuid nullable references organizations(id)
- global_subject_key text nullable
- status enum: anonymous, known, merged, blocklisted, deleted
- display_name text nullable
- first_name text nullable
- last_name text nullable
- external_customer_id text nullable
- primary_photo_asset_id uuid nullable references media_assets(id)
- first_seen_at timestamptz nullable
- last_seen_at timestamptz nullable
- created_from_observation_id uuid nullable
- confidence_level text nullable
- metadata jsonb
- created_at timestamptz
- updated_at timestamptz
```

Critical principle:

```txt
A known person and an anonymous repeat visitor are both subject_profiles.
```

This allows exposure history to start while the person is anonymous and later attach to a known identity after enrollment or merge.

### 8.7 `identity_enrollments`

Represents approved identity linkage and recognition scope.

Suggested fields:

```txt
identity_enrollments
- id uuid primary key
- subject_profile_id uuid references subject_profiles(id)
- organization_id uuid nullable references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- enrollment_scope enum: global, organization, location, system
- source enum: manual_upload, crm_import, loyalty_import, admin_created, camera_enroll, camera_match
- external_person_id text nullable
- consent_status enum: allowed, unknown, revoked, suppressed nullable
- status enum: active, inactive, revoked
- created_at timestamptz
- updated_at timestamptz
```

Why it matters:

- A person may be known at Gap but not globally.
- A person may be enrolled for one store/system only.
- Consent/suppression state may differ by organization/scope.

### 8.8 `subject_embeddings`

Canonical durable embedding reference table.

Suggested fields:

```txt
subject_embeddings
- id uuid primary key
- subject_profile_id uuid references subject_profiles(id)
- identity_enrollment_id uuid nullable references identity_enrollments(id)
- qdrant_collection text not null
- qdrant_point_id text not null
- embedding_type enum: face, body, clothing, gait, voice, full_body, other
- source enum: enroll, auto, manual, observation
- source_asset_id uuid nullable references media_assets(id)
- source_observation_id uuid nullable references subject_observations(id)
- quality_score numeric nullable
- model_name text nullable
- model_version text nullable
- status enum: active, rejected, expired, deleted
- created_at timestamptz
- expires_at timestamptz nullable
```

Map from current tables:

```txt
current identity_embeddings -> future subject_embeddings
current identities.uuid -> future subject_profiles or identity_enrollments linkage
Qdrant payload.uuid -> should point to subject_profile_id and/or enrollment ID
```

### 8.9 `subject_observations`

A single detection/perception observation from camera frames.

Suggested fields:

```txt
subject_observations
- id uuid primary key
- event_id bigint nullable references events(id)
- trigger_id uuid nullable
- organization_id uuid nullable references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- camera_id uuid nullable references cameras(id)
- observation_track_id uuid nullable references observation_tracks(id)
- frame_asset_id uuid nullable references media_assets(id)
- clip_asset_id uuid nullable references media_assets(id)
- observed_at timestamptz not null
- detection_type enum: face, body, eyes, group, demographic, object
- subject_profile_id uuid nullable references subject_profiles(id)
- camera_track_id text nullable
- bounding_box jsonb nullable
- face_quality_score numeric nullable
- identity_confidence numeric nullable
- demographic_snapshot jsonb nullable
- mood_snapshot jsonb nullable
- attention_snapshot jsonb nullable
- match_status enum: no_match, matched_known, matched_anonymous, new_anonymous, suppressed, ignored
- created_at timestamptz
```

This table prevents `events.payload` from being the only source for observations.

### 8.10 `identity_matches`

Records a specific matching attempt and result.

Suggested fields:

```txt
identity_matches
- id uuid primary key
- subject_observation_id uuid references subject_observations(id)
- candidate_subject_profile_id uuid nullable references subject_profiles(id)
- candidate_embedding_id uuid nullable references subject_embeddings(id)
- match_status enum: matched, no_match, below_threshold, suppressed, blocked
- confidence numeric nullable
- threshold numeric nullable
- model_name text nullable
- model_version text nullable
- qdrant_score numeric nullable
- rank int nullable
- created_at timestamptz
```

Why it matters:

- supports debugging false positives/false negatives;
- preserves the difference between detection, candidate match, and confirmed profile assignment;
- supports later audits and threshold tuning.

### 8.11 `observation_tracks`

Groups multiple observations across time.

Suggested fields:

```txt
observation_tracks
- id uuid primary key
- system_id uuid references systems(id)
- camera_id uuid references cameras(id)
- subject_profile_id uuid nullable references subject_profiles(id)
- camera_track_id text nullable
- started_at timestamptz
- ended_at timestamptz nullable
- max_identity_confidence numeric nullable
- track_confidence numeric nullable
- observation_count int
- created_at timestamptz
- updated_at timestamptz
```

This is important for presence, dwell, attention, and watched/not-watched calculations.

### 8.12 `personalization_decisions`

Records why an ad was selected.

Suggested fields:

```txt
personalization_decisions
- id uuid primary key
- trigger_id uuid nullable
- event_id bigint nullable references events(id)
- organization_id uuid references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- campaign_id uuid nullable references campaigns(id)
- selected_ad_id uuid nullable references ads(id)
- selected_creative_id uuid nullable
- decision_type enum: identity, demographic, contextual, scheduled, manual, fallback, blocked_suppressed, error_recovery
- target_subject_profile_id uuid nullable references subject_profiles(id)
- target_observation_id uuid nullable references subject_observations(id)
- identity_confidence numeric nullable
- demographic_confidence numeric nullable
- decision_confidence numeric nullable
- decision_factors jsonb
- prompt_used text nullable
- model_run_id uuid nullable references model_runs(id)
- created_at timestamptz
```

Example `decision_factors`:

```json
{
  "recognized_identity": false,
  "recognized_name": false,
  "estimated_gender": "male",
  "estimated_age_range": "35-44",
  "clothing_color": "blue",
  "group_size": 2,
  "confidence": 0.78
}
```

This is the model that distinguishes:

```txt
Ad shown because Jason was identified
Ad shown because anonymous profile X was recognized
Ad shown because demographic/context matched
Ad shown as fallback because identity was suppressed
Ad shown as scheduled idle/default content
```

### 8.13 `composition_runs`

Records generated/rendered media attempts.

Suggested fields:

```txt
composition_runs
- id uuid primary key
- trigger_id uuid nullable
- personalization_decision_id uuid nullable references personalization_decisions(id)
- organization_id uuid references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- ad_id uuid nullable references ads(id)
- component_id uuid nullable references components(id)
- render_mode enum: prebuilt, template_overlay, remotion, ffmpeg, genai_video, fallback
- status enum: queued, selected, rendering, rendered, failed, canceled
- input_asset_id uuid nullable references media_assets(id)
- output_asset_id uuid nullable references media_assets(id)
- used_spoken_name boolean default false
- used_visible_name boolean default false
- used_likeness boolean default false
- used_voice_clone boolean default false
- render_progress numeric nullable
- error_code text nullable
- error_message text nullable
- started_at timestamptz nullable
- ended_at timestamptz nullable
- created_at timestamptz
```

Current gap: `composition` events are coarse and mostly empty. A satisfying God View needs lifecycle instrumentation:

```txt
composition/selected
composition/rendering
composition/render_progress
composition/rendered
composition/failed
composition/dispatched
```

### 8.14 `ad_runs`

Logical ad event. This is not the same thing as a render or playback.

Suggested fields:

```txt
ad_runs
- id uuid primary key
- trigger_id uuid nullable
- organization_id uuid references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- display_id uuid nullable references displays(id)
- campaign_id uuid nullable references campaigns(id)
- ad_id uuid nullable references ads(id)
- personalization_decision_id uuid nullable references personalization_decisions(id)
- composition_run_id uuid nullable references composition_runs(id)
- target_subject_profile_id uuid nullable references subject_profiles(id)
- personalization_type enum: none, demographic, contextual, identity, name, likeness, hybrid, fallback, suppressed
- used_spoken_name boolean default false
- used_visible_name boolean default false
- used_likeness boolean default false
- used_voice_clone boolean default false
- target_watched boolean nullable
- target_watch_probability numeric nullable
- estimated_total_viewers int nullable
- estimated_identified_viewers int nullable
- estimated_anonymous_viewers int nullable
- status enum: planned, composing, ready, dispatched, playing, completed, failed, canceled
- started_at timestamptz nullable
- ended_at timestamptz nullable
- created_at timestamptz
- updated_at timestamptz
```

Why it exists:

- gives reporting a stable business event;
- ties together decision, generation, playback, and exposures;
- supports campaign performance, person exposure history, and God View drilldown.

### 8.15 `playbacks`

Records actual display playback lifecycle.

Suggested fields:

```txt
playbacks
- id uuid primary key
- ad_run_id uuid nullable references ad_runs(id)
- composition_run_id uuid nullable references composition_runs(id)
- trigger_id uuid nullable
- organization_id uuid references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- display_id uuid references displays(id)
- media_asset_id uuid nullable references media_assets(id)
- screen_id text nullable
- status enum: dispatched, started, ended, failed, interrupted, unknown
- dispatched_at timestamptz nullable
- started_at timestamptz nullable
- ended_at timestamptz nullable
- duration_ms int nullable
- error_code text nullable
- error_message text nullable
- created_at timestamptz
```

Current gap:

```txt
Current playback event only confirms dispatch, not actual started/ended.
```

Recommended instrumentation:

```txt
playback/dispatched
playback/started
playback/ended or clip_ended
playback/failed
```

### 8.16 `viewer_exposures`

Connects people/observations to ad runs/playbacks.

Suggested fields:

```txt
viewer_exposures
- id uuid primary key
- ad_run_id uuid references ad_runs(id)
- playback_id uuid nullable references playbacks(id)
- subject_profile_id uuid nullable references subject_profiles(id)
- subject_observation_id uuid nullable references subject_observations(id)
- observation_track_id uuid nullable references observation_tracks(id)
- role enum: target, viewer, bystander, possible_viewer
- identity_status enum: known, anonymous, unmatched, suppressed
- identity_confidence numeric nullable
- watch_probability numeric nullable
- watched boolean nullable
- gaze_duration_ms int nullable
- visible_duration_ms int nullable
- attending_fraction numeric nullable
- distance_estimate_m numeric nullable
- mood_label text nullable
- mood_confidence numeric nullable
- expression_label text nullable
- expression_confidence numeric nullable
- demographic_snapshot jsonb nullable
- created_at timestamptz
```

This is one of the most important missing tables.

It answers:

```txt
All ads Jason has seen
All ads anonymous profile X has seen
All ads a demographic-only viewer may have seen
Did the target watch?
Who else watched?
Can anonymous exposure history later attach to a known profile?
```

Rules:

- Known target: `subject_profile_id` points to known profile.
- Anonymous repeat visitor: `subject_profile_id` points to anonymous profile.
- One-off detection not worth persisting as a profile: `subject_profile_id = null`, `subject_observation_id` populated.
- Demographic-only crowd: store aggregate in `ad_runs` and/or `viewer_exposures` with no person profile depending on retention/product decision.

### 8.17 `subject_profile_merges`

Tracks anonymous-to-known and duplicate-profile merges.

Suggested fields:

```txt
subject_profile_merges
- id uuid primary key
- from_subject_profile_id uuid references subject_profiles(id)
- to_subject_profile_id uuid references subject_profiles(id)
- merge_reason enum: enrolled_identity, manual_merge, vector_match, admin_action, duplicate_cleanup
- confidence numeric nullable
- merged_by_user_id uuid nullable references users(id)
- created_at timestamptz
```

This supports:

```txt
Anonymous Profile A saw 8 ads at Gap.
Later Jason’s name/photo is added.
System or admin matches Jason to Anonymous Profile A.
Jason’s history can now include those prior anonymous exposures while preserving that they were anonymous at the time.
```

### 8.18 `blocklist_entries`

Required by the ecosystem model.

Suggested fields:

```txt
blocklist_entries
- id uuid primary key
- subject_profile_id uuid nullable references subject_profiles(id)
- organization_id uuid nullable references organizations(id)
- location_id uuid nullable references locations(id)
- system_id uuid nullable references systems(id)
- scope enum: global, organization, location, system
- blocklist_type enum: biometric_opt_out, personalization_opt_out, legal_hold, manual_suppression, safety
- status enum: active, inactive, expired
- reason text nullable
- created_by_user_id uuid nullable references users(id)
- starts_at timestamptz
- ends_at timestamptz nullable
- created_at timestamptz
- updated_at timestamptz
```

Required behavior:

- suppress identity resolution;
- suppress personalization;
- optionally allow default/non-personalized content;
- report suppression without exposing prohibited details to unauthorized roles.

### 8.19 `media_assets`

Common storage record for images, frames, clips, audio, generated videos, thumbnails, and composites.

Suggested fields:

```txt
media_assets
- id uuid primary key
- organization_id uuid nullable references organizations(id)
- asset_type enum: image, frame, clip, video, audio, thumbnail, composite, model_artifact
- storage_url text not null
- mime_type text nullable
- duration_ms int nullable
- width int nullable
- height int nullable
- source enum: camera, generated, uploaded, rendered, external
- sha256_hash text nullable
- metadata jsonb
- created_at timestamptz
```

Why it exists:

- avoids random URL fields in every table;
- supports evidence frames/clips;
- supports rendered ad output;
- supports generated audio/TTS;
- supports audit and debugging.

### 8.20 `model_runs`

Records ML/AI/model executions.

Suggested fields:

```txt
model_runs
- id uuid primary key
- run_type enum: recognition, demographic_estimation, mood_detection, gaze_detection, ad_decision, video_generation, voice_generation, object_detection, composition
- provider text nullable
- model_name text nullable
- model_version text nullable
- input_asset_id uuid nullable references media_assets(id)
- output_asset_id uuid nullable references media_assets(id)
- prompt_template_id uuid nullable
- prompt_text text nullable
- parameters jsonb nullable
- latency_ms int nullable
- cost_estimate numeric nullable
- status enum: success, error, timeout, skipped
- error_code text nullable
- error_message text nullable
- created_at timestamptz
```

Why it exists:

- debug bad decisions;
- trace model version changes;
- estimate cost;
- support compliance/audit/replay;
- support the n8n-style trace UI.

### 8.21 `audit_logs`

Administrative audit log.

Suggested fields:

```txt
audit_logs
- id uuid primary key
- actor_user_id uuid nullable references users(id)
- actor_type enum: user, system, model, api
- action text not null
- entity_type text not null
- entity_id text not null
- before jsonb nullable
- after jsonb nullable
- ip_address text nullable
- created_at timestamptz
```

Important for:

- identity merges;
- blocklist changes;
- deletion requests;
- campaign edits;
- manual playback overrides;
- device/system configuration changes;
- access changes.

---

## 9. Mapping God View Panels to Data

| God View panel | Current source today | Recommended canonical source | Gap |
|---|---|---|---|
| Who is identified now | recent `detection/success` events joined to `identities` | `subject_observations`, `observation_tracks`, `subject_profiles`, event stream projection | No explicit presence/left event yet. |
| Mood/attention/gaze | `scene_context.viewer`, `gaze` events | `subject_observations`, `viewer_exposures`, `observation_tracks` | Needs durable projections for reporting. |
| What advertisers uploaded/bound | `ads`, `components` | `ads`, `components`, `ad_creatives`, `media_assets`, `creative_approvals` | Current tables usable but simple. |
| What is being composed | coarse `composition` and `tts_attempt` events | `composition_runs`, `model_runs`, richer composition lifecycle events | Under-instrumented. |
| What is playing now | `playback/dispatched` events | `playbacks` with `started`/`ended` lifecycle | Dispatch only; no playback confirmation. |
| What was played historically | `events` | `ad_runs`, `playbacks`, `events` | Need normalized ad run projection. |
| Did they watch? | join `playback` and `gaze` by screen/time overlap | `viewer_exposures` | Need durable exposure rows. |
| Who else watched? | estimated from detection/gaze/crowd signals | `viewer_exposures`, aggregate fields on `ad_runs` | Needs policy on anonymous persistence. |
| Why was ad selected? | partly `composition` event; payload sparse | `personalization_decisions` | Must be added. |
| Was name/likeness used? | currently inferred from composition/TTS path | `ad_runs`, `composition_runs`, `personalization_decisions` | Must be explicit. |
| System/device health | scattered service health/status | `device_health_events`, `system_health_events`, `events` | Needs canonical health model. |
| Map dots and rollups | not location-aware yet | `locations`, `systems`, `devices`, event projections | Foundational gap. |

---

## 10. Current Shipped vs Planned Work

### 10.1 Shipped / on main

Current shipped capabilities include:

- Phase 0/1/2 perception: detect, track, mood, attention, objects/color, gaze.
- Per-display custom ads.
- Multi-display kiosk.
- Multi-embedding gallery with max-similarity recognition.
- Additive re-enroll.
- `mras-vision` + `mras-ops` migration `003_identity_embeddings.sql`.
- Recognition around `0.89` confidence after gallery/re-enrollment work.
- Serialized inference worker in `mras-vision/src/perception/infer.py`.

Important inference invariant:

```txt
Do not add concurrent heavy GPU calls.
If backend work touches native vision inference, route through run_inference.
```

### 10.2 Planned / not yet built

Planned items from existing architecture docs:

- **PR #12 — Temporal display orchestration**
  - bounded two-round-per-person ad programs;
  - even-split and newest-wins across displays;
  - event-driven pacing via kiosk `clip_ended`;
  - new vision-to-composer `/presence` stream.

- **PR #13 — Adaptive enrollment Plan 2**
  - gated auto-augmentation;
  - `augment` events;
  - purge path.

- **PR #14 — Serialized inference design/plan**
  - already implemented and merged as `mras-vision` #18.

God View should coordinate with PR #12 because `presence` and `clip_ended` are exactly the signals needed for live display state and subject presence.

---

## 11. Known Backend Gaps to Close

### 11.1 Multi-location support

Current system is effectively single-location:

```txt
one camera group: screen_id = screen_0
multiple displays: display-1..display-4
no location_id everywhere
```

Required work:

- add `locations`;
- add `systems`;
- add devices/cameras/displays scope;
- configure each service with `LOCATION_ID` and `SYSTEM_ID`;
- stamp `organization_id`, `location_id`, `system_id`, `camera_id`, and `display_id` into events where applicable;
- backfill or default the current prototype to a demo location/system.

### 11.2 Composition lifecycle instrumentation

Current `composition` events are too coarse.

Required events:

```txt
composition/selected
composition/queued
composition/rendering
composition/progress
composition/rendered
composition/failed
composition/dispatched
```

Payload should include:

```txt
trigger_id
composition_run_id
ad_id
component_id
target_subject_profile_id if applicable
render_mode
media_asset_id
progress
error_code/error_message
```

### 11.3 Playback confirmation

Current playback only logs `dispatched`.

Required events:

```txt
playback/dispatched
playback/started
playback/ended or clip_ended
playback/failed
```

This should come from the kiosk/display runtime, not just composer dispatch.

### 11.4 Presence lifecycle

Current presence is inferred from recent detection events.

Recommended events or stream:

```txt
presence/entered
presence/updated
presence/left
```

Or at minimum a projection built from `detection` and `gaze` windows.

### 11.5 Event stream scaling

Current SSE polls events every second and replays last 20 events.

Recommended additions:

```http
GET /events?cursor=&limit=&organization_id=&location_id=&system_id=&event_type=&since=&until=
GET /events/stream?organization_id=&location_id=&system_id=&event_type=&cursor=
GET /god-view/live-summary
GET /god-view/locations/:id/summary
GET /god-view/systems/:id/summary
GET /god-view/ad-runs/:id
```

### 11.6 Reporting projections

Do not make reporting depend entirely on ad hoc JSON parsing from `events.payload`.

Recommended projections:

```txt
ad_runs
playbacks
viewer_exposures
subject_observations
personalization_decisions
```

Events remain source-of-truth journal; projections make SaaS/reporting queries sane.

---

## 12. V1 Cutline Recommendation

For Gstack planning, split into phases.

### 12.1 V1 foundational schema

Implement first:

```txt
organizations
locations
location_participants
systems
devices
cameras
displays
subject_profiles
identity_enrollments
subject_embeddings
subject_observations
identity_matches
observation_tracks
personalization_decisions
composition_runs
ad_runs
playbacks
viewer_exposures
blocklist_entries
media_assets
model_runs
audit_logs
```

This does not mean every UI must use every table immediately. It means the core model should be coherent before Gstack generates partial migrations that become hard to unwind.

### 12.2 Minimum operational God View V1

The first usable God View can be smaller:

```txt
locations
systems
cameras
displays
events with location/system/device fields
subject_profiles mapped from current identities
composition_runs projection
playbacks projection
ad_runs projection
viewer_exposures projection
```

UI panels:

1. Live map.
2. Live event feed.
3. Active identities/anonymous subjects.
4. Displays now playing.
5. Composition/render queue.
6. Single ad run drilldown.
7. Device/system health.

### 12.3 Defer if necessary

Can defer:

- full RBAC permission matrix;
- advanced advertiser/agency self-service;
- DSP/SSP/programmatic concepts;
- consumer-facing privacy portal;
- complex billing;
- long-term reporting snapshots;
- full creative approval workflow;
- regulator/public-interest access.

Do not defer:

- location/system scope;
- subject profile vs observation distinction;
- blocklist/suppression logic;
- viewer exposure model;
- playback started/ended acknowledgement;
- event correlation by `trigger_id`.

---

## 13. Migration / Mapping From Current Prototype

### 13.1 Current to future mapping

| Current | Future / canonical |
|---|---|
| `events` | keep as append-only journal; add scope columns or consistently stamped payload fields; build projections |
| `identities` | `subject_profiles` + `identity_enrollments` |
| `identity_embeddings` | `subject_embeddings` |
| Qdrant `mras_embeddings` payload uuid | payload should reference `subject_profile_id`, `subject_embedding_id`, and scope metadata |
| `ads` | keep, but relate to `campaigns`, `ad_creatives`, `components`, `media_assets` |
| `components` | keep; part of creative/component model |
| `detection` events | `subject_observations`, `identity_matches`, `observation_tracks` |
| `gaze` events | `viewer_exposures` and/or observation/attention projections |
| `composition` events | `composition_runs` |
| `playback/dispatched` | `playbacks` |

### 13.2 Backfill strategy

Initial migration could create:

```txt
Demo organization
Demo location
Demo system
Demo camera group
Display 1..4
```

Then events without location/system/device IDs can be interpreted as belonging to that demo scope.

Recommended default IDs should be configured in environment variables:

```txt
MRAS_ORGANIZATION_ID
MRAS_LOCATION_ID
MRAS_SYSTEM_ID
MRAS_CAMERA_ID
MRAS_DISPLAY_ID or display mapping config
```

---

## 14. Planning Questions for Gstack `/plan-eng-review`

Gstack should answer these before implementation:

1. Should `events` receive first-class columns for `organization_id`, `location_id`, `system_id`, `camera_id`, `display_id`, `subject_profile_id`, and `ad_run_id`, or should scope remain in `payload` with projections?
2. Should `devices` be a parent table with `cameras` and `displays` as subtype tables, or should cameras/displays remain independent?
3. Should current `identities` be migrated to `subject_profiles`, or wrapped for now with a compatibility view?
4. Should `subject_profiles` replace `identities` immediately, or should it be introduced beside it?
5. What is the minimum schema needed to avoid blocking God View without overbuilding the whole SaaS?
6. How should anonymous profile retention work?
7. When should anonymous observations become durable `subject_profiles` versus one-off `subject_observations` only?
8. How should blocklisted people be matched/suppressed without exposing identity details?
9. Should `viewer_exposures` be written synchronously during playback/gaze events or generated asynchronously as a projection job?
10. How should `playback/started` and `playback/ended` acknowledgements be emitted by `mras-display`?
11. How should composition progress events be emitted by `mras-composer` and `mras-overlays`?
12. What indexes are needed for God View live feed and historical drilldown?
13. What materialized views or projections are needed for map rollups?
14. How should role scopes be modeled for Platform Operator, Agency, Advertiser, and Host IT?
15. What data should be redacted or aggregated for non-operator reporting views?

---

## 15. Suggested Gstack Prompt

Use this document with a prompt similar to:

```txt
/plan-eng-review docs/god-view-domain-model.md

Review the proposed MRAS God View domain model and produce an engineering implementation plan.

Focus on:
1. migration path from current single-location prototype to multi-location SaaS;
2. schema design and table boundaries;
3. event journal vs normalized projections;
4. identity, anonymous subject, exposure history, and blocklist modeling;
5. playback/composition instrumentation gaps;
6. API endpoints needed for the God View UI;
7. risk areas and sequencing;
8. tests required before implementation.

Do not start coding. Produce a pre-spec engineering review with open questions, recommended phased plan, and migration/ticket breakdown.
```

---

## 16. Recommended First Engineering Plan

### Phase 1 — Confirm current reality

- Read migrations and current schema.
- Read event writer code across `mras-vision`, `mras-composer`, `mras-ops`, and `mras-display`.
- Confirm exact shape of `events.payload` for detection/gaze/composition/playback.
- Confirm current frontend activity-feed assumptions.

### Phase 2 — Add location/system/device scope

- Add `organizations`, `locations`, `location_participants`, `systems`, `devices`, `cameras`, `displays`.
- Create demo records for current local setup.
- Add environment/config mapping for current services.
- Stamp future events with location/system/device scope.

### Phase 3 — Add God View projections

- Add `subject_profiles` compatibility path from `identities`.
- Add `subject_observations` from detection events.
- Add `composition_runs` from composition events.
- Add `playbacks` from playback events.
- Add `ad_runs` correlation by `trigger_id`.
- Add `viewer_exposures` from playback/gaze overlap.

### Phase 4 — Add missing runtime signals

- Add playback started/ended from kiosk.
- Add composition lifecycle events.
- Add presence events or a presence projection.

### Phase 5 — Build God View UI

- Live map with semantic zoom.
- Live feed and filters.
- Location/system/device rollups.
- Active subject list.
- Display now-playing board.
- Composition queue.
- Single ad run drilldown with trace.
- Historical search.

---

## 17. Non-Negotiable Invariants

1. `events` remains append-only and durable.
2. Redis is never durable history.
3. Vector DB is not source of truth.
4. Location and ownership are separate.
5. Observation and identity are separate.
6. Decision, composition, ad run, playback, and exposure are separate.
7. Blocklist/suppression is first-class.
8. Every model/inference-derived field should preserve confidence and source when possible.
9. V1 is fully managed; hosts and advertisers do not get admin access.
10. Customers do not have direct product access in V1.
11. Do not add concurrent heavy GPU inference paths in vision; use the serialized inference pattern.
12. Do not commit directly to `main`; follow repo workflow and delegated git management.

---

## 18. Acceptance Criteria for This Domain Model

A good implementation plan should allow MRAS to answer these questions:

### Location/system questions

- What organizations participate in this location?
- Which systems are installed at this location?
- Which cameras and displays belong to each system?
- Which systems are active, degraded, or offline?
- What is happening in this city/building/system/display right now?

### Identity/person questions

- Who is currently identified?
- Who is anonymous but repeat-detected?
- Who is blocklisted or suppressed?
- What confidence supported the match?
- What observations/frames supported the match?
- What embeddings exist for this subject?
- Was an anonymous profile later merged into a known profile?

### Ad decision questions

- Why was this ad selected?
- Was it identity-based, demographic, contextual, scheduled, fallback, or suppressed?
- What decision factors were used?
- What confidence did the system have?
- Which model/service made the decision?

### Composition/playback questions

- What was composed?
- Was a name spoken?
- Was a name shown?
- Was likeness used?
- What rendered media asset resulted?
- What display received the clip?
- Did the display start playback?
- Did playback end or fail?

### Exposure/reporting questions

- Did the target watch?
- How long did they watch?
- Who else watched?
- How many anonymous viewers were present?
- What mood/expression/attention signal was observed?
- Which ads has this known or anonymous subject seen before?
- Which campaign ran at which location/system/display?

---

## 19. Final Recommendation

The current MRAS prototype has the right event-journal foundation but needs a normalized SaaS domain model before the God View becomes multi-location, historical, and explainable.

The most urgent foundational additions are:

```txt
organizations
locations
location_participants
systems
devices
cameras
displays
subject_profiles
subject_observations
personalization_decisions
composition_runs
ad_runs
playbacks
viewer_exposures
blocklist_entries
```

The key architectural stance is:

```txt
Events tell us what happened.
Canonical tables tell us what the business objects are.
Projections connect the two for UI and reporting.
```

Gstack should use this document to produce a phased engineering pre-spec rather than jumping directly into implementation.
