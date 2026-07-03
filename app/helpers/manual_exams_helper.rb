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

# Page Schools fork (Manual Exam Workflow)
module ManualExamsHelper
  # The submission's graded exam script, if the flag is on, the script is a
  # PDF, and the viewer may read the comment it rides on (so hidden grades,
  # posting policies and observer linking all keep applying).
  def manual_exam_previewable_script(submission, user)
    return nil unless submission && user
    return nil unless submission.root_account&.feature_enabled?(:manual_exam_workflow)

    script = ManualExamScript.find_by(submission:)
    return nil unless script&.attachment&.mime_class == "pdf"
    return nil unless script.submission_comment&.grants_right?(user, :read)

    script
  end
end
