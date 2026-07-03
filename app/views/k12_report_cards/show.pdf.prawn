# frozen_string_literal: true

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

# Page Schools fork (Automatic K-12 Result): the report card as a PDF,
# rendered through prawn-rails — the same (and only) PDF engine this codebase
# already uses (see submission_comments/index.pdf.prawn).

# template code runs in a method context — no constants here
brand = "2D3193"
ink = "1C1B3B"
grey = "66717D"
line_color = "C7CDD1"
head_bg = "F0F2FA"

dash = "-"
fmt = ->(value) { value.nil? ? dash : value.round(1).to_s }
position_total = ->(set) { config.rank_among_attempted? ? set&.attempted_count : set&.enrolled_count }
fmt_position = lambda do |rank, set|
  total = position_total.call(set)
  (rank && total) ? "#{rank.ordinalize} of #{total}" : dash
end

scores = courses.filter_map { |c| results_by_course[c.id]&.score }
term_average = scores.empty? ? nil : (scores.sum / scores.size).round(1)
average_band = config.waec_band(term_average)
period_label = grading_period ? config.term_label(grading_period) : "Session (Cumulative)"
developmental = (view_mode == "developmental")

prawn_document(page_layout: :portrait, page_size: "A4") do |pdf|
  pdf.font("Helvetica")
  pdf.fill_color ink

  # ── Face A header ──
  pdf.fill_color brand
  pdf.text root_account.name, size: 20, style: :bold, align: :center
  pdf.fill_color grey
  pdf.text developmental ? "LEARNING PROGRESS REPORT" : "TERMINAL REPORT SHEET", size: 9, align: :center, character_spacing: 1.5
  pdf.text "#{period_label} - #{term&.name}", size: 9, align: :center
  pdf.fill_color ink
  pdf.stroke_color ink
  pdf.stroke_horizontal_rule
  pdf.move_down 10

  info = [
    ["Name:", student.name, "Student ID:", (student.pseudonym&.sis_user_id || student.id).to_s],
    ["Subjects:", courses.size.to_s, "Status:", finalized ? "FINAL" : "PROVISIONAL (grading in progress)"]
  ]
  pdf.table(info, cell_style: { borders: [], padding: [2, 6, 2, 0], size: 9.5 }) do
    columns([0, 2]).font_style = :bold
  end
  pdf.move_down 8

  header_style = { background_color: head_bg, font_style: :bold }

  if developmental
    rows = [["Learning Area", "Progress", "Teacher's Note"]]
    courses.each do |course|
      result = results_by_course[course.id]
      entries = result&.mastery_entries || []
      mastered = entries.count { |e| e["mastery"] }
      progress = entries.any? ? "#{mastered} of #{entries.size} skills secure" : dash
      rows << [course.name, progress, result&.remark || dash]
    end
    pdf.table(rows, header: true, width: pdf.bounds.width,
              cell_style: { size: 9, border_color: line_color, padding: [4, 6] }) do
      row(0).style(header_style)
    end
    pdf.move_down 4
    pdf.fill_color grey
    pdf.text "Skills detail follows. Scores and class positions are not reported at this level.", size: 8
    pdf.fill_color ink
  else
    header = ["Subject", "CA (#{config.ca_weight.round})", "Exam (#{config.exam_weight.round})", "Total (100)", "Grade"]
    header << "Class Median" if config.show_median?
    header << (grading_period ? "Position" : "Overall Position") if config.show_term_position?
    header << "Remark"
    rows = [header]
    courses.each do |course|
      result = results_by_course[course.id]
      set = result&.k12_result_set
      row = [course.name, fmt.call(result&.ca_score), fmt.call(result&.exam_score),
             fmt.call(result&.score), result&.grade || dash]
      row << fmt.call(set&.median) if config.show_median?
      row << fmt_position.call(result&.rank, set) if config.show_term_position?
      row << (result&.remark || config.waec_band(result&.score)&.[](2) || dash)
      rows << row
    end
    pdf.table(rows, header: true, width: pdf.bounds.width,
              cell_style: { size: 8.5, border_color: line_color, padding: [4, 5] }) do
      row(0).style(header_style)
      column(0).width = 120
    end
    pdf.move_down 8

    summary = []
    summary << "#{grading_period ? "Term" : "Session"} Average: #{term_average || dash}"
    summary << "Grade: #{term_average ? "#{average_band[1]} (#{average_band[2]})" : dash}"
    if grading_period.nil? && session_result && config.show_overall_position?
      total = config.rank_among_attempted? ? session_result.cohort_attempted_count : session_result.cohort_enrolled_count
      summary << "Overall Position: #{session_result.rank ? "#{session_result.rank.ordinalize} of #{total}" : dash}"
      summary << "Class Median Average: #{fmt.call(session_result.median)}" if config.show_median?
    end
    pdf.fill_color brand
    pdf.text summary.join("     "), size: 10, style: :bold
    pdf.fill_color ink
    if config.positions_enabled?
      pdf.fill_color grey
      note = config.rank_among_attempted? ? "Positions are ranked among students with a graded score." : "Positions are ranked among all enrolled students; the count includes students not yet graded."
      pdf.text note, size: 7.5
      pdf.fill_color ink
    end
  end

  pdf.move_down 10

  # ── traits ──
  affective = session_result&.trait_ratings("affective") || {}
  psychomotor = session_result&.trait_ratings("psychomotor") || {}
  affective_rows = [["Affective Trait", "Rating (1-5)"]] +
                   (affective.keys | affective_traits).map { |t| [t, (affective[t] || dash).to_s] }
  psychomotor_rows = [["Psychomotor Trait", "Rating (1-5)"]] +
                     (psychomotor.keys | psychomotor_traits).map { |t| [t, (psychomotor[t] || dash).to_s] }
  half = (pdf.bounds.width - 12) / 2
  y = pdf.cursor
  pdf.bounding_box([0, y], width: half) do
    pdf.table(affective_rows, header: true, width: half,
              cell_style: { size: 8.5, border_color: line_color, padding: [3, 6] }) { row(0).style(header_style) }
  end
  traits_bottom = pdf.cursor
  pdf.bounding_box([half + 12, y], width: half) do
    pdf.table(psychomotor_rows, header: true, width: half,
              cell_style: { size: 8.5, border_color: line_color, padding: [3, 6] }) { row(0).style(header_style) }
  end
  pdf.move_cursor_to([traits_bottom, pdf.cursor].min)
  pdf.move_down 12

  # ── remarks ──
  pdf.text "Class Teacher's Remark:", size: 9.5, style: :bold
  pdf.text session_result&.class_teacher_remark.presence || "", size: 9.5
  pdf.stroke_color grey
  pdf.dash(1, space: 2)
  pdf.stroke_horizontal_rule
  pdf.move_down 12
  pdf.text "Head Teacher's Remark:", size: 9.5, style: :bold
  pdf.text session_result&.head_teacher_remark.presence || "", size: 9.5
  pdf.stroke_horizontal_rule
  pdf.undash
  pdf.stroke_color ink

  # ── Face B — strand mastery ──
  if config.show_mastery?
    mastery_courses = courses.select { |c| (results_by_course[c.id]&.mastery_entries || []).any? }
    if mastery_courses.any?
      pdf.start_new_page
      pdf.fill_color brand
      pdf.text "Skills & Strand Mastery", size: 16, style: :bold, align: :center
      pdf.fill_color grey
      pdf.text "#{student.name} - #{period_label}", size: 9, align: :center
      pdf.fill_color ink
      pdf.move_down 10

      mastery_courses.each do |course|
        entries = results_by_course[course.id].mastery_entries
        pdf.text course.name, size: 11, style: :bold
        pdf.move_down 3
        rows = [["Strand / Skill", "Mastery", "Score"]]
        entries.each do |entry|
          title = entry["strand"] ? "#{entry["strand"]}: #{entry["title"]}" : entry["title"].to_s
          score = entry["points_possible"] ? "#{entry["score"]} / #{entry["points_possible"]}" : entry["score"].to_s
          rows << [title, entry["rating"] || dash, score]
        end
        pdf.table(rows, header: true, width: pdf.bounds.width,
                  cell_style: { size: 8.5, border_color: line_color, padding: [3, 6] }) do
          row(0).style(header_style)
        end
        pdf.move_down 10
      end
      pdf.fill_color grey
      pdf.text "Mastery comes from Canvas outcome results (rubrics and quizzes), rolled up with the school's mastery scale.", size: 7.5
      pdf.fill_color ink
    end
  end

  pdf.move_down 14
  pdf.fill_color grey
  pdf.text "Generated #{Time.zone.now.strftime("%-d %B %Y, %H:%M")} - #{finalized ? "final" : "provisional"} result", size: 7.5
end
