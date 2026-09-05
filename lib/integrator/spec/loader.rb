require "psych"
require "date"
require_relative "ir"
require_relative "ref_resolver"

module Integrator
  module Spec
    # Преобразует yaml -> Spec::ParsedSpec + проверяет yaml на валидность ()
    class Loader
      class InvalidSpecError < StandardError; end

      HTTP_METHODS = %w[get post put patch delete].freeze

      def self.load_file(path)
        raw = Psych.safe_load(File.read(path), permitted_classes: [Date, Time])
        new(raw).call
      rescue Errno::ENOENT
        raise InvalidSpecError, "file not found: #{path}"
      rescue Psych::SyntaxError => e
        raise InvalidSpecError, "not valid YAML: #{e.message}"
      end

      def initialize(raw_document)
        @raw = raw_document
      end

      def call
        validate_openapi_document!

        resolver = RefResolver.new(@raw)
        @doc = resolver.resolve(@raw)
        @global_security = @doc["security"]

        ParsedSpec.new(
          info: build_info(@doc["info"]),
          servers: build_servers(@doc["servers"]),
          security_schemes: build_security_schemes(@doc.dig("components", "securitySchemes")),
          endpoints: build_endpoints(@doc["paths"]),
          webhooks: build_webhooks(@doc["webhooks"])
        )
      end

      private

      def validate_openapi_document!
        raise InvalidSpecError, "input is not a mapping at the top level" unless @raw.is_a?(Hash)

        version = @raw["openapi"]
        raise InvalidSpecError, "missing 'openapi' key — this doesn't look like an OpenAPI document" unless version
        raise InvalidSpecError, "unsupported OpenAPI version: #{version} (only 3.x is supported)" unless version.to_s.start_with?("3.")
        raise InvalidSpecError, "document has no 'paths'" unless @raw["paths"].is_a?(Hash)
      end

      def build_info(info)
        info ||= {}
        { title: info["title"], version: info["version"], description: info["description"] }
      end

      def build_servers(servers)
        (servers || []).map { |s| { url: s["url"], description: s["description"] } }
      end

      def build_security_schemes(schemes)
        (schemes || {}).each_with_object({}) do |(name, definition), out|
          out[name] = SecurityScheme.new(
            name: name,
            type: definition["type"],
            location: definition["in"]&.to_sym,
            param_name: definition["name"],
            http_scheme: definition["scheme"],
            description: definition["description"]
          )
        end
      end

      def build_endpoints(paths)
        (paths || {}).flat_map do |path, path_item|
          next [] unless path_item.is_a?(Hash)

          shared_params = path_item["parameters"] || []

          HTTP_METHODS.filter_map do |method|
            op = path_item[method]
            next unless op

            build_endpoint(method.upcase, path, op, shared_params)
          end
        end
      end

      def build_endpoint(method, path, op, shared_params)
        Endpoint.new(
          method: method,
          path: path,
          operation_id: op["operationId"],
          summary: op["summary"],
          description: op["description"],
          tags: op["tags"] || [],
          security: extract_security(op["security"]),
          parameters: build_parameters(shared_params + (op["parameters"] || [])),
          request_schema: build_request_schema(op["requestBody"]),
          request_examples: extract_examples(op.dig("requestBody", "content", "application/json")),
          responses: build_responses(op["responses"])
        )
      end

      # nil at the operation level means "not specified here" -> falls back
      # to the document's top-level `security:`. An explicit `security: []`
      # is preserved as [] (== "this operation is public"), which is
      # different from nil and matters to the classifier (public + POST
      # + "webhook"/"callback" naming is a strong signal for role=:callback).
      def extract_security(op_security)
        requirements = op_security.nil? ? @global_security : op_security
        (requirements || []).flat_map(&:keys)
      end

      def build_parameters(params)
        params.map do |p|
          Parameter.new(
            name: p["name"],
            location: p["in"]&.to_sym,
            required: p["required"] || false,
            schema: build_schema(p["schema"]),
            description: p["description"]
          )
        end
      end

      def build_request_schema(request_body)
        build_schema(request_body&.dig("content", "application/json", "schema"))
      end

      def build_responses(responses)
        (responses || {}).each_with_object({}) do |(code, resp), out|
          key = code == "default" ? :default : code.to_i
          content = resp["content"]&.dig("application/json")
          out[key] = ResponseDef.new(
            status_code: key,
            description: resp["description"],
            schema: build_schema(content&.dig("schema")),
            examples: extract_examples(content)
          )
        end
      end

      def build_schema(schema)
        return nil if schema.nil?
        return circular_schema_stub(schema) if schema["_circular_ref"]

        source_name = schema["_source_ref"]&.split("/")&.last

        properties = (schema["properties"] || {}).each_with_object({}) do |(name, prop_schema), out|
          out[name] = build_schema(prop_schema)
        end

        Schema.new(
          type: schema["type"],
          format: schema["format"],
          properties: properties,
          items: build_schema(schema["items"]),
          required_fields: schema["required"] || [],
          enum: schema["enum"],
          minimum: schema["minimum"],
          maximum: schema["maximum"],
          max_length: schema["maxLength"],
          pattern: schema["pattern"],
          description: schema["description"],
          source_name: source_name
        )
      end

      def circular_schema_stub(schema)
        Schema.new(
          type: nil,
          properties: {},
          required_fields: [],
          source_name: schema["_circular_ref"].split("/").last,
          description: "(circular reference to #{schema['_circular_ref']}, not expanded further)"
        )
      end

      def extract_examples(content_node)
        return [] unless content_node

        named = (content_node["examples"] || {}).map do |name, ex|
          Example.new(name: name, summary: ex["summary"], value: ex["value"])
        end
        single = content_node["example"] ? [Example.new(name: nil, summary: nil, value: content_node["example"])] : []
        named + single
      end

      # OpenAPI 3.1 top-level `webhooks:` map. OpenAPI 3.0 specs (like
      # NovaPay's, in this project) have no such key — their webhook is
      # just a regular path (e.g. POST /webhooks/payout) with
      # `security: []`, and it will show up in `endpoints` like any other
      # operation. Recognizing *that* an endpoint plays the webhook/callback
      # role is a classification decision, not a parsing fact — it belongs
      # to Analysis::EndpointClassifier, not here.
      def build_webhooks(webhooks)
        (webhooks || {}).flat_map do |name, path_item|
          next [] unless path_item.is_a?(Hash)

          HTTP_METHODS.filter_map do |method|
            op = path_item[method]
            next unless op

            content = op.dig("requestBody", "content", "application/json")
            WebhookDef.new(
              path: name,
              method: method.upcase,
              signature_header: find_signature_header(op["parameters"]),
              signature_description: op["description"],
              payload_schema: build_schema(content&.dig("schema")),
              event_values: content&.dig("schema", "properties", "event", "enum"),
              examples: extract_examples(content)
            )
          end
        end
      end

      def find_signature_header(parameters)
        (parameters || []).find { |p| p["in"] == "header" && p["name"].to_s =~ /signature/i }&.fetch("name", nil)
      end
    end
  end
end
