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

describe ManualExamScript do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @assignment = @course.assignments.create!(title: "Midterm", submission_types: "on_paper", points_possible: 100)
    @submission = @assignment.find_or_create_submission(@student)
    @attachment = attachment_model(context: @assignment)
  end

  def build_script
    ManualExamScript.new(submission: @submission, attachment: @attachment, uploaded_by: @teacher)
  end

  it "saves and infers root_account from the submission" do
    script = build_script
    expect(script.save).to be true
    expect(script.root_account_id).to eq @submission.root_account_id
  end

  it "allows only one script pointer per submission" do
    build_script.save!
    duplicate = build_script
    duplicate.root_account_id = @submission.root_account_id
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(build_script.save).to be false
  end

  it "does not require a submission comment (comment may be deleted later)" do
    script = build_script
    script.submission_comment = nil
    expect(script.save).to be true
  end

  it "stores no grading data (grades stay on the native submission)" do
    expect(ManualExamScript.column_names).not_to include("score", "grade", "points")
  end
end
