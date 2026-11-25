# frozen_string_literal: true

require "test_helper"

# Homelab overlay: the register partial renders on the transactions list and on
# the account Activity tab when the user picked it, the Default view is the
# untouched upstream list, and the toggle is on both pages.
class Homelab::RegisterViewTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user

    @d0 = Date.current - 10
    @checking = @family.accounts.create!(name: "Register Checking", owner: @user, accountable: Depository.new, balance: 1000, currency: "USD")
    @mortgage = @family.accounts.create!(name: "Register Mortgage", owner: @user, accountable: Loan.new, balance: 50_000, currency: "USD")
    @checking.entries.create!(name: "Opening balance", date: @d0, amount: 1000, currency: "USD", entryable: Valuation.new(kind: "opening_anchor"))
    @coffee = @checking.entries.create!(name: "Register Coffee Shop", date: @d0 + 1, amount: 4.5, currency: "USD",
                                        notes: "flat white with a long memo text", entryable: Transaction.new(category: categories(:food_and_drink)))
    @salary = @checking.entries.create!(name: "Register Salary", date: @d0 + 2, amount: -2000, currency: "USD", entryable: Transaction.new)
    @valuation = @checking.entries.create!(name: "Manual principal update", date: @d0 + 3, amount: 3500, currency: "USD",
                                           entryable: Valuation.new(kind: "reconciliation"))
    create_transfer(from_account: @checking, to_account: @mortgage, amount: 300, date: @d0 + 4)
    Balance::Materializer.new(@checking, strategy: :forward).materialize_balances
  end

  test "default view keeps the upstream list and shows the toggle" do
    get transactions_url

    assert_response :success
    assert_select "[data-testid=homelab-register-toggle]" do
      assert_select "button[disabled]", text: "Default"
      assert_select "button:not([disabled])", text: "Register"
    end
    assert_select "[data-testid=homelab-register]", count: 0
    assert_select "div[id^=entry-group-]"
  end

  test "transactions list renders the register for all accounts without a balance column" do
    use_register!

    get transactions_url

    assert_response :success
    assert_select "[data-testid=homelab-register-toggle] button[disabled]", text: "Register"
    assert_select "[data-testid=homelab-register]" do
      assert_select "p", text: "Balance", count: 0
      assert_select "p", text: "Account / memo"
    end
    assert_select "div[id^=entry-group-]", count: 0

    row = css_select("[data-testid=homelab-register-row]").find { |r| r.text.include?("Register Coffee Shop") }
    assert row, "coffee row rendered"
    assert_includes row.text, (@d0 + 1).strftime("%m/%d/%y")
    assert_includes row.text, "Food & Drink"
    assert_includes row.text, "Register Checking · flat white with a long memo text"
    link = row.at_css("a[data-turbo-frame=drawer]")
    assert_equal entry_path(@coffee), link["href"]
    assert row.at_css("input[type=checkbox][data-bulk-select-target=row][data-id='#{@coffee.id}']")

    # A transfer with both legs on the page is shown once (upstream rule), as
    # the outflow, with the other account in the category column.
    transfer_rows = css_select("[data-testid=homelab-register-row]").select { |r| r.text.include?("Transfer") && r.text.include?("Register Mortgage") }
    assert_equal 1, transfer_rows.size
    assert_includes transfer_rows.first.text, "→ Register Mortgage"
  end

  test "transactions list filtered to one account shows the running balance" do
    use_register!

    get transactions_url(q: { account_ids: [ @checking.id ] })

    assert_response :success
    assert_select "[data-testid=homelab-register] p", text: "Balance"
    salary = css_select("[data-testid=homelab-register-row]").find { |r| r.text.include?("Register Salary") }
    # 1000 - 4.50 + 2000
    assert_includes salary.text, "$2,995.50"
    assert salary.at_css(".text-green-600"), "inflow amount is green"
  end

  test "account activity renders the register with valuation rows and running balance" do
    use_register!

    get account_url(@checking)

    assert_response :success
    assert_select "[data-testid=homelab-register-toggle]"
    assert_select "[data-testid=homelab-register] p", text: "Balance"
    assert_select "[data-testid=homelab-register-row][data-entry-type=Valuation]", count: 2

    valuation = css_select("[data-testid=homelab-register-row]").find { |r| r.text.include?("Manual principal update") }
    assert valuation, "valuation row rendered"
    assert_includes valuation.text, "Balance update"
    assert_includes valuation.text, "$3,500.00"   # reset balance
    assert_includes valuation.text, "$504.50"     # adjustment 3500 - 2995.50

    transfer = css_select("[data-testid=homelab-register-row]").find { |r| r.text.include?("→ Register Mortgage") }
    assert transfer, "transfer shows the other account"
    assert_includes transfer.text, "$3,200.00"
    assert_select "[data-testid=homelab-register-row] input[type=checkbox][disabled][data-id='#{transfer_entry_id}']"
  end

  test "account activity default view keeps the upstream day cards" do
    get account_url(@checking)

    assert_response :success
    assert_select "[data-testid=homelab-register-toggle]"
    assert_select "[data-testid=homelab-register]", count: 0
    assert_select "details summary", minimum: 1
  end

  private
    def use_register!
      @user.update!(preferences: (@user.preferences || {}).merge("transactions_view" => "register"))
    end

    def transfer_entry_id
      @checking.entries.joins("INNER JOIN transactions t ON t.id = entries.entryable_id")
               .where(entryable_type: "Transaction").where("t.kind = 'funds_movement' OR t.kind = 'loan_payment'").pick(:id)
    end
end
