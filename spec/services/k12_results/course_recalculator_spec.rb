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

describe K12Results::CourseRecalculator do
  before :once do
    Account.default.enable_feature!(:automatic_k12_result)
    course_with_teacher(active_all: true)
    @s1 = user_factory(active_all: true)
    @s2 = user_factory(active_all: true)
    @s3 = user_factory(active_all: true)
    @s4 = user_factory(active_all: true)
    [@s1, @s2, @s3, @s4].each { |s| @course.enroll_student(s, enrollment_state: "active") }

    @first_term, @second_term = create_k12_terms_for(@course)

    # First term: one graded assignment for @s1 only.
    @old_exam = k12_assignment(@course, "Examination", title: "First Term Exam", due_at: 6.weeks.ago)
    @old_exam.grade_student(@s1, score: 50, grader: @teacher)

    # Second term: CA (20 points) + exam (100 points).
    @ca = k12_assignment(@course, "Continuous Assessment", title: "CA 1", due_at: 1.week.ago, points: 20)
    @exam = k12_assignment(@course, "Examination", title: "Second Term Exam", due_at: 3.days.ago)
    @ca.grade_student(@s1, score: 18, grader: @teacher)
    @ca.grade_student(@s2, score: 15, grader: @teacher)
    @ca.grade_student(@s3, score: 15, grader: @teacher)
    @exam.grade_student(@s1, score: 80, grader: @teacher)
    @exam.grade_student(@s2, score: 90, grader: @teacher)
    @exam.grade_student(@s3, score: 90, grader: @teacher)
    # @s4 has no graded submission at all.
  end

  def recalc(period = @second_term)
    described_class.call(course: @course, grading_period: period)
  end

  def result_for(user, period = @second_term)
    K12CourseResult.active.find_by(user_id: user.id, course_id: @course.id, grading_period_id: period&.id)
  end

  describe "scores" do
    it "copies each student's posted period score from the same Score row the gradebook uses" do
      recalc
      [@s1, @s2, @s3].each do |student|
        enrollment = @course.enrollments.find_by(user_id: student)
        expect(result_for(student).score)
          .to eq enrollment.computed_current_score(grading_period_id: @second_term.id)
      end
    end

    it "leaves ungraded students with a nil score, never a silent zero" do
      recalc
      expect(result_for(@s4).score).to be_nil
      expect(result_for(@s4).grade).to be_nil
    end

    it "grades with the WAEC bands when the course has no grading standard" do
      recalc
      expect(result_for(@s2).grade).to eq "A1" # 87.5
    end

    it "uses the course grading standard when one is enabled" do
      standard = grading_standard_for(@course)
      @course.update!(grading_standard_enabled: true, grading_standard: standard)
      recalc
      expect(result_for(@s2).grade).to eq @course.score_to_grade(result_for(@s2).score)
    end
  end

  describe "grading period scoping" do
    it "computes each period from its own assignments only" do
      recalc(@first_term)
      recalc(@second_term)
      expect(result_for(@s1, @first_term).score).to eq 50.0
      expect(result_for(@s2, @first_term).score).to be_nil
      expect(result_for(@s1, @second_term).score).to be_within(0.01).of(81.67)
    end

    it "computes the sessional row from the course-level Score row" do
      recalc(nil)
      enrollment = @course.enrollments.find_by(user_id: @s1)
      expect(result_for(@s1, nil).score).to eq enrollment.computed_current_score
    end
  end

  describe "CA/exam split" do
    it "scales the buckets to the configured weights (default 40/60)" do
      recalc
      expect(result_for(@s1).ca_score).to eq 36.0   # 18/20 * 40
      expect(result_for(@s1).exam_score).to eq 48.0 # 80/100 * 60
      expect(result_for(@s4).ca_score).to be_nil
    end

    it "keeps hidden (unposted) grades out of the split and the score" do
      hidden = k12_assignment(@course, "Continuous Assessment", title: "CA 2", due_at: 2.days.ago, points: 10)
      hidden.ensure_post_policy(post_manually: true)
      hidden.grade_student(@s1, score: 0, grader: @teacher)
      recalc
      expect(result_for(@s1).ca_score).to eq 36.0
      expect(result_for(@s1).score).to be_within(0.01).of(81.67)
    end
  end

  describe "ranking (standard competition, both position modes share ranks)" do
    it "ranks 1,1,3 on a tie at the top and leaves unscored students unranked" do
      recalc
      expect(result_for(@s2).rank).to eq 1 # 87.5
      expect(result_for(@s3).rank).to eq 1 # 87.5
      expect(result_for(@s1).rank).to eq 3 # 81.67
      expect(result_for(@s4).rank).to be_nil
    end

    it "produces a 1,2,2,4 shape for a middle tie" do
      @ca.grade_student(@s4, score: 20, grader: @teacher)
      @exam.grade_student(@s4, score: 100, grader: @teacher) # 100%: rank 1
      @exam.grade_student(@s1, score: 90, grader: @teacher) # (18+90)/120 = 90
      # scores: s4 100, s1 90, s2 87.5, s3 87.5
      @ca.grade_student(@s1, score: 15, grader: @teacher) # s1 -> (15+90)/120 = 87.5 (three-way tie for 2nd)
      recalc
      expect(result_for(@s4).rank).to eq 1
      expect([result_for(@s1).rank, result_for(@s2).rank, result_for(@s3).rank]).to eq [2, 2, 2]

      @ca.grade_student(@s1, score: 18, grader: @teacher) # s1 -> 90, break the tie: 1,2,3,3
      recalc
      expect(result_for(@s4).rank).to eq 1
      expect(result_for(@s1).rank).to eq 2
      expect(result_for(@s2).rank).to eq 3
      expect(result_for(@s3).rank).to eq 3
    end

    it "stores both population counts so either position mode can render" do
      recalc
      set = result_for(@s1).k12_result_set
      expect(set.enrolled_count).to eq 4
      expect(set.attempted_count).to eq 3
    end
  end

  describe "median" do
    it "computes the median over graded scores with linear interpolation" do
      recalc
      set = result_for(@s1).k12_result_set
      expect(set.median).to eq 87.5 # [81.67, 87.5, 87.5]

      @exam.grade_student(@s4, score: 60, grader: @teacher) # adds (60/100 exam only) = 60.0
      recalc
      # sorted: [60.0, 81.67, 87.5, 87.5] -> (81.67 + 87.5) / 2
      expect(result_for(@s1).k12_result_set.reload.median).to be_within(0.02).of(84.58)
    end
  end

  describe "mastery snapshot" do
    before :once do
      outcome_with_rubric(course: @course)
      @association = @rubric.associate_with(@exam, @course, purpose: "grading")
      @criterion_id = @rubric.criteria[0][:id]
      @association.assess(user: @s1,
                          assessor: @teacher,
                          artifact: @exam.submission_for_student(@s1),
                          assessment: { assessment_type: "grading",
                                        "criterion_#{@criterion_id}": { points: 3 } })
    end

    it "snapshots the rollup with rating labels from the mastery scale" do
      recalc
      entries = result_for(@s1).mastery_entries
      expect(entries.size).to eq 1
      entry = entries.first
      expect(entry["outcome_id"]).to eq @outcome.id
      expect(entry["score"]).to eq 3.0
      expect(entry["mastery"]).to be true
      expect(entry["rating"]).to be_present
      expect(result_for(@s2).mastery_entries).to be_empty
    end

    it "scopes mastery to the grading period window" do
      recalc(@first_term)
      expect(result_for(@s1, @first_term).mastery_entries).to be_empty
    end

    it "omits mastery when the account turns it off" do
      Account.default.settings[:k12_result] = { "show_mastery" => false }
      Account.default.save!
      @course.reload # bust the onceler-memoized root_account (stale settings)
      recalc
      expect(result_for(@s1).mastery_entries).to be_empty
    end
  end

  describe "idempotency and upkeep" do
    it "recomputing twice changes nothing and never duplicates rows" do
      recalc
      ids = K12CourseResult.where(course_id: @course.id, grading_period_id: @second_term.id).order(:id).pluck(:id)
      recalc
      expect(K12CourseResult.where(course_id: @course.id, grading_period_id: @second_term.id).order(:id).pluck(:id))
        .to eq ids
    end

    it "preserves teacher remarks across recomputes" do
      recalc
      result_for(@s1).update!(remark: "Fine work in Number")
      recalc
      expect(result_for(@s1).remark).to eq "Fine work in Number"
    end

    it "prunes rows for students no longer enrolled" do
      recalc
      expect(result_for(@s4)).to be_present
      @course.enrollments.find_by(user_id: @s4).destroy
      recalc
      expect(result_for(@s4)).to be_nil
      expect(result_for(@s1).k12_result_set.enrolled_count).to eq 3
    end

    it "never counts the Test Student" do
      @course.student_view_student
      recalc
      expect(result_for(@s1).k12_result_set.enrolled_count).to eq 4
    end
  end

  describe "provisional vs final" do
    it "marks the set provisional while the period is open and final once closed" do
      recalc(@second_term)
      expect(result_for(@s1, @second_term).k12_result_set.finalized).to be false

      recalc(@first_term)
      expect(result_for(@s1, @first_term).k12_result_set.finalized).to be false

      @first_term.update!(close_date: 1.minute.ago)
      recalc(@first_term)
      expect(result_for(@s1, @first_term).k12_result_set.finalized).to be true
    end
  end
end
