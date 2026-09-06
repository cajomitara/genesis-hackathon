require "yaml"
require_relative "models"
require_relative "warning_collector"

module Integrator
  module Analysis
    # назначает роль эндпоинту по правилам из config/keyword_dictionaries.yml
    # каждый эндпоинт получает один EndpointAnalysis; при отсутствии совпадения сохраняется :unclassified и предупреждение
    class EndpointClassifier
      DEFAULT_RULES_PATH = File.join(__dir__, "..", "config", "keyword_dictionaries.yml")

      # роли проверяются в заданном порядке
      # на практике они различаются по методу и форме эндпоинта
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
          reason: "правило классификации не найдено"
        )
        { role: :unclassified, confidence: :low, matched_rule: "правило не найдено" }
      end

      # вспомогательные проверки формы
      def has_path_param?(path)
        path.include?("{")
      end

      # true, если путь заканчивается параметром, например "/payouts/{payout_id}"
      # путь с дополнительным сегментом не считается запросом статуса
      def last_segment_is_param?(path)
        path.split("/").last =~ /\A\{[^}]+\}\z/
      end

      def path_ends_with_suffix?(path, suffixes)
        suffixes.any? { |s| path.end_with?("/#{s}") }
      end

      def keyword_match?(haystacks, keywords)
        haystacks.compact.any? { |h| keywords.any? { |k| h.downcase.include?(k) } }
      end

      # правила с высокой уверенностью.
      # возвращает nil или данные выбранного правила.

      def match_high(role, endpoint)
        send("match_#{role}_high", endpoint)
      end

      def match_callback_high(e)
        rules = @rules["callback"]
        return nil unless e.security == []
        return nil unless keyword_match?([e.path] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("callback", :high, "security: [] и ключевое слово callback/webhook")
      end

      def match_cancel_high(e)
        rules = @rules["cancel"]
        return nil unless %w[POST DELETE].include?(e.method)
        return nil unless path_ends_with_suffix?(e.path, rules["path_suffixes"])

        rule("cancel", :high, "#{e.method}, путь заканчивается на суффикс отмены")
      end

      def match_status_high(e)
        return nil unless e.method == "GET"
        return nil unless last_segment_is_param?(e.path)

        rule("status", :high, "GET, последний сегмент пути — параметр")
      end

      def match_balance_high(e)
        rules = @rules["balance"]
        return nil unless e.method == "GET"
        return nil if has_path_param?(e.path)
        return nil unless keyword_match?([e.path, e.operation_id] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("balance", :high, "GET без параметра пути, ключевое слово баланса")
      end

      def match_create_high(e)
        rules = @rules["create"]
        return nil unless e.method == "POST"
        return nil if has_path_param?(e.path)
        return nil unless keyword_match?([e.path] + e.tags, rules["path_keywords"] + rules["tag_keywords"])

        rule("create", :high, "POST без параметра пути, ключевое слово создания")
      end

      # запасные правила со средней уверенностью
      # применяются только после правил с высокой уверенностью
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

        rule("create", :medium, "POST без параметра пути, в теле есть поле суммы")
      end

      def match_balance_medium(e)
        return nil unless e.method == "GET"
        return nil if has_path_param?(e.path)

        ok_schema = e.responses[200]&.schema
        return nil unless ok_schema&.properties&.key?("balance")

        rule("balance", :medium, "GET без параметра пути, в ответе 200 есть balance")
      end

      def rule(role, confidence, description)
        { role: role.to_sym, confidence: confidence, matched_rule: description }
      end
    end
  end
end
