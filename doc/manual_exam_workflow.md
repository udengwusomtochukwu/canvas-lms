# Manual Exam Workflow — admin & teacher guide

Page Schools fork feature for on-paper (handwritten) exams: upload each
student's scanned, hand-graded script, record the score, and have strand
mastery flow through the exam's rubric — all surfacing in the normal Canvas
places (gradebook, SpeedGrader, the student's submission page, and the linked
parent/observer view).

## Enabling it (admin)

1. **Admin > (root account) > Settings > Feature Options**
2. Turn on **Manual Exam Workflow** (`manual_exam_workflow`). Default is off.
   - When off, nothing new renders and grading behaves exactly like stock Canvas.
   - The flag is account-level: enabling on the root account covers sub-accounts.

Related flags/settings (all optional):

- **Outcome rollups** work out of the box — mastery is computed from standard
  `LearningOutcomeResult` rows. The site-admin flag `outcomes_rollup_propagation`
  only affects the persisted rollup table, not the rollups API/report.
- **Account and Course Level Outcome Mastery Scales**
  (`account_level_mastery_scales`) changes how mastery levels display; the exam
  workflow works with it on or off.
- **File access**: scripts attach as submission-comment files; they follow the
  normal submission/attachment permissions. No file-settings changes needed.

## Teacher flow

1. Create a normal assignment with **Submission Type = "On Paper"** (and points).
   A Manual Exam *is* that assignment — nothing special to set up, and
   re-using the same assignment is safe (uploads are idempotent).
2. Optionally attach a **rubric** aligned to your outcomes (check "Use this
   rubric for assignment grading" if the rubric total should be the exam grade).
3. Before the exam (optional, for bulk scanning): open
   `/courses/<course>/assignments/<assignment>/manual_exam` and click
   **Print QR Labels**. Affix one label per student's script.
4. After hand-grading, on the same page:
   - **Per student**: choose the scan, enter the score, Save. Re-uploading
     replaces the previous script — it never duplicates.
   - **Bulk**: select many scans at once. Files are matched by QR label
     (image scans, Chromium browsers), or by naming files
     `<studentId>_anything.pdf` (the ID is printed on each label), or by
     picking the student manually per file. Unmatched files are reported,
     never guessed. Then enter scores per student or in the Gradebook.
5. Fill the rubric in **SpeedGrader** as usual for strand mastery (or send
   `rubric_assessment` to the upsert endpoint if automating).

## What students and parents see

- The score appears wherever grades normally appear (subject to the
  assignment's posting policy — manually-posted assignments stay hidden
  until posted, exactly like any other grade).
- The graded script appears as a comment attachment on the student's
  submission page; linked observers (parents) see and can download it through
  Canvas's standard observer visibility. Non-linked observers cannot.

## Endpoints (for automation)

All gated on the feature flag + `manage_grades`:

- `GET  /courses/:course_id/assignments/:assignment_id/manual_exam` — teacher page
- `GET  .../manual_exam/labels` — printable QR labels
- `PUT  .../manual_exam/scripts/:user_id` — upsert one student
  (`script` file, `score`, optional `rubric_assessment[<criterion_id>][points]`;
  JSON or form)
- `POST .../manual_exam/scripts` — bulk (`scripts[]` files +
  `script_user_ids[]` aligned array; unmatched files returned)
