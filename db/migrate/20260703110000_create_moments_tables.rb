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

# Page Schools fork (Moments): per-child, consent-gated classroom highlight
# reels. Canvas is the system of record for identity, consent, tags,
# captions and delivered reels; raw and intermediate media stay in the
# configurable sidecar's own storage (guardrail G5) — only approved reels
# and thumbnails become Canvas attachments.
class CreateMomentsTables < ActiveRecord::Migration[8.0]
  tag :predeploy

  def change
    create_table :moments_sessions do |t|
      t.references :course, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false, limit: 255
      t.date :captured_at, null: false
      t.integer :clip_seconds
      t.string :workflow_state, null: false, default: "created", limit: 255
      t.string :sidecar_ref, null: false, limit: 255, index: { unique: true }
      t.timestamp :retention_expires_at
      t.timestamp :raw_purged_at
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index [:course_id, :captured_at]
    end

    create_table :moments_clips do |t|
      t.references :moments_session, null: false, foreign_key: { on_delete: :cascade }
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.float :highlight_score
      t.references :thumbnail, foreign_key: { to_table: :attachments }
      t.text :keyframe_refs
      t.text :caption
      t.string :caption_status, null: false, default: "none", limit: 255
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index
    end

    create_table :moments_clip_tags do |t|
      t.references :moments_clip, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: true
      t.references :tagged_by, null: false, foreign_key: { to_table: :users }
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index [:moments_clip_id, :user_id], unique: true
    end

    create_table :moments_consents do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.boolean :opt_in, null: false, default: false
      t.references :consented_by, foreign_key: { to_table: :users }
      t.timestamp :consented_at
      t.text :note
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index
    end

    create_table :moments_reels do |t|
      t.references :moments_session, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: true
      t.references :attachment, foreign_key: true
      t.string :workflow_state, null: false, default: "compiling", limit: 255
      t.timestamp :delivered_at
      t.references :root_account, foreign_key: { to_table: :accounts }, index: false, null: false
      t.timestamps
      t.replica_identity_index

      t.index [:moments_session_id, :user_id], unique: true
      t.index [:user_id, :delivered_at]
    end
  end
end
