# frozen_string_literal: true

# Homelab overlay: upstream api/v1/rejected_transfers/show renders its partial by
# a relative name, which only resolves inside that controller.
json.partial! "api/v1/rejected_transfers/rejected_transfer", rejected_transfer: @rejected_transfer
