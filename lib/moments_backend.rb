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

    def post(path, payload)
      body = payload.to_json
      response = CanvasHttp.post("#{base_url}#{path}",
                                 { "Content-Type" => "application/json", SIGNATURE_HEADER => sign(body) },
                                 body:)
      parse(response)
    end

    def get(path)
      response = CanvasHttp.get("#{base_url}#{path}", { SIGNATURE_HEADER => sign("") })
      parse(response)
    end

    private

    def parse(response)
      raise Error, "moments backend returned #{response.code}" unless response.code.to_i == 200

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "moments backend returned invalid JSON"
    end
  end
end
