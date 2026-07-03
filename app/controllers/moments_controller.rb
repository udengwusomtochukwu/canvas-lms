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

# Page Schools fork (Moments): the global-nav landing page. One page,
# role-aware sections:
#   * teacher  — their courses with session counts + links to the boards
#   * student  — their own delivered reels as a day-grouped timeline
#   * observer — child picker (linked children only), then that child's timeline
class MomentsController < ApplicationController
  include MomentsFeature

  before_action :require_user

  def index
    @teacher_courses = @current_user.enrollments.of_instructor_type.active_by_date
                                    .preload(:course).map(&:course).uniq

    @observed_students = ObserverEnrollment.active_or_pending
                                           .where(user_id: @current_user)
                                           .where.not(associated_user_id: nil)
                                           .preload(:associated_user)
                                           .map(&:associated_user).uniq

    @timeline_student = timeline_student
    @reels = @timeline_student ? timeline_reels(@timeline_student) : Moments::Reel.none
    @reels_by_day = @reels.group_by { |reel| reel.session.captured_at }
  end

  private

  # The user whose timeline to show: the student themselves, or for
  # observers the selected linked child (never anyone else's).
  def timeline_student
    if @observed_students.any?
      requested = params[:student_id].presence
      @observed_students.detect { |student| student.id.to_s == requested } || @observed_students.first
    elsif @current_user.enrollments.active_by_date.where(type: "StudentEnrollment").exists?
      @current_user
    end
  end

  def timeline_reels(student)
    scope = Moments::Reel.delivered.where(user_id: student.id)
                         .preload(:attachment, session: :course)
                         .order(delivered_at: :desc)
    scope.select { |reel| reel.grants_right?(@current_user, :read) }
  end
end
