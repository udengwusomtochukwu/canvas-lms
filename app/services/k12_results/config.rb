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
  # Page Schools fork (Automatic K-12 Result): the account-level report-card
  # policy, stored in the root account's `k12_result` setting (a plain hash —
  # see Account.add_setting :k12_result). Term names are labels mapped by
  # position onto the session's grading periods sorted by start date, so no
  # term-naming scheme is ever hardcoded.
  class Config
    POSITION_MODES = %w[off position_among_enrolled position_among_attempted].freeze
    VIEWS = %w[senior developmental].freeze

    DEFAULTS = {
      "term_labels" => [],
      "position_mode" => "position_among_enrolled",
      "show_term_position" => true,
      "show_overall_position" => true,
      "show_median" => true,
      "show_mastery" => true,
      "ca_weight" => 40,
      "exam_weight" => 60,
      "exam_group_pattern" => "exam",
      "default_view" => "senior"
    }.freeze

    # score floor => [grade, remark]; WAEC A1–F9, used when the course has no
    # grading standard of its own.
    WAEC_BANDS = [
      [75, "A1", "Excellent"],
      [70, "B2", "Very Good"],
      [65, "B3", "Good"],
      [60, "C4", "Credit"],
      [55, "C5", "Credit"],
      [50, "C6", "Credit"],
      [45, "D7", "Pass"],
      [40, "E8", "Pass"],
      [0, "F9", "Fail"]
    ].freeze

    def self.for(context)
      account = context.is_a?(Account) ? context : context.root_account
      new(account)
    end

    attr_reader :account

    def initialize(account)
      @account = account.root_account? ? account : account.root_account
      raw = @account.settings[:k12_result]
      raw = {} unless raw.is_a?(Hash)
      @data = DEFAULTS.merge(raw.stringify_keys)
    end

    def to_h
      @data
    end

    def position_mode
      POSITION_MODES.include?(@data["position_mode"]) ? @data["position_mode"] : "off"
    end

    def positions_enabled?
      position_mode != "off"
    end

    def rank_among_attempted?
      position_mode == "position_among_attempted"
    end

    def show_term_position?
      positions_enabled? && boolean("show_term_position")
    end

    def show_overall_position?
      positions_enabled? && boolean("show_overall_position")
    end

    def show_median?
      boolean("show_median")
    end

    def show_mastery?
      boolean("show_mastery")
    end

    def term_labels
      Array(@data["term_labels"]).map { |label| label.to_s.strip }.reject(&:empty?)
    end

    # The display label for a grading period: the configured label at the
    # period's position within its set (ordered by start date), falling back
    # to the period's own title.
    def term_label(grading_period)
      return grading_period.title if term_labels.empty?

      siblings = grading_period.grading_period_group.grading_periods.active.order(:start_date)
      index = siblings.index { |gp| gp.id == grading_period.id }
      (index && term_labels[index]) || grading_period.title
    end

    def ca_weight
      numeric("ca_weight")
    end

    def exam_weight
      numeric("exam_weight")
    end

    def exam_group_regexp
      Regexp.new(@data["exam_group_pattern"].to_s.presence || "exam", Regexp::IGNORECASE)
    rescue RegexpError
      /exam/i
    end

    def default_view
      VIEWS.include?(@data["default_view"]) ? @data["default_view"] : "senior"
    end

    # KG–Y4 developmental (skills/mastery) view vs the senior CA+exam view;
    # per-course override in the course settings hash, account default here.
    def view_for(course)
      override = course.settings[:k12_result_view].to_s
      VIEWS.include?(override) ? override : default_view
    end

    # Letter grade for a 0–100 score: the course's own grading standard when
    # one is enabled, otherwise the WAEC A1–F9 bands.
    def grade_for(course, score)
      return nil if score.nil?

      course.score_to_grade(score) || waec_band(score)&.[](1)
    end

    def waec_band(score)
      return nil if score.nil?

      WAEC_BANDS.find { |floor, _grade, _remark| score >= floor } || WAEC_BANDS.last
    end

    private

    def boolean(key)
      Canvas::Plugin.value_to_boolean(@data[key])
    end

    def numeric(key)
      value = Float(@data[key], exception: false)
      value&.positive? ? value : DEFAULTS[key]
    end
  end
end
