# MOMENTS_DISCOVERY — porting Moments into the fork as a native feature

Discovery + plan for moving Moments (per-child, consent-gated classroom
highlight reels; currently Next.js/Payload + Mongo + MinIO + Python workers)
into this Canvas fork, so rosters, parent links, auth and visibility are
Canvas-native — following the same discipline as the Manual Exam Workflow
(flag-gated, native pipelines, mostly new files).

Design decisions already made (from product discussion):
- **Global nav rail item** "Moments", like Courses/Calendar/Inbox.
- **Per-role landing**: student → own timeline; parent/observer → child
  picker then timeline; teacher → capture + review for their courses.
- **Timeline grouped by day** (`captured_at`), **scoped by EnrollmentTerm**:
  defaults to the current term, older terms via a term picker (moments are
  kept, not purged, on term rollover — reversible decision).
- **Backend is configurable**: ships with the compose sidecar by default,
  but an admin can point it at a remote/cloud deployment — configured the
  same way SAML/Canvadocs-style integrations are (Admin → Plugins).

---

## 1. What exists today (the system being ported)

Phase 0 (M0) is complete and working in the `Learning Management` monorepo:

| Piece | Where | Notes |
|---|---|---|
| Data | Mongo via Payload: `MomentsSessions`, `MomentsClips`, `MomentsReels` + `students.momentsConsent` | Sessions (raw video, status machine), clips (identity-blind ~30s segments w/ `highlightScore`, human `taggedChildren`, reviewed `caption`), reels (per-child mp4, `visibleToParents` gate) |
| Storage | MinIO, tenant-prefixed keys `{school}/sessions/{id}/…`, `{school}/reels/{child}/…` | Presigned PUT (15 min) / GET (60 min); raw purged after compile + 48h grace |
| Compute | `services/moments-worker`: FastAPI (`/jobs/segment`, `/jobs/compile`, `/jobs/record`, `/jobs/monitor`, `/progress/{id}`) + 2 RQ workers (main + live queues) + Redis | FFmpeg/OpenCV/PySceneDetect signal scoring — **no ML, no identity** (G1); RTSP window-record and live-monitor modes |
| Captions | Claude vision on 2–3 keyframe stills per clip, locked observable-actions-only system prompt, human review + approval | Prompt must move VERBATIM |
| UI | `/moments` staff pages (upload, tagging board, caption review, consent manager) + parent portal reel playback | 15 API routes |
| Guardrails | **G1** no face/biometric/ML identity; **G2** identity only via human tagging; **G3** consent opt-in enforced at write AND re-checked at compile; **G4** stills-only + locked prompt + human approval; **G5** raw purge (retention clock + hourly sweep, monitor mode never stores raw); **G6** tenant isolation at every layer | All six carry over unchanged |
| Roster sync | Payload students carry `canvasUserId`; Payload→Canvas enrollment push | **This is the layer the port deletes** — in Canvas the roster *is* the source |

## 2. Canvas primitives the port lands on (verified in this fork)

| Need | Native primitive | Where |
|---|---|---|
| Global nav item | Server-rendered ERB rail — add one flag-gated `<li>` | `app/views/shared/_new_nav_header.html.erb:104-245` (fork already patches this file for white-label; no webpack rebuild needed) |
| Configurable backend | `Canvas::Plugin.register` + settings partial + encrypted settings | `lib/canvas/plugins/default_plugins.rb:303` (canvadocs example: `base_url` + `api_key`), `app/views/plugins/_canvadocs_settings.html.erb`, `PluginSetting` (auto-encryption, caching). Admin UI at `/plugins` |
| Term scoping | `EnrollmentTerm` (`app/models/enrollment_term.rb`) — course→term FK; timeline filters via the student's courses' terms | Seeds already model "Second Term" |
| Teacher's class roster | `course.participating_students` — exactly the students in that teacher's course, nothing else | Same call the manual-exam page uses |
| Parent↔child | `ObserverEnrollment.associated_user_id` + the cookie-based child picker | `app/helpers/observer_enrollments_helper.rb:31-56` (`k5_observed_user_for_…` pattern) |
| Visibility policy | Mirror the submission observer policy block (already spec-proven in this fork for manual exams) | `app/models/submission.rb:625-649` as template |
| Durable media | Native `Attachment` (reels ≤720p mp4, thumbnails). **Avoid Kaltura/MediaObject** — degrades gracefully when unconfigured; serve reels as plain attachments w/ `<video>` | `attachment.rb:2481` |
| Async + retries | `delay(n_strand:, run_at:, priority:)` + `max_attempts`, canvadocs-style | `app/models/attachment.rb:2153-2191` as template |
| User-scoped top-level page | `/calendar`-style route + controller (`calendars_controller.rb:21-92`) | `get "moments" => "moments#index"` |

## 3. Architecture of the port

**Split of responsibilities (the key decision):**

- **Canvas = system of record for everything human and durable**: sessions
  (metadata + status), clips (metadata, scores, tags, captions, review
  states), consent, reels (final mp4 as Attachment), visibility, terms.
  Identity (who is tagged) NEVER leaves Canvas.
- **Sidecar = compute + transient media**: raw video, intermediate clips and
  keyframes live in the sidecar's own S3/MinIO (satisfying G5 — Canvas never
  stores unvetted raw footage); segmentation/compile/RTSP jobs; caption
  drafting (it holds the keyframes and the Anthropic key — the locked G4
  prompt moves verbatim into the sidecar).

This keeps the existing Python worker ~90% intact: `media.py`, the pipeline
stages, queues and monitor mode are unchanged. What changes: Mongo reads/
writes become **signed HTTP callbacks to Canvas**, and per-child refs in the
compile request become **opaque numeric ids** (worker stays identity-blind).

