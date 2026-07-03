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

# Page Schools fork (Automatic K-12 Result): one student's sessional rollup
# across all their courses in an enrollment term (the academic session) —
# overall average, overall class position, and the manually entered Nigerian
# report-card staples (affective/psychomotor traits, remarks). Computed by
# K12Results::SessionRecalculator; upserted per (user, enrollment_term).
class K12SessionResult < ApplicationRecord
  belongs_to :user
  belongs_to :enrollment_term
  belongs_to :root_account, class_name: "Account"

  scope :active, -> { where(workflow_state: "active") }

  # { "affective" => { "Punctuality" => 4, ... },
  #   "psychomotor" => { "Handwriting" => 3, ... } }
  def trait_ratings(kind)
    (traits || {}).fetch(kind.to_s, {})
  end
end
