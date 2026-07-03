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

# Page Schools fork (Automatic K-12 Result): one student's derived result for
# a (course, grading period) — or the whole session when grading_period is
# nil. `score`/`final_score`/`grade` are copied from the same posted Score row
# the gradebook shows (never re-derived); rank, CA/exam split and the mastery
# snapshot are computed set-wide by K12Results::CourseRecalculator. Rows are
# upserted against the partial unique indexes, so recomputes never duplicate.
class K12CourseResult < ApplicationRecord
  belongs_to :k12_result_set
  belongs_to :user
  belongs_to :course
  belongs_to :grading_period, optional: true
  belongs_to :root_account, class_name: "Account"

  scope :active, -> { where(workflow_state: "active") }
  scope :termly, -> { where.not(grading_period_id: nil) }
  scope :sessional, -> { where(grading_period_id: nil) }

  def sessional?
    grading_period_id.nil?
  end

  # Strand mastery snapshot: [{ "outcome_id", "title", "strand", "score",
  # "points_possible", "mastery_points", "rating", "color", "mastery" }, ...]
  def mastery_entries
    Array(mastery)
  end
end
