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
  # Page Schools fork (Moments): teacher session management for one course.
  # Raw video goes browser → backend storage via a presigned URL (never
  # through or into Canvas — guardrail G5); this controller only moves
  # metadata and drives the state machine.
  class SessionsController < ApplicationController
    include MomentsFeature

    before_action :require_context
    before_action :require_user
    before_action :check_authorized
    before_action :load_session, except: [:index, :create]

    def index
      @sessions = course_sessions.order(captured_at: :desc, id: :desc)
    end

    def show
      @clips = @session.clips.preload(:thumbnail, clip_tags: :user).order(:start_ms)
      @students = @context.participating_students.order(:sortable_name).distinct
      @consented_ids = Moments::Consent.where(user_id: @students.map(&:id), opt_in: true).pluck(:user_id).to_set
    end

    def create
      session = course_sessions.build(
        title: params[:title],
        captured_at: params[:captured_at].presence,
        clip_seconds: params[:clip_seconds].presence,
        created_by: @current_user
      )
      unless session.save
        flash[:error] = session.errors.full_messages.to_sentence
        return redirect_to course_moments_sessions_path(@context)
      end

      presign = MomentsBackend.presign_upload(session:, content_type: params[:content_type].presence || "video/mp4")
      render json: {
        session_id: session.id,
        upload_url: presign["upload_url"],
        show_url: course_moments_session_path(@context, session)
      }
    rescue MomentsBackend::Error => e
      session&.destroy
      render json: { error: e.message }, status: :bad_gateway
    end

    # Browser finished the presigned upload: verify + enqueue segmentation.
    def ingest
      MomentsBackend.segment!(
        session: @session,
        callback_url: moments_callback_url(event: "segmented", host: request.host_with_port, protocol: request.scheme)
      )
      @session.update!(workflow_state: "processing")
      render json: { ok: true, status: @session.workflow_state }
    rescue MomentsBackend::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    def progress
      render json: MomentsBackend.progress(@session)
    rescue MomentsBackend::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    private

    def check_authorized
      authorized_action(@context, @current_user, :manage_grades)
    end

    def course_sessions
      Moments::Session.where(course: @context)
    end

    def load_session
      @session = course_sessions.find(params[:session_id] || params[:id])
    end
  end
end
