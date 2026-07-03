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
  # Page Schools fork (Moments): human tagging — the only door identity
  # walks through (G2). Consent and course membership are enforced by the
  # ClipTag model, not here (G3 is a model rule).
  class ClipTagsController < ApplicationController
    include MomentsFeature

    before_action :require_context
    before_action :require_user
    before_action :check_authorized
    before_action :load_clip

    def create
      tag = @clip.clip_tags.build(user_id: params[:user_id], tagged_by: @current_user)
      if tag.save
        @clip.session.update!(workflow_state: "tagging") if @clip.session.segmented?
        render json: { ok: true, tagged_user_ids: @clip.clip_tags.pluck(:user_id) }
      else
        render json: { error: tag.errors.full_messages.to_sentence }, status: :forbidden
      end
    end

    def destroy
      @clip.clip_tags.where(user_id: params[:user_id]).destroy_all
      render json: { ok: true, tagged_user_ids: @clip.clip_tags.pluck(:user_id) }
    end

    private

    def check_authorized
      authorized_action(@context, @current_user, :manage_grades)
    end

    def load_clip
      @clip = Moments::Clip.joins(:session)
                           .where(moments_sessions: { course_id: @context.id })
                           .find(params[:clip_id])
    end
  end
end
