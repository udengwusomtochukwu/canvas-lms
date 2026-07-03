# FORK_CHANGES

## Moments (Phase 1 — flag `moments_native`, plugin `moments_backend`)

Per-child, consent-gated classroom highlight reels, native to the fork (plan:
`MOMENTS_DISCOVERY.md`). All grading-adjacent rules live in models, all
guardrails (G1–G6) carry over from the original system.

**New files (zero upstream merge risk):** migrations
`20260705100000/1` (5 additive tables: sessions, clips, clip_tags, consents,
reels — no core tables touched), models `app/models/moments/*` (consent +
course-membership validation on ClipTag = G2/G3; Reel policy mirrors the
submission observer block = G6), `lib/moments_backend.rb` (HMAC-signed client
for the configurable backend), controllers `app/controllers/moments*`
(role-aware `/moments`, course sessions/tagging/consents, HMAC-authenticated
callbacks with `skip_before_action :load_user` — lti_api precedent), views
`app/views/moments/**`, plugin partial, specs + shared context.

**Modified upstream files:**

| File | Change | Merge risk |
|---|---|---|
| `app/views/shared/_new_nav_header.html.erb` | One comment-marked, flag-gated `<li>` (Moments rail item, inline SVG icon) before the external-tools partial. | **Medium** — upstream touches this file occasionally; conflict resolves by re-inserting the block. |
| `lib/canvas/plugins/default_plugins.rb` | One marked `Canvas::Plugin.register("moments_backend", ...)` block at the end (base_url + encrypted shared_secret). | **Low** — appended registration. |
| `config/routes.rb` | Marked Moments blocks (course-scoped + top-level + callback). | **Low** — additive. |
| `config/feature_flags/page_schools_feature_flags.yml`, `ui/shared/feature-flags/react/psFlagNotes.json` | New flag entries. | Fork-only files. |

**Deliberate choices:** raw/intermediate media never enters Canvas storage
(sidecar-owned, purged per G5) — only approved reels/thumbnails become
Attachments; backend contract passes opaque refs only (identity-blind by
wire-format, not by promise); ERB + vanilla JS (no webpack bundles).
**Phase 1 scope ends at tagging** — captions/compile/deliver callbacks and
the worker v2 endpoints (LM repo, `services/moments-worker`) are Phase 2.

---

# FORK_CHANGES — Manual Exam Workflow

Every core change this feature makes to the fork, with the reason, why the
existing code couldn't be reused as-is, and the merge risk against upstream
(`instructure/canvas-lms`). Branding and other pre-existing fork changes are
tracked in git history, not here.

