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

# Page Schools fork (Moments): opaque backend-storage refs for each clip's
# cut mp4 and thumbnail — needed to compile reels and fetch previews.
class AddMediaRefsToMomentsClips < ActiveRecord::Migration[8.0]
  tag :predeploy

  def change
    change_table :moments_clips, bulk: true do |t|
      t.string :clip_ref, limit: 255
      t.string :thumbnail_ref, limit: 255
    end
  end
end
