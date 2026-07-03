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

# Page Schools fork (Automatic K-12 Result): derived result rows for the
# termly/sessional report card. Stores no primary grades — scores stay in the
# native `scores` table (GradeCalculator); these tables only hold what Canvas
# does not compute: class rank, per-(course, period) median, the sessional
# rollup, and render-ready snapshots (mastery, CA/exam split, remarks).
# A NULL grading_period_id row is the sessional (whole enrollment term) row,
# mirroring how the `scores` table models course-level vs period scores.
class CreateK12Results < ActiveRecord::Migration[8.0]
  tag :predeploy

  def change
    create_table :k12_result_sets do |t|
      t.references :course, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :grading_period, foreign_key: { on_delete: :cascade }, index: false
      t.references :enrollment_term, null: false, foreign_key: true
      t.float :median
      t.float :mean
      t.integer :enrolled_count, default: 0, null: false
      t.integer :attempted_count, default: 0, null: false
      t.boolean :finalized, default: false, null: false
      t.timestamp :computed_at
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index %i[course_id grading_period_id],
              unique: true,
              where: "grading_period_id IS NOT NULL",
              name: "index_k12_result_sets_on_course_and_period"
      t.index :course_id,
              unique: true,
              where: "grading_period_id IS NULL",
              name: "index_k12_result_sets_on_course_sessional"
    end

    create_table :k12_course_results do |t|
      t.references :k12_result_set, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: true, index: false
      t.references :course, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :grading_period, foreign_key: { on_delete: :cascade }, index: false
      t.float :score
      t.float :final_score
      t.string :grade, limit: 255
      t.float :ca_score
      t.float :exam_score
      t.integer :rank
      t.jsonb :mastery
      t.text :remark
      t.string :workflow_state, default: "active", null: false, limit: 255
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index %i[user_id course_id grading_period_id],
              unique: true,
              where: "grading_period_id IS NOT NULL",
              name: "index_k12_course_results_on_user_course_period"
      t.index %i[user_id course_id],
              unique: true,
              where: "grading_period_id IS NULL",
              name: "index_k12_course_results_on_user_course_sessional"
    end

    create_table :k12_session_results do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :enrollment_term, null: false, foreign_key: true
      t.float :average
      t.float :median
      t.integer :rank
      t.integer :cohort_enrolled_count, default: 0, null: false
      t.integer :cohort_attempted_count, default: 0, null: false
      t.integer :courses_count, default: 0, null: false
      t.boolean :finalized, default: false, null: false
      t.jsonb :traits
      t.text :class_teacher_remark
      t.text :head_teacher_remark
      t.timestamp :computed_at
      t.string :workflow_state, default: "active", null: false, limit: 255
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index %i[user_id enrollment_term_id],
              unique: true,
              name: "index_k12_session_results_on_user_and_term"
    end
  end
end
