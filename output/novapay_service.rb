# app/services/provider/novapay_service.rb
# автосгенерировано integrator. TODO требуют ручной проверки.

class Provider
  class NovaPayService < BaseService
    BASE_URL = ENV.fetch('NOVAPAY_BASE_URL', 'https://api.sandbox.novapay.example/v1')

    def create_request(operation, request_method = 'create')
      payload = build_payout_payload(operation)
      response = client.post(
        "#{BASE_URL}/payouts",
        json: payload,
        headers: auth_headers.merge('Idempotency-Key' => SecureRandom.uuid)
      )
      parse_create_response(operation, response)
    rescue Provider::RateLimitError
      failure(:too_many_requests, 'provider.rate_limit')
    rescue Provider::UnauthorizedError
      failure(:unauthorized, 'provider.invalid_credentials')
    end

    def fetch_status(operation)
      response = client.get(
        "#{BASE_URL}/payouts/#{operation.provider_operation_id}",
        headers: auth_headers
      )
      map_status(response.body['status'])
    end

    def cancel_request(operation)
      response = client.post(
        "#{BASE_URL}/payouts/#{operation.provider_operation_id}/cancel",
        headers: auth_headers
      )
      parse_cancel_response(operation, response)
    end

    def process_callback(payload)
      verify_signature!(payload) # HMAC_SHA256 из X-NovaPay-Signature
      case payload['event']
      when 'payout.completed' then approve_operation(payload['payout_id'])
      when 'payout.failed' then reject_operation(payload['payout_id'], payload.dig('error', 'code'))
      when 'payout.processing' then success # операция остаётся в процессе
      when 'payout.cancelled' then reject_operation(payload['payout_id'], payload.dig('error', 'code'))
      else failure(:unprocessable_entity, 'unknown_event')
      end
    end

    def check_conditions(operation, request_method)
      base_result = super
      return base_result if base_result.failed?
      return failure(:unprocessable_entity, 'amount_too_low') if operation.amount < 100000
      success
    end

    private

    def build_payout_payload(operation)
      {
        amount: (operation.amount * 100).to_i,
        currency: 'RUB',
        external_id: operation.id,
        recipient: {
          type: 'sbp',
          phone: operation.payout_requisite.dig('sbp', 'phone'),
          bank_code: operation.payout_requisite.dig('sbp', 'bank_code'),
          bank_name: operation.payout_requisite.dig('sbp', 'bank_name'),
          card_number: operation.payout_requisite.dig('sbp', 'card_number'),
        },
      }
    end

    STATUS_MAP = {
      'pending' => 'in_progress',
      'processing' => 'in_progress',
      'completed' => 'approved',
      'failed' => 'rejected',
      'cancelled' => 'rejected',
    }.freeze

    ERROR_MAP = {
      400 => nil, # код провайдера не указан; действие: reject
      401 => 'unauthorized',
      402 => 'insufficient_balance',
      409 => nil, # код провайдера не указан; действие: reject
      422 => 'validation_error',
      429 => 'rate_limit_exceeded',
      500 => nil, # код провайдера не указан; действие: retry
    }.freeze
  end
end
