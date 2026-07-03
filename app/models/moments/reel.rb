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
  # Page Schools fork (Moments): one compiled per-child reel. The mp4 is a
  # native Attachment. Visibility mirrors the submission observer policy:
  # the student sees their own DELIVERED reels, linked observers see their
  # child's, course teaching staff see the course's (guardrail G6).
  class Reel < ApplicationRecord
    self.table_name = "moments_reels"

    include Workflow

    belongs_to :session, class_name: "Moments::Session", foreign_key: :moments_session_id, inverse_of: :reels
    belongs_to :user
    belongs_to :attachment, optional: true
    belongs_to :root_account, class_name: "Account"
    # The reel mp4 is attached with THIS record as its context, so file
    # access falls through to this model's read policy (G6) — course-context
    # files would be listable by every course member in Files.
    has_many :attachments, as: :context, inverse_of: :context, dependent: :destroy

    validates :user_id, uniqueness: { scope: :moments_session_id }

    before_validation :set_root_account

    workflow do
      state :compiling
      state :ready
      state :delivered
    end

    scope :delivered, -> { where(workflow_state: "delivered") }

    set_policy do
      given { |viewer| session.course.grants_right?(viewer, :manage_grades) }
      can :read and can :manage

      given { |viewer| delivered? && viewer.present? && viewer.id == user_id }
      can :read

      given do |viewer|
        delivered? && viewer.present? &&
          session.course.observer_enrollments.active
                 .where(user_id: viewer, associated_user_id: user_id)
                 .exists?
      end
      can :read
    end

    # Pull the compiled mp4 from the media backend into a native Attachment.
    # Runs as a delayed job from the "compiled" callback.
    def fetch_media_from_backend!(media_ref)
      file = MomentsBackend.fetch_media(media_ref)
      attachment = nil
      begin
        attachment = FileInContext.attach(
          self,
          file.path,
          display_name: "#{session.title} — moment reel.mp4"
        )
      ensure
        file.close!
      end
      update!(attachment:, workflow_state: "ready")
    end

    # Delivery gate: re-checks consent at the moment of delivery (G3 defence
    # in depth) — a child whose consent was revoked after tagging is skipped.
    # Returns whether the reel was delivered.
    def deliver! # rubocop:disable Naming/PredicateMethod
      return false unless ready?
      return false unless Moments::Consent.opted_in?(user_id)

      update!(workflow_state: "delivered", delivered_at: Time.zone.now)
      true
    end

    private

    def set_root_account
      self.root_account_id ||= session&.root_account_id
    end
  end
end
