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
  # Page Schools fork (Automatic K-12 Result): recomputes the whole result set
  # for one (course, grading period) — or the course's sessional set when
  # grading_period is nil — in a single pass:
  #
  #   * score/grade come from the SAME posted Score rows GradeCalculator
  #     maintains (period row or course_score row) — never re-derived,
  #   * CA/exam display split from posted, graded submissions in the period,
  #   * strand mastery snapshot through Outcomes::ResultAnalytics (the same
  #     rollup math as the Learning Mastery gradebook), student-visible
  #     semantics (muted/unposted excluded),
  #   * median + competition ranks ("1,2,2,4") over the whole population,
  #
  # then upserts one K12CourseResult per student (teacher remarks preserved)
  # and prunes rows for students no longer enrolled. Pure derivation + upsert
  # keyed on unique indexes ⇒ idempotent and duplicate-free by construction.
  class CourseRecalculator < ApplicationService
    # Students who count for ranking/median: real (not Test Student), current.
    ENROLLMENT_STATES = %w[active invited].freeze

    def initialize(course:, grading_period: nil)
      super()
      @course = course
      @grading_period = grading_period
      @config = Config.for(course)
    end

    def call
      @course.shard.activate do
        enrollments = population
        if enrollments.empty?
          prune_empty_set
          return nil
        end

        rows = build_rows(enrollments)
        persist(rows)
      end
    end

    private

    def population
      @course.all_real_student_enrollments
             .where(workflow_state: ENROLLMENT_STATES)
             .select(:id, :user_id)
             .uniq(&:user_id)
    end

    def score_by_user(enrollments)
      scores = Score.active.where(enrollment_id: enrollments.map(&:id))
      scores = if @grading_period
                 scores.where(grading_period_id: @grading_period.id)
               else
                 scores.where(course_score: true)
               end
      user_by_enrollment = enrollments.index_by(&:id).transform_values(&:user_id)
      scores.index_by { |s| user_by_enrollment[s.enrollment_id] }
    end

    # Displayed score: the posted current score (what the student's own grades
    # page shows), replaced by the teacher's override when the course allows
    # final grade override.
    def displayed_score(score_row)
      return nil unless score_row

      if @course.allow_final_grade_override? && score_row.override_score
        score_row.override_score
      else
        score_row.current_score
      end
    end

    # CA/exam split per user, from posted, graded, non-excused submissions on
    # published, counted assignments — scoped to the grading period via the
    # submissions.grading_period_id Canvas already maintains. Canvas has no
    # per-period per-assignment-group score, so this display extra is the one
    # thing derived from submissions; assignment groups matching the
    # configured exam pattern (default /exam/i) are the exam bucket, all
    # others are continuous assessment.
    def ca_exam_by_user(user_ids)
      scope = @course.submissions
                     .joins(assignment: :assignment_group)
                     .where(user_id: user_ids, workflow_state: "graded", excused: [nil, false])
                     .where.not(score: nil)
                     .where.not(posted_at: nil)
                     .where(assignments: { workflow_state: "published", omit_from_final_grade: false })
                     .where("assignments.points_possible > 0")
      scope = scope.where(grading_period_id: @grading_period.id) if @grading_period

      exam_regexp = @config.exam_group_regexp
      totals = Hash.new { |h, k| h[k] = { ca: [0.0, 0.0], exam: [0.0, 0.0] } }
      scope.pluck(:user_id, :score, "assignments.points_possible", "assignment_groups.name")
           .each do |user_id, score, possible, group_name|
             bucket = exam_regexp.match?(group_name.to_s) ? :exam : :ca
             totals[user_id][bucket][0] += score
             totals[user_id][bucket][1] += possible
      end

      totals.transform_values do |t|
        {
          ca: scale(t[:ca], @config.ca_weight),
          exam: scale(t[:exam], @config.exam_weight)
        }
      end
    end

    def scale(got_and_possible, weight)
      got, possible = got_and_possible
      return nil unless possible.positive?

      ((got / possible) * weight).round(1)
    end

    # Strand mastery snapshot per user via the native rollup engine.
    # find_outcome_results is called with user: nil, so muted/unposted results
    # are excluded — student-visible semantics for a student/observer-facing
    # document. Period scoping filters on the same timestamp the rollup engine
    # itself orders by (submitted_at, falling back to assessed_at).
    def mastery_by_user(users)
      return {} unless @config.show_mastery?

      links = ContentTag.learning_outcome_links.active
                        .where(context: @course)
                        .preload(:learning_outcome_content, :associated_asset)
      return {} if links.empty?

      outcomes = links.filter_map(&:learning_outcome_content).uniq
      strand_by_outcome_id = links.each_with_object({}) do |link, memo|
        group = link.associated_asset
        strand = (group.respond_to?(:learning_outcome_group_id) && group.learning_outcome_group_id) ? group.title : nil
        memo[link.content_id] ||= strand
      end

      results = Outcomes::ResultAnalytics.find_outcome_results(
        nil, users:, context: @course, outcomes:
      )
      if @grading_period
        results = results.where(
          "COALESCE(learning_outcome_results.submitted_at, learning_outcome_results.assessed_at) >= ? " \
          "AND COALESCE(learning_outcome_results.submitted_at, learning_outcome_results.assessed_at) <= ?",
          @grading_period.start_date,
          @grading_period.end_date
        )
      end

      rollups = Outcomes::ResultAnalytics.outcome_results_rollups(results:, users:, context: @course)
      proficiency = @course.resolved_outcome_proficiency

      rollups.each_with_object({}) do |rollup, memo|
        entries = rollup.scores.filter_map do |rollup_score|
          next if rollup_score.score.nil?

          outcome = rollup_score.outcome
          snapshot_entry(outcome, rollup_score.score, strand_by_outcome_id[outcome.id], proficiency)
        end
        memo[rollup.context.id] = entries if entries.any?
      end
    end

    def snapshot_entry(outcome, score, strand, proficiency)
      ratings, mastery_points, points_possible = mastery_scale(outcome, proficiency)
      rating = ratings.sort_by { |r| -(r[:points] || 0) }.find { |r| score >= (r[:points] || 0) } ||
               ratings.min_by { |r| r[:points] || 0 }
      {
        "outcome_id" => outcome.id,
        "title" => outcome.short_description,
        "strand" => strand,
        "score" => score.round(2),
        "points_possible" => points_possible,
        "mastery_points" => mastery_points,
        "rating" => rating&.[](:description),
        "color" => rating&.[](:color),
        "mastery" => mastery_points ? score >= mastery_points : nil
      }
    end

    def mastery_scale(outcome, proficiency)
      if proficiency
        [proficiency.ratings_hash, proficiency.mastery_points, proficiency.points_possible]
      else
        criterion = outcome.rubric_criterion || {}
        [Array(criterion[:ratings]), criterion[:mastery_points], criterion[:points_possible]]
      end
    end

    def build_rows(enrollments)
      user_ids = enrollments.map(&:user_id)
      users = User.where(id: user_ids).to_a
      scores = score_by_user(enrollments)
      ca_exam = ca_exam_by_user(user_ids)
      mastery = mastery_by_user(users)

      rows = user_ids.map do |user_id|
        score_row = scores[user_id]
        split = ca_exam[user_id] || {}
        value = displayed_score(score_row)
        {
          user_id:,
          score: value,
          final_score: score_row&.final_score,
          grade: @config.grade_for(@course, value),
          ca_score: split[:ca],
          exam_score: split[:exam],
          mastery: mastery[user_id],
          rank: nil
        }
      end

      assign_competition_ranks(rows)
      rows
    end

    # Standard competition ranking ("1,2,2,4") over students with a score;
    # unscored students keep rank nil (they are counted in enrolled_count but
    # cannot be ordered — the report card renders "—", never a silent bottom
    # place). Ranks are identical under both position modes; the modes differ
    # in the displayed denominator (enrolled vs attempted count).
    def assign_competition_ranks(rows)
      scored = rows.reject { |r| r[:score].nil? }.sort_by { |r| -r[:score] }
      previous_score = nil
      previous_rank = nil
      scored.each_with_index do |row, index|
        if row[:score] == previous_score
          row[:rank] = previous_rank
        else
          row[:rank] = index + 1
          previous_rank = row[:rank]
          previous_score = row[:score]
        end
      end
    end

    def persist(rows)
      scored = rows.filter_map { |r| r[:score] }.sort
      set = K12ResultSet.where(course_id: @course.id, grading_period_id: @grading_period&.id)
                        .first_or_initialize
      set.enrollment_term_id = @course.enrollment_term_id
      set.root_account_id = @course.root_account_id
      set.median = median(scored)
      set.mean = scored.empty? ? nil : (scored.sum / scored.size).round(2)
      set.enrolled_count = rows.size
      set.attempted_count = scored.size
      set.finalized = finalized?
      set.computed_at = Time.zone.now
      set.save!

      now = Time.zone.now
      payload = rows.map do |row|
        {
          k12_result_set_id: set.id,
          user_id: row[:user_id],
          course_id: @course.id,
          grading_period_id: @grading_period&.id,
          score: row[:score],
          final_score: row[:final_score],
          grade: row[:grade],
          ca_score: row[:ca_score],
          exam_score: row[:exam_score],
          rank: row[:rank],
          mastery: row[:mastery],
          workflow_state: "active",
          root_account_id: @course.root_account_id,
          created_at: now,
          updated_at: now
        }
      end
      unique_index = if @grading_period
                       "index_k12_course_results_on_user_course_period"
                     else
                       "index_k12_course_results_on_user_course_sessional"
                     end
      # Teacher remarks are deliberately absent from the payload so upserts
      # never clobber them.
      K12CourseResult.upsert_all(payload, unique_by: unique_index) if payload.any?

      set.k12_course_results.where.not(user_id: rows.pluck(:user_id)).delete_all
      set
    end

    def prune_empty_set
      K12ResultSet.where(course_id: @course.id, grading_period_id: @grading_period&.id).destroy_all
    end

    # percentile_cont(0.5) semantics: linear interpolation for even counts,
    # matching ScoreStatisticsGenerator's assignment-level median.
    def median(sorted)
      return nil if sorted.empty?

      mid, remainder = sorted.size.divmod(2)
      value = remainder.zero? ? ((sorted[mid - 1] + sorted[mid]) / 2.0) : sorted[mid]
      value.round(2)
    end

    def finalized?
      periods = @grading_period ? [@grading_period] : GradingPeriod.for(@course).to_a
      periods.present? && periods.all?(&:closed?)
    end
  end
end
