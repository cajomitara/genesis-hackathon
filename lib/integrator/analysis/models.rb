module Integrator
  module Analysis
    # A single "couldn't confidently decide" record. Every analyzer in this
    # layer (classifier now; status/error/field mappers later) appends here
    # instead of raising or silently skipping. Never suppressed, never fatal.
    Warning = Struct.new(
      :stage,      # :classification | :status_mapping | :error_mapping | :field_mapping
      :subject,    # e.g. "POST /balance" or "status=on_hold"
      :reason,     # human-readable explanation, in the language the report is generated in
      keyword_init: true
    )

    EndpointAnalysis = Struct.new(
      :endpoint,       # Integrator::Spec::Endpoint — read-only reference to the IR object
      :role,           # :create | :status | :cancel | :callback | :balance | :unclassified
      :confidence,     # :high | :medium | :low
      :matched_rule,   # String — human-readable, for debugging/logging why this role was picked
      keyword_init: true
    )

    ErrorAction = Struct.new(
      :http_status,    # Integer
      :provider_code,  # String | nil
      :action,         # :reject | :retry | :retry_with_backoff | :alert_and_block | :unresolved
      keyword_init: true
    )

    FieldMapping = Struct.new(
      :amount_field,        # String | nil — provider's field name for the payout amount
      :amount_unit,         # :minor | :major | :unresolved
      :currency_field,      # String | nil
      :external_id_field,   # String | nil
      :recipient_fields,    # { Symbol(canonical) => String(provider_field_name) }
                            #   canonical keys: :phone, :bank_code, :bank_name, :card_number
      keyword_init: true
    )
  end
end
