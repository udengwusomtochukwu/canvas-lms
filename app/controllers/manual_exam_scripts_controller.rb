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

require "rqrcode"

# Page Schools fork (Manual Exam Workflow): teacher flow to upload scanned,
# hand-graded scripts for an on-paper exam. Entirely gated on the
# manual_exam_workflow account feature flag — when the flag is off every
# action 404s, so flag-off behaviour is exactly stock Canvas.
#
# The controller is a thin shell over ManualExams::ScriptUploadService; all
# grading, file, rubric and outcome work happens through native pipelines.
class ManualExamScriptsController < ApplicationController
  before_action :require_context
  before_action :require_user
  before_action :require_manual_exam_workflow
  before_action :check_authorized
  before_action :load_assignment

  # GET /courses/:course_id/assignments/:assignment_id/manual_exam
  # Teacher page: per-student upload + score forms, bulk upload with
  # QR/filename matching, current script status.
  def show
    load_roster
    @scripts_by_user_id = ManualExamScript.where(submission: @assignment.all_submissions)
                                          .preload(:attachment, :submission)
                                          .index_by { |script| script.submission.user_id }
  end

  # GET /courses/:course_id/assignments/:assignment_id/manual_exam/labels
  # Printable per-student QR labels (payload: assignment id + student id) to
  # affix to exam scripts before scanning, so bulk upload can route scans.
  def labels
    load_roster
    @qr_codes = @students.to_h do |student|
      [student.id, RQRCode::QRCode.new(qr_payload(student)).as_svg(module_size: 3, use_path: true)]
    end
    render layout: false
  end

  # PUT /courses/:course_id/assignments/:assignment_id/manual_exam/scripts/:user_id
  # Upsert one student's graded script and/or score and/or rubric assessment.
  # Idempotent: re-uploading replaces the existing script attachment.
  def upsert
    student = find_student(params[:user_id])
    return render_student_not_found unless student

    result = ManualExams::ScriptUploadService.call(
      assignment: @assignment,
      student:,
      grader: @current_user,
      file: params[:script].presence,
      score: params[:score].presence,
      rubric_assessment: rubric_assessment_params
    )

    respond_to do |format|
      format.html do
        flash[:notice] = t("Saved exam upload for %{student}.", student: student.short_name)
        redirect_to course_assignment_manual_exam_path(@context, @assignment)
      end
      format.json { render json: script_json(result.submission, result.script) }
    end
  rescue ManualExams::ScriptUploadService::InvalidExam, Assignment::GradeError => e
    respond_to do |format|
      format.html do
        flash[:error] = e.message
        redirect_to course_assignment_manual_exam_path(@context, @assignment)
      end
      format.json { render json: { error: e.message }, status: :unprocessable_content }
    end
  end

  # POST /courses/:course_id/assignments/:assignment_id/manual_exam/scripts
  # Bulk upload of scanned scripts. Routing per file, in order of preference:
  #   1. an explicit user id (script_user_ids[i], filled by the upload page's
  #      client-side QR decode or by manual selection)
  #   2. a "<user_id>_..." filename prefix (matching the printed QR labels)
  #   3. otherwise the file is reported back as unmatched — never guessed.
  def bulk_upsert
    files = Array(params[:scripts]).select { |f| f.respond_to?(:original_filename) }
    explicit_user_ids = Array(params[:script_user_ids])

    attached = []
    unmatched = []
    files.each_with_index do |file, index|
      student = find_student(explicit_user_ids[index].presence) || student_from_filename(file.original_filename)
      if student
        result = ManualExams::ScriptUploadService.call(assignment: @assignment, student:, grader: @current_user, file:)
        attached << script_json(result.submission, result.script)
      else
        unmatched << file.original_filename
      end
    end

    respond_to do |format|
      format.html do
        flash[:notice] = t("Attached %{count} scripts.", count: attached.size) if attached.any?
        flash[:error] = t("Could not match: %{files}", files: unmatched.join(", ")) if unmatched.any?
        redirect_to course_assignment_manual_exam_path(@context, @assignment)
      end
      format.json { render json: { attached:, unmatched: } }
    end
  rescue ManualExams::ScriptUploadService::InvalidExam => e
    respond_to do |format|
      format.html do
        flash[:error] = e.message
        redirect_to course_assignment_manual_exam_path(@context, @assignment)
      end
      format.json { render json: { error: e.message }, status: :unprocessable_content }
    end
  end

  private

  def require_manual_exam_workflow
    # applies_to: Account flags resolve on Account objects only; the course's
    # account walks its ancestor chain, so enabling at the root account works.
    not_found unless @context.account&.feature_enabled?(:manual_exam_workflow)
  end

  def check_authorized
    authorized_action(@context, @current_user, :manage_grades)
  end

  def load_assignment
    @assignment = @context.assignments.active.find(params[:assignment_id])
  end

  def load_roster
    @students = @context.participating_students.order(:sortable_name).distinct
  end

  def find_student(user_id)
    return nil if user_id.blank?

    @context.participating_students.where(id: user_id).first
  end

  def student_from_filename(filename)
    user_id = filename[/\A(\d+)[_\-.]/, 1]
    find_student(user_id)
  end

  def render_student_not_found
    respond_to do |format|
      format.html do
        flash[:error] = t("That student is not enrolled in this course.")
        redirect_to course_assignment_manual_exam_path(@context, @assignment)
      end
      format.json { render json: { error: t("That student is not enrolled in this course.") }, status: :not_found }
    end
  end

  def rubric_assessment_params
    return nil unless params[:rubric_assessment].is_a?(ActionController::Parameters)

    params[:rubric_assessment].permit!.to_h
  end

  def qr_payload(student)
    "PSEXAM:1:#{@assignment.id}:#{student.id}"
  end

  def script_json(submission, script)
    {
      user_id: submission.user_id,
      submission_id: submission.id,
      score: submission.score,
      grade: submission.grade,
      attachment: script && {
        id: script.attachment_id,
        display_name: script.attachment.display_name
      },
      submission_comment_id: script&.submission_comment_id
    }
  end
end
