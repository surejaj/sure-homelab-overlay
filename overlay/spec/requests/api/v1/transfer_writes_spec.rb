# frozen_string_literal: true

require 'swagger_helper'

# Homelab overlay: documents POST/PATCH /api/v1/transfers. Behaviour is covered
# by test/controllers/api/v1/transfer_writes_controller_test.rb.
RSpec.describe 'API V1 Transfer writes (homelab overlay)', type: :request do
  let(:family) do
    Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end

  let(:user) do
    family.users.create!(email: 'api-user@example.com', password: 'password123', password_confirmation: 'password123')
  end

  let(:api_key) do
    ApiKey.create!(user: user, name: 'API Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web')
  end

  let(:read_only_key) do
    ApiKey.create!(user: user, name: 'API Docs Read Key', key: ApiKey.generate_secure_key, scopes: %w[read], source: 'mobile')
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:checking) { family.accounts.create!(name: 'Checking', owner: user, balance: 5000, currency: 'USD', accountable: Depository.create!) }
  let(:mortgage) { family.accounts.create!(name: 'Mortgage', owner: user, balance: 100_000, currency: 'USD', accountable: Loan.create!) }
  let!(:outflow_entry) do
    checking.entries.create!(date: Date.current, amount: 1500, name: 'Mortgage principal', currency: 'USD',
                             entryable: Transaction.new(kind: 'standard'))
  end
  let!(:inflow_entry) do
    mortgage.entries.create!(date: Date.current, amount: -1500, name: 'Principal', currency: 'USD',
                             entryable: Transaction.new(kind: 'standard'))
  end

  path '/api/v1/transfers' do
    post 'Link two transactions as a confirmed transfer' do
      tags 'Transfers'
      description 'Homelab overlay. Creates a confirmed transfer, or confirms the pending auto-match for the same pair. ' \
                  'Idempotent: repeating it returns 200. A rejected pair is overridden.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[transfer],
        properties: {
          transfer: {
            type: :object,
            required: %w[inflow_transaction_id outflow_transaction_id],
            properties: {
              inflow_transaction_id: { type: :string, format: :uuid, description: 'The negative (money in) leg' },
              outflow_transaction_id: { type: :string, format: :uuid, description: 'The positive (money out) leg; may be a split part' },
              notes: { type: :string, nullable: true }
            }
          }
        }
      }

      let(:body) do
        { transfer: { inflow_transaction_id: inflow_entry.entryable.id, outflow_transaction_id: outflow_entry.entryable.id } }
      end

      response '201', 'transfer created and confirmed' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test! do |response|
          parsed = JSON.parse(response.body)
          expect(parsed['status']).to eq 'confirmed'
          expect(parsed['transfer_type']).to eq 'loan_payment'
        end
      end

      response '200', 'pair already linked (pending match confirmed, or already confirmed)' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        before do
          Transfer.create!(inflow_transaction: inflow_entry.entryable, outflow_transaction: outflow_entry.entryable, status: 'pending')
        end

        run_test! do |response|
          expect(JSON.parse(response.body)['status']).to eq 'confirmed'
        end
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope or no write access to both accounts' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_key.plain_key }

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { transfer: { inflow_transaction_id: SecureRandom.uuid, outflow_transaction_id: outflow_entry.entryable.id } } }

        run_test!
      end

      response '409', 'a leg is already in a different transfer (transfer_conflict)' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          savings = family.accounts.create!(name: 'Savings', owner: user, balance: 0, currency: 'USD', accountable: Depository.create!)
          other_inflow = savings.entries.create!(date: Date.current, amount: -1500, name: 'To savings', currency: 'USD',
                                                 entryable: Transaction.new(kind: 'standard'))
          Transfer.create!(inflow_transaction: other_inflow.entryable, outflow_transaction: outflow_entry.entryable, status: 'confirmed')
        end

        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq 'transfer_conflict'
        end
      end

      response '422', 'not transferable, same account, amounts not opposite, or validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          { transfer: { inflow_transaction_id: outflow_entry.entryable.id, outflow_transaction_id: inflow_entry.entryable.id } }
        end

        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq 'opposite_amounts'
        end
      end
    end
  end

  path '/api/v1/transfers/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Transfer ID'

    let!(:transfer) do
      Transfer.create!(inflow_transaction: inflow_entry.entryable, outflow_transaction: outflow_entry.entryable, status: 'pending')
    end
    let(:id) { transfer.id }

    patch 'Confirm or reject a transfer' do
      tags 'Transfers'
      description 'Homelab overlay. confirmed applies the transfer kinds; rejected deletes the transfer, releases the kinds, ' \
                  'and records a rejected transfer so auto-match does not pair the legs again (returns the rejected transfer).'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[transfer],
        properties: {
          transfer: {
            type: :object,
            required: %w[status],
            properties: { status: { type: :string, enum: %w[confirmed rejected] } }
          }
        }
      }

      response '200', 'transfer confirmed' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        let(:body) { { transfer: { status: 'confirmed' } } }

        run_test! do |response|
          expect(JSON.parse(response.body)['status']).to eq 'confirmed'
        end
      end

      response '200', 'transfer rejected' do
        schema '$ref' => '#/components/schemas/RejectedTransfer'

        let(:body) { { transfer: { status: 'rejected' } } }

        run_test! do
          expect(RejectedTransfer.count).to eq 1
          expect(Transfer.exists?(transfer.id)).to be false
        end
      end

      response '404', 'transfer not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:body) { { transfer: { status: 'confirmed' } } }

        run_test!
      end

      response '422', 'invalid status' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { transfer: { status: 'settled' } } }

        run_test!
      end
    end
  end
end
