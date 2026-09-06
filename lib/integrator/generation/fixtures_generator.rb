require "json"
require "time"

module Integrator
  module Generation
    # формирует fixtures.json
    # синтез используется только при их отсутствии
    class FixturesGenerator
      def initialize(analysis)
        @analysis = analysis
      end

      def generate
        create_request_fixture
          .merge(fetch_status_fixture)
          .merge(callback_fixtures)
      end

      def write(path)
        File.write(path, JSON.pretty_generate(generate))
      end

      private

      def create_request_fixture
        return {} unless @analysis.create

        endpoint = @analysis.create.endpoint
        entry = { "request" => endpoint.request_examples.first&.value || synthesize(endpoint.request_schema) }

        success_code = endpoint.responses.keys.find { |k| k.is_a?(Integer) && (200...300).cover?(k) }
        if success_code
          entry["response_#{success_code}"] = find_example(endpoint, [success_code]) ||
                                               synthesize(endpoint.responses[success_code].schema)
        end

        error_code = endpoint.responses.key?(422) ? 422 : endpoint.responses.keys.find { |k| k.is_a?(Integer) && k >= 400 }
        if error_code
          entry["response_#{error_code}"] = find_example(endpoint, [error_code]) ||
                                             synthesize(endpoint.responses[error_code].schema)
        end

        { "create_request" => entry }
      end

      def fetch_status_fixture
        return {} unless @analysis.status

        endpoint = @analysis.status.endpoint
        response = find_example(endpoint, [200]) || synthesize(endpoint.responses[200]&.schema)
        { "fetch_status" => { "response_200" => response } }
      end

      def callback_fixtures
        return {} unless @analysis.callback

        endpoint = @analysis.callback.endpoint
        endpoint.request_examples.each_with_object({}) do |example, out|
          event = example.value["event"]
          canonical = @analysis.event_status_map[event]
          key = example.name || event.to_s
          out[key] = {
            "payload" => example.value,
            "expected_operation_status" => canonical.to_s
          }
        end
      end

      def find_example(endpoint, codes)
        codes.each do |code|
          example = endpoint.responses[code]&.examples&.first
          return example.value if example
        end
        nil
      end

      # запасные значения используются только без примера в спецификации
      # значения берутся из enum/minimum или заменяются простыми заглушками
      def synthesize(schema)
        return nil unless schema

        case schema.type
        when "object"
          (schema.properties || {}).each_with_object({}) { |(name, prop), out| out[name] = synthesize(prop) }
        when "array"
          [synthesize(schema.items)].compact
        when "integer", "number"
          schema.enum&.first || schema.minimum || 0
        when "boolean"
          true
        else
          schema.enum&.first || placeholder_string(schema)
        end
      end

      def placeholder_string(schema)
        return Time.now.utc.iso8601 if schema.format == "date-time"
        return "00000000-0000-0000-0000-000000000000" if schema.format == "uuid"

        "example_#{schema.description ? schema.description.to_s.split.first&.downcase : "value"}"
      end
    end
  end
end
