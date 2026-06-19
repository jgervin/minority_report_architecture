# Adaptive Enrollment — Multi-Embedding Gallery + Gated Auto-Augmentation (Design)

**Date:** 2026-06-17
**Status:** Approved by owner (brainstorming session 2026-06-17)
**Repos affected:** `mras-vision` (resolution, enrollment, auto-augmentation), `mras-ops`
(Postgres migration for the gallery table)
**Related:** independent of temporal orchestration
(`2026-06-17-temporal-display-orchestration-design.md`). Motivated by live recognition being
marginal — enrolled "Jason" scores ~0.679 against the 0.68 threshold under new lighting (the
interim fix was lowering `CONFIDENCE_THRESHOLD` to 0.67).

---

## Goal

Replace the single averaged embedding per identity with a **multi-embedding gallery** that covers
multiple lighting/pose conditions, and let it **self-improve safely** — automatically adding new
embeddings from high-certainty live identifications, with strict gates, full audit, and one-command
reversibility so a mis-identification can't silently poison a person's identity.

**Done means:** an identity can hold many embeddings; a face matches if its best similarity to *any*
of a person's embeddings clears the threshold; live identifications that pass conservative gates add
to the gallery automatically with logged provenance; manual re-enrollment is additive (non-
destructive); and a purge operation removes auto-added embeddings for a uuid. Verified by unit tests
plus a live walk-up showing recognition improve across conditions.

## Owner decisions from the brainstorm

| Question | Decision |
|---|---|
| Gallery model | **Full gallery, match = max similarity over a person's embeddings.** Most accurate across conditions (averaging blurs; clustering is a later optimization). Capped + diversity-aware eviction. |
| Trust model | **Auto-add, audited + reversible.** Gated candidates enter the gallery automatically; full provenance logged; purge-by-uuid undoes mistakes. No human in the loop. |
| Gate strictness | **Conservative** (defaults, all env-tunable): confidence ≥ 0.90, dwell ≥ 5s **and** ≥ 10 frames agreeing on the same uuid, strict quality (size/pose/sharpness/single-face), admission dedup < 0.95. |
| Anchors | **`source='enroll'` embeddings are protected** — never auto-evicted, never purged by the auto-purge. |
| Evaluation point | **End of dwell (track close).** |
| Manual re-enroll | **Additive** — adds an `enroll` gallery embedding under current lighting instead of overwriting. |
| Reversibility | **Purge** auto embeddings for a uuid (optionally since a timestamp). |
| Threshold | Re-tune `CONFIDENCE_THRESHOLD` once gallery + max-similarity is live (max-sim slightly raises false-accept). Tuning task, not a fixed value here. |

## Architecture

```
Enrollment (additive) ─┐
                       ├─▶ identity_embeddings (Postgres, durable, D19) ─┐
Auto-augmentation ─────┘     id, identity_uuid, embedding, source,        │ index
  (vision, end of dwell,     quality, provenance, created_at              ▼
   conservative gates)                                              Qdrant points
                                                          (1 per embedding; payload.uuid groups)
Resolution (resolver.py): query limit=K → group hits by payload.uuid → max score per uuid → threshold
Purge (CLI/endpoint): delete source='auto' points for uuid [since T] from Postgres + Qdrant
```

## Storage & resolution

**Postgres — new table (migration in `mras-ops`):**
```
identity_embeddings(
  id           uuid primary key,
  identity_uuid uuid not null references identities(uuid),
  embedding    real[] not null,         -- 512-dim ArcFace
  source       text not null,           -- 'enroll' | 'auto'
  quality      real,                    -- composite quality score of the source frame
  provenance   jsonb,                   -- {track_id, frames, confidence, ts} for auto; {photo} for enroll
  created_at   timestamptz default now()
)
```
Backfill: each existing `identities.embedding` becomes one `identity_embeddings` row
(`source='enroll'`). The legacy `identities.embedding` column may remain for back-compat but is no
longer the source of truth.

**Qdrant:** one point per gallery embedding; point-id = the `identity_embeddings.id`;
`payload = {uuid, name, source}`. Existing per-uuid points already carry `payload.uuid`, so they
resolve correctly without migration; new members use distinct ids.

**Resolution (`resolver.py`):** `query_points(limit=K, with_payload=True)` with `K =
QDRANT_GALLERY_FANOUT` (default 15). Group the returned hits by `payload.uuid`, take the **max**
score per uuid, pick the best uuid; match if its max score ≥ `CONFIDENCE_THRESHOLD`. Today's
`limit=1` single-hit logic is replaced by this group-by-max.

## Auto-augmentation pipeline (vision)

**Evidence accumulation (per track):** extend the tracker so each resolved frame contributes
`(uuid, confidence, quality, embedding)` to a per-track identification buffer (alongside the existing
mood/attention buffers). `quality` is a composite of: face bbox area (≥ `AUG_MIN_FACE_PX`),
frontality (reuse the head-pose/attention signal; yaw/pitch within `AUG_MAX_POSE_DEG`), and
sharpness (Laplacian variance ≥ `AUG_MIN_SHARPNESS`); single-face-in-frame required.

