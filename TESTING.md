# TESTING — Automatic K-12 Result (`automatic_k12_result`)

How to enable, configure, spec, and manually exercise the native termly/sessional
report card. Everything below assumes the fork image ≥ the commit that ships this
feature and a migrated DB (`bin/rake db:migrate` — three additive tables).

---

## 1. Enable + configure

1. **Flag** — as an admin: `Admin > Settings > Feature Options` →
   "Automatic K-12 Result" → **Enabled**. (Account flag, default off. Everything —
   pages, hooks, jobs — is inert while it's off.)
   Console alternative: `Account.default.enable_feature!(:automatic_k12_result)`.
2. **Grading periods** — the feature maps *terms onto grading periods* and the
   *session onto the enrollment term*. Set up `Admin > Grading > Grading Periods`
   with (say) three periods attached to the enrollment term your courses use.
   No periods ⇒ only the sessional (cumulative) view exists.
3. **Result policy** — visit `/accounts/1/k12_result_settings` (linked nowhere on
   purpose while we trial it; admins with `manage_account_settings` only):
   * **Term labels** — one per line, mapped onto the term's grading periods sorted
     by start date (e.g. `First Term / Second Term / Third Term`, or
     `Harmattan / Rain`). Empty = use the periods' own names. Never hardcoded.
   * **Position mode** — `off` | `among enrolled` | `among attempted`.
     Ranks are identical in both modes (competition ranking over graded students);
     the mode changes the displayed denominator ("5th of 40" vs "5th of 32").
   * **Toggles** — per-subject term position, overall (sessional) position,
     median, strand mastery.
   * **CA/exam split** — weights (default 40/60) and the assignment-group name
     pattern that counts as "exam" (default `exam`, case-insensitive regex).
   * **Default view** — `senior` (CA+exam+positions) or `developmental` (KG–Y4
     skills view). Each course can override on its K-12 Results page.

## 2. RSpec

Suite (all new files, no upstream spec touched):

| File | Proves |
|---|---|
| `spec/services/k12_results_spec.rb` | flag OFF == vanilla (grading creates zero result rows; override edits compute nothing); flag ON: grading a submission recomputes the student's result end-to-end; singleton/coalescing job args (`on_conflict: :loose`, one key per (course, period), one per term); override-score edits recompute; a recompute failure can never break grading; deleted-period enqueues no-op. |
| `spec/services/k12_results/course_recalculator_spec.rb` | scores copied from the same Score rows the gradebook shows; nil (never 0) for ungraded; WAEC bands vs course grading standard; period scoping (each term from its own assignments; sessional from the course-level Score); CA/exam split incl. unposted-grade exclusion; competition ranking `1,1,3` and `1,2,2,4` incl. unranked ungraded students; both population counts; interpolated median; mastery snapshot (rollup + rating labels, period-windowed, account toggle); idempotent upsert (no duplicates, remarks preserved); pruning; Test-Student exclusion; provisional→final on period close. |
| `spec/services/k12_results/session_recalculator_spec.rb` | session average skips ungraded subjects; overall position within the union-of-coursemates cohort; ties; cohort median; traits/remarks preserved; idempotence + pruning. |
| `spec/controllers/k12_report_cards_controller_spec.rb` | flag off 404; student sees own card; **linked observer sees it; non-linked observer and other students are refused**; teacher sees it; senior vs developmental (KG–Y4) rendering; position/median toggles respected; session view; PDF (`%PDF`, `application/pdf`); staff-only traits/remarks update. |
| `spec/controllers/k12_results_controller_spec.rb` | flag gate; `manage_grades` required; teacher table renders; on-demand recalculate; course view-mode override; per-subject remark save. |
| `spec/controllers/k12_result_settings_controller_spec.rb` | flag gate; root-account only; admin-only; full config round-trip; term-label ↔ grading-period mapping. |

Run them the way this fork runs specs — a throwaway container from the image
(full bundle incl. rspec is baked in):

```sh
docker run -d --name hyde-canvas-spec --entrypoint bash \
  page-schools/canvas:<tag> -lc 'service postgresql start && sleep infinity'
docker exec hyde-canvas-spec bash -lc \
  'su postgres -c "psql -c \"ALTER USER canvas CREATEDB SUPERUSER\""'
docker exec hyde-canvas-spec bash -lc \
  'cd /work/canvas-source && RAILS_ENV=test bin/rake db:test:reset db:migrate'
# (building from a ref older than this feature? tar-pipe the changed files in first)
docker exec hyde-canvas-spec bash -lc 'cd /work/canvas-source && RAILS_ENV=test \
  bin/rspec spec/services/k12_results_spec.rb spec/services/k12_results \
            spec/controllers/k12_report_cards_controller_spec.rb \
            spec/controllers/k12_results_controller_spec.rb \
            spec/controllers/k12_result_settings_controller_spec.rb'
```

Regression safety: also run the neighbouring upstream suites the hooks touch —
`spec/lib/grade_calculator_spec.rb`, `spec/models/score_spec.rb` — with the flag
off (default) they must be green and unchanged.

## 3. Manual walkthrough on local Canvas (:3102, hyde-canvas-own)

Seed a small class with terms, subjects and a CA/exam structure (idempotent):

```sh
docker exec -i hyde-canvas-own bash -lc 'cd /work/canvas-source && bin/rails runner -' <<'RUBY'
account = Account.default
account.enable_feature!(:automatic_k12_result)
account.settings[:k12_result] = {
  "term_labels" => ["First Term", "Second Term", "Third Term"],
  "position_mode" => "position_among_enrolled",
  "show_term_position" => true, "show_overall_position" => true,
  "show_median" => true, "show_mastery" => true
}
account.save!

term = EnrollmentTerm.active.find_by(name: "K12 Demo Session") ||
       account.enrollment_terms.create!(name: "K12 Demo Session")
group = account.grading_period_groups.active.find_by(title: "K12 Demo Periods") ||
        account.grading_period_groups.create!(title: "K12 Demo Periods")
group.enrollment_terms << term unless group.enrollment_terms.include?(term)
now = Time.zone.now
[["First Term", 4.months.ago(now), 2.months.ago(now), 2.months.ago(now)],
 ["Second Term", 2.months.ago(now) + 1.minute, 1.month.from_now(now), 2.months.from_now(now)],
 ["Third Term", 1.month.from_now(now) + 1.minute, 3.months.from_now(now), 4.months.from_now(now)]]
  .each do |title, s, e, c|
  group.grading_periods.active.find_by(title:) ||
    group.grading_periods.create!(title:, start_date: s, end_date: e, close_date: c)
end

teacher = User.active.joins(:pseudonyms).where(pseudonyms: { unique_id: "k12demo-teacher" }).first
unless teacher
  teacher = User.create!(name: "K12 Demo Teacher")
  teacher.pseudonyms.create!(account:, unique_id: "k12demo-teacher", password: "Demo!2025", password_confirmation: "Demo!2025")
  teacher.register!
end
students = (1..12).map do |i|
  uid = format("k12demo-student%02d", i)
  User.active.joins(:pseudonyms).where(pseudonyms: { unique_id: uid }).first || begin
    u = User.create!(name: "Demo Student #{i}")
    u.pseudonyms.create!(account:, unique_id: uid, password: "Demo!2025", password_confirmation: "Demo!2025")
    u.register!
    u
  end
end

%w[Mathematics English Basic\ Science].each do |subject|
  course = Course.where(name: "Primary 5A - #{subject}", enrollment_term_id: term.id).first ||
           account.courses.create!(name: "Primary 5A - #{subject}", enrollment_term: term, workflow_state: "available")
  course.offer! unless course.available?
  course.enroll_teacher(teacher, enrollment_state: "active")
  students.each { |s| course.enroll_student(s, enrollment_state: "active") }
  ca = course.assignment_groups.find_by(name: "Continuous Assessment") || course.assignment_groups.create!(name: "Continuous Assessment", group_weight: 40)
  ex = course.assignment_groups.find_by(name: "Examination") || course.assignment_groups.create!(name: "Examination", group_weight: 60)
  course.update!(group_weighting_scheme: "percent")
  { "CA 1" => [ca, 20, 6.weeks.ago], "CA 2" => [ca, 20, 3.weeks.ago], "Second Term Exam" => [ex, 100, 1.week.ago] }.each do |title, (g, points, due)|
    course.assignments.find_by(title:) ||
      course.assignments.create!(title:, assignment_group: g, points_possible: points, due_at: due, submission_types: "on_paper", workflow_state: "published")
  end
end
puts "Seeded. teacher=k12demo-teacher students=k12demo-student01..12 (pass Demo!2025)"
RUBY
```

Then **watch the report card build live**:

1. Log in as `k12demo-teacher` / `Demo!2025` on http://localhost:3102.
2. Open `Primary 5A - Mathematics` → gradebook → grade a few students on *CA 1*.
3. Within ~a minute (the coalesced job's debounce; the delayed_job worker runs
   in-container) open `/courses/<id>/k12_results` — scores, WAEC grades, median
   and positions are there. "Recalculate now" forces it synchronously if you're
   impatient.
4. Open a student's card (click their name, or as the student/parent:
   `/users/<student_id>/k12_report_card`). Grade the exam for more students and
   reload — totals, CA/exam columns, median and positions move as you grade.
   The card says **PROVISIONAL** while the period is open.
