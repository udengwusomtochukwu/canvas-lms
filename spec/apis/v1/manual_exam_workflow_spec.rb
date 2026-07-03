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

require_relative "../api_spec_helper"

# Page Schools fork (Manual Exam Workflow): proves that a manual exam's
# score, graded script and outcome mastery surface through Canvas's EXISTING
# APIs and visibility rules — no new permission code:
#   * linked observers see the score and can download the script
#   * non-linked observers cannot
#   * outcome rollups reflect the exam via the standard rubric pipeline
describe "Manual Exam Workflow (existing API surfaces)", type: :request do
  before :once do
    course_with_teacher(active_all: true)
    @course.root_account.enable_feature!(:manual_exam_workflow)
    @student = student_in_course(course: @course, active_all: true).user
    @assignment = @course.assignments.create!(title: "Midterm Exam", submission_types: "on_paper", points_possible: 100)

    @observer = user_factory(active_all: true)
    enrollment = @course.enroll_user(@observer, "ObserverEnrollment", enrollment_state: "active")
    enrollment.update!(associated_user_id: @student.id)

    # an observer in the same course who is NOT linked to @student
    # (enroll directly: student_in_course would reassign @student)
    @other_student = user_factory(active_all: true)
    @course.enroll_student(@other_student, enrollment_state: "active")
    @non_linked_observer = user_factory(active_all: true)
    other_enrollment = @course.enroll_user(@non_linked_observer, "ObserverEnrollment", enrollment_state: "active")
    other_enrollment.update!(associated_user_id: @other_student.id)

    dir = Dir.mktmpdir
    path = File.join(dir, "marked_script.pdf")
    File.write(path, "scanned exam script")
    @result = ManualExams::ScriptUploadService.call(
      assignment: @assignment,
      student: @student,
      grader: @teacher,
      file: Rack::Test::UploadedFile.new(path, "application/pdf"),
      score: 87
    )
    @script_attachment = @result.script.attachment
  end

  def show_submission_params
    { controller: "submissions_api",
      action: "show",
      format: "json",
      course_id: @course.id.to_s,
      assignment_id: @assignment.id.to_s,
      user_id: @student.id.to_s,
      include: ["submission_comments"] }
  end

  def show_submission_path
    "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}.json?include[]=submission_comments"
  end

  describe "a linked observer" do
    before { @user = @observer }

    it "retrieves the exam score through the existing submissions API" do
      json = api_call(:get, show_submission_path, show_submission_params)
      expect(json["score"]).to eq 87
    end

    it "sees the graded script on the submission comment" do
      json = api_call(:get, show_submission_path, show_submission_params)
      attachments = json["submission_comments"].flat_map { |c| c["attachments"] || [] }
      expect(attachments.pluck("display_name")).to include "marked_script.pdf"
    end

    it "can download the script attachment (existing attachment policy)" do
      expect(@script_attachment.grants_right?(@observer, :read)).to be true
      expect(@script_attachment.grants_right?(@observer, :download)).to be true
    end
  end

  describe "a NON-linked observer" do
    before { @user = @non_linked_observer }

    it "cannot retrieve the student's submission" do
      # Canvas 404s here: a non-observed student isn't even visible to the
      # observer, which is a stronger denial than 403.
      api_call(:get, show_submission_path, show_submission_params, {}, {}, { expected_status: 404 })
    end

    it "cannot read the grade or download the script (model policies)" do
      submission = @result.submission
      expect(submission.grants_right?(@non_linked_observer, :read)).to be false
      expect(submission.grants_right?(@non_linked_observer, :read_grade)).to be false
      expect(@script_attachment.grants_right?(@non_linked_observer, :read)).to be false
      expect(@script_attachment.grants_right?(@non_linked_observer, :download)).to be false
    end
  end

  describe "the student" do
    before { @user = @student }

    it "sees their own score and graded script" do
      json = api_call(:get, show_submission_path, show_submission_params)
      expect(json["score"]).to eq 87
      attachments = json["submission_comments"].flat_map { |c| c["attachments"] || [] }
      expect(attachments.pluck("display_name")).to include "marked_script.pdf"
    end
  end

  describe "outcome rollups" do
    before :once do
      outcome_with_rubric(course: @course)
      @rubric.associate_with(@assignment, @course, purpose: "grading", use_for_grading: true)
      criterion_id = @rubric.criteria[0][:id]
      ManualExams::ScriptUploadService.call(
        assignment: @assignment,
        student: @student,
        grader: @teacher,
        rubric_assessment: { criterion_id.to_s => { "points" => 3 } }
      )
      run_jobs
    end

    it "reflects the exam through the standard outcome rollup API" do
      @user = @teacher
      json = api_call(:get,
                      "/api/v1/courses/#{@course.id}/outcome_rollups?user_ids[]=#{@student.id}",
                      { controller: "outcome_results",
                        action: "rollups",
                        format: "json",
                        course_id: @course.id.to_s,
                        user_ids: [@student.id.to_s] })
      rollup = json["rollups"].find { |r| r.dig("links", "user") == @student.id.to_s }
      expect(rollup).not_to be_nil
      score = rollup["scores"].find { |s| s.dig("links", "outcome") == @outcome.id.to_s }
      expect(score).not_to be_nil
      expect(score["score"]).to eq 3.0
    end
  end
end
