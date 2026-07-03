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

describe PaperExamsController do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user

    # unpublished source quiz with an MCQ and an essay question
    @quiz = @course.quizzes.create!(title: "Second Term Mathematics Exam", description: "Answer all questions.")
    @mcq = @quiz.quiz_questions.create!(question_data: {
                                          question_type: "multiple_choice_question",
                                          question_text: "<p>2 + 2 = ?</p>",
                                          points_possible: 5,
                                          answers: [{ text: "3", weight: 0 }, { text: "4", weight: 100 }]
                                        })
    @quiz.quiz_questions.create!(question_data: {
                                   question_type: "essay_question",
                                   question_text: "<p>Explain long division.</p>",
                                   points_possible: 15
                                 })
    expect(@quiz).not_to be_published
  end

  def base_params
    { course_id: @course.id, quiz_id: @quiz.id }
  end

  context "with the flag OFF" do
    before { user_session(@teacher) }

    it "404s every action (flag off == vanilla Canvas)" do
      get :show, params: base_params
      assert_status(404)
      post :prepare, params: base_params
      assert_status(404)
      get :printable, params: base_params
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before :once do
      @course.root_account.enable_feature!(:manual_exam_workflow)
    end

    before { user_session(@teacher) }

    it "denies students" do
      user_session(@student)
      get :show, params: base_params
      assert_unauthorized
    end

    describe "prepare" do
      it "creates a companion on_paper assignment; the quiz stays unpublished with no gradebook column" do
        expect { post :prepare, params: base_params }.to change { @course.assignments.active.count }.by(1)

        paper_exam = PaperExam.find_by(quiz: @quiz)
        assignment = paper_exam.assignment
        expect(assignment.submission_types).to eq "on_paper"
        expect(assignment.title).to eq @quiz.title
        expect(assignment.points_possible).to eq 20.0
        expect(assignment.published?).to be true

        @quiz.reload
        expect(@quiz).not_to be_published
        expect(@quiz.assignment).to be_nil # no second gradebook column, ever
      end

      it "is idempotent — re-preparing updates, never duplicates" do
        post :prepare, params: base_params
        @quiz.quiz_questions.create!(question_data: {
                                       question_type: "short_answer_question",
                                       question_text: "<p>Define a fraction.</p>",
                                       points_possible: 10
                                     })
        expect { post :prepare, params: base_params }.not_to change { @course.assignments.active.count }
        expect(PaperExam.where(quiz: @quiz).count).to eq 1
        expect(PaperExam.find_by(quiz: @quiz).assignment.points_possible).to eq 30.0
      end

      it "refuses a published quiz" do
        @quiz.publish!
        expect { post :prepare, params: base_params }.not_to change { PaperExam.count }
        expect(flash[:error]).to match(/unpublished/)
      end

      it "dates the companion inside the current grading period" do
        group = @course.root_account.grading_period_groups.create!(title: "terms")
        group.enrollment_terms << @course.enrollment_term
        period = group.grading_periods.create!(title: "Second Term", start_date: 2.weeks.ago, end_date: 2.weeks.from_now)

        post :prepare, params: base_params
        due_at = PaperExam.find_by(quiz: @quiz).assignment.due_at
        expect(period.in_date_range?(due_at)).to be true
      end

      it "carries question-bank outcome alignments into the companion rubric" do
        outcome = @course.created_learning_outcomes.create!(short_description: "Number Sense", context: @course)
        outcome.rubric_criterion = { mastery_points: 3, ratings: [{ description: "M", points: 5 }, { description: "B", points: 0 }] }
        outcome.save!
        bank = @course.assessment_question_banks.create!(title: "Numbers")
        outcome.align(bank, @course)
        aq = bank.assessment_questions.create!(question_data: @mcq.question_data)
        @mcq.update!(assessment_question: aq)

        post :prepare, params: base_params
        assignment = PaperExam.find_by(quiz: @quiz).assignment
        expect(assignment.active_rubric_association?).to be true

        rubric = assignment.rubric_association.rubric
        aligned = rubric.criteria.detect { |c| c[:learning_outcome_id] == outcome.id }
        expect(aligned).not_to be_nil
        expect(aligned[:points]).to eq 5.0 # the MCQ's marks
        expect(assignment.rubric_association.use_for_grading).to be_falsey
        expect(assignment.learning_outcome_alignments.map(&:learning_outcome_id)).to include outcome.id
      end
    end

    describe "printable" do
      render_views

      before :once do
        PaperExams::Preparer.call(quiz: @quiz, prepared_by: @teacher)
      end

      it "renders sections, marks, tick boxes, ruled space, and records the print" do
        get :printable, params: base_params
        expect(response).to be_successful
        body = response.body
        expect(body).to include "Section A"
        expect(body).to include "2 + 2"
        expect(body).to include "tickbox"       # MCQ options
        expect(body).to include "answer-lines"  # essay ruled space
        expect(body).to include "(5)"
        expect(PaperExam.find_by(quiz: @quiz).printed?).to be true
      end

      it "renders one QR-headed copy per student when personalized" do
        get :printable, params: base_params.merge(personalized: 1)
        expect(response.body.scan("exam-copy").length).to be >= 1
        expect(response.body).to include "<svg" # QR
        expect(response.body).to include @student.name
      end

      it "warns truthfully about drift and clears it on reprint" do
        get :printable, params: base_params
        paper_exam = PaperExam.find_by(quiz: @quiz)
        expect(paper_exam.drifted?).to be false

        @quiz.quiz_questions.active.first.update!(question_data: @mcq.question_data.merge(question_text: "<p>3 + 3 = ?</p>"))
        expect(paper_exam.reload.drifted?).to be true

        get :printable, params: base_params # reprint
        expect(paper_exam.reload.drifted?).to be false
      end
    end
  end
end
