# DISCOVERY — Automatic K-12 Result (`automatic_k12_result`)

Investigation of the fork (`page-schools/main`, pinned upstream `release/2026-03-11.209`)
before building the native termly + sessional report-card feature. Verdict per system,
with file references. (The previous feature's discovery moved to
`doc/manual_exam_workflow_discovery.md`.)

**Bottom line: no report-card / transcript / termly-result feature exists anywhere in
this codebase — nothing to enable, so no ENABLE.md; this is net-new.** But Canvas
already computes and stores everything except ranking, median-per-period, and the
sessional rollup: per-(student, course, grading-period) scores live in the `scores`
table maintained by `GradeCalculator`; outcome mastery rollups have a reusable engine
in `Outcomes::ResultAnalytics`; observer visibility is a solved policy on `Enrollment`;
and the fork already has an inline PDF viewer plus `prawn-rails` for server-side PDFs.
What we add is a thin, coalesced aggregation layer (two tables + one recompute job) and
a rendering layer. **Never a parallel grade store — our tables hold only ranking/median/
snapshot data derived from Canvas's own Score rows.**

---

## 1. Does any report-card / result / transcript feature exist?

**ABSENT.** Searched `app/`, `ui/`, `gems/plugins/`, `config/feature_flags/*.yml` for
report card, transcript, grade report, student report:

- The only student-facing grade view is the single-course grade summary
  (`app/views/gradebooks/grade_summary.html.erb`, `GradebooksController#grade_summary`)
  — no cross-course, no termly aggregation, no print/export.
- `gems/plugins/account_reports/` has admin CSV exports (grade export, outcome export)
  — admin-facing flat files, not a student document.
- No flag or fork commit is result/report-card related.

Nothing to partially enable → build the feature; reuse the building blocks below.

## 2. How grade changes propagate (and the hook point we'll use)

The full chain, verified:

1. Grading writes through `AbstractAssignment#grade_student`
   (`app/models/abstract_assignment.rb:2312`) → `submission.save!`.
2. `Submission` `after_save :update_final_score` (`app/models/submission.rb:498`,
   defined at `:769`) — when score/excused changed, after commit calls
   `Enrollment.recompute_final_score_in_singleton(user_id, course_id, grading_period_id:)`.
3. `Enrollment.recompute_final_score_in_singleton` (`app/models/enrollment.rb:1117`)
   enqueues via `delay_if_production(singleton: "Enrollment.recompute_final_score:
   #{user_id}:#{course_id}:#{grading_period_id}", max_attempts: 10)` — the codebase's
   canonical coalescing idiom.
4. `GradeCalculator.recompute_final_score` (`lib/grade_calculator.rb:86`) batches ≤100
   users → `compute_and_save_scores` (`lib/grade_calculator.rb:137-155`): computes
   course + per-grading-period + per-assignment-group scores and persists them in
   `save_course_and_grading_period_scores` (`lib/grade_calculator.rb:516-582`) as a
   **raw SQL `INSERT … ON CONFLICT` — Score ActiveRecord callbacks do NOT fire**.
5. `update_score_statistics` (`lib/grade_calculator.rb:470-475`) then enqueues
   `ScoreStatisticsGenerator.update_score_statistics_in_singleton(course)`.

### Hook-point evaluation

| Candidate | Verdict |
|---|---|
| `Score` model callbacks | **Dead end** — rows written via raw SQL upsert, callbacks never fire. |
| `Submission` after_save | Fires per submission, *before* Scores exist; would recompute N times per grading session. |
| `Canvas::LiveEvents.course_grade_change` (`lib/grade_calculator.rb:206`) | Per-user, only when values changed, and conceptually an external event bus — wrong layer. |
| `Auditors::GradeChange.record` (`app/models/submission.rb:2331`) | Per-submission, audit concern. |
| **End of `GradeCalculator#compute_and_save_scores`** | **CHOSEN.** Fires exactly once per recompute batch, after all Score rows are committed, with `@course`, `@user_ids`, `@grading_period` in scope. Everything that changes grades funnels through here — SpeedGrader, API, manual-exam workflow, grading-period date/weight changes (`GradingPeriod#recompute_scores`, `app/models/grading_period.rb:275-285`), term re-links (`EnrollmentTerm` after_save `:40`). |

