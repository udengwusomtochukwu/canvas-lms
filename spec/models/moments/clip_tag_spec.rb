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

describe Moments::ClipTag do
  include_context "moments course"

  def build_tag(student)
    @clip.clip_tags.build(user: student, tagged_by: @teacher)
  end

  it "tags a consented, enrolled student (G2: identity via human tagging only)" do
    consent!(@student)
    tag = build_tag(@student)
    expect(tag.save).to be true
    expect(tag.root_account_id).to eq @course.root_account_id
  end

  it "rejects tagging without consent (G3 is a model rule, not UI)" do
    tag = build_tag(@student)
    expect(tag.save).to be false
    expect(tag.errors.full_messages.to_sentence).to match(/consent/)
  end

  it "rejects tagging after consent is revoked" do
    consent!(@student)
    consent!(@student, opt_in: false)
    expect(build_tag(@student).save).to be false
  end

  it "rejects students who are not in the session's course" do
    other_course_student = user_factory(active_all: true)
    course_with_teacher(active_all: true) # a different course
    @course.enroll_student(other_course_student, enrollment_state: "active")
    consent!(other_course_student)

    tag = build_tag(other_course_student)
    expect(tag.save).to be false
    expect(tag.errors.full_messages.to_sentence).to match(/not an active student/)
  end

  it "does not tag the same student twice on one clip" do
    consent!(@student)
    build_tag(@student).save!
    expect(build_tag(@student).save).to be false
  end
end
