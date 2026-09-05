require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # Maps a provider's own status vocabulary (e.g. "pending", "completed",
    # "failed" — taken from a response or webhook schema's `enum`) onto the
    # three canonical outcomes Space Payments understands.
    #
    # Deliberately takes a plain Array<String> rather than an
    # Spec::Endpoint or Spec::Schema — it doesn't care *where* the statuses
    # came from, only what they say. Figuring out which schema's `enum` to
    # read is the caller's job (it depends on the endpoint's classified
    # role, which this class has no reason to know about).
    class StatusMapper
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        @rules = YAML.safe_load(File.read(rules_path))["statuses"]
        @warnings = warnings
      end

      attr_reader :warnings

      # statuses: [String], e.g. ["pending", "processing", "completed", "failed", "cancelled"]
      # returns { "pending" => :in_progress, "completed" => :approved, ... }
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
          reason: "не удалось отнести к in_progress/approved/rejected по ключевым словам — " \
                  "добавьте слово в config/keyword_dictionaries.yml (statuses) или обработайте вручную"
        )
        :unresolved
      end
    end
  end
end
