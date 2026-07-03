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

# Page Schools fork (Manual Exam Workflow, phase 2): links a permanently
# unpublished source quiz (authoring artifact) to its companion on_paper
# assignment (the graded exam instance), and records the question-content
# fingerprint captured at print time so edits after printing can be
# surfaced truthfully.
class CreatePaperExams < ActiveRecord::Migration[8.0]
  tag :predeploy

  def change
    create_table :paper_exams do |t|
      t.references :quiz, null: false, foreign_key: { to_table: :quizzes }, index: { unique: true }
      t.references :assignment, null: false, foreign_key: true, index: { unique: true }
      t.string :printed_fingerprint, limit: 255
      t.timestamp :printed_at
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index
    end
  end
end
