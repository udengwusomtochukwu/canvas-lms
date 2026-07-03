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

module ManualExams
  # Page Schools fork (Manual Exam Workflow): one teacher action for an
  # on-paper exam — attach the scanned, hand-graded script to the student's
  # submission, record the score, and optionally fill the aligned rubric.
  #
  # Everything writes through the native pipelines:
  #   * file      -> FileInContext.attach + Submission#add_comment (same as
  #                  the gradebook zip re-upload), so SpeedGrader, the student
  #                  view and observers see it with no new permission code
  #   * score     -> AbstractAssignment#grade_student (gradebook totals,
  #                  grading periods, posting policies all apply)
  #   * rubric    -> RubricAssociation#assess (same call the Submissions API
  #                  makes), so LearningOutcomeResults and outcome rollups
  #                  come from the standard Rubric + Outcomes pipeline
  #
  # Idempotent: a re-upload replaces the attachment on the existing manual
  # exam comment (tracked via ManualExamScript) instead of stacking comments.
  class ScriptUploadService < ApplicationService
    class InvalidExam < StandardError; end

    def initialize(assignment:, student:, grader:, file: nil, score: nil, rubric_assessment: nil)
      super()
      @assignment = assignment
      @student = student
      @grader = grader
      @file = file
      @score = score
      @rubric_assessment = rubric_assessment
    end

    def call
      validate!
      @submission = @assignment.find_or_create_submission(@student)
      attach_script if @file
      record_score if @score.present?
      assess_rubric if @rubric_assessment.present?
      Result.new(submission: @submission.reload, script: @script)
    end

    Result = Struct.new(:submission, :script, keyword_init: true) do
      def attachment
        script&.attachment
      end

      def comment
        script&.submission_comment
      end
    end

    private

    def validate!
      unless @assignment.submission_types.to_s.split(",").include?("on_paper")
        raise InvalidExam, I18n.t("A manual exam must be an assignment with the 'on_paper' submission type.")
      end

      if @rubric_assessment.present? && !@assignment.active_rubric_association?
        raise InvalidExam, I18n.t("This assignment has no rubric to assess.")
      end
    end

    def attach_script
      attachment = FileInContext.attach(@assignment, @file.path, display_name: @file.original_filename)
      attachment.ok_for_submission_comment = true

      begin
        upsert_script(attachment)
      rescue ActiveRecord::RecordNotUnique
        # Concurrent first upload for the same submission: the other request
        # created the pointer row; run once more as a replace.
        upsert_script(attachment)
      end
    end

    def upsert_script(attachment)
      ManualExamScript.transaction do
        @script = ManualExamScript.where(submission: @submission).lock.first
        if @script
          replace_script(attachment)
        else
          create_script(attachment)
        end
      end
    end

    def create_script(attachment)
      comment = @submission.add_comment(
        author: @grader,
        comment: comment_text,
        attachments: [attachment],
        hidden: @submission.hide_grade_from_student?
      )
      @script = ManualExamScript.create!(
        submission: @submission,
        attachment:,
        submission_comment: comment,
        uploaded_by: @grader
      )
    end

    def replace_script(attachment)
      previous_attachment = @script.attachment
      # Hard-deleted comments (SubmissionComment has no soft delete) leave the
      # foreign key nullified, so the association is simply nil here.
      comment = @script.submission_comment
      if comment
        comment.attachments = [attachment]
        comment.author = @grader
        comment.save!
      else
        comment = @submission.add_comment(
          author: @grader,
          comment: comment_text,
          attachments: [attachment],
          hidden: @submission.hide_grade_from_student?
        )
      end
      @script.update!(attachment:, submission_comment: comment, uploaded_by: @grader)
      previous_attachment.destroy if previous_attachment && previous_attachment != attachment
    end

    def comment_text
      I18n.t("Graded exam script attached.")
    end

    def record_score
      @assignment.grade_student(@student, score: @score, grader: @grader).first
    end

    # Mirrors SubmissionsApiController#update's rubric_assessment handling:
    # keys are criterion ids, values are {points:, rating_id:, comments:}.
    def assess_rubric
      association = @assignment.rubric_association
      criterion_ids = association.rubric.criteria_object.map { |c| c.id.to_s }
      assessment = @rubric_assessment.to_h.with_indifferent_access
      unless assessment.keys.intersect?(criterion_ids)
        raise InvalidExam, I18n.t("invalid rubric_assessment")
      end

      assessment.transform_keys! { |crit_id| "criterion_#{crit_id}" }
      association.assess(
        assessor: @grader,
        user: @student,
        artifact: @submission,
        assessment: assessment.merge(assessment_type: "grading")
      )
    end
  end
end
