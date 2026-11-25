# frozen_string_literal: true

require "test_helper"

# Homelab overlay: PATCH /homelab/preferences/transactions_view.
class Homelab::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("show_split_grouped" => false))
    sign_in @user
  end

  test "saves register, keeps other preferences and goes back with 303" do
    patch homelab_transactions_view_preference_path,
          params: { view: "register" },
          headers: { "Referer" => transactions_url(q: { search: "x" }) }

    assert_response :see_other
    assert_redirected_to transactions_url(q: { search: "x" })
    @user.reload
    assert_equal "register", @user.preferences["transactions_view"]
    assert_equal false, @user.preferences["show_split_grouped"]
  end

  test "switches back to default" do
    @user.update!(preferences: @user.preferences.merge("transactions_view" => "register"))

    patch homelab_transactions_view_preference_path, params: { view: "default" }

    assert_redirected_to transactions_url
    assert_equal "default", @user.reload.preferences["transactions_view"]
  end

  test "goes through User#with_locked_preferences" do
    User.any_instance.expects(:with_locked_preferences).yields({}).once

    patch homelab_transactions_view_preference_path, params: { view: "register" }

    assert_response :see_other
  end

  test "rejects an unknown view" do
    patch homelab_transactions_view_preference_path, params: { view: "compact" }

    assert_response :unprocessable_entity
    assert_nil @user.reload.preferences["transactions_view"]
  end

  test "requires sign in" do
    reset! # new integration session, no login cookie

    patch homelab_transactions_view_preference_path, params: { view: "register" }

    assert_response :redirect
    assert_nil @user.reload.preferences["transactions_view"]
  end
end
