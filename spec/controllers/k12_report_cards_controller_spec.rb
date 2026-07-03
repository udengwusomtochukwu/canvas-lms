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

describe K12ReportCardsController do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    # NOT student_in_course twice — it reassigns @student under the hood
    @other_student = user_factory(active_all: true)
    @course.enroll_student(@other_student, enrollment_state: "active")
    @first_term, @second_term = create_k12_terms_for(@course)
    @assignment = k12_assignment(@course, "Continuous Assessment", title: "CA 1", due_at: 1.week.ago)

    # linked observer (parent) for @student
    @observer = user_factory(active_all: true)
    @course.enroll_user(@observer,
                        "ObserverEnrollment",
                        enrollment_state: "active",
                        associated_user_id: @student.id)
    UserObservationLink.create_or_restore(observer: @observer,
                                          student: @student,
                                          root_account: Account.default)

    # observer in the course NOT linked to @student
    @stranger_observer = user_factory(active_all: true)
    @course.enroll_user(@stranger_observer,
                        "ObserverEnrollment",
                        enrollment_state: "active",
                        associated_user_id: @other_student.id)
    UserObservationLink.create_or_restore(observer: @stranger_observer,
                                          student: @other_student,
                                          root_account: Account.default)
  end

  def show_params(extra = {})
    { user_id: @student.id,
      enrollment_term_id: @course.enrollment_term_id,
      grading_period_id: @second_term.id }.merge(extra)
  end

  context "with the flag OFF" do
    it "404s even for the student themself" do
      user_session(@student)
      get :show, params: show_params
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before :once do
      Account.default.enable_feature!(:automatic_k12_result)
      @assignment.grade_student(@student, score: 78, grader: @teacher)
      @assignment.grade_student(@other_student, score: 55, grader: @teacher)
    end

    describe "visibility" do
      it "lets the student see their own report card" do
        user_session(@student)
        get :show, params: show_params
        expect(response).to have_http_status :ok
      end

      it "lets a linked observer see their student's report card" do
        user_session(@observer)
        get :show, params: show_params
        expect(response).to have_http_status :ok
      end

      it "refuses a non-linked observer in the same course" do
        user_session(@stranger_observer)
        get :show, params: show_params
        assert_unauthorized
      end

      it "refuses another student" do
        user_session(@other_student)
        get :show, params: show_params
        assert_unauthorized
      end

      it "lets the teacher see any student's card" do
        user_session(@teacher)
        get :show, params: show_params
        expect(response).to have_http_status :ok
      end
    end

    describe "rendering" do
      render_views

      it "shows the senior sheet with scores, grade, median and position" do
        user_session(@student)
        get :show, params: show_params
        expect(response.body).to include "Terminal Report Sheet"
        expect(response.body).to include "78"
        expect(response.body).to include "A1"
        expect(response.body).to include "PROVISIONAL"
      end

      it "shows the developmental sheet when the course is set to KG–Y4 mode" do
        @course.settings_frd[:k12_result_view] = "developmental"
        @course.save!
        user_session(@student)
        get :show, params: show_params
        expect(response.body).to include "Learning Progress Report"
        expect(response.body).not_to include "Terminal Report Sheet"
        expect(response.body).not_to include "Position"
      end

      it "respects the account position and median toggles" do
        Account.default.settings[:k12_result] = { "position_mode" => "off", "show_median" => false }
        Account.default.save!
        user_session(@student)
        get :show, params: show_params
        expect(response.body).not_to include "Class Median"
        expect(response.body).not_to include "Position"
      end

      it "renders the session (cumulative) view" do
        user_session(@student)
        get :show, params: show_params(grading_period_id: "session")
        expect(response.body).to include "Session (Cumulative)"
      end

      it "renders a PDF through prawn" do
        user_session(@student)
        get :show, params: show_params(format: :pdf)
        expect(response).to have_http_status :ok
        expect(response.media_type).to eq "application/pdf"
        expect(response.body[0, 4]).to eq "%PDF"
      end
    end

    describe "update (traits and remarks)" do
      it "lets the teacher save traits and remarks" do
        user_session(@teacher)
        put :update, params: show_params(
          traits: { affective: { "Punctuality" => "5" } },
          class_teacher_remark: "A diligent term",
          head_teacher_remark: "Keep it up"
        )
        expect(response).to be_redirect
        session_result = K12SessionResult.find_by(user_id: @student.id,
                                                  enrollment_term_id: @course.enrollment_term_id)
        expect(session_result.trait_ratings("affective")).to eq({ "Punctuality" => 5 })
        expect(session_result.class_teacher_remark).to eq "A diligent term"
      end

      it "refuses the student and observers" do
        [@student, @observer].each do |user|
          user_session(user)
          put :update, params: show_params(class_teacher_remark: "hax")
          assert_unauthorized
        end
      end
    end
  end
end
