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

# Page Schools fork (Automatic K-12 Result): shared spec setup.
module K12ResultsSpecHelper
  # Account-level grading period set linked to the course's enrollment term
  # (the modern Canvas shape): an ended-but-still-open "First Term" (grading
  # in a CLOSED period is refused at the model level, so specs close it
  # explicitly when they need to) and a current "Second Term".
  # Returns [first_term, second_term].
  def create_k12_terms_for(course)
    account = course.root_account
    group = account.grading_period_groups.create!(title: "Session Periods")
    group.enrollment_terms << course.enrollment_term
    now = Time.zone.now
    first = group.grading_periods.create!(
      title: "First Term",
      start_date: 3.months.ago(now),
      end_date: 1.month.ago(now),
      close_date: 2.months.from_now(now)
    )
    second = group.grading_periods.create!(
      title: "Second Term",
      start_date: 1.month.ago(now) + 1.minute,
      end_date: 1.month.from_now(now),
      close_date: 2.months.from_now(now)
    )
    [first, second]
  end

  def k12_assignment(course, group_name, title:, due_at:, points: 100)
    group = course.assignment_groups.find_by(name: group_name) ||
            course.assignment_groups.create!(name: group_name)
    course.assignments.create!(title:,
                               points_possible: points,
                               due_at:,
                               assignment_group: group,
                               submission_types: "on_paper",
                               workflow_state: "published")
  end
end

RSpec.configure do |config|
  config.include K12ResultsSpecHelper
end
