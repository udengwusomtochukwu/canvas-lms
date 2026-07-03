# DISCOVERY — Manual Exam Workflow

Investigation of the fork (`page-schools/main`, pinned upstream `release/2026-03-11.209`)
before building anything. Verdict per system, with file references.

**Bottom line: no manual/offline exam feature exists (upstream or fork-added). Every
building block it needs already exists and is reusable. What's missing is a thin,
idempotent glue layer: upload-a-graded-script + enter-score + fill-rubric in one
teacher action, bulk routing of scans, and a stable "current script" pointer. Build
only that.**

---

## 1. Does a manual/offline/on-paper exam grading feature already exist?

**ABSENT as a feature; PARTIAL as raw building blocks.**

- No `manual_exam` / offline-exam / scanned-script flag or code anywhere:
  `config/feature_flags/*.yml`, `app/`, `lib/`, `ui/` — zero hits.
- Fork-added commits are branding/QoL only (white-label, feature-option summaries,
  QTI fixes); nothing exam-related. Remotes: `origin` = our fork, `upstream` = instructure.
- QR: `rqrcode ~> 3.0` is already a dependency (`Gemfile.d/app.rb`) but is used only to
  *generate* QR for 2FA login (`app/controllers/login/otp_controller.rb`). There is no
  server-side QR *decoder* in the stack.

### What exists and works today for on-paper exams

| Piece | Where | State |
|---|---|---|
| `on_paper` submission type | `app/models/abstract_assignment.rb:46` (`OFFLINE_SUBMISSION_TYPES`), GraphQL enum `app/graphql/types/assignment_submission_type.rb:30` | EXISTS. Students see no submit button; teachers grade via Gradebook/SpeedGrader. |
| Submission rows for on_paper | `AbstractAssignment#find_or_create_submission` `app/models/abstract_assignment.rb:2554` | EXISTS. Grading/commenting creates the row on demand — an on_paper assignment **does** have a Submission to hang attachments and grades on. |
| SpeedGrader for on_paper | `AbstractAssignment#can_view_speed_grader?` `app/models/abstract_assignment.rb:4161` | EXISTS. Gating is permissions-only, not submission-type; on_paper is gradeable in SpeedGrader (no doc preview, comments + grade + rubric all work). |
| Bulk re-upload of graded files | `GradebooksController#submissions_zip_upload` `app/controllers/gradebooks_controller.rb:1025`; `AbstractAssignment#generate_comments_from_files(_later)` `app/models/abstract_assignment.rb:3038-3113` | PARTIAL. Unzips, routes files by *download-generated filename* (`infer_comment_context_from_filename`, `abstract_assignment.rb:3635` — expects `..._<user_id>_<attachment_id>_...` and requires the attachment to already exist on the submission), attaches as submission comments via `find_or_create_submissions`. **Unusable for on_paper**: there was never a "download submissions" step, so no filename carries a user/attachment id and every file lands in `ignored_files`. Also: not idempotent (new comment per upload), no score entry, no rubric fill. |

## 2. Map of the existing systems to reuse (verified paths)

### Grading write path (reuse as-is)
- `AbstractAssignment#grade_student(student, score:, grader:, ...)` —
  `app/models/abstract_assignment.rb:2312-2364` → `save_grade_to_submission`.
  Handles versioning, `workflow_state = "graded"`, auto-posting unless
  `post_manually?`, grade-change auditing, grading periods, gradebook recalculation.
  This is the same call the Submissions API (`submissions_api_controller.rb:945`) and
  SpeedGrader use. **Writing through it means totals/grading periods/posting policies
  just work.**

### Attachment-on-Submission (reuse as-is)
- Graded files surface to students/SpeedGrader as **submission comment attachments**
  (Canvas never attaches teacher files directly to Submission).
- `Submission#add_comment(comment:, author:, attachments:)` via
  `AbstractAssignment#update_submission` (`abstract_assignment.rb:2661`).
- File objects are created against the assignment with
  `FileInContext.attach(assignment, path, display_name:)` — exactly what the existing
  zip re-upload does (`abstract_assignment.rb:3067`). Comment attachment reads are
  scoped to `submission.assignment.attachments` (`app/models/submission_comment.rb:473-478`).
- SpeedGrader + student submission view render these natively
  (`lib/api/v1/submission_comment.rb:38-74`).

### Rubric → Outcomes pipeline (reuse as-is; do NOT compute mastery separately)
- Attach rubric: `RubricAssociation` (`app/models/rubric_association.rb:31-39`),
  criteria aligned via `learning_outcome_id` in rubric data.
- Assess: `rubric_association.assess(user:, assessor:, artifact: submission,
  assessment: {assessment_type: "grading", criterion_<id> => {points:, comments:}})`
  (`rubric_association.rb:302-407`) — the same call the Submissions API makes for
  `rubric_assessment` params (`submissions_api_controller.rb:998-1015`).
