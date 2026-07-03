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

# Page Schools fork (Manual Exam Workflow): bookkeeping pointer from a
# submission to its current graded exam script. Stores no grades — scores,
# rubric assessments and outcome results live in their native tables. The
# row only makes re-uploads idempotent (replace, never duplicate).
class CreateManualExamScripts < ActiveRecord::Migration[8.0]
  tag :predeploy

  def change
    create_table :manual_exam_scripts do |t|
      t.references :submission, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :attachment, null: false, foreign_key: true
      t.references :submission_comment, foreign_key: { on_delete: :nullify }
      t.references :uploaded_by, null: false, foreign_key: { to_table: :users }
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index
    end
  end
end
