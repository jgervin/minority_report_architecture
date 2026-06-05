# AdFace — Personalized OOH Advertising Platform
### 30,000 ft Product Requirements Document

---

<project_overview>
**Name:** AdFace — Personalized Out-of-Home Advertising Platform  
**Codename:** ADFACE  
**Vision:** A real-time, AI-driven out-of-home advertising system that identifies individuals via computer vision, dynamically generates or assembles personalized video advertisements addressed to that person by name, and displays them full-screen on digital signage — inspired by the Minority Report concept.  
**Build Philosophy:** Build in public, MVP-first. Deliver a small vertical slice across all four pillars before deep-diving any single one.  
**Business Model Status:** TBD — operator-controlled model (we run everything, brands/retailers come to us) is the leading candidate. Self-serve brand dashboard (Pillar 4) is deferred until business model is confirmed.
</project_overview>

---

<pillars>

  <pillar id="P1" name="Vision and Identity Engine" priority="1">
    <description>Camera capture, real-time face detection, identification against a vector database, and optional demographic inference. This is the entry point of every personalization loop.</description>
    <mvp_scope>Single-camera feed, DeepFace recognition against a pre-seeded vector DB, result emitted to event bus with identity UUID and confidence score.</mvp_scope>
    <components>
      - P1-C1 Camera Capture Service — OpenCV, RTSP/USB ingestion, configurable frame sampling
      - P1-C2 Face Detection and Embedding Generator — DeepFace with ArcFace or FaceNet backend
      - P1-C3 Vector DB Identity Store — Qdrant / Pinecone / Weaviate (TBD); cosine similarity lookup; embeddings linked to pseudonymous UUIDs only
      - P1-C4 Identity Resolution Service — FastAPI microservice; returns UUID + confidence + is_new_visitor flag
      - P1-C5 Demographic Inference (Phase 2) — DeepFace attribute analysis for age/gender fallback when identity is unknown
    </components>
    <data_flow>Camera Frame → Face Detection → Embedding Extraction → Vector DB Lookup → Identity UUID emitted to event bus</data_flow>
    <open_questions>
      - Camera hardware spec (resolution, FOV, lighting)?
      - Acceptable false-positive rate for identity matching?
      - Enrollment model — opt-in kiosk, loyalty program tie-in, or manual seeding for demo?
      - Biometric data legal review required before any public deployment (BIPA, GDPR, CCPA).
    </open_questions>
  </pillar>

  <pillar id="P2" name="Ad Composition and Delivery Engine" priority="2">
    <description>Receives identity UUID from P1, selects the appropriate campaign, assembles or generates a personalized video, and pushes it to the display for full-screen playback.</description>
    <mvp_scope>Pre-composed base video with dynamic name injection via ElevenLabs TTS audio spliced in at a defined timecode using ffmpeg. GenAI video generation is Phase 2.</mvp_scope>
    <components>
      - P2-C1 Ad Selector / Campaign Matcher — rule-based selection MVP; ML ranker in Phase 2; backed by PostgreSQL/Supabase
      - P2-C2 Video Assembly Service (ffmpeg path) — splice personalized audio into base video; target assembly time under 3 seconds
      - P2-C3 Voice Synthesis Service — ElevenLabs API; pre-cache common names to reduce latency; fallback to cached TTS if API is down
      - P2-C4 GenAI Video Generation Service (Phase 2) — Runway ML / Kling / Nanobanna; triggered at detection time while base ad plays to hide generation latency; optional face/likeness inclusion requires consent framework
      - P2-C5 Display / Playback Controller — full-screen kiosk (React + HTML5 video or Electron); WebSocket trigger; handles idle loop → personalized ad → return to idle
    </components>
    <data_flow>Identity UUID → Ad Selector → Campaign Template → Voice Synthesis → ffmpeg Assembly → Video Asset → Display Controller → Full-screen Playback</data_flow>
    <open_questions>
      - Maximum acceptable latency from face detection to playback start?
      - Will the ad ever incorporate the person's likeness? Consent mechanism required if so.
      - Video asset storage — S3 or local?
      - If person walks away before assembly completes, cancel or play anyway?
    </open_questions>
  </pillar>

  <pillar id="P3" name="God View — Operator Super Admin Dashboard" priority="3">
    <description>Full-visibility control plane for the system operator. Shows all system activity, AI prompts and outputs, identity embeddings, campaign performance, errors, and platform health in real time.</description>
    <mvp_scope>Read-only activity log feed showing detection events, matched UUID, campaign triggered, and video output. Error/fault panel for camera and AI services.</mvp_scope>
    <components>
      - P3-C1 Activity Feed and Event Log — real-time WebSocket/SSE feed; React + shadcn/ui; filterable by camera, location, time, UUID, campaign
      - P3-C2 AI Prompt and Output Inspector — full audit trail of all GenAI API calls (ElevenLabs, video gen, LLM); expand/collapse per event
      - P3-C3 Embedding and Identity Browser — browse DeepFace embeddings and visit history per UUID; no raw PII displayed
      - P3-C4 System Health and Fault Monitor — camera online/offline, AI API latency/errors, DB status, display heartbeat; alert on failures
      - P3-C5 User and Account Management — RBAC for operator admins and brand users; Supabase Auth or Clerk
      - P3-C6 Campaign and Video Asset Manager — CRUD for campaigns and base video assets; upload, tag, activate/deactivate, schedule
    </components>
    <data_flows>
      - All system events → Event Log DB → Real-time feed to dashboard
      - All AI API calls → Prompt/Output Logger → AI Inspector panel
      - Camera heartbeat + service health → Health Monitor → Alert triggers
    </data_flows>
    <open_questions>
      - Self-hosted or cloud-deployed dashboard?
      - Alerting channels needed — email, SMS, Slack?
      - Event log retention period?
    </open_questions>
  </pillar>

  <pillar id="P4" name="Brand and Retailer Self-Serve Dashboard" priority="4" status="DEFERRED">
    <description>Scoped dashboard for brands, mall operators, and retail clients to manage their own campaigns and view performance — isolated to their account only.</description>
    <mvp_scope>Deferred. Business model must be finalized first. Only needed if moving to a self-serve SaaS model vs. fully managed operator model.</mvp_scope>
    <components>
      - P4-C1 Campaign Management (scoped) — reuses P3-C6 with RBAC scoping; no cross-brand visibility
      - P4-C2 Analytics and Performance Reporting — impressions, unique visitor estimates, campaign delivery stats; Recharts or similar
      - P4-C3 Fault Visibility (scoped) — filtered view of P3-C4 data for their campaigns and locations only
    </components>
    <open_questions>
      - Fully managed vs. self-serve business model decision required first.
      - Billing model — CPM, flat rate, per-play?
      - What campaign customization is permitted vs. operator-controlled?
    </open_questions>
  </pillar>

