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
  # Page Schools fork (Manual Exam Workflow): the admin-configurable exam
  # letterhead. An account stores an HTML template with {{variables}}; it is
  # sanitized through Canvas's own HTML sanitizer at save AND render time
  # (defence in depth — this markup lands on every printed paper), then the
  # variables are substituted with HTML-escaped values.
  module Letterhead
    VARIABLES = %w[
      logo_url
      school_name
      motto
      exam_title
      course
      term
      session
      duration
      total_marks
      date
    ].freeze

    SAMPLE_VALUES = {
      "logo_url" => "",
      "school_name" => "Page Schools, Apo",
      "motto" => "Nature, Knowledge and Excellence",
      "exam_title" => "Second Term Mathematics Examination",
      "course" => "Primary 4B — Mathematics",
      "term" => "Second Term",
      "session" => "2024/2025",
      "duration" => "90 minutes",
      "total_marks" => "60",
      "date" => "12 March 2025"
    }.freeze

    module_function

    def template_for(account)
      account.settings[:paper_exam_letterhead].presence
    end

    def save_template(account, html)
      account.settings[:paper_exam_letterhead] = sanitize(html.to_s).presence
      account.save!
    end

    def sanitize(html)
      Sanitize.clean(html, CanvasSanitize::SANITIZE).strip
    end

    # Sanitize first, substitute after — substituted values are HTML-escaped,
    # so a value can never smuggle markup past the sanitizer.
    def render(template, values)
      html = sanitize(template.to_s)
      VARIABLES.each do |name|
        html = html.gsub("{{#{name}}}", ERB::Util.html_escape(values[name].to_s))
      end
      html.html_safe # rubocop:disable Rails/OutputSafety -- sanitized above, values escaped
    end

    def values_for(quiz:, grading_period: nil, total_marks: nil)
      course = quiz.context
      root_account = course.root_account
      {
        "logo_url" => root_account.try(:brand_config)&.variables&.dig("ic-brand-header-image").to_s,
        "school_name" => root_account.name,
        "motto" => "",
        "exam_title" => quiz.title,
        "course" => course.name,
        "term" => grading_period&.title.to_s,
        "session" => course.enrollment_term&.name.to_s,
        "duration" => quiz.time_limit ? "#{quiz.time_limit} minutes" : "",
        "total_marks" => total_marks.to_s,
        "date" => Time.zone.today.to_fs(:long)
      }
    end
  end
end
