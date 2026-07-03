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
  # Page Schools fork (Manual Exam Workflow, phase 2): the source-agnostic
  # document the print view renders — an ordered list of sections, each an
  # ordered list of questions with points. Built from a classic quiz today;
  # any future question source that produces the same shape reuses the
  # renderer and the whole graded return path untouched.
  class Document
    Question = Struct.new(:number, :points, :html, :question_type, :options, :answer_lines, keyword_init: true)
    Section = Struct.new(:title, :instructions, :points, :questions, keyword_init: true) do
      def total_points
        points || questions.sum { |q| q.points.to_f }
      end
    end

    attr_reader :sections

    def initialize(sections)
      @sections = sections
    end

    def total_points
      sections.sum(&:total_points)
    end

    def question_count
      sections.sum { |s| s.questions.length }
    end

    ANSWER_LINES = {
      "essay_question" => 12,
      "short_answer_question" => 3,
      "numerical_question" => 2,
      "calculated_question" => 4,
      "fill_in_multiple_blanks_question" => 3
    }.freeze
    NO_ANSWER_SPACE = %w[multiple_choice_question true_false_question text_only_question].freeze

    # Build from a classic quiz. Ungrouped questions form the first section;
    # each quiz group becomes its own section (bank-linked groups take their
    # pick_count questions from the bank in a stable order, so a reprint is
    # deterministic).
    def self.from_quiz(quiz)
      number = 0
      build_question = lambda do |data, points|
        number += 1
        qtype = data[:question_type].to_s
        options = Array(data[:answers]).map { |a| a[:html].presence || a[:text].to_s }
        Question.new(
          number:,
          points: points || data[:points_possible].to_f,
          html: data[:question_text].to_s,
          question_type: qtype,
          options: (qtype == "text_only_question") ? [] : options,
          answer_lines: NO_ANSWER_SPACE.include?(qtype) ? 0 : ANSWER_LINES.fetch(qtype, 4)
        )
      end

      sections = []
      ungrouped = quiz.quiz_questions.active.where(quiz_group_id: nil).order(:position, :id)
      if ungrouped.any?
        sections << Section.new(
          title: nil,
          instructions: nil,
          questions: ungrouped.map { |q| build_question.call(q.question_data, nil) }
        )
      end

      quiz.quiz_groups.order(:position, :id).each do |group|
        questions =
          if group.assessment_question_bank_id
            bank = group.assessment_question_bank
            bank.assessment_questions.active.order(:id).limit(group.pick_count).map do |aq|
              build_question.call(aq.question_data.symbolize_keys, group.question_points)
            end
          else
            group.quiz_questions.active.order(:position, :id).first(group.pick_count || 0).map do |q|
              build_question.call(q.question_data, group.question_points)
            end
          end
        next if questions.empty?

        sections << Section.new(title: group.name, instructions: nil, questions:)
      end

      new(sections)
    end
  end
end
