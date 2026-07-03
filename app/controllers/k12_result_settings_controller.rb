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

# Page Schools fork (Automatic K-12 Result): the account-level report-card
# policy — term naming labels, position mode, display toggles, CA/exam split.
# Stored in the root account's `k12_result` setting (Account.add_setting,
# root_only) and read through K12Results::Config everywhere else.
class K12ResultSettingsController < ApplicationController
  POSITION_MODES = K12Results::Config::POSITION_MODES
  VIEWS = K12Results::Config::VIEWS

  before_action :require_context
  before_action :require_user
  before_action :require_root_account
  before_action :require_automatic_k12_result
  before_action :check_authorized

  def show
    @config = K12Results::Config.new(@context)
  end

  def update
    @context.settings[:k12_result] = permitted_config
    @context.save!
    flash[:notice] = t("K-12 result settings saved.")
    redirect_to account_k12_result_settings_path(@context)
  end

  private

  def require_root_account
    not_found unless @context.is_a?(Account) && @context.root_account?
  end

  def require_automatic_k12_result
    not_found unless @context.feature_enabled?(:automatic_k12_result)
  end

  def check_authorized
    authorized_action(@context, @current_user, :manage_account_settings)
  end

  def permitted_config
    raw = params.expect(k12_result: %i[position_mode
                                       show_term_position
                                       show_overall_position
                                       show_median
                                       show_mastery
                                       ca_weight
                                       exam_weight
                                       exam_group_pattern
                                       default_view
                                       term_labels])

    {
      "term_labels" => raw[:term_labels].to_s.split("\n").map(&:strip).reject(&:empty?),
      "position_mode" => POSITION_MODES.include?(raw[:position_mode]) ? raw[:position_mode] : "off",
      "show_term_position" => Canvas::Plugin.value_to_boolean(raw[:show_term_position]),
      "show_overall_position" => Canvas::Plugin.value_to_boolean(raw[:show_overall_position]),
      "show_median" => Canvas::Plugin.value_to_boolean(raw[:show_median]),
      "show_mastery" => Canvas::Plugin.value_to_boolean(raw[:show_mastery]),
      "ca_weight" => Float(raw[:ca_weight], exception: false) || K12Results::Config::DEFAULTS["ca_weight"],
      "exam_weight" => Float(raw[:exam_weight], exception: false) || K12Results::Config::DEFAULTS["exam_weight"],
      "exam_group_pattern" => raw[:exam_group_pattern].to_s.strip.presence || "exam",
      "default_view" => VIEWS.include?(raw[:default_view]) ? raw[:default_view] : "senior"
    }
  end
end
