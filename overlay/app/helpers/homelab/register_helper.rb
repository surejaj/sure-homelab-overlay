# frozen_string_literal: true

# Homelab overlay (not upstream Sure): helpers for the condensed register view
# (app/views/homelab/register/*). Included in every view by Rails' default
# `helper :all`.
module Homelab::RegisterHelper
  TRANSACTIONS_VIEWS = %w[default register].freeze

  # True when the signed-in user picked the Register view.
  def register_view?
    Current.user&.preferences&.dig("transactions_view") == "register"
  end

  # { entry_id => Homelab::RunningBalance::Row } for a single-account list.
  def running_balances(entries, account)
    return {} if account.nil?

    Homelab::RunningBalance.for(account, entries)
  end

  # The one account the transactions list is filtered to, or nil. Only then is
  # a running balance meaningful. Accepts the q[account_ids] and q[accounts]
  # (by name) filters; the account must be one the user can see.
  def register_single_account(q)
    q = (q || {}).to_h.with_indifferent_access
    ids = Array(q[:account_ids]).compact_blank.uniq
    names = Array(q[:accounts]).compact_blank.uniq
    return nil if ids.size > 1 || names.size > 1 || (ids.empty? && names.empty?)

    scope = Current.user.accessible_accounts
    scope = scope.where(id: ids) if ids.any?
    scope = scope.where(name: names) if names.any?
    matches = scope.limit(2).to_a
    matches.size == 1 ? matches.first : nil
  end

  # Upstream EntriesHelper#entries_by_date shows a transfer once when both legs
  # are on the page (it drops the inflow leg). Same rule, without the day cards.
  def register_dedupe_transfers(entries)
    entries = entries.to_a
    transfer_ids = entries.filter_map { |e| e.entryable.transfer&.id if e.entryable_type == "Transaction" }
    shown_twice = transfer_ids.tally.select { |_, n| n > 1 }.keys.to_set
    return entries if shown_twice.empty?

    entries.reject do |e|
      e.entryable_type == "Transaction" &&
        e.entryable.transfer_as_inflow.present? &&
        shown_twice.include?(e.entryable.transfer_as_inflow.id)
    end
  end

  # Same target as upstream transactions/_transaction (transfers open the
  # transfer drawer).
  def register_open_path(entry)
    return entry_path(entry) unless entry.entryable_type == "Transaction"

    transaction = entry.entryable
    transaction.transfer? && transaction.transfer.present? ? transfer_path(transaction.transfer) : entry_path(entry)
  end

  # Category column text and an optional title. Transfers show the other
  # account ("→ Mortgage", "← Checking") instead of a category.
  def register_category_label(entry)
    case entry.entryable_type
    when "Valuation"
      [ t("homelab.register.balance_update"), nil ]
    when "Trade"
      [ entry.entryable.investment_activity_label.presence || t("homelab.register.trade"), nil ]
    else
      transaction = entry.entryable
      if transaction.transfer?
        register_transfer_label(entry, transaction)
      else
        name = transaction.category&.name
        [ name.presence || t("homelab.register.uncategorized"), nil ]
      end
    end
  end

  # Last column: notes when the list is one account; otherwise the account
  # name, then the notes.
  def register_memo(entry, single_account:)
    notes = entry.notes.to_s.squish.presence
    single_account ? notes : [ entry.account.name, notes ].compact.join(" · ")
  end

  def register_date(date)
    date.strftime("%m/%d/%y")
  end

  private
    def register_transfer_label(entry, transaction)
      kind = transaction.loan_payment? ? t("transactions.show.loan_payment") : t("transactions.show.transfer")
      transfer = transaction.transfer
      return [ kind, nil ] unless transfer

      outflow = transaction.transfer_as_outflow.present?
      counterpart = outflow ? transfer.to_account : transfer.from_account
      # Same visibility rule as upstream transactions/_transaction.
      return [ kind, nil ] unless counterpart && @accessible_account_ids&.include?(counterpart.id)

      [ "#{outflow ? "→" : "←"} #{counterpart.name}", "#{kind} • #{entry.account.name} #{outflow ? "→" : "←"} #{counterpart.name}" ]
    end
end
