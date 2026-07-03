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

# Page Schools fork (Manual Exam Workflow): account admin editor for the
# exam-paper letterhead — HTML with {{variables}}, sanitized, with a live
# preview against sample data. Blank template = the built-in default header.
class PaperExamLetterheadsController < ApplicationController
  before_action :require_user
  before_action :load_account
  before_action :require_manual_exam_workflow
  before_action :check_authorized

  def show
    @template = PaperExams::Letterhead.template_for(@account)
    @variables = PaperExams::Letterhead::VARIABLES
  end

  def update
    PaperExams::Letterhead.save_template(@account, params[:template].to_s)
    flash[:notice] = if PaperExams::Letterhead.template_for(@account)
                       t("Letterhead saved.")
                     else
                       t("Letterhead cleared — papers use the built-in header.")
                     end
    redirect_to account_paper_exam_letterhead_path(@account)
  end

  # Live preview: sanitize + substitute sample values, return an HTML
  # fragment the editor renders in a sandboxed iframe.
  def preview
    html = PaperExams::Letterhead.render(params[:template].to_s, PaperExams::Letterhead::SAMPLE_VALUES)
    render html:, layout: false
  end

  private

  def load_account
    @account = Account.find(params[:account_id])
  end

  def require_manual_exam_workflow
    not_found unless @account.feature_enabled?(:manual_exam_workflow)
  end

  def check_authorized
    authorized_action(@account, @current_user, :manage_account_settings)
  end
end