5. **Positions/median**: grade two students to the same total → they share a
   position ("1st, 1st, 3rd"). Toggle the position mode at
   `/accounts/1/k12_result_settings` between enrolled/attempted and watch the
   denominator change ("2nd of 12" vs "2nd of 5"); turn median off and the
   column disappears.
6. **Mastery**: align a rubric with an outcome on any assignment, assess it in
   SpeedGrader → strand bars appear on face B of the card (and on the PDF).
7. **KG–Y4 mode**: on `/courses/<id>/k12_results` switch "Report card view" to
   Developmental → the card becomes the skills/progress sheet (no CA/exam or
   positions). Switch back for the senior sheet.
8. **Session view**: pick "Session" on the card → cumulative per-subject rows
   (period-weighted where the period set is weighted), session average, overall
   position + cohort median.
9. **Observer/negative test**: link a parent to one student
   (`UserObservationLink.create_or_restore(observer:, student:, root_account:)` +
   an ObserverEnrollment, or use an observer pairing code), log in as them —
   they see that child's card; hitting another student's URL is refused.
10. **PDF**: "Download PDF" — renders in the browser's PDF viewer inline
    (prawn); print via the Print button uses the print stylesheet.
11. Close a period (set its close date in the past) and recalculate → the card
    flips to **FINAL** for that term.

