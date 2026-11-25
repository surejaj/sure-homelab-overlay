# frozen_string_literal: true

require "test_helper"

# Homelab overlay: Homelab::RunningBalance against balances written by the real
# upstream materializer (Balance::Materializer, forward strategy).
class Homelab::RunningBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @d0 = Date.current - 10
    @d1 = @d0 + 1
    @d2 = @d0 + 2
    @d3 = @d0 + 3
  end

  test "walks a day newest first; top row is end_balance, bottom row minus its effect is start_balance" do
    account = create_account(Depository.new, opening: 1000)
    older = add_txn(account, @d1, 100, created_at: 3.hours.ago)  # expense
    newer = add_txn(account, @d1, -50, created_at: 1.hour.ago)   # income
    materialize(account)

    rows = Homelab::RunningBalance.for(account, page(account))
    day = account.balances.find_by!(date: @d1)

    assert_equal [ newer.id, older.id ], page(account).select { |e| e.date == @d1 }.map(&:id), "display order"
    assert_equal day.end_balance, rows[newer.id].balance
    assert_equal 950, rows[newer.id].balance
    assert_equal 900, rows[older.id].balance
    # Effect of the bottom (oldest) row is -amount * flows_factor = -100.
    assert_equal day.start_balance, rows[older.id].balance + 100
    assert_nil rows[older.id].adjustment
  end

  test "a valuation resets the balance on its day and reports the adjustment" do
    account = create_account(Depository.new, opening: 1000)
    add_txn(account, @d1, 50)
    before = add_txn(account, @d2, 30)
    valuation = add_valuation(account, @d2, 2000)
    after = add_txn(account, @d3, 10)
    materialize(account)

    rows = Homelab::RunningBalance.for(account, page(account))
    d2 = account.balances.find_by!(date: @d2)

    assert_equal 2000, d2.end_balance
    assert_equal 2000, rows[valuation.id].balance
    # 1000 - 50 - 30 = 920 before the reset.
    assert_equal 920, rows[before.id].balance
    assert_equal 1080, rows[valuation.id].adjustment
    assert_equal d2.start_balance - 30, rows[before.id].balance
    assert_equal 1990, rows[after.id].balance
    assert_equal 1000, rows[account.entries.find_by!(date: @d0).id].balance
  end

  test "liability balances use flows_factor -1" do
    account = create_account(Loan.new, opening: 10_000)
    payment = add_txn(account, @d1, -500, created_at: 3.hours.ago) # payment received by the loan
    interest = add_txn(account, @d1, 20, created_at: 1.hour.ago)   # charge added to the loan
    materialize(account)

    day = account.balances.find_by!(date: @d1)
    assert_equal(-1, day.flows_factor)

    rows = Homelab::RunningBalance.for(account, page(account))
    assert_equal 9520, day.end_balance
    assert_equal 9520, rows[interest.id].balance
    assert_equal 9500, rows[payment.id].balance
    assert_equal day.start_balance, 10_000
  end

  test "rows hidden by a filter or another page still move the balance; pending and split parents get none" do
    account = create_account(Depository.new, opening: 1000)
    shown = add_txn(account, @d1, 100, created_at: 3.hours.ago)
    add_txn(account, @d1, 40, created_at: 2.hours.ago)  # not on this page
    pending = add_txn(account, @d1, 7, created_at: 1.hour.ago)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })
    materialize(account)

    rows = nil
    assert_queries_count(2) do
      rows = Homelab::RunningBalance.for(account, [ shown, pending ])
    end

    assert_equal 860, account.balances.find_by!(date: @d1).end_balance
    assert_equal 900, rows[shown.id].balance
    assert_nil rows[pending.id]
  end

  test "no account, no entries or no balances give an empty result" do
    account = create_account(Depository.new, opening: 1000)
    txn = add_txn(account, @d1, 10)

    assert_equal({}, Homelab::RunningBalance.for(nil, [ txn ]))
    assert_equal({}, Homelab::RunningBalance.for(account, []))
    assert_equal({}, Homelab::RunningBalance.for(account, [ txn ])) # not materialized yet
  end

  private
    def create_account(accountable, opening:)
      account = @family.accounts.create!(name: "Register #{accountable.class.name}", balance: opening, currency: "USD", accountable: accountable)
      account.entries.create!(name: "Opening balance", date: @d0, amount: opening, currency: "USD",
                              entryable: Valuation.new(kind: "opening_anchor"))
      account
    end

    def add_txn(account, date, amount, created_at: nil)
      entry = account.entries.create!(name: "Txn #{amount}", date: date, amount: amount, currency: "USD", entryable: Transaction.new)
      entry.update_column(:created_at, created_at) if created_at
      entry
    end

    def add_valuation(account, date, amount)
      account.entries.create!(name: "Manual balance update", date: date, amount: amount, currency: "USD",
                              entryable: Valuation.new(kind: "reconciliation"))
    end

    def materialize(account)
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
    end

    def page(account)
      account.entries.excluding_split_parents.reverse_chronological.includes(:entryable).to_a
    end
end
