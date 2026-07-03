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

describe Moments::CallbacksController do
  include_context "moments course"

  before :once do
    enable_moments!
    configure_moments_backend!
  end

  def post_callback(event, payload, signature: nil)
    body = payload.to_json
    request.headers["Content-Type"] = "application/json"
    request.headers[MomentsBackend::SIGNATURE_HEADER] = signature || MomentsBackend.sign(body)
    post :receive, params: { event: }, body:
  end

  def segmented_payload
    {
      session_ref: @session.sidecar_ref,
      clips: [
        { start_ms: 0, end_ms: 30_000, highlight_score: 0.8, keyframe_refs: ["frames/000-0.jpg"] },
        { start_ms: 60_000, end_ms: 90_000, highlight_score: 0.6, keyframe_refs: [] }
      ]
    }
  end

  it "rejects a bad signature" do
    post_callback("segmented", segmented_payload, signature: "forged")
    assert_status(401)
  end

  it "rejects an unknown session ref" do
    post_callback("segmented", segmented_payload.merge(session_ref: "nope"))
    assert_status(404)
  end

  it "creates identity-blind clips from a segmented callback" do
    post_callback("segmented", segmented_payload)
    expect(response).to be_successful

    @session.reload
    expect(@session.workflow_state).to eq "segmented"
    # replaces the pre-existing fixture clip: re-segmentation is idempotent
    expect(@session.clips.count).to eq 2
    clip = @session.clips.order(:start_ms).first
    expect(clip.highlight_score).to eq 0.8
    expect(clip.keyframe_refs).to eq ["frames/000-0.jpg"]
    expect(clip.clip_tags).to be_empty
  end

  it "is idempotent: a repeated callback replaces, never duplicates" do
    post_callback("segmented", segmented_payload)
    post_callback("segmented", segmented_payload)
    expect(@session.reload.clips.count).to eq 2
  end

  it "marks the session failed on an error callback" do
    post_callback("error", { session_ref: @session.sidecar_ref, message: "ffmpeg exploded" })
    expect(@session.reload.workflow_state).to eq "failed"
  end

  it "stores caption drafts as needs_review — never auto-approved (G4)" do
    post_callback("captions", { session_ref: @session.sidecar_ref,
                                captions: [{ clip_id: @clip.id, caption: "A student stacks blocks." }] })
    expect(response).to be_successful
    expect(@clip.reload.caption).to eq "A student stacks blocks."
    expect(@clip.caption_status).to eq "needs_review"
  end

  it "routes blank caption drafts (no AI key) to needs_review for manual writing" do
    post_callback("captions", { session_ref: @session.sidecar_ref,
                                captions: [{ clip_id: @clip.id, caption: "" }] })
    expect(@clip.reload.caption_status).to eq "needs_review"
  end

  it "fetches compiled reels into attachments and readies them" do
    reel = @session.reels.create!(user: @student)
    file = Tempfile.new(["reel", ".mp4"])
    file.write("fake mp4 bytes")
    file.rewind
    expect(MomentsBackend).to receive(:fetch_media).with("canvas/sessions/x/reels/#{reel.id}.mp4").and_return(file)

    post_callback("compiled", { session_ref: @session.sidecar_ref,
                                reels: [{ reel_ref: reel.id, media_ref: "canvas/sessions/x/reels/#{reel.id}.mp4" }] })
    expect(response).to be_successful
    run_jobs

    reel.reload
    expect(reel.workflow_state).to eq "ready"
    expect(reel.attachment).not_to be_nil
    # the reel itself is the file's context, so file access follows the
    # reel policy (G6) instead of course-files visibility
    expect(reel.attachment.context).to eq reel
  end

  it "404s when the flag is off (callbacks are feature-gated too)" do
    @course.root_account.disable_feature!(:moments_native)
    post_callback("segmented", segmented_payload)
    assert_status(404)
  end
end
