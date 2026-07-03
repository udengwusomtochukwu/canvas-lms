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

# Page Schools fork (Moments): client for the configurable media backend
# (Admin > Plugins > Moments Backend). The backend is identity-blind by
# contract: it only ever sees opaque refs, media, and timings — never
# names, never which child is which (guardrails G1/G2).
#
# Requests both ways are authenticated with an HMAC-SHA256 of the raw body
# using the plugin's shared secret.
module MomentsBackend
  class Error < StandardError; end
  class NotConfigured < Error; end

  SIGNATURE_HEADER = "X-Moments-Signature"

  class << self
    def plugin_settings
      Canvas::Plugin.find("moments_backend")&.settings || {}
    end

    def base_url
      url = plugin_settings[:base_url].presence
      raise NotConfigured, "Moments backend base_url is not configured" unless url

      url.chomp("/")
    end

    def shared_secret
      # encrypted plugin settings decrypt into :shared_secret_dec; the plain
      # key holds a placeholder once saved
      secret = plugin_settings[:shared_secret_dec].presence || plugin_settings[:shared_secret].presence
      (secret == PluginSetting::DUMMY_STRING) ? nil : secret
    end

    # Base URL the BACKEND uses to reach Canvas for callbacks. Needed when
    # the backend runs in another docker network or another cloud, where the
    # request host ("localhost:3102") would point at the wrong machine.
    # Blank = fall back to the requesting host.
    def callback_base_url
      plugin_settings[:callback_base_url].presence&.chomp("/")
    end

    def sign(body)
      raise NotConfigured, "Moments backend shared secret is not configured" unless shared_secret

      OpenSSL::HMAC.hexdigest("SHA256", shared_secret, body)
    end

    def valid_signature?(body, signature)
      return false if shared_secret.blank? || signature.blank?

      ActiveSupport::SecurityUtils.secure_compare(sign(body), signature)
    end

    # Ask the backend for a browser-direct upload URL for a session's raw
    # video (raw media never transits or lands in Canvas storage — G5).
    def presign_upload(session:, content_type:)
      post("/v2/uploads/presign", { session_ref: session.sidecar_ref, content_type: })
    end

    # Verify the upload landed and enqueue identity-blind segmentation.
    def segment!(session:, callback_url:)
      post("/v2/jobs/segment", {
             session_ref: session.sidecar_ref,
             clip_seconds: session.clip_seconds,
             callback_url:
           })
    end

    def progress(session)
      get("/v2/progress/#{session.sidecar_ref}")
    end

    # Draft observable-actions-only captions for the given clips (G4).
    # clips: [{ clip_id:, keyframe_refs: [] }] — opaque ids only.
    def captions!(session:, clips:, callback_url:)
      post("/v2/jobs/captions", { session_ref: session.sidecar_ref, clips:, callback_url: })
    end

    # Compile per-child reels. reels: [{ reel_ref:, clip_refs: [] }] —
    # reel_ref is opaque to the backend (identity-blind, G1/G2).
    def compile!(session:, reels:, callback_url:)
      post("/v2/jobs/compile", { session_ref: session.sidecar_ref, reels:, callback_url: })
    end

    # Stream one backend object (reel mp4, thumbnail) into a local tempfile.
    def fetch_media(ref)
      uri = URI.parse("#{base_url}/v2/media?ref=#{CGI.escape(ref)}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 120

      req = Net::HTTP::Get.new(uri.request_uri)
      req[SIGNATURE_HEADER] = sign("")

      file = Tempfile.new(["moments-media", File.extname(ref)])
      file.binmode
      http.request(req) do |response|
        raise Error, "moments backend returned #{response.code} for media" unless response.code.to_i == 200

        response.read_body { |chunk| file.write(chunk) }
      end
      file.flush
      file.rewind
      file
    rescue Timeout::Error, SystemCallError, SocketError => e
      raise Error, "moments backend unreachable: #{e.message}"
    end

    # The backend URL is admin-configured (Admin > Plugins), not user input,
    # so we use Net::HTTP directly rather than CanvasHttp — whose SSRF
    # protections (rightly) refuse private addresses, which is exactly where
    # a compose-network sidecar lives. Canvadocs-style integrations do the same.
    def post(path, payload)
      body = payload.to_json
      request(Net::HTTP::Post, path, body:) do |req|
        req["Content-Type"] = "application/json"
        req[SIGNATURE_HEADER] = sign(body)
        req.body = body
      end
    end

    def get(path)
      request(Net::HTTP::Get, path) do |req|
        req[SIGNATURE_HEADER] = sign("")
      end
    end

    private

    def request(verb, path, body: nil)
      uri = URI.parse("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      req = verb.new(uri.request_uri)
      yield req if block_given?
      parse(http.request(req))
    rescue Timeout::Error, SystemCallError, SocketError => e
      raise Error, "moments backend unreachable: #{e.message}"
    end

    def parse(response)
      raise Error, "moments backend returned #{response.code}" unless response.code.to_i == 200

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "moments backend returned invalid JSON"
    end
  end
end
