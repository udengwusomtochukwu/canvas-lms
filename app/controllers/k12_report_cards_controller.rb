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

# Page Schools fork (Automatic K-12 Result): the student/observer-facing
# report card — print-ready HTML and PDF (prawn, the codebase's existing PDF
# engine). Visibility reuses the rights Canvas already grants for reading a
# student's grades: the student themself / staff via :read_grades, parents
# via :read_as_parent (UserObservationLink) or a linked ObserverEnrollment —
# the same checks Score#set_policy and the enrollment :read_grades policy
# rest on. A non-linked observer holds none of these and is refused.
class K12ReportCardsController < ApplicationController
  ENROLLMENT_STATES = %w[active invited completed].freeze
  COURSE_STATES = %w[available completed].freeze

  AFFECTIVE_TRAITS = %w[Punctuality Neatness Politeness Honesty Cooperation Attentiveness].freeze
  PSYCHOMOTOR_TRAITS = ["Handwriting", "Sports", "Drawing/Art", "Handling of tools", "Public speaking"].freeze

  before_action :require_user
  before_action :require_automatic_k12_result
  before_action :load_student
  before_action :check_read_authorized, only: :show
  before_action :check_manage_authorized, only: :update

  def show
    @config = K12Results.config_for(@domain_root_account)
    load_term_and_period
    load_results

    respond_to do |format|
      format.html { render :show }
      format.pdf { render pdf: :show, locals: pdf_locals }
    end
  end

  # Staff-entered report-card staples: per-subject remark lives on
  # K12CourseResult; traits and the class/head teacher remarks live on
  # K12SessionResult. Recomputes never clobber these columns.
  def update
    @term = student_terms.find_by(id: params[:enrollment_term_id])
    return render_unauthorized_action unless @term

    session_result = K12SessionResult.find_or_initialize_by(user_id: @student.id, enrollment_term_id: @term.id)
    session_result.root_account_id ||= @term.root_account_id
    session_result.workflow_state ||= "active"
    if params.key?(:traits)
      session_result.traits = normalized_traits
    end
    session_result.class_teacher_remark = params[:class_teacher_remark] if params.key?(:class_teacher_remark)
    session_result.head_teacher_remark = params[:head_teacher_remark] if params.key?(:head_teacher_remark)
    session_result.save!

    redirect_to user_k12_report_card_path(@student,
                                          enrollment_term_id: @term.id,
                                          grading_period_id: params[:grading_period_id].presence)
  end

  private

  def require_automatic_k12_result
    not_found unless @domain_root_account.feature_enabled?(:automatic_k12_result)
  end

  def load_student
    @student = api_find(User.active, params[:user_id])
  end

  # The student themself and account admins hold :read_grades on the User;
  # parents linked via UserObservationLink hold :read_as_parent (the same
  # right Score#set_policy trusts). Everyone else — course staff and
  # course-linked observers — is covered by the enrollment-level :read_grades
  # policy, exactly the rule the grade summary page authorizes against.
  # A non-linked observer holds none of these.
  def check_read_authorized
    return true if @student.grants_any_right?(@current_user, session, :read_grades, :read_as_parent)
    return true if @student.enrollments.of_student_type.active_or_pending
                           .any? { |e| e.grants_right?(@current_user, session, :read_grades) }

    render_unauthorized_action
  end

  def check_manage_authorized
    return true if manageable_courses.any? { |c| c.grants_right?(@current_user, session, :manage_grades) }

    render_unauthorized_action
  end

  def manageable_courses
    @manageable_courses ||= student_courses(student_terms.find_by(id: params[:enrollment_term_id]))
  end

  def student_terms
    EnrollmentTerm.active
                  .where(id: Course.where(workflow_state: COURSE_STATES)
                                   .joins(:enrollments)
                                   .where(enrollments: { user_id: @student.id,
                                                         type: "StudentEnrollment",
                                                         workflow_state: ENROLLMENT_STATES })
                                   .select(:enrollment_term_id))
  end

  def student_courses(term)
    return [] unless term

    Course.where(enrollment_term_id: term.id, workflow_state: COURSE_STATES)
          .joins(:enrollments)
          .where(enrollments: { user_id: @student.id,
                                type: "StudentEnrollment",
                                workflow_state: ENROLLMENT_STATES })
          .distinct
          .order(:name)
          .to_a
  end

  def load_term_and_period
    @terms = student_terms.to_a
    @term = @terms.find { |t| t.id.to_s == params[:enrollment_term_id].to_s } ||
            @terms.max_by { |t| [t.start_at || Time.zone.at(0), t.id] }
    @periods = @term&.grading_period_group&.grading_periods&.active&.order(:start_date).to_a
    @grading_period = if params[:grading_period_id].present? && params[:grading_period_id] != "session"
                        @periods.find { |gp| gp.id.to_s == params[:grading_period_id].to_s }
                      elsif params[:grading_period_id] != "session"
                        @periods.find { |gp| gp.in_date_range?(Time.zone.now) }
                      end
    @sessional = @grading_period.nil?
  end

  def load_results
    @courses = student_courses(@term)
    @results_by_course = K12CourseResult.active
                                        .where(user_id: @student.id,
                                               course_id: @courses.map(&:id),
                                               grading_period_id: @grading_period&.id)
                                        .preload(:k12_result_set)
                                        .index_by(&:course_id)
    @session_result = @term && K12SessionResult.active.find_by(user_id: @student.id, enrollment_term_id: @term.id)
    @view_mode = majority_view_mode
    @can_manage = @courses.any? { |c| c.grants_right?(@current_user, session, :manage_grades) }
    @finalized = if @grading_period
                   @grading_period.closed?
                 else
                   @periods.present? && @periods.all?(&:closed?)
                 end
  end

  def majority_view_mode
    modes = @courses.map { |c| @config.view_for(c) }
    return "senior" if modes.empty?

    (modes.count("developmental") > modes.size / 2.0) ? "developmental" : "senior"
  end

  def normalized_traits
    permitted = params[:traits].permit(affective: {}, psychomotor: {}).to_h
    %w[affective psychomotor].index_with do |kind|
      (permitted[kind] || {}).each_with_object({}) do |(trait, rating), memo|
        rating = rating.to_i
        memo[trait.to_s] = rating.clamp(1, 5) if rating.positive?
      end
    end
  end

  def pdf_locals
    {
      student: @student,
      config: @config,
      term: @term,
      grading_period: @grading_period,
      periods: @periods,
      courses: @courses,
      results_by_course: @results_by_course,
      session_result: @session_result,
      view_mode: @view_mode,
      finalized: @finalized,
      root_account: @domain_root_account,
      affective_traits: AFFECTIVE_TRAITS,
      psychomotor_traits: PSYCHOMOTOR_TRAITS
    }
  end
end