Implementation: a 3-line, flag-guarded enqueue appended to `compute_and_save_scores`,
delegating to our own module. Direct edit rather than a `Module#prepend` from an
initializer: a prepend is zero-conflict at rebase time but **fails silently** if
upstream renames the method; an in-file edit surfaces as a loud merge conflict —
preferable for a grading-adjacent hook. Merge risk: low (3 lines, end of method).

**Gap the GradeCalculator hook misses:** Final-grade override edits
(`StudentEnrollment#update_override_score`) write `Score#override_score` via plain
ActiveRecord *without* running GradeCalculator. Covered by a small flag-guarded
`after_save` on `Score` (fires only for AR writes, i.e. exactly the override path).

### Recompute/coalescing idiom to copy

`ScoreStatisticsGenerator.update_score_statistics_in_singleton`
(`lib/score_statistics_generator.rb:22-39`):

```ruby
delay_if_production(singleton: "ScoreStatisticsGenerator:#{course_global_id}",
                    n_strand: ["ScoreStatisticsGenerator", global_root_account_id],
                    run_at: rand(10..130).seconds.from_now,
                    on_conflict: :loose)
```

- `singleton:` — one pending job per key; `on_conflict: :loose` — later enqueues are
  dropped while one is pending (debounce); `run_at: rand(...)` — batches a burst of
  grading into one run and avoids thundering herd; `n_strand:` — bounded parallelism
  per root account.
- This gives us the required **set-level ranking in one job**: the job key is
  `(course, grading_period)`, so concurrent grading of many students coalesces into a
  single recompute that ranks the whole population race-free. Never rank per-submission.

## 3. Grading periods / terms / session mapping

- `GradingPeriodGroup` (period set) belongs to the **root account** and links to terms
  via `enrollment_terms.grading_period_group_id` (`app/models/grading_period_group.rb:21-27`).
  **Session = `EnrollmentTerm`** (e.g. 2024/2025), **Term = `GradingPeriod`** (First/
  Second/Third), exactly matching the Nigerian model. One term has exactly one active
  period set; all courses in the term share it (course-level sets are legacy).
- Course resolution: `GradingPeriod.for(course)` (`app/models/grading_period.rb:85-92`),
  current period `GradingPeriod.current_period_for(context)` (`:94-96`), date lookup
  `for_date_in_course` (`:75-83`).
- **Closed = `Time.zone.now > close_date`** (`GradingPeriod#closed?`, `:144-146`);
  grading in closed periods is already blocked for non-admins by
  `SubmittablesGradingPeriodProtection` (`lib/submittables_grading_period_protection.rb`).
  → provisional/final state = `period.closed?`, no new locking machinery.
- **Per-period scores are already stored**: `scores` is unique on
  `(enrollment_id, grading_period_id)`, plus a `course_score: true` row per enrollment
  that **already applies grading-period weights** when the set is weighted
  (`GradeCalculator#calculate_grading_period_scores`, `lib/grade_calculator.rb:375-389`).
  Read path: `enrollment.find_score(grading_period_id: X)` (`app/models/enrollment.rb:1250`)
  and `computed_current_score/final_score` helpers (`:1138-1240`).
  → **Term score = period Score row; sessional per-course score = the course Score row.
  We re-derive neither.** Posted vs unposted: students/observers see `current_score` /
  `final_score`; `unposted_*` are teacher-only — the report card uses posted values.
- Period date/weight changes already trigger full recomputes (callbacks above), which
  flow through our GradeCalculator hook for free.
- Submissions carry `grading_period_id` (`GradingPeriod has_many :submissions`),
  giving native period scoping for the CA/exam breakdown (Canvas has no per-period
  per-assignment-group score, so that one display extra is derived from posted, graded,
  non-excused submissions in the period — the same classification the Payload-layer
  report card uses).

### Ranking population

- `position_among_enrolled` → `course.all_real_student_enrollments`
  (`app/models/course.rb:135`: `type = 'StudentEnrollment' AND workflow_state <> 'deleted'`),
  narrowed to active states; excludes the Test Student (`StudentViewEnrollment`) the
  same way `ScoreStatisticsGenerator` does (`lib/score_statistics_generator.rb:70-74`).
- `position_among_attempted` → same set, filtered to enrollments whose period Score has
  a non-nil posted score.
