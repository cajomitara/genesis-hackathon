require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # сопоставляет статусы провайдера с каноническими статусами
    # принимает только массив строк и не зависит от источника статусов
    class StatusMapper
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        @rules = YAML.safe_load(File.read(rules_path))["statuses"]
        @warnings = warnings
      end

      attr_reader :warnings

      # statuses — массив статусов провайдера
      def map(statuses)
        statuses.each_with_object({}) { |status, out| out[status] = bucket_for(status) }
      end

      private

      def bucket_for(status)
        normalized = status.to_s.downcase
        matched = @rules.find { |_canonical, keywords| keywords.any? { |k| normalized.include?(k) } }
        return matched.first.to_sym if matched

        @warnings.add(
          stage: :status_mapping,
          subject: "status=#{status}",
          reason: "статус не сопоставлен — добавьте ключевое слово или обработайте вручную"
        )
        :unresolved
      end
    end
  end
end
