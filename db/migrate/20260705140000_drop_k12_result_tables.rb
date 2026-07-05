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

# Page Schools fork (Phase 10 un-fork): drop the Automatic K-12 Result tables.
# The feature and its engine have been removed; these derived report-card
# tables held no data Canvas needs (primary grades always lived in `scores`).
# Dropped children-first: k12_course_results and k12_session_results reference
# k12_result_sets, so the parent goes last.
class DropK12ResultTables < ActiveRecord::Migration[8.0]
  tag :postdeploy

  def up
    drop_table :k12_course_results, if_exists: true
    drop_table :k12_session_results, if_exists: true
    drop_table :k12_result_sets, if_exists: true
  end
end
