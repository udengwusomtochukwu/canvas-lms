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

describe Moments::Reel do
  include_context "moments course"

  before :once do
    @reel = Moments::Reel.create!(session: @session, user: @student, workflow_state: "delivered", delivered_at: Time.zone.now)
  end

  it "is readable by the student it belongs to once delivered" do
    expect(@reel.grants_right?(@student, :read)).to be true
  end

  it "is NOT readable by the student while still compiling" do
    peer = user_factory(active_all: true)
    @course.enroll_student(peer, enrollment_state: "active")
    compiling = Moments::Reel.create!(session: @session, user: peer)
    expect(compiling.grants_right?(peer, :read)).to be false
  end

  it "is readable by the linked observer (G6 via native observer linking)" do
    expect(@reel.grants_right?(@observer, :read)).to be true
  end

  it "is NOT readable by a non-linked observer in the same course" do
    other_student = user_factory(active_all: true)
    @course.enroll_student(other_student, enrollment_state: "active")
    non_linked = user_factory(active_all: true)
    @course.enroll_user(non_linked, "ObserverEnrollment", enrollment_state: "active").update!(associated_user_id: other_student.id)

    expect(@reel.grants_right?(non_linked, :read)).to be false
  end

  it "is NOT readable by another student" do
    peer = user_factory(active_all: true)
    @course.enroll_student(peer, enrollment_state: "active")
    expect(@reel.grants_right?(peer, :read)).to be false
  end

  it "is readable and manageable by the course teacher" do
    expect(@reel.grants_right?(@teacher, :read)).to be true
    expect(@reel.grants_right?(@teacher, :manage)).to be true
  end

  describe "the reel file" do
    it "is downloadable by the student and linked observer, and by nobody else in the course" do
      file = Tempfile.new(["reel", ".mp4"])
      file.write("mp4")
      file.rewind
      allow(MomentsBackend).to receive(:fetch_media).and_return(file)
      @reel.fetch_media_from_backend!("canvas/x/reels/#{@reel.id}.mp4")
      @reel.update!(workflow_state: "delivered", delivered_at: Time.zone.now)

      attachment = @reel.reload.attachment
      expect(attachment.grants_right?(@student, :download)).to be true
      expect(attachment.grants_right?(@observer, :download)).to be true

      peer = user_factory(active_all: true)
      @course.enroll_student(peer, enrollment_state: "active")
      expect(attachment.grants_right?(peer, :download)).to be false
    end
  end
end
