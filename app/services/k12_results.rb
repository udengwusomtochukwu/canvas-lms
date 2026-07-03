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

# Page Schools fork (Automatic K-12 Result): entry points for the result
# engine. Everything here is a no-op unless the account feature flag is on.
#
# Recomputes are coalesced exactly like ScoreStatisticsGenerator: one
# singleton job per (course, grading period) with on_conflict: :loose and a
# randomized run_at, so a burst of grading collapses into a single set-level
# pass. Ranking is therefore always computed over the whole population in one
# job — never incrementally per submission — which makes it race-free under
# concurrent grading.
module K12Results
  class << self
    def enabled?(course)
      course.root_account.feature_enabled?(:automatic_k12_result)
    end

    def config_for(context)
      Config.for(context)
    end

    # Queue the (course, grading period) result recompute. grading_period nil
    # means the sessional (whole enrollment term) pass for that course, which
    # also refreshes the cross-course session rollup afterwards.
    def recalculate_later(course:, grading_period: nil)
      return unless enabled?(course)

      grading_period_id = grading_period.is_a?(GradingPeriod) ? grading_period.id : grading_period
      delay_if_production(singleton: "K12Results:recalculate:#{course.global_id}:#{grading_period_id || "session"}",
                          n_strand: ["K12Results", course.global_root_account_id],
                          run_at: rand(10..60).seconds.from_now,
                          on_conflict: :loose,
                          max_attempts: 3)
        .recalculate(course.id, grading_period_id)
    end

    def recalculate(course_id, grading_period_id = nil)
      course = Course.active.find_by(id: course_id)
      return unless course && enabled?(course)

      grading_period = grading_period_id && GradingPeriod.for(course).find_by(id: grading_period_id)
      return if grading_period_id && grading_period.nil? # period deleted/re-linked since enqueue

      CourseRecalculator.call(course:, grading_period:)
      recalculate_session_later(course) if grading_period.nil?
    end

    def recalculate_session_later(course)
      term = course.enrollment_term
      return unless term && enabled?(course)

      delay_if_production(singleton: "K12Results:session:#{term.global_id}",
                          n_strand: ["K12Results", course.global_root_account_id],
                          run_at: rand(30..90).seconds.from_now,
                          on_conflict: :loose,
                          max_attempts: 3)
        .recalculate_session(term.id)
    end

    def recalculate_session(enrollment_term_id)
      term = EnrollmentTerm.active.find_by(id: enrollment_term_id)
      return unless term&.root_account&.feature_enabled?(:automatic_k12_result)

      SessionRecalculator.call(enrollment_term: term)
    end

    # Synchronous full build for one course (all periods + sessional + the
    # session rollup) — used by specs and the seeded walkthrough/backfill.
    def recalculate_course_now(course)
      return unless enabled?(course)

      GradingPeriod.for(course).each do |gp|
        CourseRecalculator.call(course:, grading_period: gp)
      end
      CourseRecalculator.call(course:, grading_period: nil)
      recalculate_session(course.enrollment_term_id)
    end
  end
end
