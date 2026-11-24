# frozen_string_literal: true

require "test_helper"

# Homelab overlay: POST/PATCH /api/v1/transfers (Api::V1::TransferWritesController).
class Api::V1::TransferWritesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @member = users(:family_member)
    @family = @user.family
    @user.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = create_key(@user, [ "read_write" ])

    @checking = @family.accounts.create!(name: "Overlay Checking", owner: @user, accountable: Depository.new, balance: 5000, currency: "USD")
    @savings = @family.accounts.create!(name: "Overlay Savings", owner: @user, accountable: Depository.new, balance: 1000, currency: "USD")
    @mortgage = @family.accounts.create!(name: "Overlay Mortgage", owner: @user, accountable: Loan.new(subtype: "mortgage"), balance: 100_000, currency: "USD")

    @date = Date.parse("2026-09-08")
    @outflow = create_transaction(@checking, amount: 2288.81, name: "Mortgage payment")
    @loan_inflow = create_transaction(@mortgage, amount: -2288.81, name: "Mortgage principal")
  end

  test "creates a confirmed loan_payment transfer for a new pair and syncs both accounts" do
    Account.any_instance.expects(:sync_later).twice

    assert_difference -> { Transfer.count }, 1 do
      post_transfer(@loan_inflow, @outflow, notes: "Linked by Hermes")
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "loan_payment", body["transfer_type"]
    assert_equal "Linked by Hermes", body["notes"]
    assert_equal @loan_inflow.id, body.dig("inflow_transaction", "id")
    assert_equal @outflow.id, body.dig("outflow_transaction", "id")
    assert_equal "funds_movement", body.dig("inflow_transaction", "kind")
    assert_equal "loan_payment", body.dig("outflow_transaction", "kind")

    assert_equal "loan_payment", @outflow.reload.kind
    assert_equal "funds_movement", @loan_inflow.reload.kind
  end

  test "repeating the same POST returns 200 and creates no second transfer" do
    post_transfer(@loan_inflow, @outflow)
    assert_response :created
    first_id = JSON.parse(response.body)["id"]

    Account.any_instance.expects(:sync_later).never
    assert_no_difference -> { Transfer.count } do
      post_transfer(@loan_inflow, @outflow)
    end

    assert_response :ok
    assert_equal first_id, JSON.parse(response.body)["id"]
    assert_equal "confirmed", JSON.parse(response.body)["status"]
  end

  test "confirms an existing pending auto-match instead of creating a new transfer" do
    pending = Transfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow, status: "pending")
    assert_equal "standard", @outflow.reload.kind, "a pending match leaves kinds alone"

    assert_no_difference -> { Transfer.count } do
      post_transfer(@loan_inflow, @outflow)
    end

    assert_response :ok
    assert_equal pending.id, JSON.parse(response.body)["id"]
    assert pending.reload.confirmed?
    assert_equal "loan_payment", @outflow.reload.kind
    assert_equal "funds_movement", @loan_inflow.reload.kind
  end

  test "a split part can be the outflow leg" do
    payment = create_transaction(@checking, amount: 3000, name: "Mortgage payment (split)")
    payment.entry.split!([
      { name: "Mortgage principal", amount: 2000 },
      { name: "Mortgage interest", amount: 1000 }
    ])
    principal = payment.entry.reload.child_entries.find_by!(name: "Mortgage principal").transaction
    interest = payment.entry.child_entries.find_by!(name: "Mortgage interest").transaction
    loan_side = create_transaction(@mortgage, amount: -2000, name: "Principal")

    post_transfer(loan_side, principal)

    assert_response :created
    assert_equal "loan_payment", JSON.parse(response.body)["transfer_type"]
    assert_equal "loan_payment", principal.reload.kind
    assert_equal "standard", interest.reload.kind
  end

  test "a split parent cannot be a leg" do
    payment = create_transaction(@checking, amount: 3000, name: "Mortgage payment (split)")
    payment.entry.split!([
      { name: "Mortgage principal", amount: 2000 },
      { name: "Mortgage interest", amount: 1000 }
    ])
    loan_side = create_transaction(@mortgage, amount: -3000, name: "Whole payment")

    assert_no_difference -> { Transfer.count } do
      post_transfer(loan_side, payment)
    end

    assert_response :unprocessable_entity
    assert_equal "not_transferable", JSON.parse(response.body)["error"]
  end

  test "amounts that are not exactly opposite are rejected" do
    short_inflow = create_transaction(@mortgage, amount: -2288.80, name: "Short")

    post_transfer(short_inflow, @outflow)

    assert_response :unprocessable_entity
    assert_equal "opposite_amounts", JSON.parse(response.body)["error"]
  end

  test "swapped legs (positive inflow) are rejected" do
    post_transfer(@outflow, @loan_inflow)

    assert_response :unprocessable_entity
    assert_equal "opposite_amounts", JSON.parse(response.body)["error"]
  end

  test "both legs in the same account are rejected" do
    same_account_inflow = create_transaction(@checking, amount: -2288.81, name: "Refund")

    post_transfer(same_account_inflow, @outflow)

    assert_response :unprocessable_entity
    assert_equal "same_account", JSON.parse(response.body)["error"]
  end

  test "model validation errors return validation_failed" do
    far_inflow = create_transaction(@mortgage, amount: -2288.81, name: "Much later", date: @date + 45.days)

    post_transfer(far_inflow, @outflow)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert body["errors"].any?
  end

  test "another family's transaction is not found" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Loan", accountable: Loan.new, balance: 0, currency: "USD")
    other_inflow = create_transaction(other_account, amount: -2288.81, name: "Other")

    post_transfer(other_inflow, @outflow)

    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "a malformed id is not found and a missing id is a validation error" do
    post api_v1_homelab_create_transfer_url,
         params: { transfer: { inflow_transaction_id: "not-a-uuid", outflow_transaction_id: @outflow.id } },
         headers: api_headers(@api_key), as: :json
    assert_response :not_found

    post api_v1_homelab_create_transfer_url, params: {}, headers: api_headers(@api_key), as: :json
    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "a read-only key is forbidden" do
    read_key = create_key(@user, [ "read" ])

    assert_no_difference -> { Transfer.count } do
      post_transfer(@loan_inflow, @outflow, key: read_key)
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "a read-only share on one of the accounts is forbidden" do
    member_key = create_key(@member, [ "read_write" ])
    member_checking = @family.accounts.create!(name: "Member Checking", owner: @member, accountable: Depository.new, balance: 100, currency: "USD")
    share = @mortgage.account_shares.find_or_initialize_by(user: @member)
    share.update!(permission: "read_only")
    member_outflow = create_transaction(member_checking, amount: 500, name: "Member payment")
    loan_side = create_transaction(@mortgage, amount: -500, name: "Member principal")

    assert_no_difference -> { Transfer.count } do
      post_transfer(loan_side, member_outflow, key: member_key)
    end

    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body)["error"]
  end

  test "a leg already in a different transfer is a conflict" do
    savings_inflow = create_transaction(@savings, amount: -2288.81, name: "To savings")
    Transfer.create!(inflow_transaction: savings_inflow, outflow_transaction: @outflow, status: "confirmed")

    assert_no_difference -> { Transfer.count } do
      post_transfer(@loan_inflow, @outflow)
    end

    assert_response :conflict
    assert_equal "transfer_conflict", JSON.parse(response.body)["error"]
  end

  test "PATCH rejected records the rejection, releases kinds, and auto-match no longer pairs them" do
    @family.auto_match_transfers!
    transfer = Transfer.find_by(inflow_transaction: @loan_inflow, outflow_transaction: @outflow)
    assert transfer&.pending?, "auto-match pairs the legs before the rejection"
    transfer.confirm!
    assert_equal "loan_payment", @outflow.reload.kind

    patch api_v1_homelab_update_transfer_url(transfer), params: { transfer: { status: "rejected" } },
          headers: api_headers(@api_key), as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @loan_inflow.id, body.dig("inflow_transaction", "id")
    assert RejectedTransfer.exists?(inflow_transaction: @loan_inflow, outflow_transaction: @outflow)
    assert_not Transfer.exists?(transfer.id)
    assert_equal "standard", @outflow.reload.kind
    assert_equal "standard", @loan_inflow.reload.kind

    @family.auto_match_transfers!
    assert_not Transfer.exists?(inflow_transaction: @loan_inflow, outflow_transaction: @outflow)
  end

  test "an explicit POST overrides an earlier rejection" do
    RejectedTransfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow)

    post_transfer(@loan_inflow, @outflow)

    assert_response :created
    assert_not RejectedTransfer.exists?(inflow_transaction: @loan_inflow, outflow_transaction: @outflow)
  end

  test "PATCH confirmed confirms a pending transfer" do
    transfer = Transfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow, status: "pending")

    patch api_v1_homelab_update_transfer_url(transfer), params: { transfer: { status: "confirmed" } },
          headers: api_headers(@api_key), as: :json

    assert_response :ok
    assert_equal "confirmed", JSON.parse(response.body)["status"]
    assert transfer.reload.confirmed?
    assert_equal "loan_payment", @outflow.reload.kind
  end

  test "PATCH with an unknown status is a validation error" do
    transfer = Transfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow, status: "pending")

    patch api_v1_homelab_update_transfer_url(transfer), params: { transfer: { status: "settled" } },
          headers: api_headers(@api_key), as: :json

    assert_response :unprocessable_entity
    assert transfer.reload.pending?
  end

  test "PATCH needs write access to both accounts" do
    member_key = create_key(@member, [ "read_write" ])
    @mortgage.account_shares.find_or_initialize_by(user: @member).update!(permission: "read_only")
    @checking.account_shares.find_or_initialize_by(user: @member).update!(permission: "full_control")
    transfer = Transfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow, status: "pending")

    patch api_v1_homelab_update_transfer_url(transfer), params: { transfer: { status: "confirmed" } },
          headers: api_headers(member_key), as: :json

    assert_response :forbidden
    assert transfer.reload.pending?
  end

  test "upstream GET routes are unchanged" do
    transfer = Transfer.create!(inflow_transaction: @loan_inflow, outflow_transaction: @outflow, status: "confirmed")

    get api_v1_transfer_url(transfer), headers: api_headers(@api_key)
    assert_response :success
    assert_equal transfer.id, JSON.parse(response.body)["id"]

    get api_v1_transfers_url, headers: api_headers(@api_key)
    assert_response :success
  end

  private

    def create_key(user, scopes)
      ApiKey.create!(
        user: user,
        name: "Overlay #{scopes.join('-')} #{SecureRandom.hex(4)}",
        scopes: scopes,
        source: scopes.include?("read_write") ? "web" : "mobile",
        display_key: "overlay_#{SecureRandom.hex(12)}"
      )
    end

    def create_transaction(account, amount:, name:, date: @date)
      account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "standard")
      ).entryable
    end

    def post_transfer(inflow, outflow, notes: nil, key: @api_key)
      payload = { inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id }
      payload[:notes] = notes if notes
      post api_v1_homelab_create_transfer_url, params: { transfer: payload }, headers: api_headers(key), as: :json
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
