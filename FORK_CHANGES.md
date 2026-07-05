# FORK_CHANGES

This fork is **vanilla Canvas + one feature family: the Manual Exam Workflow**
(on-paper exam scripts → scores/mastery visible to parents), plus its Phase-2
extension, **Paper Exam Generation** (printable exam papers + companion
`on_paper` assignment) and the admin **letterhead editor**. Branding /
white-label and upstream PR cherry-picks are tracked in git history, not here.

Everything else that once lived in this fork — the Automatic K-12 Result engine
and the native Moments feature — has been **removed** (Phase 10 "un-fork"): both
now live in the standalone Extender App (Postgres + LTI 1.3), which computes
results from Canvas's own grades/outcomes over the API and owns Moments over an
HMAC callback contract. See the migration repo's `EXTENDER_DELIVERABLES.md`.
Drop-migrations `20260705140000` (k12_* tables) and `20260705140001` (moments_*
tables) retire the now-unused tables; the pre-un-fork data is archived.

Design rule followed throughout: **augment, never fork a parallel path.** Scores
go through `AbstractAssignment#grade_student`, files through `FileInContext.attach`
+ `Submission#add_comment`, mastery through `RubricAssociation#assess` →
`LearningOutcomeResult`. No new grading store, no new permission code
(observer/student visibility is upstream's).

---

## Manual Exam Workflow (flag `manual_exam_workflow`)

Files an on-paper exam script against the correct Canvas submission and records
its score + rubric (strand) mastery — all on native Canvas pipelines, so it
stays upstream-merge-safe.

### New files (zero upstream merge risk — upstream never touches them)

| File | What / why |
|---|---|
| `config/feature_flags/page_schools_feature_flags.yml` | Registers `manual_exam_workflow` (applies_to: Account, `state: allowed` = visible, default **off**). Own file so upstream flag files merge cleanly. |
| `db/migrate/20260703100000_create_manual_exam_scripts.rb` | Additive `CREATE TABLE manual_exam_scripts`. Pure bookkeeping: submission → current script (attachment + comment) pointer for idempotent re-uploads. Stores no grades. FKs: cascade on submission, nullify on submission_comment. Nothing upstream records "which attachment is the current graded script"; without it, re-uploads stack duplicate comments. |
| `app/models/manual_exam_script.rb` | Model for the pointer table. |
| `app/services/manual_exams/script_upload_service.rb` | The one-action flow: attach script / record score / assess rubric — each step delegating to the native pipeline. `generate_comments_from_files` (upstream) is zip-only, non-idempotent, has no score/rubric handling. |
| `app/controllers/manual_exam_scripts_controller.rb` | Thin controller: teacher page, printable QR labels (`rqrcode`, already a dependency), single upsert, bulk upsert. Every action gated `not_found unless @context.feature_enabled?(:manual_exam_workflow)` + `:manage_grades`. |
| `app/views/manual_exam_scripts/show.html.erb` | Teacher upload page (per-student forms + bulk with client-side QR decode via browser `BarcodeDetector`; no new JS deps). |
| `app/views/manual_exam_scripts/labels.html.erb` | Printable QR label sheet (layout-less). |
| `app/helpers/manual_exams_helper.rb` | Inline-PDF preview helper. |
| `spec/models/manual_exam_script_spec.rb`, `spec/services/manual_exams/script_upload_service_spec.rb`, `spec/controllers/manual_exam_scripts_controller_spec.rb`, `spec/controllers/manual_exam_inline_preview_spec.rb`, `spec/apis/v1/manual_exam_workflow_spec.rb` | Full coverage: flag on/off, upload→attach→grade→rubric→outcome rollup, gradebook, posting policy, student view, observer positive + negative, idempotent re-upload. |
| `DISCOVERY.md`, `doc/manual_exam_workflow.md` | Docs. |

### Modified upstream files (keep an eye on these at merge time)

| File | Change | Merge risk |
|---|---|---|
| `config/routes.rb` | One contiguous, comment-marked block inside `resources :courses` (manual-exam + paper-exam routes). | **Low.** Additive block; a conflict resolves by re-inserting the block. |
| `app/controllers/files_controller.rb` | `send_attachment`: one appended `|| manual_exam_inline_pdf?(attachment)` in the inline-disposition condition + a marked protected helper. Lets the browser's built-in viewer show PDFs inline when the flag is on. Flag off = byte-identical, proven by spec. | **Medium-low.** Upstream edits this condition rarely; conflict resolves by re-appending the call. |
| `app/views/submissions/show_preview.html.erb` | One comment-marked `elsif` branch before "No Preview Available": embeds the graded script in an iframe when `manual_exam_previewable_script` returns one. Visibility keys off the comment's own read policy (posting policies + observer linking apply). | **Low.** Legacy, stable view; additive branch. |
| `app/models/account.rb` | Two `add_setting` lines (`paper_exam_letterhead`, root_only) — see Paper Exam below. | **Low.** |
| `ui/shared/feature-flags/react/psFlagNotes.json` | One JSON entry for the flag. | **None vs upstream** (file is fork-only). |

## Paper Exam Generation + letterhead (Phase 2, same `manual_exam_workflow` flag)

Turns an **unpublished classic quiz** (a permanent authoring artifact that never
gains a gradebook column) into a printable exam paper + companion `on_paper`
assignment, so exam scores produce **strand mastery**, not a bare score.

### New files (zero upstream merge risk)

| File | What / why |
|---|---|
| `db/migrate/20260703110003_create_paper_exams.rb` | `paper_exams` pointer table (unique quiz↔assignment + `printed_fingerprint`/`printed_at` — the content-version marker behind the truthful "questions changed since printing" drift warning). |
| `app/models/paper_exam.rb` | Model + `drifted?`. |
| `app/services/paper_exams/document.rb` | Source-agnostic renderer input: ordered sections of questions + points. |
| `app/services/paper_exams/preparer.rb` | Idempotent companion `on_paper` assignment: same title, summed points, due date inside the current grading period, and a rubric whose criteria carry the questions' **bank-level outcome alignments** (`use_for_grading: false` — score entered directly, rubric carries mastery). |
| `app/services/paper_exams/letterhead.rb` | Admin-designed HTML letterhead with `{{variables}}`, sanitized at save AND render, values HTML-escaped. |
| `app/controllers/paper_exams_controller.rb`, `app/controllers/paper_exam_letterheads_controller.rb` | Thin controllers (prepare/print + letterhead editor with live preview). |
| `app/views/paper_exams/*`, `app/views/paper_exam_letterheads/*` | Print CSS (real Nigerian exam format: crest + institution block, underlined Instruction/Time Allowed, bold right-aligned marks, MCQ tick boxes, ruled answer space by question type, `page-break-inside: avoid`, per-student QR headers routing scans into the bulk upload); the letterhead editor. |
| specs | Preparer, drift, print format, letterhead sanitization. |

### Modified upstream files

| File | Change | Merge risk |
|---|---|---|
| `config/routes.rb` | Paper-exam routes appended to the existing marked manual-exam block, + account letterhead routes. | **Low** — additive. |
| `app/models/account.rb` | `add_setting :paper_exam_letterhead, root_only: true`. | **Low** — one line, K-12 precedent (now the only such add_setting). |

### Known limits

- QR decoding is client-side (`BarcodeDetector`, Chromium). Fallbacks: filename prefix, then manual selection. Unmatched files reported, never guessed.
- Bulk upload is synchronous (classroom-sized batches).
- Bank-linked question groups print a deterministic `pick_count` selection (ordered by id) — no per-student variants; `text_only_question` renders as instructions.

**Deploy note:** run `bin/rake db:migrate` when rolling out the image containing
this feature (additive tables). The Phase-10 drop-migrations
(`20260705140000/1`) retire the removed K-12 + Moments tables.