</pillars>

---

<cross_cutting_concerns>

  <data_architecture>
    - **Vector DB:** Facial embeddings + identity UUIDs — Qdrant, Pinecone, or Weaviate (TBD)
    - **Relational DB:** User accounts, campaigns, event logs, asset metadata — PostgreSQL via Supabase
    - **File Storage:** Video assets, rendered ad clips, AI-generated media — S3 or local NAS
    - **Event Bus:** Decouples P1 detection events from P2 ad trigger — Redis Streams or NATS
  </data_architecture>

  <tech_stack>
    - **Backend:** Python, FastAPI microservices
    - **Frontend:** React, shadcn/ui
    - **Face ID:** DeepFace (ArcFace or FaceNet backend)
    - **Voice:** ElevenLabs API
    - **Video Assembly:** ffmpeg
    - **GenAI Video (Phase 2):** Runway ML / Kling / Nanobanna
    - **Auth:** Supabase Auth or Clerk
    - **Infra:** Docker Compose for local dev; Kubernetes or Railway for cloud
  </tech_stack>

  <legal_and_compliance priority="HIGH">
    Must be addressed before any public deployment.
    - Biometric data laws: BIPA (Illinois), GDPR (EU), CCPA (California)
    - Consent framework required for identity enrollment
    - Data retention and right-to-deletion policies
    - Likeness rights if face is used in GenAI video
    - Physical signage disclosure requirements (camera and AI in use)
  </legal_and_compliance>

  <privacy_by_design>
    - No PII stored in vector DB — embeddings linked to pseudonymous UUIDs only
    - Opt-in enrollment for named identity; anonymous demographic fallback for unknown visitors
    - Embeddings encrypted at rest
    - Automatic embedding expiry / TTL policy
  </privacy_by_design>

</cross_cutting_concerns>

---

<build_order>

  <phase id="0" name="MVP Vertical Slice" goal="Public demo — person walks in front of camera, screen plays ad calling them by name">
    Single camera → DeepFace match against pre-enrolled test identity → ElevenLabs name call-out → ffmpeg assembly → full-screen playback → minimal event log entry.
    Pillars touched: P1 (C1–C4), P2 (C2, C3, C5), P3 (C1 minimal).
  </phase>

  <phase id="1" name="Expand Each Pillar">
    - Multi-camera support (P1)
    - Campaign selector with multiple ad templates (P2-C1)
    - GenAI video generation integration (P2-C4)
    - Full God View dashboard (P3 all components)
  </phase>

  <phase id="2" name="Scale and Productize">
    - Brand/retailer dashboard (P4) — if business model warrants
    - ML-based ad ranking and personalization engine
    - Multi-location networked display management
    - Consent and enrollment kiosk UX
  </phase>

</build_order>
