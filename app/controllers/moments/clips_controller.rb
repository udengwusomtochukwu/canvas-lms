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
  # Page Schools fork (Moments): human caption review (G4) — edit the draft
  # and/or approve it. Approval is the gate to compilation.
  class ClipsController < ApplicationController
    include MomentsFeature

    before_action :require_context
    before_action :require_user
    before_action :check_authorized
    before_action :load_clip

    def update_caption
      updates = { caption: params[:caption].to_s.strip }
      updates[:caption_status] = if Canvas::Plugin.value_to_boolean(params[:approve]) && updates[:caption].present?
                                   "approved"
                                 else
                                   "needs_review"
                                 end
      @clip.update!(updates)
      respond_to do |format|
        format.html { redirect_to course_moments_session_path(@context, @clip.session) }
        format.json { render json: { ok: true, caption_status: @clip.caption_status } }
      end
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
