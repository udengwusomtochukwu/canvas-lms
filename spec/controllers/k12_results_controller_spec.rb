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

describe K12ResultsController do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @first_term, @second_term = create_k12_terms_for(@course)
    @assignment = k12_assignment(@course, "Examination", title: "Exam", due_at: 1.week.ago)
  end

  context "with the flag OFF" do
    it "404s" do
      user_session(@teacher)
      get :show, params: { course_id: @course.id }
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before :once do
      Account.default.enable_feature!(:automatic_k12_result)
      @assignment.grade_student(@student, score: 64, grader: @teacher)
    end

    it "refuses students" do
      user_session(@student)
      get :show, params: { course_id: @course.id }
      assert_unauthorized
    end

    describe "show" do
      render_views

      it "shows the current period's computed set to the teacher" do
        user_session(@teacher)
        get :show, params: { course_id: @course.id }
        expect(response).to have_http_status :ok
        expect(response.body).to include @student.name
        expect(response.body).to include "64"
      end
    end

    it "recalculates on demand" do
      K12ResultSet.destroy_all
      K12CourseResult.delete_all
      user_session(@teacher)
      post :recalculate, params: { course_id: @course.id, grading_period_id: @second_term.id }
      expect(response).to be_redirect
      expect(K12CourseResult.active.where(course_id: @course.id, grading_period_id: @second_term.id)).to be_present
    end

    it "stores the course view-mode override" do
      user_session(@teacher)
      put :update_view_mode, params: { course_id: @course.id, view_mode: "developmental" }
      expect(@course.reload.settings[:k12_result_view]).to eq "developmental"

      put :update_view_mode, params: { course_id: @course.id, view_mode: "bogus" }
      expect(@course.reload.settings[:k12_result_view]).to eq "developmental"
    end

    it "saves a per-subject remark on the result row" do
      user_session(@teacher)
      put :update_remark, params: { course_id: @course.id,
                                    user_id: @student.id,
                                    grading_period_id: @second_term.id,
                                    remark: "Strong exam technique" }
      result = K12CourseResult.active.find_by(user_id: @student.id,
                                              course_id: @course.id,
                                              grading_period_id: @second_term.id)
      expect(result.remark).to eq "Strong exam technique"
    end
  end
end
