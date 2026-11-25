# frozen_string_literal: true

# Homelab overlay (not upstream Sure): extra routes, added without editing
# config/routes.rb. Prepended blocks are re-evaluated on every routes draw
# (including reloads). Upstream only routes GET for /api/v1/transfers, so these
# verbs don't shadow anything; the explicit names avoid taking upstream's
# api_v1_transfers / api_v1_transfer helper names. The /homelab/ path prefix
# keeps the register-view preference route clear of upstream paths.
Rails.application.routes.prepend do
  namespace :api do
    namespace :v1 do
      post "transfers", to: "transfer_writes#create", as: :homelab_create_transfer
      patch "transfers/:id", to: "transfer_writes#update", as: :homelab_update_transfer
    end
  end

  patch "homelab/preferences/transactions_view",
        to: "homelab/preferences#update_transactions_view",
        as: :homelab_transactions_view_preference
end
