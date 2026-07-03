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

module Moments
  # Page Schools fork (Moments): per-student opt-in management (G3).
  class ConsentsController < ApplicationController
    include MomentsFeature

    before_action :require_context
    before_action :require_user
    before_action :check_authorized

    def index
      @students = @context.participating_students.order(:sortable_name).distinct
      @consents = Moments::Consent.where(user_id: @students.map(&:id)).preload(:consented_by).index_by(&:user_id)
    end

    def update
      student = @context.participating_students.where(id: params[:user_id]).first
      return render json: { error: t("That student is not in this course.") }, status: :not_found unless student

      Moments::Consent.record!(
        student:,
        opt_in: Canvas::Plugin.value_to_boolean(params[:opt_in]),
        by: @current_user,
        root_account: @context.root_account,
        note: params[:note].presence
      )
      respond_to do |format|
        format.html { redirect_to course_moments_consents_path(@context) }
        format.json { render json: { ok: true, opt_in: Moments::Consent.opted_in?(student.id) } }
      end
    end

    private

    def check_authorized
      authorized_action(@context, @current_user, :manage_grades)
    end
  end
end
