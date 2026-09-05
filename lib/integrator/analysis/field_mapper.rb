require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # Aliases a provider's own field names (whatever the "create" endpoint's
    # request schema happens to call them) onto the canonical names the
    # generated service needs to fill in: amount, currency, external_id,
    # and the recipient's phone/bank_code/bank_name/card_number.
    #
    # Also tries to detect whether `amount` is expressed in minor units
    # (kopecks/cents) or major units, from that field's own description —
    # getting this wrong means every generated payout is off by 100x, so
    # when the description gives no hint, the unit is :unresolved rather
    # than assumed.
    class FieldMapper
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      # amount/currency/external_id/phone are expected on essentially any
      # payout API — their absence is worth a warning. bank_code/bank_name/
      # card_number are legitimately conditional (e.g. NovaPay only requires
      # bank_code for type=sbp, card_number for type=card) — silently
      # absent is normal, not a warning.
      REQUIRED_CANONICAL_FIELDS = %w[amount currency external_id phone].freeze
      OPTIONAL_RECIPIENT_FIELDS = %w[bank_code bank_name card_number].freeze

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        rules = YAML.safe_load(File.read(rules_path))
        @field_aliases = rules["field_aliases"]
        @amount_unit_keywords = rules["amount_unit_keywords"]
        @warnings = warnings
      end

      attr_reader :warnings

      # request_schema: Integrator::Spec::Schema — the request body schema
      # of the endpoint the classifier assigned role=:create.
      def map(request_schema)
        top_level = request_schema.properties || {}
        # Recipient sub-fields (phone, bank_code, ...) usually live inside a
        # nested object (NovaPay's "recipient"), but nothing requires that —
        # a flatter spec might put "msisdn" right at the top level. Search
        # whichever nested object looks recipient-shaped, and fall back to
        # the top level itself if none is found, so both shapes work.
        recipient_properties = find_recipient_like_properties(top_level) || top_level

        amount_field = find_field(top_level, "amount", required: true)

        FieldMapping.new(
          amount_field: amount_field,
          amount_unit: amount_field ? detect_amount_unit(top_level[amount_field]) : :unresolved,
          currency_field: find_field(top_level, "currency", required: true),
          external_id_field: find_field(top_level, "external_id", required: true),
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
            reason: "поле не найдено среди #{properties.keys.inspect} (искали алиасы #{aliases.inspect})"
          )
        end

        match
      end

      def find_recipient_like_properties(top_level)
        candidate = top_level.values.find do |schema|
          schema.type == "object" && schema.properties&.any? &&
            (@field_aliases["phone"] + @field_aliases["card_number"]).any? { |alias_name| schema.properties.key?(alias_name) }
        end
        candidate&.properties
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
          reason: "в описании поля суммы (#{amount_schema.description.inspect}) нет ключевых слов " \
                  "минимальных/основных единиц — уточните вручную, иначе конвертация суммы будет неверной"
        )
        :unresolved
      end
    end
  end
end
