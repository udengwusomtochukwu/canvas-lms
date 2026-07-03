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

module K12Results
  # Page Schools fork (Automatic K-12 Result): rolls the sessional per-course
  # results (K12CourseResult rows with grading_period_id nil, whose scores are
  # Canvas's own course-level Score rows — grading-period weights already
  # applied) up into one K12SessionResult per (student, enrollment term):
  # overall average across the student's subjects and overall class position.
  #
  # "Class" is not a Canvas concept, so the ranking cohort for a student is
  # the union of students sharing a course with them in the term. In this
  # deployment every subject course of a class arm has the same roster, so
  # the cohort IS the class arm; with heterogeneous rosters (electives) each
  # student is ranked within their own cohort and the counts say so.
  # Runs as one job per term (singleton), so positions are set-consistent.
  class SessionRecalculator < ApplicationService
    COURSE_STATES = %w[available completed].freeze

    Aggregate = Struct.new(:user_id,
                           :average,
                           :courses_count,
                           :rank,
                           :median,
                           :cohort_enrolled,
                           :cohort_attempted,
                           keyword_init: true)

    def initialize(enrollment_term:)
      super()
      @term = enrollment_term
    end

    def call
      @term.shard.activate do
        rows = K12CourseResult.active.sessional
                              .joins(:course)
                              .where(courses: { enrollment_term_id: @term.id, workflow_state: COURSE_STATES })
                              .pluck(:user_id, :course_id, :score)
        if rows.empty?
          K12SessionResult.where(enrollment_term_id: @term.id).delete_all
          return nil
        end

        persist(aggregate(rows))
      end
    end

    private

    def aggregate(rows)
      courses_by_user = Hash.new { |h, k| h[k] = [] }
      users_by_course = Hash.new { |h, k| h[k] = [] }
      scores_by_user = Hash.new { |h, k| h[k] = [] }

      rows.each do |user_id, course_id, score|
        courses_by_user[user_id] << course_id
        users_by_course[course_id] << user_id
        scores_by_user[user_id] << score if score
      end

      averages = courses_by_user.keys.index_with do |user_id|
        scores = scores_by_user[user_id]
        scores.empty? ? nil : (scores.sum / scores.size).round(2)
      end

      courses_by_user.map do |user_id, course_ids|
        cohort = course_ids.flat_map { |cid| users_by_course[cid] }.uniq
        cohort_averages = cohort.filter_map { |uid| averages[uid] }.sort
        mine = averages[user_id]
        Aggregate.new(
          user_id:,
          average: mine,
          courses_count: course_ids.size,
          rank: mine && (1 + cohort_averages.count { |a| a > mine }),
          median: median(cohort_averages),
          cohort_enrolled: cohort.size,
          cohort_attempted: cohort_averages.size
        )
      end
    end

    def persist(aggregates)
      now = Time.zone.now
      finalized = finalized?
      payload = aggregates.map do |agg|
        {
          user_id: agg.user_id,
          enrollment_term_id: @term.id,
          average: agg.average,
          median: agg.median,
          rank: agg.rank,
          cohort_enrolled_count: agg.cohort_enrolled,
          cohort_attempted_count: agg.cohort_attempted,
          courses_count: agg.courses_count,
          finalized:,
          computed_at: now,
          workflow_state: "active",
          root_account_id: @term.root_account_id,
          created_at: now,
          updated_at: now
        }
      end
      # traits and remarks are deliberately absent so upserts never clobber
      # the manually entered report-card staples.
      K12SessionResult.upsert_all(payload, unique_by: "index_k12_session_results_on_user_and_term")

      K12SessionResult.where(enrollment_term_id: @term.id)
                      .where.not(user_id: aggregates.map(&:user_id))
                      .delete_all
    end

    def finalized?
      periods = @term.grading_period_group&.grading_periods&.active&.to_a
      periods.present? && periods.all?(&:closed?)
    end

    def median(sorted)
      return nil if sorted.empty?

      mid, remainder = sorted.size.divmod(2)
      value = remainder.zero? ? ((sorted[mid - 1] + sorted[mid]) / 2.0) : sorted[mid]
      value.round(2)
    end
  end
end
