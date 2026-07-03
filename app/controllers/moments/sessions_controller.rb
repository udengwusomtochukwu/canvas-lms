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
      MomentsBackend.segment!(session: @session, callback_url: callback_url_for("segmented"))
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

    # Draft captions for tagged clips that aren't approved yet (G4: drafts
    # always land in needs_review; a human approves before anything ships).
    def draft_captions
      clips = @session.clips.joins(:clip_tags).where.not(caption_status: "approved").distinct
      if clips.none?
        return redirect_back_with(t("Tag students on at least one clip first."))
      end

      MomentsBackend.captions!(
        session: @session,
        clips: clips.map { |c| { clip_id: c.id, keyframe_refs: c.keyframe_refs } },
        callback_url: callback_url_for("captions")
      )
      redirect_back_with(t("Drafting captions — refresh in a moment."))
    rescue MomentsBackend::Error => e
      redirect_back_with(e.message, error: true)
    end

    # Compile per-child reels from approved, tagged clips. Consent is
    # re-checked here (G3): revoked children are silently dropped.
    def compile
      clips = @session.clips.where(caption_status: "approved").where.not(clip_ref: nil)
                      .preload(:clip_tags).order(:start_ms)
      by_student = Hash.new { |h, k| h[k] = [] }
      clips.each do |clip|
        clip.clip_tags.each do |tag|
          by_student[tag.user_id] << clip.clip_ref if Moments::Consent.opted_in?(tag.user_id)
        end
      end
      if by_student.empty?
        return redirect_back_with(t("Nothing to compile — approve captions on tagged clips first."))
      end

      reels = by_student.map do |student_id, clip_refs|
        reel = @session.reels.find_or_create_by!(user_id: student_id)
        reel.update!(workflow_state: "compiling", attachment_id: nil) unless reel.compiling?
        { reel_ref: reel.id, clip_refs: }
      end
      MomentsBackend.compile!(session: @session, reels:, callback_url: callback_url_for("compiled"))
      @session.update!(workflow_state: "compiling")
      redirect_back_with(t("Compiling %{count} reels — refresh in a moment.", count: reels.length))
    rescue MomentsBackend::Error => e
      redirect_back_with(e.message, error: true)
    end

    # Deliver ready reels to students/parents (visibility flips here and
    # only here; Reel#deliver! re-checks consent per child).
    def deliver
      delivered = @session.reels.where(workflow_state: "ready").count(&:deliver!)
      @session.update!(workflow_state: "delivered") if delivered.positive?
      redirect_back_with(t("Delivered %{count} reels.", count: delivered))
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

    def callback_url_for(event)
      if (base = MomentsBackend.callback_base_url)
        "#{base}/moments/callbacks/#{event}"
      else
        moments_callback_url(event:, host: request.host_with_port, protocol: request.scheme)
      end
    end

    def redirect_back_with(message, error: false)
      flash[error ? :error : :notice] = message
      redirect_to course_moments_session_path(@context, @session)
    end
  end
end
