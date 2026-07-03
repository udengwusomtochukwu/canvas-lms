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

# Page Schools fork (Manual Exam Workflow)
RSpec.shared_context "manual exam with uploaded script" do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @assignment = @course.assignments.create!(title: "Midterm Exam", submission_types: "on_paper", points_possible: 100)

    @observer = user_factory(active_all: true)
    @course.enroll_user(@observer, "ObserverEnrollment", enrollment_state: "active").update!(associated_user_id: @student.id)

    dir = Dir.mktmpdir
    path = File.join(dir, "marked_script.pdf")
    File.write(path, "%PDF-1.4 scanned script")
    @result = ManualExams::ScriptUploadService.call(
      assignment: @assignment,
      student: @student,
      grader: @teacher,
      file: Rack::Test::UploadedFile.new(path, "application/pdf"),
      score: 87
    )
    @script_attachment = @result.script.attachment
  end
end
