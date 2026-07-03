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

module PaperExams
  # Page Schools fork (Manual Exam Workflow, phase 2): "Prepare paper exam".
  # Idempotently creates/updates the companion on_paper assignment for an
  # unpublished source quiz:
  #   * same title, total points = the printed document's total
  #   * due date inside the CURRENT grading period, so the score lands in
  #     the right term's rollup
  #   * a rubric whose criteria carry the source questions' outcome
  #     alignments (via their question banks), so grading the paper produces
  #     the SAME outcome rollups / strand mastery as any other assignment
  # The quiz itself is never published and never gains a gradebook column.
  class Preparer < ApplicationService
    def initialize(quiz:, prepared_by:)
      super()
      @quiz = quiz
      @course = quiz.context
      @prepared_by = prepared_by
    end

    def call
      document = Document.from_quiz(@quiz)
      paper_exam = PaperExam.find_by(quiz: @quiz)

      assignment = paper_exam&.assignment || @course.assignments.build
      assignment.title = @quiz.title
      assignment.submission_types = "on_paper"
      assignment.points_possible = document.total_points
      assignment.due_at ||= due_date_in_current_period
      assignment.workflow_state = "published" if assignment.new_record?
      assignment.save!

      paper_exam ||= PaperExam.create!(quiz: @quiz, assignment:)
      sync_outcome_rubric(assignment)
      paper_exam
    end

    private

    def due_date_in_current_period
      period = GradingPeriod.current_period_for(@course)
      now = Time.zone.now
      return now unless period
      return now if period.in_date_range?(now)

      period.end_date - 1.day
    end

    # Outcomes reach classic quiz questions through their question banks;
    # each outcome aligned to a bank that contributes questions becomes one
    # rubric criterion worth the sum of those questions' points.
    def outcome_points
      points_by_outcome = Hash.new(0.0)
      each_question_with_points do |assessment_question, points|
        bank = assessment_question&.assessment_question_bank
        next unless bank

        bank.learning_outcome_alignments.each do |alignment|
          points_by_outcome[alignment.learning_outcome] += points
        end
      end
      points_by_outcome
    end

    def each_question_with_points(&)
      # .each, not find_each: Canvas's batching forbids find_each outside
      # transactions/migrations, and a quiz has classroom-scale questions
      @quiz.quiz_questions.active.where(quiz_group_id: nil).preload(assessment_question: :assessment_question_bank).each do |question| # rubocop:disable Rails/FindEach
        yield(question.assessment_question, question.question_data[:points_possible].to_f)
      end
      @quiz.quiz_groups.each do |group|
        next unless group.assessment_question_bank_id

        group.assessment_question_bank.assessment_questions.active.order(:id).limit(group.pick_count).each do |aq|
          yield(aq, group.question_points.to_f)
        end
      end
    end

    def sync_outcome_rubric(assignment)
      points_by_outcome = outcome_points
      return if points_by_outcome.empty?

      criteria = {}
      points_by_outcome.each_with_index do |(outcome, points), index|
        mastery_ratio = mastery_ratio_for(outcome)
        criteria[index.to_s] = {
          description: outcome.short_description,
          long_description: "",
          points:,
          mastery_points: (points * mastery_ratio).round(2),
          learning_outcome_id: outcome.id,
          ratings: {
            "0" => { description: "Mastery", points: },
            "1" => { description: "Developing", points: (points * mastery_ratio).round(2) },
            "2" => { description: "Beginning", points: 0 }
          }
        }
      end

      rubric = assignment.active_rubric_association? ? assignment.rubric_association.rubric : @course.rubrics.build(context: @course)
      rubric.user ||= @prepared_by
      rubric.update_criteria(
        title: "#{@quiz.title} — mastery",
        criteria:
      )
      rubric.save!
      # use_for_grading false: the exam total is entered directly through the
      # manual exam workflow; the rubric exists to carry strand mastery.
      rubric.associate_with(assignment, @course, purpose: "grading", use_for_grading: false)
    end

    def mastery_ratio_for(outcome)
      data = outcome.rubric_criterion
      possible = data&.dig(:points_possible).to_f
      mastery = data&.dig(:mastery_points).to_f
      return 0.6 if possible <= 0 || mastery <= 0

      (mastery / possible).clamp(0.1, 1.0)
    end
  end
end
