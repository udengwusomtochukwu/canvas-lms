# frozen_string_literal: true

#
# Copyright (C) 2026 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

describe K12Results do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @first_term, @second_term = create_k12_terms_for(@course)
    @assignment = k12_assignment(@course, "Continuous Assessment", title: "CA 1", due_at: 1.week.ago)
  end

  context "with the flag OFF (vanilla Canvas)" do
    it "grading computes gradebook scores but creates no result rows" do
      @assignment.grade_student(@student, score: 70, grader: @teacher)
      enrollment = @course.enrollments.find_by(user_id: @student)
      expect(enrollment.computed_current_score(grading_period_id: @second_term.id)).to eq 70.0
      expect(K12ResultSet.count).to eq 0
      expect(K12CourseResult.count).to eq 0
      expect(K12SessionResult.count).to eq 0
    end

    it "recalculate_later is a no-op" do
      expect(K12Results).not_to receive(:delay_if_production)
      K12Results.recalculate_later(course: @course, grading_period: @second_term)
    end

    it "override edits compute nothing" do
      @assignment.grade_student(@student, score: 70, grader: @teacher)
      score = @course.enrollments.find_by(user_id: @student).find_score(course_score: true)
      score.update!(override_score: 95)
      expect(K12ResultSet.count).to eq 0
      expect(K12CourseResult.count).to eq 0
    end
  end

  context "with the flag ON" do
    before :once do
      Account.default.enable_feature!(:automatic_k12_result)
    end

    it "grading a submission recomputes the student's result automatically" do
      @assignment.grade_student(@student, score: 70, grader: @teacher)
      result = K12CourseResult.active.find_by(user_id: @student.id,
                                              course_id: @course.id,
                                              grading_period_id: @second_term.id)
      expect(result).to be_present
      expect(result.score).to eq 70.0
      # the chain also builds the sessional row and the session rollup
      expect(K12CourseResult.active.find_by(user_id: @student.id, course_id: @course.id, grading_period_id: nil)).to be_present
      expect(K12SessionResult.active.find_by(user_id: @student.id, enrollment_term_id: @course.enrollment_term_id)).to be_present
    end

    it "coalesces recomputes into one singleton job per (course, period)" do
      # fresh instance: the onceler-restored @course carries a root_account
      # memoized before the flag flipped on
      course = Course.find(@course.id)
      captured = nil
      # stubbing the delay returns the module itself, so the chained call runs
      # inline exactly as delay_if_production would in the test environment
      allow(K12Results).to receive(:delay_if_production) do |**opts|
        captured = opts
        K12Results
      end
      K12Results.recalculate_later(course:, grading_period: @second_term)
      expect(captured).to include(singleton: "K12Results:recalculate:#{course.global_id}:#{@second_term.id}",
                                  n_strand: ["K12Results", course.global_root_account_id],
                                  on_conflict: :loose)
      expect(K12CourseResult.active.where(course_id: course.id, grading_period_id: @second_term.id)).to be_present
    end

    it "uses one singleton per term for the session rollup" do
      course = Course.find(@course.id)
      captured = nil
      allow(K12Results).to receive(:delay_if_production) do |**opts|
        captured = opts
        K12Results
      end
      K12Results.recalculate_session_later(course)
      expect(captured).to include(singleton: "K12Results:session:#{course.enrollment_term.global_id}",
                                  on_conflict: :loose)
    end

    it "final-grade override edits (which skip GradeCalculator) still recompute" do
      @course.enable_feature!(:final_grades_override)
      @course.update!(allow_final_grade_override: "true")
      @assignment.grade_student(@student, score: 70, grader: @teacher)

      score = @course.enrollments.find_by(user_id: @student).find_score(course_score: true)
      # re-find: the inverse associations otherwise point back at the
      # onceler-restored @course, whose root_account predates the flag flip
      score = Score.find(score.id)
      score.update!(override_score: 95)

      sessional = K12CourseResult.active.find_by(user_id: @student.id,
                                                 course_id: @course.id,
                                                 grading_period_id: nil)
      expect(sessional.score).to eq 95.0
    end

    it "never lets a result recompute failure break grading" do
      allow(K12Results).to receive(:recalculate_later).and_raise("boom")
      expect(Canvas::Errors).to receive(:capture_exception).with(:k12_results, anything).at_least(:once)
      expect do
        @assignment.grade_student(@student, score: 42, grader: @teacher)
      end.not_to raise_error
      submission = @assignment.submission_for_student(@student)
      expect(submission.score).to eq 42.0
    end

    it "skips gracefully when the enqueued period has since been deleted" do
      expect do
        K12Results.recalculate(@course.id, @second_term.id + 1000)
      end.not_to change(K12ResultSet, :count)
    end
  end
end
