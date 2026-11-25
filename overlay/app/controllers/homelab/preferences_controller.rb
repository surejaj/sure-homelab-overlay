# frozen_string_literal: true

# Homelab overlay (not upstream Sure): per-user UI preferences.
#
# PATCH /homelab/preferences/transactions_view  (params: view=default|register)
# Stores users.preferences["transactions_view"] through the same locked
# read-modify-write upstream uses (User#with_locked_preferences), then goes
# back to the page the toggle was on.
class Homelab::PreferencesController < ApplicationController
  def update_transactions_view
    view = params[:view].to_s
    unless Homelab::RegisterHelper::TRANSACTIONS_VIEWS.include?(view)
      return head :unprocessable_entity
    end

    Current.user.with_locked_preferences do |prefs|
      prefs["transactions_view"] = view
    end

    redirect_back_or_to transactions_path, status: :see_other
  end
end
