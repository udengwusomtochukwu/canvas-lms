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

# Page Schools fork (Manual Exam Workflow): the submission preview pane
# embeds the graded exam script when the flag is on.
describe Submissions::PreviewsController do
  render_views

  include_context "manual exam with uploaded script"

  def fetch_preview
    get :show, params: { course_id: @course.id, assignment_id: @assignment.id, id: @student.id, preview: true }
  end

  context "with the flag on" do
    before(:once) { @course.root_account.enable_feature!(:manual_exam_workflow) }

    it "embeds the graded script for the student" do
      user_session(@student)
      fetch_preview
      expect(response).to be_successful
      expect(response.body).to include "manual-exam-script-preview"
      expect(response.body).to include "/files/#{@script_attachment.id}/download"
    end

    it "embeds the graded script for the teacher" do
      user_session(@teacher)
      fetch_preview
      expect(response.body).to include "manual-exam-script-preview"
    end

    it "does not embed when the grade is hidden by a manual posting policy" do
      @assignment.ensure_post_policy(post_manually: true)
      @assignment.hide_submissions
      user_session(@student)
      fetch_preview
      expect(response.body).not_to include "manual-exam-script-preview"
    end
  end

  context "with the flag off" do
    it "renders exactly the stock preview (no script iframe)" do
      user_session(@student)
      fetch_preview
      expect(response).to be_successful
      expect(response.body).not_to include "manual-exam-script-preview"
    end
  end
end
