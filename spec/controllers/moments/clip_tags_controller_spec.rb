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

describe Moments::ClipTagsController do
  include_context "moments course"

  context "with the flag OFF" do
    it "404s" do
      user_session(@teacher)
      post :create, params: { course_id: @course.id, clip_id: @clip.id, user_id: @student.id }
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before(:once) { enable_moments! }
    before { user_session(@teacher) }

    it "tags a consented student" do
      consent!(@student)
      post :create, params: { course_id: @course.id, clip_id: @clip.id, user_id: @student.id }, format: :json
      expect(response).to be_successful
      expect(response.parsed_body["tagged_user_ids"]).to eq [@student.id]
    end

    it "refuses a non-consented student with 403 (G3)" do
      post :create, params: { course_id: @course.id, clip_id: @clip.id, user_id: @student.id }, format: :json
      assert_status(403)
      expect(response.parsed_body["error"]).to match(/consent/)
      expect(@clip.clip_tags.count).to eq 0
    end

    it "cannot reach a clip through the wrong course" do
      other_course = course_with_teacher(active_all: true, user: @teacher).course
      post :create, params: { course_id: other_course.id, clip_id: @clip.id, user_id: @student.id }, format: :json
      assert_status(404)
    end

    it "untags" do
      consent!(@student)
      @clip.clip_tags.create!(user: @student, tagged_by: @teacher)
      delete :destroy, params: { course_id: @course.id, clip_id: @clip.id, user_id: @student.id }, format: :json
      expect(response).to be_successful
      expect(@clip.clip_tags.count).to eq 0
    end

    it "denies students entirely" do
      user_session(@student)
      post :create, params: { course_id: @course.id, clip_id: @clip.id, user_id: @student.id }
      assert_unauthorized
    end
  end
end