- Tie handling: standard competition ranking ("1,2,2,4").

## 4. Outcomes → strand mastery (READ path)

Reuse the rollup engine wholesale — never reimplement the math:

- Results: `Outcomes::ResultAnalytics.find_outcome_results(user, users:, context:, outcomes:)`
  (`lib/outcomes/result_analytics.rb:39-65`) — already handles deleted alignments
  (`with_active_link`), hidden results, and **`exclude_muted_associations`** (posting
  policy) for non-teachers.
- Rollups: `Outcomes::ResultAnalytics.outcome_results_rollups(results:, users:, context:)`
  (`:134`) → `RollupScore` (`app/models/rollup_score.rb:100-130`) applies the outcome's
  calculation method (highest / latest / average / decaying_average / n_mastery /
  weighted_average) with `calculation_int`, resolved per course/account
  (`course.resolved_outcome_calculation_method`, `resolved_outcome_proficiency`,
  `app/models/course.rb:4770-4776`, `app/models/account.rb:254-278`).
- Mastery scale + labels/colors: `course.resolved_outcome_proficiency.ratings_hash`
  (defaults 4 Exceeds / 3 Mastery / 2 Near / 1 Below / 0 No Evidence,
  `app/models/outcome_proficiency.rb:98-106`).
- Strands: `course.learning_outcome_groups` with `child_outcome_links`
  (`app/models/learning_outcome_group.rb`; link scope `ContentTag.learning_outcome_links`,
  `app/models/content_tag.rb:616`).
- **Grading-period scoping does not exist natively** (no date params on the rollups
  API). The natural filter is the result timestamp the engine itself uses for "latest":
  `submitted_at || assessed_at` (`RollupScoreAggregatorHelper#result_time`,
  `app/models/rollup_score_aggregator_helper.rb:40-48`). We filter results to the
  period's `[start_date, end_date]` window on `COALESCE(submitted_at, assessed_at)`
  before rolling up. Sessional mastery = same rollup, unfiltered (whole session).
- Snapshot the rollup (outcome id/title/strand/score/rating/color/points) into our
  result row's jsonb so the report card renders without recompute.

## 5. Observer visibility (inherit, don't invent)

The report card copies the existing grade-summary authorization shape:

- Enrollment policy grants `:read_grades` to the student themself
  (`app/models/enrollment.rb:1359-1360`), staff with `manage_grades`/`view_all_grades`
  (`:1362-1366`), and — the load-bearing rule — **a linked observer**:
  `course.observer_enrollments.where(user_id: user, associated_user_id: user_id).exists?`
  (`:1368-1369`). Non-linked observers (associated_user_id nil or another student) fail
  this check — negative case is already enforced.
- User-level (cross-course, what `/grades` uses): `UsersController#grades` gates on
  `authorized_action(@user, @current_user, :read_grades)` (`app/controllers/users_controller.rb:133`)
  and builds the observer picker from `ObserverEnrollment.observed_students(course,
  user, grade_summary: true)` (`app/models/observer_enrollment.rb:58`).
- Posting policy: student/observer-visible data must respect
  `Submission#hide_grade_from_student?` (`app/models/submission.rb:3184-3191`) — using
  **posted** Score values + posted submissions + `exclude_muted_associations` (mastery)
  gives this for free.
- The fork's own flag-gated page pattern (manual exam,
  `app/controllers/manual_exam_scripts_controller.rb:132-140`): `before_action`s
  `require_user` → flag gate `not_found unless account.feature_enabled?(...)` → 
  `authorized_action(...)`. **Account-scoped flags must be checked on an Account** —
  `@context.account.feature_enabled?(:flag)` (Course does not resolve Account-scoped
  flags; the fork was bitten by this before).
- K5/elementary: `enable_as_k5_account` account setting exists
  (`app/models/account.rb:409`) but only affects layout/dashboard, not grades display —
  our KG-Y4 developmental view is therefore our own per-course toggle (course
  `settings` hash), defaulting sensibly.

## 6. ScoreStatistic — what's reusable

- `ScoreStatistic` (`app/models/score_statistic.rb`) is **per assignment**:
  count/min/max/mean **and lower_q/median/upper_q** via SQL `percentile_cont`
  (`lib/score_statistics_generator.rb:51-90`). Population: real, active student
  enrollments, graded, non-excused. Feeds the "class average" on grade pages.
