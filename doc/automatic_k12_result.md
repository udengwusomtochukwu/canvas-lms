# Automatic K-12 Result

Page Schools fork feature (flag `automatic_k12_result`, Account, default off).
Computes each student's termly + sessional result automatically as grading
happens and renders it as a printable/PDF report card for the student, their
linked observers (parents), and staff. See `DISCOVERY.md` for the design
investigation, `FORK_CHANGES.md` for the merge-risk ledger, `TESTING.md` for
the test guide.

## Model

* **Term** = a Canvas `GradingPeriod` (labels configurable per account —
  First/Second/Third Term, Harmattan/Rain, anything — mapped by position onto
  the term's periods sorted by start date).
* **Session** = the Canvas `EnrollmentTerm` (e.g. 2024/2025).
* **Subject** = a Canvas `Course` (this deployment: one course per
  class-arm × subject).

## Data flow (no parallel grade store)

```
grade_student / SpeedGrader / API / override
        │ (native pipelines, untouched)
        ▼
GradeCalculator ──writes──▶ scores (course + per-period rows)
        │ 3-line fork hook (posted branches only)          Score#after_save
        ▼                                                  (override edits only)
K12Results.recalculate_later(course, period)  ◀────────────────────┘
        │ singleton per (course, period), n_strand per root account,
        │ run_at rand(10..60s), on_conflict: :loose  → bursts coalesce
        ▼
K12Results::CourseRecalculator  — ONE set-level pass, race-free ranking:
   • score/grade   ← the Score row (posted; override honoured)
   • CA/exam split ← posted, graded submissions in the period, bucketed by
                     assignment-group name (configurable exam pattern)
   • mastery       ← Outcomes::ResultAnalytics rollups (muted excluded),
                     period-windowed on COALESCE(submitted_at, assessed_at)
   • median (percentile_cont semantics) + competition ranks ("1,2,2,4")
   → upsert k12_course_results (+ k12_result_sets stats), prune leavers
        │ (sessional pass only)
        ▼
K12Results::SessionRecalculator — singleton per enrollment term:
   session average across subjects, overall position within the union of the
   student's coursemates (= the class arm here), cohort median
   → upsert k12_session_results (traits/remarks columns never clobbered)
```

Tables (all additive): `k12_result_sets` (per course × period|session:
median/mean/counts/finalized), `k12_course_results` (per student × course ×
period|session: score/grade/ca/exam/rank/mastery-jsonb/remark),
`k12_session_results` (per student × term: average/rank/cohort/traits/remarks).

## Pages

| Route | Who | What |
|---|---|---|
| `/users/:user_id/k12_report_card(.pdf)` | student (self), linked observer, staff | The two-faced card: termly sheet (CA/exam/total, WAEC or course-standard grade, class median, position, traits, remarks) + strand-mastery sheet; term pills + Session view; PROVISIONAL while the period is open, FINAL when closed; print CSS + prawn PDF. Developmental (KG–Y4) mode renders a skills/progress sheet without scores/positions. |
| `/courses/:course_id/k12_results` | `manage_grades` | The course's computed set per period; per-student subject remarks; view-mode override; "Recalculate now". |
| `/accounts/:account_id/k12_result_settings` | root-account `manage_account_settings` | Term labels, position mode (off/enrolled/attempted), median/mastery/position toggles, CA-exam weights + exam pattern, default view. Stored in the `k12_result` account setting. |

## Visibility

Reuses Canvas's existing grade-visibility rules, nothing invented:
user-level `:read_grades` (self/admins) or `:read_as_parent`
(UserObservationLink) or the student's enrollment-level `:read_grades` policy
(course staff, course-linked observers via `associated_user_id`). Non-linked
observers hold none of these. All displayed data is posted-only (Score posted
columns, posted submissions, `exclude_muted_associations` for mastery).

## Semantics worth knowing

* Ungraded students are **never** scored 0 or ranked bottom — nil score, no
  rank, rendered "—". Position modes change the denominator only.
* Median is computed over graded scores (both modes).
* The sessional per-course score is Canvas's own course Score row, so weighted
  grading-period sets are honoured automatically.
* Period date/weight changes re-trigger GradeCalculator upstream, which flows
  through the same hook — results follow automatically.
* Everything is idempotent: rerun any recompute any number of times; unique
  indexes make duplicates impossible; staff-entered remarks/traits survive.

## Limitations / deliberate scope

* The sessional "class" cohort is the union of a student's coursemates in the
  term — exactly the class arm when subject courses share rosters (this
  deployment), approximate under elective-style rosters (counts displayed).
* Attendance is not on the card (lives in the Payload layer here).
* The settings page is intentionally unlinked from account navigation.