Design rule followed throughout: **augment, never fork a parallel path.**
Scores go through `AbstractAssignment#grade_student`, files through
`FileInContext.attach` + `Submission#add_comment`, mastery through
`RubricAssociation#assess` → `LearningOutcomeResult`. No new grading store,
no new permission code (observer/student visibility is upstream's).

## New files (zero upstream merge risk — upstream never touches them)

| File | What / why |
|---|---|
| `config/feature_flags/page_schools_feature_flags.yml` | Registers `manual_exam_workflow` (applies_to: Account, `state: allowed` = visible, default **off**). Own file so upstream flag files merge cleanly. |
| `db/migrate/20260703100000_create_manual_exam_scripts.rb` | Additive `CREATE TABLE manual_exam_scripts`. Pure bookkeeping: submission → current script (attachment + comment) pointer for idempotent re-uploads. Stores no grades. FKs: cascade on submission (submissions can be hard-deleted via `dependent: :delete_all`), nullify on submission_comment (comments hard-delete). Not reusable-instead: nothing upstream records "which attachment is the current graded script"; without it, re-uploads stack duplicate comments (that is exactly what the upstream zip re-upload does). |
| `app/models/manual_exam_script.rb` | Model for the pointer table. |
| `app/services/manual_exams/script_upload_service.rb` | The one-action flow: attach script / record score / assess rubric — each step delegating to the native pipeline. Not reusable-instead: `generate_comments_from_files` is zip-only, routes by download-generated filenames that on_paper assignments never have, has no score/rubric handling, and is non-idempotent. |
| `app/controllers/manual_exam_scripts_controller.rb` | Thin controller: teacher page, printable QR labels (`rqrcode`, already a dependency), single upsert, bulk upsert. Every action gated `not_found unless @context.feature_enabled?(:manual_exam_workflow)` + `:manage_grades`. |
| `app/views/manual_exam_scripts/show.html.erb` | Teacher upload page (per-student forms + bulk with client-side QR decode via browser `BarcodeDetector`; no new JS deps, no webpack bundle). |
| `app/views/manual_exam_scripts/labels.html.erb` | Printable QR label sheet (layout-less). |
| `spec/models/manual_exam_script_spec.rb`, `spec/services/manual_exams/script_upload_service_spec.rb`, `spec/controllers/manual_exam_scripts_controller_spec.rb`, `spec/apis/v1/manual_exam_workflow_spec.rb` | Full coverage: flag on/off, upload→attach→grade→rubric→outcome rollup, gradebook, posting policy, student view, observer positive + negative, idempotent re-upload. |
| `DISCOVERY.md`, `FORK_CHANGES.md`, `doc/manual_exam_workflow.md` | Docs. |

## Modified upstream files (keep an eye on these at merge time)

| File | Change | Merge risk |
|---|---|---|
| `config/routes.rb` | One contiguous, comment-marked block of 4 routes inside `resources :courses` (before `resource :gradebook`). | **Low.** Additive block; a conflict resolves by re-inserting the block. |
| `ui/shared/feature-flags/react/psFlagNotes.json` | One JSON entry for the new flag. | **None vs upstream** (file is fork-only), trivial vs our own edits. |
| `app/controllers/files_controller.rb` | `send_attachment`: one appended `\|\| manual_exam_inline_pdf?(attachment)` in the inline-disposition condition + a marked protected helper. Lets the browser's built-in viewer show PDFs inline when the flag is on (stock Canvas never inlines PDFs; DocViewer is a commercial service). Flag off = byte-identical behaviour, proven by spec. | **Medium-low.** Upstream edits this condition rarely; conflict resolves by re-appending the call. |
| `app/views/submissions/show_preview.html.erb` | One comment-marked `elsif` branch before "No Preview Available": embeds the graded script in an iframe when `manual_exam_previewable_script` (new fork helper) returns one — so students/parents see the scanned script in the submission preview pane. Visibility keys off the comment's own read policy (posting policies + observer linking apply). | **Low.** Legacy, stable view; additive branch. |

Additional fork-only files for the preview: `app/helpers/manual_exams_helper.rb`, `spec/controllers/manual_exam_inline_preview_spec.rb`.

## Deliberate choices / limitations

- **QR decoding is client-side** (`BarcodeDetector`, Chromium browsers). Server-side
  decoding would add a native-extension dependency (zxing/zbar) to the image; declined.
  Fallbacks: `<studentId>_name.pdf` filename prefix (server-side), then manual
  per-file student selection in the UI. Unmatched files are reported, never guessed.
- **Bulk upload is synchronous** (classroom-sized batches). The upstream zip
  re-upload uses a `Progress` + delayed job; if batches ever exceed ~100 files,
  wrap `ScriptUploadService` calls in a `Progress.process_job` the same way.
- **Rubric UI is SpeedGrader.** The upload page handles file + score; the rubric
  (strand mastery) is filled in SpeedGrader as usual, or via the endpoint's
  `rubric_assessment` param (same format as the Submissions API).
- **No GraphQL surface** was added — keeps the upstream-merge surface minimal;
  the data all flows through existing REST/GraphQL types (submissions, comments,
  attachments, outcome rollups) anyway.
- **Deploy note:** run `bin/rake db:migrate` (one additive table) when rolling
  out the image containing this feature.
