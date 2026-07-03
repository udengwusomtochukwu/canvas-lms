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

# Page Schools fork (Manual Exam Workflow): points a submission at its
# current graded exam script (an Attachment surfaced through a normal
# submission comment). Holds no grading data — it exists so a re-upload
# replaces the previous script instead of stacking a new comment each time.
class ManualExamScript < ApplicationRecord
  belongs_to :submission
  belongs_to :attachment
  belongs_to :submission_comment, optional: true
  belongs_to :uploaded_by, class_name: "User"
  belongs_to :root_account, class_name: "Account"

  validates :submission_id, uniqueness: true

  before_validation :set_root_account

  private

  def set_root_account
    self.root_account_id ||= submission&.root_account_id
  end
end
