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
  # Page Schools fork (Moments): inbound callbacks from the media backend.
  # Authenticated by HMAC of the raw body with the plugin's shared secret —
  # no session, no cookies. Payloads reference sessions by opaque
  # sidecar_ref only; they never contain student identity (G1/G2).
  class CallbacksController < ApplicationController
    include MomentsFeature

    skip_before_action :verify_authenticity_token
    skip_before_action :load_user

    before_action :verify_signature
    before_action :load_session_from_ref

    def receive
      case params[:event]
      when "segmented" then handle_segmented
      when "captions" then handle_captions
      when "compiled" then handle_compiled
      when "progress" then head :ok
      when "error" then handle_error
      else
        render json: { error: "unknown event" }, status: :bad_request
      end
    end

    private

    def require_moments_native
      not_found unless @domain_root_account&.feature_enabled?(:moments_native)
    end

    def verify_signature
      signature = request.headers[MomentsBackend::SIGNATURE_HEADER]
      return if MomentsBackend.valid_signature?(request.raw_post, signature)

      render json: { error: "invalid signature" }, status: :unauthorized
    end

    def load_session_from_ref
      return if performed?

      @session = Moments::Session.find_by(sidecar_ref: payload["session_ref"])
      render json: { error: "unknown session" }, status: :not_found unless @session
    end

    def payload
      @payload ||= JSON.parse(request.raw_post)
    rescue JSON::ParserError
      {}
    end

    # Identity-blind clip metadata: offsets, scores, transient media refs.
    # Thumbnails are pulled into Canvas attachments asynchronously.
    def handle_segmented
      clips = Array(payload["clips"])
      Moments::Session.transaction do
        @session.clips.destroy_all # idempotent re-segmentation
        clips.each do |clip|
          @session.clips.create!(
            start_ms: clip["start_ms"],
            end_ms: clip["end_ms"],
            highlight_score: clip["highlight_score"],
            keyframe_refs: Array(clip["keyframe_refs"]),
            clip_ref: clip["clip_ref"],
            thumbnail_ref: clip["thumbnail_ref"],
            caption_status: "none"
          )
        end
        @session.update!(workflow_state: "segmented", retention_expires_at: payload["retention_expires_at"])
      end
      render json: { ok: true, clip_count: @session.clips.count }
    end

    # Caption drafts (G4): blank drafts (no API key on the backend) still go
    # to needs_review so a human writes them — never auto-approved.
    def handle_captions
      Array(payload["captions"]).each do |draft|
        clip = @session.clips.find_by(id: draft["clip_id"])
        next unless clip

        clip.update!(caption: draft["caption"].to_s, caption_status: "needs_review")
      end
      @session.update!(workflow_state: "captioning") if @session.tagging? || @session.segmented?
      render json: { ok: true }
    end

    # Compiled reels: pull each mp4 out of the backend into a native
    # Attachment asynchronously; the reel flips to "ready" when fetched.
    def handle_compiled
      Array(payload["reels"]).each do |entry|
        reel = @session.reels.find_by(id: entry["reel_ref"])
        next unless reel

        reel.delay(n_strand: ["moments_reel_fetch", reel.root_account_id])
            .fetch_media_from_backend!(entry["media_ref"].to_s)
      end
      render json: { ok: true }
    end

    def handle_error
      @session.update!(workflow_state: "failed")
      Canvas::Errors.capture_exception(:moments_backend, RuntimeError.new(payload["message"].to_s.presence || "moments backend error"))
      render json: { ok: true }
    end
  end
end
