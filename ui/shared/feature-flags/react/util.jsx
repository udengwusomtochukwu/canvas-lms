/*
 * Copyright (C) 2020 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import {useScope as createI18nScope} from '@canvas/i18n'
import React from 'react'

const I18n = createI18nScope('feature_flags')

export function buildTransitions(flag, allowsDefaults) {
  const ret = {}
  if (flag.state.includes('allowed') && allowsDefaults) {
    ret.enabled = 'allowed_on'
    ret.disabled = 'allowed'
  } else {
    ret.enabled = 'on'
    ret.disabled = 'off'
  }
  switch (flag.state) {
    case 'allowed_on':
      ret.lock = 'on'
      break
    case 'allowed':
      ret.lock = 'off'
      break
    case 'on':
      ret.lock = 'allowed_on'
      break
    case 'off':
      ret.lock = 'allowed'
      break
  }
  return ret
}

export function buildDescription(flag, allowsDefaults, appliesTo) {
  const validStates = ['on', 'off', 'hidden', 'allowed', 'allowed_on']
  if (!validStates.includes(flag.state)) {
    return
  }
  const contextType = appliesTo === 'Course' ? 'Course' : 'Account'
  let descriptions

  if (allowsDefaults) {
    descriptions = {
      on: {
        Account: I18n.t('Enabled for all subaccounts'),
        Course: I18n.t('Enabled for all courses'),
      },
      off: {
        Account: I18n.t('Disabled for all subaccounts'),
        Course: I18n.t('Disabled for all courses'),
      },
      hidden: {
        Account: I18n.t('Disabled for all subaccounts'),
        Course: I18n.t('Disabled for all courses'),
      },
      allowed: {
        Account: I18n.t('Allowed for subaccounts, default off'),
        Course: I18n.t('Allowed for courses, default off'),
      },
      allowed_on: {
        Account: I18n.t('Allowed for subaccounts, default on'),
        Course: I18n.t('Allowed for courses, default on'),
      },
    }
  } else {
    const enabled = I18n.t('Enabled')
    const disabled = I18n.t('Disabled')

    descriptions = {
      on: {
        Account: enabled,
        Course: enabled,
      },
      allowed_on: {
        Account: enabled,
        Course: I18n.t('Optional in course, default on'),
      },
      off: {
        Account: disabled,
        Course: disabled,
      },
      hidden: {
        Account: disabled,
        Course: disabled,
      },
      allowed: {
        Account: disabled,
        Course: I18n.t('Optional in course, default off'),
      },
    }
  }

  return descriptions[flag.state][contextType]
}

export function shouldDelete(flag, allowsDefaults, state) {
  // Easy case
  if (flag.parent_state === state) {
    return true
  }
  // Awkward hidden case
  if (flag.parent_state === 'hidden' && state === 'off') {
    return true
  }
  // Revert to inheriting when reasonable
  if (!allowsDefaults && flag.parent_state === 'allowed_on' && state === 'on') {
    // Exception: new_user_tutorial_on_off needs explicit 'on' flags for legacy users
    // (created before 2017-04-22) who must explicitly opt-in to the tutorial
    if (flag.feature === 'new_user_tutorial_on_off') {
      return false
    }
    return true
  }
  if (!allowsDefaults && flag.parent_state === 'allowed' && state === 'off') {
    return true
  }
  return false
}

export function doesAllowDefaults(flag, disableDefaults) {
  let allowsDefaults = false
  if (flag.transitions.allowed && !flag.transitions.allowed.locked) {
    allowsDefaults = true
  }
  if (flag.transitions.allowed_on && !flag.transitions.allowed_on.locked) {
    allowsDefaults = true
  }
  if (disableDefaults) {
    allowsDefaults = false
  }
  return allowsDefaults
}

export function transitionLocked(flag, name) {
  if (flag.transitions[name] || flag.state === name) {
    return flag.transitions[name]?.locked
  }

  return null
}

export function isEnabled(flag) {
  return flag.state === 'on' || flag.state === 'allowed_on'
}

export function isLocked(flag) {
  return flag.state !== 'allowed' && flag.state !== 'allowed_on'
}

// Page Schools: plain-English explanation of what the flag's current state
// means in practice, derived from state + scope. Complements the terse
// Hidden/Shadow pills and lock icons with a sentence a non-Canvas-expert
// admin can act on.
export function humanizeFlagState(feature, updatedState) {
  const state = updatedState || feature.feature_flag.state
  const scope = {
    Course: I18n.t('each course can change this in its own settings'),
    User: I18n.t('each user can change this in their own settings'),
    Account: I18n.t('each sub-account can change this'),
    RootAccount: I18n.t('this is a single school-wide switch'),
  }
  const perContext = scope[feature.applies_to] || scope.Account

  if (feature.shadow) {
    return I18n.t(
      'Instructure-internal flag. Regular admins never see it, even when enabled — it exists for the vendor’s own operations, not for schools.',
    )
  }
  switch (state) {
    case 'hidden':
      return I18n.t(
        'Off, and invisible to account admins. Only site admins can see it here and choose to make it available.',
      )
    case 'allowed':
      return I18n.t('Off by default, but available — %{perContext}.', {perContext})
    case 'allowed_on':
      return I18n.t('On by default, but optional — %{perContext}.', {perContext})
    case 'on':
      return I18n.t('On for everyone below this level; it cannot be switched off further down.')
    case 'off':
      return I18n.t('Off for everyone below this level; it cannot be switched on further down.')
    default:
      return null
  }
}
