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

## Modified upstream files (the only two — keep an eye on these at merge time)

| File | Change | Merge risk |
|---|---|---|
| `config/routes.rb` | One contiguous, comment-marked block of 4 routes inside `resources :courses` (before `resource :gradebook`). | **Low.** Additive block; a conflict resolves by re-inserting the block. |
| `ui/shared/feature-flags/react/psFlagNotes.json` | One JSON entry for the new flag. | **None vs upstream** (file is fork-only), trivial vs our own edits. |

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
