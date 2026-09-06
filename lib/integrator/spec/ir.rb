module Integrator
  module Spec
    # типизированное представление после разворачивания $ref
    ParsedSpec = Struct.new(
      :info,               # Hash: { title:, version:, description: }
      :servers,            # [ { url:, description: } ]
      :security_schemes,   # { String(scheme_name) => SecurityScheme }
      :endpoints,          # [Endpoint]
      :webhooks,           # [WebhookDef]
      keyword_init: true
    )

    Endpoint = Struct.new(
      :method,             # "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
      :path,                # "/payouts/{payout_id}"
      :operation_id,        # String | nil
      :summary,             # String | nil
      :description,         # String | nil
      :tags,                # [String]
      :security,            # [String](scheme names) | nil
      :parameters,          # [Parameter]
      :request_schema,      # Schema | nil
      :request_examples,    # [Example]
      :responses,           # { Integer(status_code) | :default => ResponseDef }
      keyword_init: true
    )

    Parameter = Struct.new(
      :name,
      :location,            # :path | :query | :header | :cookie
      :required,            # Boolean
      :schema,              # Schema
      :description,
      keyword_init: true
    )

    # узел, соответствующий фрагменту json schema
    Schema = Struct.new(
      :type,                # "object" | "integer" | "string" | "array" | ... | nil
      :format,              # "uuid" | "date-time" | ... | nil
      :properties,          # { String(name) => Schema } — only for type=object
      :items,               # Schema | nil — only for type=array
      :required_fields,     # [String] — names of required properties
      :enum,                # [String] | nil
      :minimum,             # Numeric | nil
      :maximum,             # Numeric | nil
      :max_length,          # Integer | nil
      :pattern,             # String | nil
      :description,         # String | nil
      :source_name,         # String | nil
      keyword_init: true
    )

    SecurityScheme = Struct.new(
      :name,                # key from components/securitySchemes
      :type,                # "apiKey" | "http" | "oauth2" | "openIdConnect"
      :location,            # :header | :query | :cookie — only for type=apiKey
      :param_name,          # "X-API-Key" — only for type=apiKey
      :http_scheme,         # "bearer" | "basic" — only for type=http
      :description,
      keyword_init: true
    )

    ResponseDef = Struct.new(
      :status_code,         # Integer | :default
      :description,
      :schema,              # Schema | nil
      :examples,            # [Example]
      keyword_init: true
    )

    WebhookDef = Struct.new(
      :path,                # webhook name, e.g. "payoutStatusChanged"
      :method,
      :signature_header,    # String | nil — header name matching /signature/i
      :signature_description, # raw description text, for algorithm-detection
                            # эвристики анализа, здесь не разрешается
      :payload_schema,      # Schema | nil
      :event_values,        # [String] | nil — enum values of a top-level
                            # поле "event", если оно есть в payload
      :examples,            # [Example]
      keyword_init: true
    )

    Example = Struct.new(
      :name,                # key from `examples:`, or nil for a single `example:`
      :summary,
      :value,               # raw Hash, verbatim
      keyword_init: true
    )
  end
end
