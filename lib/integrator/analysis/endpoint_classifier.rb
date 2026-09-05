require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # Assigns each Spec::Endpoint a role by scoring it against keyword rules
    # loaded from config/keyword_dictionaries.yml. Nothing here is
    # NovaPay-specific — the rules are generic path/method/tag/schema shapes,
    # and the dictionary is data, not code, so a differently-worded spec
    # just needs new keywords, not new logic.
    #
    # Every endpoint gets exactly one EndpointAnalysis. If nothing matches,
    # the role is :unclassified and a Warning is recorded — classification
    # never raises and never silently drops an endpoint.
    class EndpointClassifier
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      # Order matters only in that it's the order candidate roles are tried
      # in; roles are mutually exclusive by method/shape in practice (e.g.
      # :cancel requires POST/DELETE, :status requires GET), so ties are rare.
      ROLE_ORDER = %i[callback cancel status balance create].freeze

      def initialize(rules_path: DEFAULT_RULES_PATH, warnings: WarningCollector.new)
        @rules = YAML.safe_load(File.read(rules_path))
        @warnings = warnings
      end

      attr_reader :warnings

      def classify(endpoints)
        endpoints.map { |endpoint| classify_one(endpoint) }
      end

      private

      def classify_one(endpoint)
        match = ROLE_ORDER.filter_map { |role| match_high(role, endpoint) }.first
        match ||= ROLE_ORDER.filter_map { |role| match_medium(role, endpoint) }.first
        match ||= unclassified(endpoint)

        EndpointAnalysis.new(endpoint: endpoint, **match)
      end

      def unclassified(endpoint)
        @warnings.add(
          stage: :classification,
          subject: "#{endpoint.method} #{endpoint.path}",
          reason: "no role rule matched (tags=#{endpoint.tags.inspect}, " \
                  "operation_id=#{endpoint.operation_id.inspect}) — review manually " \
                  "or add a keyword to config/keyword_dictionaries.yml"
        )
        { role: :unclassified, confidence: :low, matched_rule: "no rule matched" }
      end

      # ---- shape helpers -------------------------------------------------

      def has_path_param?(path)
        path.include?("{")
      end

      # True only when the path *ends* in a bare {param} segment, e.g.
      # "/payouts/{payout_id}" — but not "/payouts/{payout_id}/receipt",
      # which is a different action performed *on* that resource, not a
      # plain status lookup.
      def last_segment_is_param?(path)
        path.split("/").last =~ /\A\{[^}]+\}\z/
      end

      def path_ends_with_suffix?(path, suffixes)
        suffixes.any? { |s| path.end_with?("/#{s}") }
      end

      def keyword_match?(haystacks, keywords)
        haystacks.compact.any? { |h| keywords.any? { |k| h.downcase.include?(k) } }
      end

      # ---- high-confidence rules ------------------------------------------
      # Each returns nil (no match) or {role:, confidence:, matched_rule:}.

      def match_high(role, endpoint)
        send("match_#{role}_high", endpoint)
      end

      def match_callback_high(e)
        rules = @rules["callback"]
        return nil unless e.security == [] # explicit public — real requirement, not "unspecified"
        return nil unless keyword_match?([e.path] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("callback", :high, "security is explicitly [] and path/tags mention #{rules['path_keywords']}")
      end

      def match_cancel_high(e)
        rules = @rules["cancel"]
        return nil unless %w[POST DELETE].include?(e.method)
        return nil unless path_ends_with_suffix?(e.path, rules["path_suffixes"])

        rule("cancel", :high, "#{e.method} and path ends with one of #{rules['path_suffixes']}")
      end

      def match_status_high(e)
        return nil unless e.method == "GET"
        return nil unless last_segment_is_param?(e.path)

        rule("status", :high, "GET and the final path segment is a bare {parameter}")
      end

      def match_balance_high(e)
        rules = @rules["balance"]
        return nil unless e.method == "GET"
        return nil if has_path_param?(e.path)
        return nil unless keyword_match?([e.path, e.operation_id] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("balance", :high, "GET, no path parameter, path/tags/operationId mention #{rules['path_keywords']}")
      end

      def match_create_high(e)
        rules = @rules["create"]
        return nil unless e.method == "POST"
        return nil if has_path_param?(e.path)
        return nil unless keyword_match?([e.path] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("create", :high, "POST, no path parameter, path/tags mention #{rules['path_keywords']}")
      end

      # ---- medium-confidence fallbacks ------------------------------------
      # Only tried when no high-confidence rule matched anything.

      def match_medium(role, endpoint)
        meth = "match_#{role}_medium"
        respond_to?(meth, true) ? send(meth, endpoint) : nil
      end

      def match_create_medium(e)
        return nil unless e.method == "POST"
        return nil if has_path_param?(e.path)
        return nil unless e.request_schema&.properties&.any?

        aliases = @rules["create"]["amount_field_aliases"]
        return nil unless e.request_schema.properties.keys.any? { |field| aliases.include?(field.downcase) }

        rule("create", :medium, "POST, no path parameter, request body has an amount-like field (#{aliases})")
      end

      def match_balance_medium(e)
        return nil unless e.method == "GET"
        return nil if has_path_param?(e.path)

        ok_schema = e.responses[200]&.schema
        return nil unless ok_schema&.properties&.key?("balance")

        rule("balance", :medium, "GET, no path parameter, 200 response body has a 'balance' field")
      end

      def rule(role, confidence, description)
        { role: role.to_sym, confidence: confidence, matched_rule: description }
      end
    end
  end
end
