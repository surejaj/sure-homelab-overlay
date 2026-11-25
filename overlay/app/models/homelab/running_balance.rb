# frozen_string_literal: true

# Homelab overlay (not upstream Sure): running balance for the register view.
#
# Gives the account balance after each entry shown on one page of a single
# account's list, derived from the materialized `balances` rows, without a
# window query over the whole history.
#
# Per page there are two indexed queries:
#   1. balances for the page's dates (start_balance, end_balance, flows_factor);
#   2. every entry of the account on those dates (id, type, amount, trade qty),
#      in the same reverse_chronological order the lists use.
# The second query makes the walk correct when the page is filtered (search,
# category, ...) or a day is cut by pagination: entries that are not shown still
# move the balance.
#
# Walk per day, newest first (display order):
#   - Entries after the day's last valuation (above it in the list) walk back
#     from end_balance: the first row shows end_balance, the next one
#     end_balance minus the effect of the row above, and so on.
#   - The valuation row shows the balance it sets; its "adjustment" is that
#     balance minus the balance just before it.
#   - Entries before the valuation walk forward from start_balance (upstream
#     Balance::ForwardCalculator sets the day's end to the valuation amount, so
#     these rows can't be reached from end_balance).
#
# Effect of an entry on the balance (mirrors Balance::BaseCalculator#flows_for_date
# and Balance::SyncCache): -amount * flows_factor for transactions and for
# income-only trades (qty 0); 0 for buy/sell trades (cash and holdings cancel)
# and for transactions on non-cash, non-loan accounts (property, vehicle).
# Pending transactions and split parents are not in the balance and get no row.
#
# Values are stale while a sync is running, as the account chart is.
module Homelab
  class RunningBalance
    Row = Data.define(:balance, :adjustment)

    DayEntry = Data.define(:id, :date, :entryable_type, :amount, :qty) do
      def valuation? = entryable_type == "Valuation"
      def trade? = entryable_type == "Trade"
    end

    def self.for(account, entries)
      new(account, entries).call
    end

    def initialize(account, entries)
      @account = account
      @entries = entries.to_a
    end

    # Returns { entry_id => Row(balance:, adjustment:) }. Amounts are BigDecimal
    # in the account currency; adjustment is only set for valuation rows.
    def call
      return {} if account.nil? || entries.empty?

      dates = entries.map(&:date).uniq
      balances = balances_by_date(dates)
      return {} if balances.empty?

      day_entries(dates.select { |d| balances.key?(d) }).group_by(&:date).each_with_object({}) do |(date, rows), result|
        walk_day(rows, balances.fetch(date), result)
      end
    end

    private
      attr_reader :account, :entries

      def balances_by_date(dates)
        account.balances
          .where(date: dates, currency: account.currency)
          .pluck(:date, :start_balance, :end_balance, :flows_factor)
          .to_h { |date, start_balance, end_balance, flows_factor| [ date, [ start_balance, end_balance, flows_factor ] ] }
      end

      def day_entries(dates)
        return [] if dates.empty?

        account.entries
          .excluding_split_parents
          .excluding_pending
          .where(date: dates)
          .joins("LEFT JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
          .reverse_chronological
          .pluck(:id, :date, :entryable_type, :amount, :currency, Arel.sql("trades.qty"))
          .map do |id, date, type, amount, currency, qty|
            DayEntry.new(id: id, date: date, entryable_type: type, amount: to_account_currency(amount, currency, date), qty: qty)
          end
      end

      # Same conversion as Balance::SyncCache; an entry without a rate is left
      # out of the balance there, so it has no effect here either.
      def to_account_currency(amount, currency, date)
        return amount if currency == account.currency

        Money.new(amount, currency).exchange_to(account.currency, date: date).amount
      rescue Money::ConversionError
        0
      end

      def walk_day(rows, balance, result)
        start_balance, end_balance, flows_factor = balance
        last_valuation = rows.index(&:valuation?)

        running = end_balance
        rows.each_with_index do |row, i|
          break if i == last_valuation

          result[row.id] = Row.new(balance: running, adjustment: nil)
          running -= effect(row, flows_factor)
        end
        return unless last_valuation

        forward = start_balance
        rows[(last_valuation + 1)..].reverse_each do |row|
          if row.valuation?
            result[row.id] = Row.new(balance: row.amount, adjustment: row.amount - forward)
            forward = row.amount
          else
            forward += effect(row, flows_factor)
            result[row.id] = Row.new(balance: forward, adjustment: nil)
          end
        end

        result[rows[last_valuation].id] = Row.new(balance: running, adjustment: running - forward)
      end

      def effect(row, flows_factor)
        return 0 if row.valuation?
        return 0 if row.trade? && row.qty.to_d != 0
        return 0 if !row.trade? && non_cash_without_flows?

        -row.amount * flows_factor
      end

      # Balance::BaseCalculator#flows_for_date books no transaction flows on a
      # non-cash account unless it is a loan.
      def non_cash_without_flows?
        account.balance_type == :non_cash && account.accountable_type != "Loan"
      end
  end
end
