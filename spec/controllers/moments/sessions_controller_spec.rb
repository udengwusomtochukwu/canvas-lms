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

describe Moments::SessionsController do
  include_context "moments course"

  context "with the flag OFF" do
    it "404s" do
      user_session(@teacher)
      get :index, params: { course_id: @course.id }
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before(:once) { enable_moments! }

    it "denies students" do
      user_session(@student)
      get :index, params: { course_id: @course.id }
      assert_unauthorized
    end

    it "lists sessions for the teacher" do
      user_session(@teacher)
      get :index, params: { course_id: @course.id }
      expect(response).to be_successful
      expect(assigns[:sessions]).to include @session
    end

    it "creates a session and returns the backend's presigned upload URL" do
      expect(MomentsBackend).to receive(:presign_upload)
        .and_return({ "upload_url" => "http://worker.test/put/abc" })

      user_session(@teacher)
      post :create, params: { course_id: @course.id, title: "Assembly", clip_seconds: 30 }, format: :json
      expect(response).to be_successful

      json = response.parsed_body
      expect(json["upload_url"]).to eq "http://worker.test/put/abc"
      session = Moments::Session.find(json["session_id"])
      expect(session.course).to eq @course
      expect(session.sidecar_ref).to be_present
    end

    it "rolls the session back when the backend is unreachable" do
      expect(MomentsBackend).to receive(:presign_upload).and_raise(MomentsBackend::Error, "down")

      user_session(@teacher)
      expect do
        post :create, params: { course_id: @course.id, title: "Assembly" }, format: :json
      end.not_to change { Moments::Session.count }
      assert_status(502)
    end

    it "ingest enqueues segmentation with a callback URL and advances state" do
      expect(MomentsBackend).to receive(:segment!) do |session:, callback_url:|
        expect(session).to eq @session
        expect(callback_url).to include "/moments/callbacks/segmented"
        {}
      end

      user_session(@teacher)
      post :ingest, params: { course_id: @course.id, session_id: @session.id }, format: :json
      expect(response).to be_successful
      expect(@session.reload.workflow_state).to eq "processing"
    end

    it "shows the board with the course roster and consent flags" do
      consent!(@student)
      user_session(@teacher)
      get :show, params: { course_id: @course.id, id: @session.id }
      expect(response).to be_successful
      expect(assigns[:students]).to include @student
      expect(assigns[:consented_ids]).to include @student.id
    end
  end
end