**Evaluation at track close** (`drain_closed`): a candidate is accepted iff ALL hold —
- dwell ≥ `AUG_MIN_DWELL_S` (5.0) **and** ≥ `AUG_MIN_FRAMES` (10) frames resolved to the **same** uuid;
- the best agreeing frame's `confidence` ≥ `AUG_MIN_CONF` (0.90);
- that frame passed the quality gates above;
- **admission dedup:** the candidate embedding's max cosine similarity to that uuid's existing
  gallery < `AUG_MAX_REDUNDANCY` (0.95) — skip near-duplicates.

**On accept:** insert one `identity_embeddings` row (`source='auto'`, quality, provenance =
`{track_id, frames, confidence, ts}`) + upsert the Qdrant point; log an audit event
(`events`, `event_type='augment'`, `status='success'`, payload = provenance + uuid). On reject for a
gate, optionally log `event_type='augment', status='rejected'` with the failing gate (useful for
tuning; low volume).

**Cap + eviction:** if a uuid's gallery exceeds `AUG_GALLERY_CAP` (12) after an add, evict the
**most-redundant `source='auto'`** embedding (the one with the highest max-similarity to the rest —
diversity-preserving). **`source='enroll'` anchors are never evicted.**

## Manual additive re-enroll

The current `/enroll` averages a person's photos into one vector and **overwrites**. Add an additive
path (a flag or a sibling endpoint) that, for an existing identity, **adds** each photo's embedding
as a new `source='enroll'` gallery member (Postgres + Qdrant) rather than overwriting — so a person
can be enriched with new lighting/pose without losing prior coverage. This is the non-destructive
"re-enroll Jason under demo lighting" fix.

## Reversibility / purge

A purge operation (CLI in `mras-ops` and/or a vision endpoint) deletes `source='auto'` gallery
members for a given `identity_uuid` (optionally only those `created_at >= since`) from both Postgres
and Qdrant, leaving `source='enroll'` anchors intact. Backed by the `augment` audit events, a
mis-identification is traceable (which track/frames added what) and fully reversible.

## Env vars (conservative defaults)

`QDRANT_GALLERY_FANOUT=15`, `AUG_MIN_CONF=0.90`, `AUG_MIN_DWELL_S=5.0`, `AUG_MIN_FRAMES=10`,
`AUG_MIN_FACE_PX=10000` (bbox area, i.e. ~100×100), `AUG_MAX_POSE_DEG=20` (yaw/pitch from frontal),
`AUG_MIN_SHARPNESS=100` (Laplacian variance), `AUG_MAX_REDUNDANCY=0.95`, `AUG_GALLERY_CAP=12`.
All are starting points, tuned against live captures.

The per-frame `quality` stored on each gallery member is a composite ranking score (normalized blend
of bbox area, frontality, and sharpness) used to pick the **best agreeing frame** to store and to
rank eviction candidates; the accept/reject **gates** check each component independently against the
thresholds above.

## Error handling / edge cases

- **Qdrant write fails on auto-add:** reuse the existing pending/reconciler pattern — the durable
  Postgres row is written `embedding_status`-style and the reconciler retries Qdrant.
- **Track resolves to multiple uuids across the dwell** (flicker): the "≥ N frames agreeing on the
  SAME uuid" gate rejects it — no add.
- **Unidentified / below-threshold track:** never a candidate (no uuid).
- **Gallery for a uuid is empty (brand-new auto before any enroll):** not possible — auto requires a
  match, which requires an existing embedding.
- **Purge of a uuid with only anchors:** no-op (nothing `auto` to remove).

## Testing strategy (TDD)

- **Resolution:** group-by-uuid max-score picks the best of several gallery hits; a probe matching
  one gallery member (and not others) still resolves the person (unit test with a fake Qdrant
  returning multiple hits across uuids).
- **Gates:** each gate independently rejects (low confidence, short dwell, too few frames, uuid
  disagreement, failed quality, redundant duplicate); all-pass accepts. Pure unit tests over the
  per-track evidence buffer + a gate function.
- **Eviction:** over-cap evicts the most-redundant `auto`, never an `enroll` anchor.
- **Additive enroll:** adds a gallery member without removing existing ones.
- **Purge:** removes `auto` for a uuid (and `since` filter), leaves `enroll` anchors.
- **Migration:** backfill creates one `enroll` row per existing identity.
- **Live E2E:** enroll Jason once, walk up under different lighting until an `augment/success` event
  is logged, confirm subsequent recognition confidence rises across conditions; then purge and
  confirm rollback.

## v1 scope boundary

**In:** `identity_embeddings` table + backfill migration; multi-point Qdrant gallery; group-by-uuid
max resolution; conservative gated auto-augmentation at end of dwell with audit; cap + diversity-
aware eviction with protected anchors; additive manual re-enroll; purge-by-uuid.

**Deferred (YAGNI for v1):** clustering/medoid compaction (only when galleries get large); a review-
queue UI (we chose auto-add); cross-camera gallery federation; automatic threshold auto-tuning
(manual re-tune for now); per-person gate overrides.
