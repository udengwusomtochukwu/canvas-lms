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

# Page Schools fork (Phase 10 un-fork): drop the Moments tables. The feature
# and its media sidecar have been removed. Dropped in FK-safe order: reels,
# consents, clip_tags and clips all reference moments_sessions, and clip_tags
# references clips, so sessions goes last and clip_tags before clips.
class DropMomentsNativeTables < ActiveRecord::Migration[8.0]
  tag :postdeploy

  def up
    drop_table :moments_reels, if_exists: true
    drop_table :moments_consents, if_exists: true
    drop_table :moments_clip_tags, if_exists: true
    drop_table :moments_clips, if_exists: true
    drop_table :moments_sessions, if_exists: true
  end
end
