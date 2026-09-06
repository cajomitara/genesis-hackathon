require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # определяет действие для ошибки: reject, retry или alert_and_block
    # сначала проверяется код провайдера, затем http-статус и правило для 5xx
    class ErrorMapper
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        @rules = YAML.safe_load(File.read(rules_path))["error_actions"]
        @warnings = warnings
      end

      attr_reader :warnings

      # http_status — http-статус. provider_code — код ошибки провайдера или nil
      def action_for(http_status, provider_code)
        action = action_by_provider_code(provider_code) || action_by_http_status(http_status)

        unless action
          @warnings.add(
            stage: :error_mapping,
            subject: "http_status=#{http_status} code=#{provider_code.inspect}",
            reason: "нет правила ни по коду ошибки, ни по HTTP-статусу — потребуется ручная проверка"
          )
          action = :unresolved
        end

        ErrorAction.new(http_status: http_status, provider_code: provider_code, action: action)
      end

      private

      def action_by_provider_code(provider_code)
        return nil unless provider_code

        normalized = provider_code.to_s.downcase
        match = @rules["by_provider_code_keywords"].find { |_action, keywords| keywords.any? { |k| normalized.include?(k) } }
        match&.first&.to_sym
      end

      def action_by_http_status(http_status)
        fixed = @rules["by_http_status"][http_status]
        return fixed.to_sym if fixed
        return @rules["default_for_5xx"].to_sym if (500...600).cover?(http_status)

        nil
      end
    end
  end
end