**Sidecar contract v2** (shared-secret HMAC both directions):
- Canvas→worker: `POST {base_url}/jobs/segment {session_ref, callback_url}`;
  `POST /jobs/compile {session_ref, reels: [{child_ref, clip_refs[]}]}`;
  `POST /jobs/record|monitor|stop-monitor` (RTSP); `GET /progress/{ref}` (proxied).
  Upload stays presigned-PUT direct to worker storage (raw never transits Canvas).
- Worker→Canvas: `POST /api/moments/callbacks/segmented` (clip list: offsets,
  scores, thumbnail+keyframe fetch URLs — Canvas pulls thumbnails into small
  Attachments); `/callbacks/captions` (drafts per clip); `/callbacks/compiled`
  (reel fetch URL per child_ref — Canvas pulls the mp4 into an Attachment,
  creates the reel row); `/callbacks/progress|error`.

**Configurability (the SAML-style requirement):** register plugin
`moments_backend` with settings `base_url` (default
`http://moments-worker:8000`, the compose sidecar), `api_key`/shared secret
(encrypted via `encrypted_settings`), timeouts. Admin → Plugins → Moments
Backend swaps in a cloud deployment with zero code change. The sidecar stack
(worker + redis + minio) stays a standalone compose unit exactly as today —
deployable next to Canvas or on another cloud.

## 4. Data model (additive migrations, no grading/core tables touched)

- `moments_sessions` — course, created_by, title, captured_at, clip_seconds,
  workflow_state (uploaded→processing→segmented→tagging→captioning→
  compiling→delivered), sidecar_ref, retention fields, root_account.
- `moments_clips` — session, start_ms/end_ms, highlight_score,
  thumbnail attachment, sidecar keyframe refs, caption, caption_status
  (none/draft/needs_review/approved), root_account.
- `moments_clip_tags` — clip, student (user), tagged_by, unique(clip, student).
  **G2/G3 hook**: validates active enrollment in the session's course AND
  `moments_consents.opt_in` — rejected server-side, mirroring `enforceConsent`.
- `moments_consents` — student (user), opt_in, consented_by, consented_at,
  note, root_account. (Own table — no column on `users`, zero merge risk.)
- `moments_reels` — student (user), session, attachment (final mp4),
  workflow_state (compiling→ready→delivered), delivered_at, root_account.
  Policy: course teachers/admins manage; student reads own **delivered**
  reels; linked observers read via `associated_user_id`; others nothing.
  G3 re-check at delivery time (consent revoked ⇒ reel not delivered).
- G6 note: single-school deployment, but scope everything by root_account
  anyway (Canvas convention + free multi-tenant correctness).

## 5. UI (server-rendered ERB like the manual-exam pages; no React bundles)

- **Nav rail**: one marked, flag-gated `<li>` in `_new_nav_header.html.erb` → `/moments`.
- **`/moments`** routes by role:
  - *Teacher*: their courses → sessions list, upload form (presigned PUT),
    RTSP form, per-session board: clip grid (thumbnails), click-to-tag from
    `course.participating_students` (consented students enabled), caption
    review + approve, compile + deliver buttons, progress poll.
  - *Student*: timeline — delivered reels grouped by day, newest first,
    current term default, term picker.
  - *Observer*: child picker (cookie pattern) → same timeline for that child.
- **Consent manager**: per-course page for staff (list, toggle, who/when/note).
- Reel playback: native attachment inline URL in `<video>` (same file-access
  path as manual-exam scripts; the inline-PDF work already opened this trail).

## 6. Migration & portal impact

- One-off `script/moments_import.rb` (or rake task): Mongo sessions/clips/
  reels + consent → new tables (map `student.canvasUserId`), reel mp4s +
  thumbnails MinIO → Canvas Attachments. Raw videos are NOT migrated (G5 —
  most are purged already).
- Parent portal: Canvas becomes source of truth. Portal reel views either
  retire or read a small flag-gated REST index (`GET /api/moments/reels?child_id=`)
  — decision deferred to rollout.
- Delivery notification: phase 1 = visible in timeline only; a native
  BroadcastPolicy notification ("New Moment delivered") is a phase-3 nicety.

## 7. Phases

1. **Foundation**: flag `moments_native` (Account, default off) + plugin
   `moments_backend` + migrations + models/policies + nav item + teacher
   upload/session pages + sidecar contract v2 (segment + callbacks) +
   tagging with consent enforcement + consent manager. Specs: flag off=404s
   & no rail item, consent negative, tag roster limited to course students.
2. **Review → deliver**: caption drafts via sidecar, review/approve UI,
   compile/deliver flow with G3 re-check, student+observer timelines with
   term picker. Specs: observer positive/negative, delivery gating, term
   filtering, caption approval required before compile.
3. **Parity + cutover**: RTSP record/monitor passthrough, retention sweep
   coordination (sidecar purges raw; Canvas records `raw_purged_at`), Mongo/
   MinIO import script, portal read-API or retirement, notifications.

Worker changes (LM repo, parallel track): replace Mongo client with Canvas
callback client + HMAC signing; accept opaque child_refs; keep everything else.

## 8. Risks / open questions

- `_new_nav_header.html.erb` is the one recurring-merge-risk touch (upstream
  edits it occasionally); keep the block marked and single.
- Reel files in Canvas storage: ~10-40MB each; fine at one-school scale —
  revisit quotas if multi-school.
- Live-monitor progress UX in ERB (polling) is basic vs the React original —
  acceptable for phase 1.
- Decide at cutover: keep portal reel view (read from Canvas) or retire.
