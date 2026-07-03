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

# Page Schools fork (Automatic K-12 Result): the teacher/admin side of the
# feature for one course — the computed result set per grading period
# (scores, ranks, median), per-student subject remarks, the KG–Y4 vs senior
# view toggle, and links to each student's report card. Thin controller:
# all computation lives in K12Results::*.
class K12ResultsController < ApplicationController
  before_action :require_context
  before_action :require_user
  before_action :require_automatic_k12_result
  before_action :check_authorized

  def show
    @config = K12Results.config_for(@context)
    @periods = GradingPeriod.for(@context).order(:start_date).to_a
    @grading_period = if params[:grading_period_id].present? && params[:grading_period_id] != "session"
                        @periods.find { |gp| gp.id.to_s == params[:grading_period_id].to_s }
                      elsif params[:grading_period_id] != "session"
                        @periods.find { |gp| gp.in_date_range?(Time.zone.now) }
                      end
    @result_set = K12ResultSet.find_by(course_id: @context.id, grading_period_id: @grading_period&.id)
    @results = if @result_set
                 @result_set.k12_course_results.active.preload(:user).sort_by { |r| [r.rank || Float::INFINITY, r.user_id] }
               else
                 []
               end
    @view_mode = @config.view_for(@context)
  end

  # Synchronous full rebuild (all periods + sessional + session rollup) so a
  # teacher never has to wait out the debounce window during review/demo.
  def recalculate
    K12Results.recalculate_course_now(@context)
    flash[:notice] = t("Results recalculated.")
    redirect_to course_k12_results_path(@context, grading_period_id: params[:grading_period_id].presence)
  end

  def update_view_mode
    mode = params[:view_mode].to_s
    return render_unauthorized_action unless K12Results::Config::VIEWS.include?(mode)

    @context.settings_frd[:k12_result_view] = mode
    @context.save!
    flash[:notice] = t("Report card view updated.")
    redirect_to course_k12_results_path(@context, grading_period_id: params[:grading_period_id].presence)
  end

  def update_remark
    student = api_find(User.active, params[:user_id])
    result = K12CourseResult.active.find_by!(user_id: student.id,
                                             course_id: @context.id,
                                             grading_period_id: params[:grading_period_id].presence)
    result.update!(remark: params[:remark].to_s.strip.presence)
    redirect_to course_k12_results_path(@context, grading_period_id: params[:grading_period_id].presence)
  end

  private

  def require_automatic_k12_result
    # applies_to: Account flags do not resolve on Course objects; the course's
    # account walks its ancestor chain, so enabling at the root account works.
    not_found unless @context.account&.feature_enabled?(:automatic_k12_result)
  end

  def check_authorized
    authorized_action(@context, @current_user, :manage_grades)
  end
end
