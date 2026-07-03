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

# Page Schools fork (Automatic K-12 Result): set-level statistics for one
# (course, grading period) — or the whole session when grading_period is nil.
# Holds what Canvas doesn't compute at this granularity (median, population
# counts) and anchors the result rows ranked together in one recompute pass.
class K12ResultSet < ApplicationRecord
  belongs_to :course
  belongs_to :grading_period, optional: true
  belongs_to :enrollment_term
  belongs_to :root_account, class_name: "Account"
  has_many :k12_course_results, dependent: :delete_all

  scope :termly, -> { where.not(grading_period_id: nil) }
  scope :sessional, -> { where(grading_period_id: nil) }

  def sessional?
    grading_period_id.nil?
  end
end
