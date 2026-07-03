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

# Page Schools fork (Moments): shared flag gate. When the account flag is
# off, every Moments surface 404s — behaviour is exactly stock Canvas.
module MomentsFeature
  extend ActiveSupport::Concern

  included do
    before_action :require_moments_native
  end

  private

  def require_moments_native
    account = @context.respond_to?(:root_account) ? @context.root_account : @domain_root_account
    not_found unless account&.feature_enabled?(:moments_native)
  end
end
