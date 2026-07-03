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
  # Page Schools fork (Moments): per-student opt-in (guardrail G3). Default
  # is NOT consented; tagging is blocked and compiles drop the student
  # unless an explicit opt-in record exists.
  class Consent < ApplicationRecord
    self.table_name = "moments_consents"

    belongs_to :user
    belongs_to :consented_by, class_name: "User", optional: true
    belongs_to :root_account, class_name: "Account"

    validates :user_id, uniqueness: true

    def self.opted_in?(user_id)
      where(user_id:, opt_in: true).exists?
    end

    def self.record!(student:, opt_in:, by:, root_account:, note: nil)
      consent = find_or_initialize_by(user_id: student.id)
      consent.root_account = root_account if consent.root_account_id.nil?
      consent.update!(opt_in:, consented_by: by, consented_at: Time.zone.now, note:)
      consent
    end
  end
end
