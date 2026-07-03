# FORK_CHANGES

## Automatic K-12 Result (flag `automatic_k12_result`)

The native termly + sessional report card (plan: `DISCOVERY.md`, docs:
`doc/automatic_k12_result.md`, test guide: `TESTING.md`). Design rule:
**no parallel grade store** — scores are read from the same `scores` rows
GradeCalculator maintains (period + course-level); the new tables hold only
what Canvas doesn't compute: class rank, per-(course, period) median, the
sessional rollup, and render-ready snapshots (mastery, CA/exam split,
staff-entered traits/remarks).

**New files (zero upstream merge risk):** migrations `20260703120000/1`
(3 additive tables: `k12_result_sets`, `k12_course_results`,
`k12_session_results`; CREATE only), models `app/models/k12_*.rb`, engine
`app/services/k12_results.rb` + `app/services/k12_results/*`
(Config / CourseRecalculator / SessionRecalculator — coalesced singleton jobs
copied from the ScoreStatisticsGenerator idiom, `on_conflict: :loose`, one
set-level pass per (course, period) so ranking is race-free), controllers
`app/controllers/k12_report_cards_controller.rb` (student/observer card,
HTML + prawn PDF), `k12_results_controller.rb` (teacher course page),
`k12_result_settings_controller.rb` (account policy), views
`app/views/k12_report_cards/**` (incl. `show.pdf.prawn` — prawn-rails is the
codebase's existing PDF engine), `k12_results/`, `k12_result_settings/`,
specs (`spec/services/k12_results*`, `spec/controllers/k12_*`) + shared
helper `spec/support/k12_results_spec_helper.rb`.

**Modified upstream files:**

| File | Change | Merge risk |
|---|---|---|
| `lib/grade_calculator.rb` | 3-line hook at the end of `compute_and_save_scores` + one private method: queue the coalesced result recompute after Score rows persist (guarded `@ignore_muted`, like `update_score_statistics`; wrapped in `Canvas::Errors.capture_exception` so it can never break grading). Chosen over a `Module#prepend` from an initializer so upstream reshaping the method surfaces as a loud conflict instead of a silent no-op. | **Low-Medium** — hot upstream file, but the hook is an append at a stable seam. |
| `app/models/score.rb` | Flag-guarded `after_save` for `override_score` changes — final-grade override edits write Scores via plain AR without running GradeCalculator, so this is the one grading path the hook above misses. GradeCalculator's bulk SQL upserts bypass callbacks, so this fires only for overrides. | **Low** — small, stable file. |
| `app/models/account.rb` | One `add_setting :k12_result, root_only: true` line. | Trivial. |
| `config/routes.rb` | Marked K-12 Result blocks (course-scoped + top-level user/account). | **Low** — additive. |
| `config/feature_flags/page_schools_feature_flags.yml`, `ui/shared/feature-flags/react/psFlagNotes.json` | New flag entry + plain-English note. | Fork-only files. |

**Deliberate choices:** positions use standard competition ranking
("1,2,2,4") computed only over graded students — ungraded students are never
silently ranked bottom or scored 0 (the two position modes change the
displayed denominator: enrolled vs attempted); the sessional ranking cohort
is the union of a student's coursemates in the term (= the class arm in this
deployment, where subject courses share rosters); mastery is snapshotted
through `Outcomes::ResultAnalytics` with student-visible semantics (muted/
unposted excluded) and period-scoped on `COALESCE(submitted_at, assessed_at)`
— the same timestamp the rollup engine orders by (Canvas has no native
period filter for outcome results); the CA/exam split is the one value
derived from submissions (posted, graded, non-excused, period-scoped via
`submissions.grading_period_id`) because Canvas has no per-period
per-assignment-group score — the subject total itself always comes from the
Score row; ERB + inline styles, no webpack bundles (hot-patchable, no image
rebuild for iteration).

**Deploy note:** run `bin/rake db:migrate` (three additive tables), rebuild
the image for the `psFlagNotes.json` entry (cosmetic only), enable the
account flag, then configure `/accounts/1/k12_result_settings`.

---

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
| `app/views/shared/_new_nav_header.html.erb` | One comment-marked, flag-gated `<li>` (Moments rail item, inline SVG icon) before the external-tools partial — used when `instui_nav` is off. | **Medium** — upstream touches this file occasionally; conflict resolves by re-inserting the block. |
| `ui/features/navigation_header/react/SideNav.tsx` | Marked, flag-gated `SideNavBar.Item` after History — used when `instui_nav` is on (the React nav hardcodes its items, so both navs need the entry). | **Medium** — upstream iterates on this component; conflict resolves by re-inserting the block. |
| `app/controllers/application_controller.rb` | One symbol (`moments_native`) added to `JS_ENV_ROOT_ACCOUNT_FEATURES` so the React nav can see the flag via `ENV.FEATURES`. | **Low** — one line in a long frozen list. |
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

# FORK_CHANGES — Manual Exam phase 2: Paper Exam Generation

Turns an **unpublished classic quiz** into a printable exam paper + companion
`on_paper` assignment. The model (deliberate, Path A): the quiz is a
PERMANENTLY UNPUBLISHED authoring artifact — chosen to reuse Canvas's quiz
editor and question banks (the same banks that feed online CAs and carry
outcome alignments) instead of rebuilding question authoring. It never gains
a gradebook column (classic quizzes only create their shadow assignment on
publish, and `prepare` refuses published quizzes); the companion assignment
holds all graded reality via the existing manual exam workflow.

**New files (zero upstream merge risk):** migration `20260703110003/4`
(`paper_exams`: unique quiz↔assignment pointer + `printed_fingerprint`/
`printed_at` — the content-version marker behind the truthful "questions
changed since printing" drift warning), `app/models/paper_exam.rb`,
`app/services/paper_exams/document.rb` (source-agnostic renderer input:
ordered sections of questions+points — a future assignment-owned question
source reuses the print view and the whole return path),
`app/services/paper_exams/preparer.rb` (idempotent: same title, summed
points, due date inside the current grading period, and a companion rubric
whose criteria carry the questions' **bank-level outcome alignments** with
`use_for_grading: false` — score entered directly, rubric carries strand
mastery for rollups/report cards), `app/controllers/paper_exams_controller.rb`,
`app/views/paper_exams/*` (print CSS: Nigerian exam format — header/motto,
name/adm-no lines, lettered sections with mark totals, MCQ tick boxes,
ruled answer space by question type, `page-break-inside: avoid`, per-student
QR headers routing scans into the existing bulk upload), specs.

**Modified upstream files:** `config/routes.rb` (3 routes appended to the
existing marked manual-exam block — low risk). Also two of OUR phase-1 files
(`manual_exam_scripts_controller.rb` + its show view) gained the drift
banner — fork-owned, no upstream risk.

**Known limits:** bank-linked question groups print a deterministic
`pick_count` selection (ordered by id) — no per-student variants;
`text_only_question` renders as instructions.

**Letterhead (admin-designed):** the print layout follows real Nigerian past
papers (centred crest + institution block, underlined Instruction/Time
Allowed, bold right-aligned marks; theory prints without answer space —
`answer_space=1` restores ruled lines). Admins can replace the header
entirely at `/accounts/:id/paper_exam_letterhead`: HTML with `{{variables}}`
(`PaperExams::Letterhead`), live preview, sanitized through
`CanvasSanitize::SANITIZE` at save AND render with substituted values
HTML-escaped. Stored via one `add_setting :paper_exam_letterhead,
root_only: true` line in `app/models/account.rb` (trivial merge risk, K-12
precedent). Blank template = built-in header.

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
