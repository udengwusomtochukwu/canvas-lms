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

describe K12Results::SessionRecalculator do
  before :once do
    Account.default.enable_feature!(:automatic_k12_result)
    course_with_teacher(active_all: true)
    @term = @course.enrollment_term
    @maths = @course
    @english = course_factory(active_all: true, account: Account.default)
    @english.update!(enrollment_term: @term)

    @s1 = user_factory(active_all: true)
    @s2 = user_factory(active_all: true)
    @s3 = user_factory(active_all: true)
    @s4 = user_factory(active_all: true)
    [@s1, @s2, @s3, @s4].each { |s| @maths.enroll_student(s, enrollment_state: "active") }
    [@s1, @s2, @s3].each { |s| @english.enroll_student(s, enrollment_state: "active") }
  end

  # Sessional per-course rows are CourseRecalculator's output; the session
  # rollup only reads them, so the specs write them directly for precision.
  def seed_course_results(course, scores_by_user)
    set = K12ResultSet.create!(course:,
                               grading_period_id: nil,
                               enrollment_term: @term,
                               root_account: Account.default,
                               enrolled_count: scores_by_user.size,
                               attempted_count: scores_by_user.values.compact.size)
    scores_by_user.each do |user, score|
      K12CourseResult.create!(k12_result_set: set,
                              user:,
                              course:,
                              grading_period_id: nil,
                              score:,
                              root_account: Account.default)
    end
  end

  before :once do
    seed_course_results(@maths, { @s1 => 80.0, @s2 => 60.0, @s3 => 40.0, @s4 => 70.0 })
    seed_course_results(@english, { @s1 => 90.0, @s2 => 70.0, @s3 => nil })
  end

  def recalc
    described_class.call(enrollment_term: @term)
  end

  def session_for(user)
    K12SessionResult.active.find_by(user_id: user.id, enrollment_term_id: @term.id)
  end

  it "averages each student's sessional course scores, skipping ungraded subjects" do
    recalc
    expect(session_for(@s1).average).to eq 85.0  # (80 + 90) / 2
    expect(session_for(@s2).average).to eq 65.0
    expect(session_for(@s3).average).to eq 40.0  # english nil is skipped, not zero
    expect(session_for(@s4).average).to eq 70.0
    expect(session_for(@s1).courses_count).to eq 2
    expect(session_for(@s4).courses_count).to eq 1
  end

  it "ranks each student within the union of their coursemates (the class arm)" do
    recalc
    expect(session_for(@s1).rank).to eq 1 # 85
    expect(session_for(@s4).rank).to eq 2 # 70
    expect(session_for(@s2).rank).to eq 3 # 65
    expect(session_for(@s3).rank).to eq 4 # 40
    expect(session_for(@s1).cohort_enrolled_count).to eq 4
    expect(session_for(@s1).cohort_attempted_count).to eq 4
  end

  it "ties share a rank (competition ranking)" do
    K12CourseResult.find_by(user_id: @s2.id, course_id: @english.id).update!(score: 80.0) # avg 70 — ties @s4
    recalc
    expect(session_for(@s1).rank).to eq 1
    expect(session_for(@s2).rank).to eq 2
    expect(session_for(@s4).rank).to eq 2
    expect(session_for(@s3).rank).to eq 4
  end

  it "computes the cohort median of session averages" do
    recalc
    expect(session_for(@s1).median).to eq 67.5 # [40, 65, 70, 85]
  end

  it "preserves manually entered traits and remarks across recomputes" do
    recalc
    session_for(@s1).update!(traits: { "affective" => { "Punctuality" => 5 } },
                             class_teacher_remark: "Consistently excellent",
                             head_teacher_remark: "Promoted")
    recalc
    expect(session_for(@s1).trait_ratings("affective")).to eq({ "Punctuality" => 5 })
    expect(session_for(@s1).class_teacher_remark).to eq "Consistently excellent"
    expect(session_for(@s1).head_teacher_remark).to eq "Promoted"
  end

  it "is idempotent and prunes students who left the term" do
    recalc
    ids = K12SessionResult.where(enrollment_term_id: @term.id).order(:id).pluck(:id)
    recalc
    expect(K12SessionResult.where(enrollment_term_id: @term.id).order(:id).pluck(:id)).to eq ids

    K12CourseResult.where(user_id: @s4.id).destroy_all
    recalc
    expect(session_for(@s4)).to be_nil
  end
end
