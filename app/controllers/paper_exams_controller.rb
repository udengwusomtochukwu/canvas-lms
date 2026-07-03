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

# Page Schools fork (Manual Exam Workflow, phase 2): turn an unpublished
# classic quiz into a printable paper exam + companion on_paper assignment.
# The quiz stays permanently unpublished (question source only); everything
# graded happens on the companion assignment through the existing manual
# exam workflow. Gated on the same manual_exam_workflow account flag.
class PaperExamsController < ApplicationController
  before_action :require_context
  before_action :require_user
  before_action :require_manual_exam_workflow
  before_action :check_authorized
  before_action :load_quiz

  # Management page: prepare button, link status, drift warning.
  def show
    @paper_exam = PaperExam.find_by(quiz: @quiz)
    @document = PaperExams::Document.from_quiz(@quiz)
  end

  # Idempotent: creates or updates the companion assignment + outcome rubric.
  def prepare
    if @quiz.published?
      flash[:error] = t("This quiz is published — paper exams use an unpublished quiz as their question source.")
      return redirect_to course_quiz_paper_exam_path(@context, @quiz)
    end

    PaperExams::Preparer.call(quiz: @quiz, prepared_by: @current_user)
    flash[:notice] = t("Paper exam prepared — the companion on-paper assignment is ready.")
    redirect_to course_quiz_paper_exam_path(@context, @quiz)
  end

  # The printable document. personalized=1 renders one copy per student with
  # a QR header (studentId + companion assignment id) so scans self-route in
  # the manual exam bulk upload; otherwise one generic copy.
  def printable
    @paper_exam = PaperExam.find_by(quiz: @quiz)
    unless @paper_exam
      flash[:error] = t("Prepare the paper exam first.")
      return redirect_to course_quiz_paper_exam_path(@context, @quiz)
    end

    @document = PaperExams::Document.from_quiz(@quiz)
    @grading_period = GradingPeriod.current_period_for(@context)
    @students =
      if Canvas::Plugin.value_to_boolean(params[:personalized])
        @context.participating_students.order(:sortable_name).distinct.to_a
      else
        [nil]
      end
    @qr_codes = @students.compact.to_h do |student|
      payload = "PSEXAM:1:#{@paper_exam.assignment_id}:#{student.id}"
      [student.id, RQRCode::QRCode.new(payload).as_svg(module_size: 2, use_path: true)]
    end
    @paper_exam.mark_printed!
    render layout: false
  end

  private

  def require_manual_exam_workflow
    not_found unless @context.account&.feature_enabled?(:manual_exam_workflow)
  end

  def check_authorized
    authorized_action(@context, @current_user, :manage_grades)
  end

  def load_quiz
    @quiz = @context.quizzes.active.find(params[:quiz_id])
  end
end
