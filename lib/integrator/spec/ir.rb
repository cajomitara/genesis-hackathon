module Integrator
  module Spec
    # Layer 1 (IR): a typed, fully $ref-resolved mirror of the OpenAPI
    # document. Nothing here decides what anything *means* — no role
    # classification, no status/error/field mapping. That happens one layer
    # up, in Integrator::Analysis, which reads these objects read-only.

    ParsedSpec = Struct.new(
      :info,               # Hash: { title:, version:, description: }
      :servers,            # [ { url:, description: } ]
      :security_schemes,   # { String(scheme_name) => SecurityScheme }
      :endpoints,          # [Endpoint]
      :webhooks,           # [WebhookDef] — only populated for OpenAPI 3.1
                            # top-level `webhooks:`. For OpenAPI 3.0 specs
                            # (like NovaPay's), webhooks show up as ordinary
                            # Endpoints instead — see Loader#build_webhooks.
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
                            #   [] literal        -> operation explicitly public
                            #   [..names..]        -> operation requires these schemes
                            #   nil                -> operation didn't specify security;
                            #                         inherits the document's top-level
                            #                         `security:` (already resolved by
                            #                         the loader, so nil should be rare)
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

    # A recursive node mirroring a (resolved) JSON Schema fragment.
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
      :source_name,         # String | nil — components/schemas name this came
                            # from via $ref (e.g. "Recipient", "PayoutError").
                            # A strong hint for the classifier/mappers; lost
                            # for inline (non-$ref) schemas.
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

    # Populated only from an OpenAPI 3.1 top-level `webhooks:` map.
    WebhookDef = Struct.new(
      :path,                # webhook name, e.g. "payoutStatusChanged"
      :method,
      :signature_header,    # String | nil — header name matching /signature/i
      :signature_description, # raw description text, for algorithm-detection
                            # heuristics in Analysis (not resolved here)
      :payload_schema,      # Schema | nil
      :event_values,        # [String] | nil — enum values of a top-level
                            # "event" property, if the payload has one
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
