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

# Page Schools fork (Manual Exam Workflow): the files controller serves PDFs
# inline when the flag is on, so browsers can preview graded exam scripts.
describe FilesController do
  include_context "manual exam with uploaded script"

  before do
    # serve from the files domain directly (upstream spec pattern) so the
    # safe-domain redirect hop doesn't get in the way of disposition checks
    allow(HostUrl).to receive(:file_host).and_return("files.test")
    request.host = "files.test"
  end

  # the context-less /files/:id/download route — the one submission comment
  # attachment links actually use
  def fetch_file(inline: "1")
    get :show, params: { id: @script_attachment.id, download: "1", inline: }
  end

  context "with the flag on" do
    before(:once) { @course.root_account.enable_feature!(:manual_exam_workflow) }

    it "serves the PDF inline when requested" do
      user_session(@student)
      fetch_file
      expect(response).to be_successful
      expect(response.header["Content-Disposition"]).to start_with "inline"
    end

    it "serves inline to the linked observer too" do
      user_session(@observer)
      fetch_file
      expect(response).to be_successful
      expect(response.header["Content-Disposition"]).to start_with "inline"
    end

    it "still downloads when inline is not requested" do
      user_session(@student)
      get :show, params: { id: @script_attachment.id, download: "1", download_frd: "1" }
      expect(response.header["Content-Disposition"]).to start_with "attachment"
    end
  end

  context "with the flag off" do
    it "keeps stock behaviour: PDFs are never served inline" do
      user_session(@student)
      fetch_file
      expect(response.header["Content-Disposition"]).to start_with "attachment"
    end
  end
end
