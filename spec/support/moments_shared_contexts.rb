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

# Page Schools fork (Moments)
RSpec.shared_context "moments course" do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user

    @observer = user_factory(active_all: true)
    @course.enroll_user(@observer, "ObserverEnrollment", enrollment_state: "active").update!(associated_user_id: @student.id)

    @session = Moments::Session.create!(course: @course, created_by: @teacher, title: "Sports Day", captured_at: Time.zone.today)
    @clip = @session.clips.create!(start_ms: 0, end_ms: 30_000, highlight_score: 0.9)
  end

  def enable_moments!
    @course.root_account.enable_feature!(:moments_native)
  end

  def consent!(student, opt_in: true)
    Moments::Consent.record!(student:, opt_in:, by: @teacher, root_account: @course.root_account)
  end

  def configure_moments_backend!(base_url: "http://worker.test", shared_secret: "sekrit-sekrit")
    PluginSetting.create!(name: "moments_backend", settings: { base_url:, shared_secret: })
  end
end
