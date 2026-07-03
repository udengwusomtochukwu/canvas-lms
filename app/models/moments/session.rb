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
  # Page Schools fork (Moments): one uploaded/recorded classroom video.
  # Raw media lives in the sidecar's storage (guardrail G5) — this row only
  # tracks metadata and the processing state machine.
  class Session < ApplicationRecord
    self.table_name = "moments_sessions"

    include Workflow

    belongs_to :course
    belongs_to :created_by, class_name: "User"
    belongs_to :root_account, class_name: "Account"
    has_many :clips, class_name: "Moments::Clip", foreign_key: :moments_session_id, inverse_of: :session, dependent: :destroy
    has_many :reels, class_name: "Moments::Reel", foreign_key: :moments_session_id, inverse_of: :session, dependent: :destroy

    validates :title, presence: true, length: { maximum: 255 }
    validates :captured_at, presence: true
    validates :clip_seconds, numericality: { in: 5..120 }, allow_nil: true

    before_validation :set_defaults, on: :create

    workflow do
      state :created
      state :uploaded
      state :processing
      state :segmented
      state :tagging
      state :captioning
      state :compiling
      state :delivered
      state :failed
    end

    set_policy do
      given { |user| course.grants_right?(user, :manage_grades) }
      can :read and can :manage
    end

    private

    def set_defaults
      self.captured_at ||= Time.zone.today
      self.sidecar_ref ||= CanvasSlug.generate_securish_uuid
      self.root_account_id ||= course&.root_account_id
    end
  end
end
