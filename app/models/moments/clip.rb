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
  # Page Schools fork (Moments): one identity-blind highlight segment.
  # Scored by signal heuristics only (guardrail G1); identity attaches
  # exclusively through human ClipTags (G2).
  class Clip < ApplicationRecord
    self.table_name = "moments_clips"

    CAPTION_STATUSES = %w[none draft needs_review approved].freeze

    belongs_to :session, class_name: "Moments::Session", foreign_key: :moments_session_id, inverse_of: :clips
    belongs_to :thumbnail, class_name: "Attachment", optional: true
    belongs_to :root_account, class_name: "Account"
    has_many :clip_tags, class_name: "Moments::ClipTag", foreign_key: :moments_clip_id, inverse_of: :clip, dependent: :destroy
    has_many :tagged_students, through: :clip_tags, source: :user

    serialize :keyframe_refs, type: Array, yaml: { permitted_classes: [String] }

    validates :start_ms, :end_ms, presence: true
    validates :caption_status, inclusion: { in: CAPTION_STATUSES }

    before_validation :set_root_account

    private

    def set_root_account
      self.root_account_id ||= session&.root_account_id
    end
  end
end
