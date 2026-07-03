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

describe K12ResultSettingsController do
  before :once do
    @account = Account.default
    account_admin_user(account: @account)
  end

  it "404s when the flag is off" do
    user_session(@admin)
    get :show, params: { account_id: @account.id }
    assert_status(404)
  end

  context "with the flag ON" do
    before :once do
      @account.enable_feature!(:automatic_k12_result)
    end

    it "404s on a sub-account (the setting is root-only)" do
      sub = @account.sub_accounts.create!(name: "Primary Section")
      user_session(@admin)
      get :show, params: { account_id: sub.id }
      assert_status(404)
    end

    it "refuses non-admins" do
      course_with_teacher(active_all: true)
      user_session(@teacher)
      get :show, params: { account_id: @account.id }
      assert_unauthorized
    end

    it "renders for admins" do
      user_session(@admin)
      get :show, params: { account_id: @account.id }
      expect(response).to have_http_status :ok
    end

    it "round-trips the configuration" do
      user_session(@admin)
      put :update, params: {
        account_id: @account.id,
        k12_result: {
          term_labels: "First Term\nSecond Term\nThird Term",
          position_mode: "position_among_attempted",
          show_term_position: "1",
          show_overall_position: "1",
          show_median: "1",
          ca_weight: "30",
          exam_weight: "70",
          exam_group_pattern: "exam|test of knowledge",
          default_view: "developmental"
        }
      }
      expect(response).to be_redirect

      config = K12Results::Config.new(@account.reload)
      expect(config.term_labels).to eq ["First Term", "Second Term", "Third Term"]
      expect(config.position_mode).to eq "position_among_attempted"
      expect(config.rank_among_attempted?).to be true
      expect(config.show_median?).to be true
      expect(config.show_mastery?).to be false # unchecked checkbox
      expect(config.ca_weight).to eq 30.0
      expect(config.exam_weight).to eq 70.0
      expect(config.exam_group_regexp).to eq(/exam|test of knowledge/i)
      expect(config.default_view).to eq "developmental"
    end

    it "maps term labels onto grading periods by start-date order" do
      course_with_teacher(active_all: true)
      first, second = create_k12_terms_for(@course)
      @account.settings[:k12_result] = { "term_labels" => ["Harmattan", "Rain"] }
      @account.save!
      config = K12Results::Config.new(@account.reload)
      expect(config.term_label(first)).to eq "Harmattan"
      expect(config.term_label(second)).to eq "Rain"
    end
  end
end