- `CourseScoreStatistic` (`app/models/course_score_statistic.rb`) is **per course**:
  `average` + `score_count` only — **no median, no grading-period granularity**.
- Verdict: **REUSE the pattern, not the rows.** Nothing existing gives per-(course,
  grading-period) median. Our recompute job computes median over the same population
  definition (and the same `percentile_cont(0.5)` semantics — linear interpolation for
  even n) as part of the single set-level pass it already does for ranking, and stores
  it on our result-set row. Per-assignment ScoreStatistic stays untouched and unused
  (wrong granularity for a termly subject median).

## 7. Print + PDF (existing mechanisms only)

- **Server-side PDF exists: `prawn-rails ~1.4`** (`Gemfile.d/app.rb`), used by
  `SubmissionCommentsController#index` → `render pdf: :index` with
  `app/views/submission_comments/index.pdf.prawn`. That is the one PDF engine in the
  codebase → the report card gets a `.pdf.prawn` template, no new engine.
- **The fork's inline PDF viewer** (commit `ce0190e4e9`): `files_controller.rb:860,
  880-883` streams PDFs `disposition: "inline"` (flag-gated), embedded via iframe on
  `file_download_path(id, inline: 1)`. Our PDF is generated on the fly (`format.pdf`),
  so it renders directly in the browser's PDF viewer with `disposition: inline` —
  same mechanism, no Attachment needed (nothing to persist).
- **Print CSS**: global chrome-hiding print rules exist
  (`app/stylesheets/base/_print.scss`); the fork's `manual_exam_scripts/labels.html.erb`
  is the pattern for a print-ready ERB page — no layout, inline `<style>`,
  `@media print { .no-print { display:none } }`, `window.print()` button.
- **ERB + inline styles, no new webpack bundles** — deliberate: frontend bundles need a
  ~1-2h image rebuild; ERB is hot-patchable into the running container (fork workflow).

## 8. Proposed implementation (most idiomatic given the above)

### Feature flag + configuration

- `automatic_k12_result` in `config/feature_flags/page_schools_feature_flags.yml`
  (applies_to: Account, `state: allowed` = visible, default **off**) + a
  `psFlagNotes.json` entry (fork convention).
- **Account-level config** (one report-card policy per school), stored as a hash
  account setting `k12_result` via the `add_setting` DSL (`app/models/account.rb`,
  precedent: `custom_help_links`-style hash settings), edited on a small flag-gated
  ERB settings page (own controller — zero upstream view edits):
  - `term_labels`: ordered labels mapped by index onto the term's grading periods
    sorted by `start_date` (e.g. First/Second/Third Term, or Harmattan/Rain). Default:
    the periods' own titles — never hardcoded names.
  - `position_mode`: `off | position_among_enrolled | position_among_attempted`
  - `show_term_position`, `show_overall_position`, `show_median`, `show_mastery`: booleans
  - `ca_weight` / `exam_weight` (default 40/60) + `exam_group_pattern` (default `exam`)
    for the CA/exam display split
  - `grade_scheme`: `course` (course grading standard) with built-in WAEC A1–F9
    fallback bands when no standard is set
- **Per-course view mode** for KG-Y4: `course.settings[:k12_result_view] =
  "developmental" | "senior"` (course settings hash, `app/models/course.rb:4206-4220`),
  account-level default in the config; small PUT to set it.

### Data model (additive migrations only)

- `k12_result_sets` — one per (course, grading_period | NULL=sessional):
  `course_id`, `grading_period_id` (null ⇒ whole-session), `enrollment_term_id`,
  `median`, `mean`, `enrolled_count`, `attempted_count`, `finalized` (period closed at
  compute time), `computed_at`, `root_account_id`, timestamps.
  Unique `(course_id, grading_period_id)` (partial for the NULL sessional row).
- `k12_course_results` — one per (user, course, grading_period | NULL=sessional):
  `k12_result_set_id`, `user_id`, `course_id`, `grading_period_id`, `score`
  (posted current), `final_score`, `grade` (letter), `ca_score`, `exam_score`,
  `rank`, `rank_attempted` (per both modes; whichever the config picks is displayed),
  `mastery` jsonb snapshot, `remark` (teacher, optional), `workflow_state`, timestamps.
  Unique `(user_id, course_id, grading_period_id)` → upsert target, no duplicates.
- `k12_session_results` — one per (user, enrollment_term):
  `user_id`, `enrollment_term_id`, `average`, `rank`, `rank_attempted`,
  `cohort_enrolled_count`, `cohort_attempted_count`, `courses_count`, `finalized`,
  `traits` jsonb (affective/psychomotor, optional manual input),
  `class_teacher_remark`, `head_teacher_remark`, `root_account_id`, timestamps.
  Unique `(user_id, enrollment_term_id)`.
- Conventions per fork precedent (`db/migrate/20260703100000_create_manual_exam_scripts.rb`):
  Rails 8.0 migration, `tag :predeploy`, FK `on_delete` rules, `root_account_id`,
  `t.replica_identity_index` + companion `set_replica_identity` migration. CREATE only.

### Engine (`K12Results::` namespace, `app/services/k12_results/*`)

- `K12Results.recalculate_later(course:, grading_period_id:)` — the ScoreStatistics
  idiom verbatim: `delay_if_production(singleton: "K12Results:#{course.global_id}:
  #{grading_period_id}", n_strand: ["K12Results", global_root_account_id],
  run_at: rand(10..60).seconds.from_now, on_conflict: :loose)`.
- `K12Results::CourseRecalculator` (an `ApplicationService`) — ONE job per (course,
  period) computes the whole set: reads period Score rows for the real-student
  population, derives CA/exam from posted submissions in the period, snapshots mastery
  rollups (period-windowed), computes median + both rank modes with competition
  tie-handling, bulk-upserts `k12_course_results` + the set row. Idempotent by
  construction (pure derivation + upsert). Prunes result rows for users no longer in
  the population.
- `K12Results::SessionRecalculator` — coalesced per enrollment term: sessional
  per-course rows (grading_period_id NULL; score = the course-level Score row, which
  already honours period weights), then `k12_session_results` (average across the
  student's course aggregates; overall position within the cohort = union of real
  students across the student's term courses — equal to the class arm in this
  deployment where subject-course rosters coincide; both rank modes; overall median on
  the set rows).
- Triggers: the GradeCalculator hook (batch), the Score override hook, and both are
  no-ops (zero queries beyond one flag memo) when the flag is off.

### Report card (view + PDF)

- `K12ReportCardsController` — `GET /users/:user_id/k12_report_card(.pdf)` (+ optional
  `term_id`/`grading_period_id` params), auth = `authorized_action(@user, @current_user,
  :read_grades)` (the `/grades` pattern — self, linked observer, staff; non-linked
  observers already denied by policy), flag gate `not_found unless
  @user.root_account.feature_enabled?(:automatic_k12_result)`-style on the domain root
  account. Plus a teacher/admin index per course (`/courses/:id/k12_results`,
  `:manage_grades`) for entering remarks/traits and jumping to students' cards.
- HTML: ERB + inline styles (two faces: termly sheet — CA/exam/total/grade/median/
  position per config — and strand-mastery sheet; provisional banner while
  `!period.closed?`, FINAL when closed), print CSS + window.print. Developmental
  (KG-Y4) mode: mastery/skills view, no CA/exam/position.
- PDF: `format.pdf` rendering a `.pdf.prawn` template (prawn-rails, the existing
  engine), `disposition: "inline"` so it opens in the same inline PDF viewing path the
  fork already uses.

### Merge-risk summary vs upstream

| Change | Risk |
|---|---|
| New files (flag yml, migrations, models, services, controller, views, specs, docs) | None — upstream never touches them. |
| `lib/grade_calculator.rb` — 3-line hook at end of `compute_and_save_scores` | Low; loud conflict if upstream reshapes the method (desired). |
| `app/models/score.rb` — flag-guarded after_save for override edits | Low; Score is small and stable. |
| `app/models/account.rb` — one `add_setting` line | Trivial. |
| `config/routes.rb` — routes near the fork's existing manual-exam block | Trivial. |
| `ui/shared/feature-flags/react/psFlagNotes.json` — one entry | Fork-owned file. |

No upstream behaviour changes when the flag is off: hooks early-return, routes 404,
tables sit empty — proven by specs (flag-off == vanilla).
