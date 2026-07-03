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

describe ManualExams::ScriptUploadService do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @assignment = @course.assignments.create!(title: "Midterm Exam", submission_types: "on_paper", points_possible: 100)
  end

  def script_file(name = "script.pdf", content: "scanned exam script")
    dir = Dir.mktmpdir
    path = File.join(dir, name)
    File.write(path, content)
    Rack::Test::UploadedFile.new(path, "application/pdf")
  end

  def upload(**)
    described_class.call(assignment: @assignment, student: @student, grader: @teacher, **)
  end

  describe "validation" do
    it "rejects assignments that are not on_paper" do
      online = @course.assignments.create!(title: "Essay", submission_types: "online_text_entry")
      expect do
        described_class.call(assignment: online, student: @student, grader: @teacher, file: script_file)
      end.to raise_error(ManualExams::ScriptUploadService::InvalidExam, /on_paper/)
    end

    it "rejects a rubric assessment when the assignment has no rubric" do
      expect do
        upload(rubric_assessment: { "1" => { "points" => 3 } })
      end.to raise_error(ManualExams::ScriptUploadService::InvalidExam, /no rubric/)
    end
  end

  describe "script attachment" do
    it "attaches the script to the student's submission as a comment attachment" do
      result = upload(file: script_file)

      submission = result.submission
      expect(submission.user).to eq @student
      comments = submission.submission_comments
      expect(comments.count).to eq 1
      expect(comments.first.author).to eq @teacher
      expect(comments.first.attachments.map(&:display_name)).to eq ["script.pdf"]
      # stored through the native mechanism: file lives on the assignment
      expect(comments.first.attachments.first.context).to eq @assignment
      expect(result.script.attachment).to eq comments.first.attachments.first
    end

    it "is idempotent: re-uploading replaces the script instead of duplicating" do
      first = upload(file: script_file("marked_v1.pdf"))
      old_attachment = first.attachment

      second = upload(file: script_file("marked_v2.pdf"))

      submission = second.submission
      expect(submission.submission_comments.count).to eq 1
      comment = submission.submission_comments.first
      expect(comment.attachments.map(&:display_name)).to eq ["marked_v2.pdf"]
      expect(ManualExamScript.where(submission:).count).to eq 1
      expect(second.script.id).to eq first.script.id
      expect(first.script.reload.attachment.display_name).to eq "marked_v2.pdf"
      # the replaced file is cleaned up (Canvas soft delete)
      expect(old_attachment.reload).to be_deleted
    end

    it "recreates the comment if a teacher deleted it manually" do
      first = upload(file: script_file("marked_v1.pdf"))
      first.comment.destroy

      second = upload(file: script_file("marked_v2.pdf"))
      submission = second.submission
      expect(submission.submission_comments.count).to eq 1
      expect(submission.submission_comments.first.attachments.map(&:display_name)).to eq ["marked_v2.pdf"]
    end
  end

  describe "score" do
    it "grades through the standard submission grading path" do
      result = upload(file: script_file, score: 87)

      submission = result.submission
      expect(submission.score).to eq 87
      expect(submission.workflow_state).to eq "graded"
      expect(submission.grader).to eq @teacher
      # auto-posting applies like any other grade
      expect(submission).to be_posted
    end

    it "updates the gradebook (enrollment computed score)" do
      upload(score: 80)
      run_jobs
      score = @student.enrollments.where(course: @course).first.computed_current_score
      expect(score).to eq 80.0
    end

    it "respects manual posting policies" do
      @assignment.ensure_post_policy(post_manually: true)
      result = upload(file: script_file, score: 55)
      expect(result.submission.score).to eq 55
      expect(result.submission).not_to be_posted
    end

    it "updates the score on re-grade without duplicating anything" do
      upload(file: script_file, score: 70)
      result = upload(score: 91)
      expect(result.submission.score).to eq 91
      expect(result.submission.submission_comments.count).to eq 1
    end
  end

  describe "rubric and outcomes" do
    before :once do
      outcome_with_rubric(course: @course)
      @association = @rubric.associate_with(@assignment, @course, purpose: "grading", use_for_grading: true)
      @criterion_id = @rubric.criteria[0][:id]
    end

    it "assesses through RubricAssociation#assess and writes standard outcome results" do
      result = upload(file: script_file, rubric_assessment: { @criterion_id.to_s => { "points" => 3 } })

      submission = result.submission
      assessment = submission.rubric_assessments.first
      expect(assessment).not_to be_nil
      expect(assessment.assessment_type).to eq "grading"
      expect(assessment.rubric_association).to eq @association

      run_jobs
      outcome_result = LearningOutcomeResult.where(user: @student).first
      expect(outcome_result).not_to be_nil
      expect(outcome_result.learning_outcome).to eq @outcome
      expect(outcome_result.score).to eq 3
      expect(outcome_result.mastery).to be true
      expect(outcome_result.artifact).to eq assessment
    end

    it "uses the rubric total as the grade when the association is use_for_grading" do
      result = upload(rubric_assessment: { @criterion_id.to_s => { "points" => 3 } })
      run_jobs
      expect(result.submission.reload.score).to eq 3
    end

    it "rejects assessments that reference no rubric criterion" do
      expect do
        upload(rubric_assessment: { "bogus" => { "points" => 3 } })
      end.to raise_error(ManualExams::ScriptUploadService::InvalidExam, /invalid rubric_assessment/)
    end
  end
end
