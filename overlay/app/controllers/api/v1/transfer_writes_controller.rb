# frozen_string_literal: true

# Homelab overlay (not upstream Sure): write endpoints for transfers.
#
#   POST  /api/v1/transfers      link two transactions as a confirmed transfer
#   PATCH /api/v1/transfers/:id  confirm or reject an existing transfer
#
# Upstream exposes transfers read-only (Api::V1::TransfersController, index and
# show). This controller sits beside it instead of reopening it, so no upstream
# file changes. The write path is the one the web UI takes in
# TransferMatchesController#create (save! + confirm! in one transaction, then
# sync_account_later) and TransfersController#update (confirm! / reject!).
# Responses reuse the upstream api/v1/transfers and api/v1/rejected_transfers
# jbuilder views.
class Api::V1::TransferWritesController < Api::V1::BaseController
  include Api::V1::TransferDecisionFiltering

  WRITE_PERMISSIONS = %i[owner full_control].freeze

  before_action -> { authorize_scope!(:write) }
  before_action :set_transfer, only: :update

  # POST /api/v1/transfers
  # {"transfer": {"inflow_transaction_id": "...", "outflow_transaction_id": "...", "notes": "optional"}}
  def create
    inflow_id = transfer_params[:inflow_transaction_id]
    outflow_id = transfer_params[:outflow_transaction_id]
    if inflow_id.blank? || outflow_id.blank?
      return render_validation_error("inflow_transaction_id and outflow_transaction_id are required")
    end

    inflow = find_accessible_transaction!(inflow_id)
    outflow = find_accessible_transaction!(outflow_id)
    return unless require_write_access!(inflow, outflow)
    return unless transferable_pair?(inflow, outflow)

    status = nil
    changed = false
    Transfer.transaction do
      # Serialise concurrent POSTs on the same legs (in a stable order), then
      # re-read the transfer state under the lock.
      [ inflow, outflow ].sort_by(&:id).each(&:lock!)
      inflow.reload
      outflow.reload

      existing = [ inflow.transfer, outflow.transfer ].compact.uniq
      if existing.size > 1 || (existing.one? && !same_pair?(existing.first, inflow, outflow))
        status = :conflict
        raise ActiveRecord::Rollback
      end

      if (@transfer = existing.first)
        status = :ok
        if @transfer.pending?
          @transfer.notes = transfer_params[:notes] if transfer_params.key?(:notes)
          @transfer.confirm!
          changed = true
        end
      else
        status = :created
        # An explicit link overrides an earlier "not a transfer" decision.
        RejectedTransfer.where(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id).delete_all
        @transfer = Transfer.new(
          inflow_transaction: inflow,
          outflow_transaction: outflow,
          status: "confirmed",
          notes: transfer_params[:notes]
        )
        @transfer.save!
        @transfer.confirm!
        changed = true
      end
    end

    return render_conflict if status == :conflict

    @transfer.sync_account_later if changed
    @transfer.reload
    render "api/v1/transfers/show", status: status
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable("validation_failed", e.record.errors.full_messages.presence || [ e.message ])
  rescue ActiveRecord::RecordNotUnique
    # Lost a race to another request that linked one of these legs.
    render_conflict
  end

  # PATCH /api/v1/transfers/:id
  # {"transfer": {"status": "confirmed" | "rejected"}}
  def update
    return unless require_write_access!(@transfer.inflow_transaction, @transfer.outflow_transaction)

    case transfer_params[:status]
    when "confirmed"
      changed = @transfer.pending?
      @transfer.confirm! if changed
      @transfer.sync_account_later if changed
      @transfer.reload
      render "api/v1/transfers/show"
    when "rejected"
      entries = [ @transfer.inflow_transaction.entry, @transfer.outflow_transaction.entry ]
      @transfer.reject!
      entries.each(&:sync_account_later)
      @rejected_transfer = RejectedTransfer.find_by!(
        inflow_transaction_id: @transfer.inflow_transaction_id,
        outflow_transaction_id: @transfer.outflow_transaction_id
      )
      render :rejected
    else
      render_validation_error("status must be one of: confirmed, rejected")
    end
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable("validation_failed", e.record.errors.full_messages.presence || [ e.message ])
  end

  private

    def transfer_params
      @transfer_params ||= params.fetch(:transfer, {}).permit(:inflow_transaction_id, :outflow_transaction_id, :notes, :status)
    end

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfer_decision_scope(Transfer).find(params[:id])
    end

    # Family- and share-scoped, the same set the read endpoints use.
    def find_accessible_transaction!(id)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(id)

      accessible_transactions.includes(entry: :account).find(id)
    end

    # Confirming or rejecting rewrites the kind of both legs, so (as in the web
    # UI) the caller must be able to write to both accounts.
    def require_write_access!(*transactions)
      writable = transactions.all? do |transaction|
        transaction.entry.account.permission_for(current_resource_owner).in?(WRITE_PERMISSIONS)
      end
      return true if writable

      render_json({ error: "forbidden", message: "You do not have write access to both accounts" }, status: :forbidden)
      false
    end

    def transferable_pair?(inflow, outflow)
      if inflow.entry.account_id == outflow.entry.account_id
        render_unprocessable("same_account", [ "Both transactions are in the same account" ])
        return false
      end

      not_transferable = [ inflow, outflow ].find { |t| t.entry.split_parent? || t.entry.excluded? }
      if not_transferable
        reason = not_transferable.entry.split_parent? ? "is split; link one of its split parts instead" : "is excluded"
        render_unprocessable("not_transferable", [ "Transaction #{not_transferable.id} #{reason}" ])
        return false
      end

      # Same rule as Transfer#transfer_has_opposite_amounts: the inflow is the
      # negative leg, and same-currency legs must cancel exactly.
      in_amount = inflow.entry.amount
      out_amount = outflow.entry.amount
      same_currency = inflow.entry.currency == outflow.entry.currency
      unless in_amount.negative? && out_amount.positive? && (!same_currency || (in_amount + out_amount).zero?)
        render_unprocessable("opposite_amounts", [ "The inflow must be negative and the outflow its exact opposite" ])
        return false
      end

      true
    end

    def same_pair?(transfer, inflow, outflow)
      transfer.inflow_transaction_id == inflow.id && transfer.outflow_transaction_id == outflow.id
    end

    def render_conflict
      render_json({
        error: "transfer_conflict",
        message: "A transaction is already part of a different transfer",
        errors: [ "A transaction is already part of a different transfer" ]
      }, status: :conflict)
    end

    def render_unprocessable(error, errors)
      render_json({ error: error, message: errors.first, errors: errors }, status: :unprocessable_entity)
    end
end
