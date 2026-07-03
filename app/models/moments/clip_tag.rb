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
  # Page Schools fork (Moments): a human tagging one student in one clip —
  # the ONLY place identity enters the system (guardrail G2). Server-side
  # validations enforce consent (G3) and course membership, mirroring the
  # original enforceConsent hook: these are model rules, not UI convenience.
  class ClipTag < ApplicationRecord
    self.table_name = "moments_clip_tags"

    belongs_to :clip, class_name: "Moments::Clip", foreign_key: :moments_clip_id, inverse_of: :clip_tags
    belongs_to :user
    belongs_to :tagged_by, class_name: "User"
    belongs_to :root_account, class_name: "Account"

    validates :user_id, uniqueness: { scope: :moments_clip_id }
    validate :student_enrolled_in_course
    validate :student_has_consented

    before_validation :set_root_account

    private

    def course
      clip&.session&.course
    end

    def student_enrolled_in_course
      return if course&.participating_students&.where(id: user_id)&.exists?

      errors.add(:user, "is not an active student in this course")
    end

    def student_has_consented
      return if Moments::Consent.opted_in?(user_id)

      errors.add(:user, "has not opted in to Moments — consent is required before tagging")
    end

    def set_root_account
      self.root_account_id ||= clip&.root_account_id
    end
  end
end
