require_relative "models"
require_relative "warning_collector"
require_relative "endpoint_classifier"
require_relative "status_mapper"
require_relative "error_mapper"
require_relative "field_mapper"

module Integrator
  module Analysis
    # связывает роли эндпоинтов со схемами для маппинга
    class SpecAnalyzer
      def initialize(parsed_spec, warnings: WarningCollector.new)
        @spec = parsed_spec
        @warnings = warnings
        @classifier = EndpointClassifier.new(warnings: @warnings)
        @status_mapper = StatusMapper.new(warnings: @warnings)
        @error_mapper = ErrorMapper.new(warnings: @warnings)
        @field_mapper = FieldMapper.new(warnings: @warnings)
      end

      attr_reader :warnings

      def call
        by_role = @classifier.classify(@spec.endpoints).group_by(&:role)
        create = pick_one(by_role, :create)
        status = pick_one(by_role, :status)
        cancel = pick_one(by_role, :cancel)
        callback = pick_one(by_role, :callback)
        balance = pick_one(by_role, :balance)

        field_mapping = create ? @field_mapper.map(create.endpoint.request_schema) : blank_field_mapping
        status_map = @status_mapper.map(extract_status_values(status, callback))
        recipient_type_field, recipient_type_value = detect_recipient_type(create)

        # всегда требует ручного заполнения
        @warnings.add(
          stage: :field_mapping,
          subject: "ProviderGateway config (external_method / gateway)",
          reason: "не определяется по API-спецификации, заполните вручную"
        )

        SpecAnalysis.new(
          info: @spec.info,
          class_name: derive_class_name,
          env_prefix: derive_env_prefix,
          base_url: pick_base_url,
          security_scheme: primary_security_scheme(create),
          create: create,
          status: status,
          cancel: cancel,
          callback: callback,
          balance: balance,
          field_mapping: field_mapping,
          recipient_type_field: recipient_type_field,
          recipient_type_value: recipient_type_value,
          status_map: status_map,
          event_status_map: build_event_status_map(callback, status_map),
          error_rows: create ? build_error_rows(create.endpoint) : [],
          webhook_signature_header: callback&.endpoint&.parameters&.find { |p| p.name.to_s =~ /signature/i }&.name,
          webhook_signature_algorithm: detect_signature_algorithm(callback),
          idempotency_header: create&.endpoint&.parameters&.find { |p| p.name.to_s =~ /idempotency/i }&.name,
          amount_minimum: amount_minimum(create, field_mapping),
          warnings: @warnings
        )
      end

      private

      def pick_one(by_role, role)
        candidates = by_role[role] || []
        case candidates.size
        when 0
          @warnings.add(
            stage: :classification,
            subject: role.to_s,
            reason: "эндпоинт этой роли не найден"
          )
        when 2..Float::INFINITY
          @warnings.add(
            stage: :classification,
            subject: role.to_s,
            reason: "найдено несколько эндпоинтов этой роли"
          )
        end
        candidates.first
      end

      def blank_field_mapping
        FieldMapping.new(amount_field: nil, amount_unit: :unresolved, currency_field: nil,
                          external_id_field: nil, recipient_fields: {})
      end

      def extract_status_values(status_analysis, callback_analysis)
        from_status = status_analysis&.endpoint&.responses&.dig(200)&.schema&.properties&.dig("status")&.enum
        return from_status if from_status&.any?

        from_callback = callback_analysis&.endpoint&.request_schema&.properties&.dig("status")&.enum
        return from_callback if from_callback&.any?

        @warnings.add(
          stage: :status_mapping,
          subject: "status enum",
          reason: "перечисление статусов не найдено в ответе или webhook"
        )
        []
      end

      def build_event_status_map(callback, status_map)
        return {} unless callback

        events = callback.endpoint.request_schema&.properties&.dig("event")&.enum || []
        events.each_with_object({}) do |event, out|

          # если статус не найден, добавляется предупреждение
          guess = event.to_s.split(".").last
          canonical = status_map[guess]
          if canonical.nil?
            @warnings.add(
              stage: :status_mapping,
              subject: "webhook event=#{event}",
              reason: "событие webhook не сопоставлено со статусом"
            )
            canonical = :unresolved
          end
          out[event] = canonical
        end
      end

      def build_error_rows(endpoint)
        endpoint.responses.filter_map do |status_code, response|
          next unless status_code.is_a?(Integer) && status_code >= 400

          provider_code = response.examples.first&.value&.dig("error", "code")
          action = @error_mapper.action_for(status_code, provider_code).action
          { http_status: status_code, provider_code: provider_code, action: action }
        end.sort_by { |row| row[:http_status] }
      end

      def detect_recipient_type(create)
        return [nil, nil] unless create

        recipient_schema = create.endpoint.request_schema&.properties&.values&.find do |s|
          s.type == "object" && s.properties&.dig("type")&.enum
        end
        return [nil, nil] unless recipient_schema

        ["type", recipient_schema.properties["type"].enum.first]
      end

      def detect_signature_algorithm(callback)
        return :unresolved unless callback

        text = callback.endpoint.description.to_s.downcase
        return :hmac_sha256 if text.include?("hmac-sha256") || text.include?("hmac sha256")
        return :hmac_sha1 if text.include?("hmac-sha1") || text.include?("hmac sha1")

        @warnings.add(
          stage: :field_mapping,
          subject: "webhook signature algorithm",
          reason: "алгоритм подписи webhook не определён"
        )
        :unresolved
      end

      def amount_minimum(create, field_mapping)
        return nil unless create && field_mapping.amount_field

        create.endpoint.request_schema.properties[field_mapping.amount_field]&.minimum
      end

      def derive_class_name
        word = first_word(@spec.info[:title])
        word.empty? ? "Provider" : word[0].upcase + word[1..]
      end

      def derive_env_prefix
        first_word(@spec.info[:title]).upcase
      end

      def first_word(title)
        (title.to_s.split(/\s+/).first || "Provider").gsub(/[^A-Za-z0-9]/, "")
      end

      def pick_base_url
        sandbox = @spec.servers.find { |s| s[:description].to_s.downcase.include?("sandbox") }
        (sandbox || @spec.servers.first || {})[:url]
      end

      def primary_security_scheme(create)
        return nil unless create

        name = create.endpoint.security&.first
        name && @spec.security_schemes[name]
      end
    end
  end
end