- `RubricAssessment` `after_save :track_outcomes` (`rubric_assessment.rb:49-83`) →
  `create_outcome_result` (`:86-135`) writes standard `LearningOutcomeResult` rows
  (mastery = score >= mastery_points).
- `LearningOutcomeResult` `after_commit :rollup_calculation`
  (`learning_outcome_result.rb:58, 264-276`) → rollups. **Anything that writes a
  standard LearningOutcomeResult appears in rollups automatically.**
- Bonus: with `use_for_grading: true`, `RubricAssessment#update_artifact`
  (`rubric_assessment.rb:199-221`) itself calls `assignment.grade_student` — score and
  mastery stay on the one native path.

### Observer visibility (already fully wired — verify with specs, add NO permission code)
- Link: `ObserverEnrollment.associated_user_id` (`app/models/enrollment.rb:38,53-55`).
- Submission `:read`/`:read_comments` for linked observers:
  `app/models/submission.rb:625-635`; `:read_grade` requires `posted?` +
  enrollment `:read_grades` (`submission.rb:637-649`).
- Comments: `SubmissionComment#can_view_comment?` includes observers of the student
  (`submission_comment.rb:272-330`, observer branch at `:305`).
- Comment attachments: `Attachment#can_read_through_assignment?`
  (`app/models/attachment.rb:1450-1487`) searches submissions of the user **plus all
  users they observe** (`ObserverEnrollment.observed_students`) including
  submission_comment attachment ids → grants `:read`/`:download`.
- Non-linked observer denial: the policy `where(associated_user_id: self.user)` simply
  doesn't match (`submission.rb:625-635`); API-level 403 in
  `submissions_api_controller.rb:403-422`.
- Posting policies apply to observers exactly as to students (`posted?` gate).
- Existing spec patterns to mirror: `spec/models/attachment_spec.rb:1315-1339`
  (observer downloads comment attachment), `spec/apis/v1/submissions_api_spec.rb:1488-1506`
  (observer reads grade), `:3685-3696` (non-observed student → 403).

### Feature flag convention
- YAML under `config/feature_flags/*.yml`, loaded by `lib/feature_flags/loader.rb:63-78`.
  Account-level example: `config/feature_flags/00_standard.yml:78-83`
  (`applies_to: Account`, `type: setting`, plain-string display_name/description).
- Checks: `context.feature_enabled?(:flag)` (`lib/feature_flags.rb:26` — a Course
  delegates up its account chain for Account-applies flags);
  controller gating precedent: `ApplicationController#require_feature_enabled`
  (`application_controller.rb:3600`, renders `not_found`).
- Specs: `account.enable_feature!(:flag)`.
- Fork convention: `ui/shared/feature-flags/react/psFlagNotes.json` carries a
  plain-English "In plain terms" summary per flag (optional, graceful fallback).

### Migration/model conventions for a new table
- Mirror `db/migrate/20260130000001_create_ai_experience_context_files.rb`:
  `tag :predeploy`, `t.references ... foreign_key: true`,
  `t.references :root_account, foreign_key: { to_table: :accounts }, null: false`,
  `t.replica_identity_index`, unique index. Model mirrors
  `app/models/ai_experience_context_file.rb` (`before_validation :set_root_account`).

## 3. Already implemented? → No ENABLE.md

Not implemented, fully or partially, so per the brief we build the missing parts.
(If it had been, this file would be accompanied by ENABLE.md instead of code.)

## 4. The gap — only what we will build

1. **One-action teacher flow** (per student, on an on_paper assignment): attach scanned
   graded script to the student's Submission (comment attachment via
   `FileInContext.attach` + `Submission#add_comment`), record score through
   `grade_student`, optionally fill the aligned rubric through
   `rubric_association.assess`. No such combined action exists.
2. **Idempotency pointer**: re-upload must *replace*, not duplicate. Nothing in Canvas
   tracks "the current graded script" for a submission — the zip re-upload happily
   stacks comments. → one small additive table (`manual_exam_scripts`) holding
   submission_id → (attachment_id, submission_comment_id). It stores **no grades** —
   scores/rubrics/outcomes stay in their native stores.
3. **Bulk upload with QR routing**: per-student QR cover labels can be *generated*
   server-side with the existing `rqrcode` dependency (payload `studentId+assignmentId`).
   Server-side *decoding* would need a new native dependency (zxing/zbar) — instead the
   upload page decodes QR client-side with the browser `BarcodeDetector` API where
   available; files that can't be QR-matched fall back to a `<user_id>_...` filename
   convention (same spirit as `infer_comment_context_from_filename`) and finally to
   manual student selection in the UI. Unmatched files are reported, never guessed.
4. **Feature flag** `manual_exam_workflow` (Account, default off) gating all of the
   above; when off, nothing new renders and no route responds.
5. **Specs**: the observer-positive/negative, outcome-rollup, gradebook, idempotency,
   and flag-off==current-behaviour proofs listed in the brief.

Everything else in the brief already exists and is reused, not rebuilt.
