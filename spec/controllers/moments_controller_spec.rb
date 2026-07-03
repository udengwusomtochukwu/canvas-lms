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

describe MomentsController do
  include_context "moments course"

  context "with the flag OFF" do
    it "404s for everyone (flag-off == stock Canvas)" do
      user_session(@teacher)
      get :index
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before :once do
      enable_moments!
      @reel = Moments::Reel.create!(session: @session, user: @student, workflow_state: "delivered", delivered_at: Time.zone.now)
    end

    it "requires login" do
      get :index
      expect(response).to be_redirect
    end

    it "shows a teacher their courses" do
      user_session(@teacher)
      get :index
      expect(response).to be_successful
      expect(assigns[:teacher_courses]).to include @course
    end

    it "shows a student their own delivered reels grouped by day" do
      user_session(@student)
      get :index
      expect(response).to be_successful
      expect(assigns[:timeline_student]).to eq @student
      expect(assigns[:reels_by_day].values.flatten).to include @reel
    end

    it "shows a linked observer their child's timeline" do
      user_session(@observer)
      get :index
      expect(response).to be_successful
      expect(assigns[:timeline_student]).to eq @student
      expect(assigns[:reels_by_day].values.flatten).to include @reel
    end

    it "never lets an observer select a non-linked student" do
      other_student = user_factory(active_all: true)
      @course.enroll_student(other_student, enrollment_state: "active")
      Moments::Reel.create!(session: @session, user: other_student, workflow_state: "delivered", delivered_at: Time.zone.now)

      user_session(@observer)
      get :index, params: { student_id: other_student.id }
      expect(assigns[:timeline_student]).to eq @student
      expect(assigns[:reels_by_day].values.flatten.map(&:user_id)).not_to include other_student.id
    end
  end
end
