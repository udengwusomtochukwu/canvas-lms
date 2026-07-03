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

describe PaperExamLetterheadsController do
  before :once do
    @account = Account.default
    @admin = account_admin_user(account: @account)
    course_with_teacher(active_all: true, account: @account)
  end

  def base_params
    { account_id: @account.id }
  end

  context "with the flag OFF" do
    it "404s" do
      user_session(@admin)
      get :show, params: base_params
      assert_status(404)
    end
  end

  context "with the flag ON" do
    before(:once) { @account.enable_feature!(:manual_exam_workflow) }

    it "denies teachers (account admins only)" do
      user_session(@teacher)
      get :show, params: base_params
      assert_unauthorized
    end

    it "saves a sanitized template — scripts are stripped" do
      user_session(@admin)
      put :update, params: base_params.merge(template: "<div style='text-align: center;'><b>{{school_name}}</b></div><script>alert(1)</script>")
      template = PaperExams::Letterhead.template_for(@account.reload)
      expect(template).to include "{{school_name}}"
      expect(template).not_to include "<script"
    end

    it "clears the template when blank (falls back to the built-in header)" do
      PaperExams::Letterhead.save_template(@account, "<b>x</b>")
      user_session(@admin)
      put :update, params: base_params.merge(template: "")
      expect(PaperExams::Letterhead.template_for(@account.reload)).to be_nil
    end

    it "previews with sample values substituted and escaped" do
      user_session(@admin)
      post :preview, params: base_params.merge(template: "<b>{{school_name}}</b> — {{term}}")
      expect(response.body).to include "Page Schools, Apo"
      expect(response.body).to include "Second Term"
    end

    it "never lets a substituted value smuggle markup" do
      values = PaperExams::Letterhead::SAMPLE_VALUES.merge("school_name" => "<img src=x onerror=alert(1)>")
      html = PaperExams::Letterhead.render("<b>{{school_name}}</b>", values)
      expect(html).not_to include "<img"
      expect(html).to include "&lt;img"
    end
  end
end
