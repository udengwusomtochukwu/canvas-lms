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

# Page Schools fork (Manual Exam Workflow, phase 2): the quiz↔assignment
# pointer for a paper exam. The quiz is a PERMANENTLY UNPUBLISHED authoring
# artifact (question source, no gradebook column, invisible to students);
# the companion on_paper assignment holds all graded reality. This row
# stores the question-content fingerprint captured at print time so the UI
# can warn — truthfully — when questions changed after papers were printed.
class PaperExam < ApplicationRecord
  belongs_to :quiz, class_name: "Quizzes::Quiz"
  belongs_to :assignment
  belongs_to :root_account, class_name: "Account"

  validates :quiz_id, uniqueness: true
  validates :assignment_id, uniqueness: true

  before_validation :set_root_account

  # Deterministic digest of everything that changes the printed paper:
  # quiz title, question content/points/order, and group structure.
  def self.fingerprint(quiz)
    parts = [quiz.title]
    quiz.quiz_groups.order(:id).each do |group|
      parts << "g#{group.id}:#{group.name}:#{group.pick_count}:#{group.question_points}:#{group.updated_at.to_f}"
    end
    quiz.quiz_questions.active.order(:id).each do |question|
      parts << "q#{question.id}:#{question.updated_at.to_f}"
    end
    Digest::SHA256.hexdigest(parts.join("|"))
  end

  def current_fingerprint
    self.class.fingerprint(quiz)
  end

  def printed?
    printed_at.present?
  end

  # True when the questions changed after the last print run.
  def drifted?
    printed? && printed_fingerprint != current_fingerprint
  end

  def mark_printed!
    update!(printed_fingerprint: current_fingerprint, printed_at: Time.zone.now)
  end

  private

  def set_root_account
    self.root_account_id ||= assignment&.root_account_id || quiz&.context&.root_account_id
  end
end