## 4. Performance check (~40 students × ~10 subjects)

1. Re-run the seed with `(1..40)` students and ten subjects.
2. Grade a whole class in one course (runner):
   `course.assignments.find_by(title: "Second Term Exam")` then
   `students.each { |s| a.grade_student(s, score: rand(35..98), grader: teacher) }`.
3. Verify **coalescing**: `Delayed::Job.where("tag LIKE 'K12Results%'").count`
   right after — you should see ~1 job per (course, period) + 1 sessional +
   1 session job, *not* 40. (Each graded submission enqueues; `singleton` +
   `on_conflict: :loose` collapse them.) **Caveat:** the hyde containers run
   the Rails *development* env, where `delay_if_production` executes inline —
   the count is 0 there because the recompute already ran synchronously
   (results appear instantly as you grade). The queue/coalesce behaviour only
   engages under `RAILS_ENV=production`.
4. Time the set-level pass:
   `puts Benchmark.realtime { K12Results::CourseRecalculator.call(course:, grading_period: gp) }`
   — expect well under a second for 40 students (a handful of queries: one
   enrollment scan, one Score read, one submissions aggregate, the outcome
   rollup, one bulk upsert). The full course rebuild
   (`K12Results.recalculate_course_now(course)`) covers 3 periods + sessional +
   session rollup; expect ~2–4s.
5. Confirm grading latency is untouched: grading one submission enqueues one
   loose singleton (microseconds) — watch `production.log` for the grade save
   timing before/after enabling the flag.

## 5. Flag-off regression sanity

With the flag disabled (default): gradebook, SpeedGrader, `/grades`, observer
views behave exactly as before (`spec/services/k12_results_spec.rb` "flag OFF"
group proves no rows are written); `/courses/:id/k12_results`,
`/users/:id/k12_report_card` and `/accounts/1/k12_result_settings` all 404.
