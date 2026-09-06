require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # сопоставляет поля провайдера с каноническими именами
    # единицы суммы определяются по описанию поля; при отсутствии признака остаются :unresolved
    class FieldMapper
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      # amount/currency/external_id/phone считаются обязательными для выплаты
      # bank_code/bank_name/card_number могут зависеть от типа реквизитов
      REQUIRED_CANONICAL_FIELDS = %w[amount currency external_id phone].freeze
      OPTIONAL_RECIPIENT_FIELDS = %w[bank_code bank_name card_number].freeze

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        rules = YAML.safe_load(File.read(rules_path))
        @field_aliases = rules["field_aliases"]
        @amount_unit_keywords = rules["amount_unit_keywords"]
        @warnings = warnings
      end

      attr_reader :warnings

      # request_schema — схема тела запроса эндпоинта :create
      def map(request_schema)
        top_level = request_schema.properties || {}
        container_field, container_schema = find_recipient_container(top_level)
        recipient_properties = container_schema&.properties || top_level

        amount_field = find_field(top_level, "amount", required: true)

        FieldMapping.new(
          amount_field: amount_field,
          amount_unit: amount_field ? detect_amount_unit(top_level[amount_field]) : :unresolved,
          currency_field: find_field(top_level, "currency", required: true),
          external_id_field: find_field(top_level, "external_id", required: true),
          recipient_container_field: container_field, # nil означает плоские поля.
          recipient_fields: map_recipient_fields(recipient_properties)
        )
      end

      private

      def find_field(properties, canonical_name, required:)
        aliases = @field_aliases[canonical_name] || [canonical_name]
        match = properties.keys.find { |name| aliases.include?(name.downcase) }

        if match.nil? && required
          @warnings.add(
            stage: :field_mapping,
            subject: canonical_name,
            reason: "поле не найдено"
          )
        end

        match
      end

      # возвращает контейнер реквизитов или [nil, nil], если поля находятся на верхнем уровне
      def find_recipient_container(top_level)
        entry = top_level.find do |_name, schema|
          schema.type == "object" && schema.properties&.any? &&
            (@field_aliases["phone"] + @field_aliases["card_number"]).any? { |alias_name| schema.properties.key?(alias_name) }
        end
        entry || [nil, nil]
      end

      def map_recipient_fields(properties)
        (["phone"] + OPTIONAL_RECIPIENT_FIELDS).each_with_object({}) do |canonical, out|
          match = find_field(properties, canonical, required: REQUIRED_CANONICAL_FIELDS.include?(canonical))
          out[canonical.to_sym] = match if match
        end
      end

      def detect_amount_unit(amount_schema)
        text = amount_schema.description.to_s.downcase
        return :minor if @amount_unit_keywords["minor"].any? { |k| text.include?(k) }
        return :major if @amount_unit_keywords["major"].any? { |k| text.include?(k) }

        @warnings.add(
          stage: :field_mapping,
          subject: "amount unit",
          reason: "единица суммы не определена по описанию поля — уточните вручную"
        )
        :unresolved
      end
    end
  end
end
