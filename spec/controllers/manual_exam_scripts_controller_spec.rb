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

describe ManualExamScriptsController do
  before :once do
    course_with_teacher(active_all: true)
    @student = student_in_course(course: @course, active_all: true).user
    @assignment = @course.assignments.create!(title: "Midterm Exam", submission_types: "on_paper", points_possible: 100)
  end

  def script_file(name = "script.pdf")
    dir = Dir.mktmpdir
    path = File.join(dir, name)
    File.write(path, "scanned exam script")
    Rack::Test::UploadedFile.new(path, "application/pdf")
  end

  def base_params
    { course_id: @course.id, assignment_id: @assignment.id }
  end

  context "when the manual_exam_workflow flag is OFF" do
    before { user_session(@teacher) }

    it "404s the teacher page" do
      get :show, params: base_params
      assert_status(404)
    end

    it "404s the labels page" do
      get :labels, params: base_params
      assert_status(404)
    end

    it "404s single upload" do
      put :upsert, params: base_params.merge(user_id: @student.id, score: 50)
      assert_status(404)
    end

    it "404s bulk upload" do
      post :bulk_upsert, params: base_params.merge(scripts: [script_file])
      assert_status(404)
    end

    it "leaves the existing grading path exactly as it was" do
      # flag-off == current behaviour: standard grading and comment
      # attachments still work through the native paths, untouched by us
      submission = @assignment.grade_student(@student, score: 42, grader: @teacher).first
      expect(submission.score).to eq 42
      comment = submission.add_comment(author: @teacher, comment: "existing path")
      expect(comment).to be_persisted
      expect(ManualExamScript.count).to eq 0
    end
  end

  context "when the manual_exam_workflow flag is ON" do
    before :once do
      @course.root_account.enable_feature!(:manual_exam_workflow)
    end

    context "authorization" do
      it "denies students" do
        user_session(@student)
        get :show, params: base_params
        assert_unauthorized
      end

      it "denies non-linked users entirely" do
        user_session(user_factory(active_all: true))
        get :show, params: base_params
        assert_unauthorized
      end
    end

    context "as a teacher" do
      before { user_session(@teacher) }

      describe "the upload page" do
        render_views

        it "renders with the roster and upload forms" do
          get :show, params: base_params
          expect(response).to be_successful
          expect(assigns[:students]).to include @student
          expect(response.body).to include @student.sortable_name
          expect(response.body).to include "bulk-scripts-form"
        end
      end

      describe "labels" do
        render_views

        it "renders printable QR labels for every student" do
          get :labels, params: base_params
          expect(response).to be_successful
          expect(response.body).to include "<svg"
          expect(response.body).to include @student.sortable_name
        end
      end

      it "uploads a script and score for one student" do
        put :upsert, params: base_params.merge(user_id: @student.id, score: 87, script: script_file), format: :json
        expect(response).to be_successful

        submission = @assignment.submission_for_student(@student)
        expect(submission.score).to eq 87
        expect(submission.submission_comments.count).to eq 1
        expect(submission.submission_comments.first.attachments.map(&:display_name)).to eq ["script.pdf"]

        json = response.parsed_body
        expect(json["score"]).to eq 87
        expect(json["attachment"]["display_name"]).to eq "script.pdf"
      end

      it "is idempotent over repeated uploads" do
        put :upsert, params: base_params.merge(user_id: @student.id, script: script_file("v1.pdf")), format: :json
        put :upsert, params: base_params.merge(user_id: @student.id, script: script_file("v2.pdf")), format: :json

        submission = @assignment.submission_for_student(@student)
        expect(submission.submission_comments.count).to eq 1
        expect(submission.submission_comments.first.attachments.map(&:display_name)).to eq ["v2.pdf"]
        expect(ManualExamScript.count).to eq 1
      end

      it "rejects non on_paper assignments" do
        essay = @course.assignments.create!(title: "Essay", submission_types: "online_text_entry")
        put :upsert, params: { course_id: @course.id, assignment_id: essay.id, user_id: @student.id, score: 10 }, format: :json
        assert_status(422)
      end

      it "rejects users who are not students in the course" do
        outsider = user_factory(active_all: true)
        put :upsert, params: base_params.merge(user_id: outsider.id, score: 10), format: :json
        assert_status(404)
      end

      describe "bulk upload" do
        before :once do
          # enroll directly: student_in_course would reassign @student
          @student2 = user_factory(active_all: true)
          @course.enroll_student(@student2, enrollment_state: "active")
        end

        it "routes files by explicit user id and by filename, reporting unmatched" do
          files = [script_file("scan_a.pdf"), script_file("#{@student2.id}_scan_b.pdf"), script_file("mystery.pdf")]
          post :bulk_upsert,
               params: base_params.merge(scripts: files, script_user_ids: [@student.id.to_s, "", ""]),
               format: :json
          expect(response).to be_successful

          json = response.parsed_body
          expect(json["attached"].pluck("user_id")).to match_array([@student.id, @student2.id])
          expect(json["unmatched"]).to eq ["mystery.pdf"]

          expect(@assignment.submission_for_student(@student).submission_comments.first.attachments.first.display_name).to eq "scan_a.pdf"
          expect(@assignment.submission_for_student(@student2).submission_comments.first.attachments.first.display_name).to eq "#{@student2.id}_scan_b.pdf"
        end

        it "does not route a filename id that is not a student in this course" do
          other_user = user_factory(active_all: true)
          post :bulk_upsert,
               params: base_params.merge(scripts: [script_file("#{other_user.id}_scan.pdf")]),
               format: :json
          json = response.parsed_body
          expect(json["attached"]).to be_empty
          expect(json["unmatched"]).to eq ["#{other_user.id}_scan.pdf"]
        end
      end
    end
  end
end
