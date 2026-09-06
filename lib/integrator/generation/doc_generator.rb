require "erb"

module Integrator
  module Generation
    class DocGenerator
      TEMPLATE_PATH = File.join(__dir__, "templates", "integration.md.erb")

      def initialize(analysis)
        @analysis = analysis
        @provider_name = (@analysis.info[:title].to_s.split(/\s+/).first || @analysis.class_name)
      end

      def render
        template_source = File.read(TEMPLATE_PATH, encoding: Encoding::UTF_8)
        ERB.new(template_source, trim_mode: "-").result(binding)
      end

      def write(path)
        File.write(path, render)
      end

      private

      def auth_type_label(scheme)
        case scheme.type
        when "apiKey" then "API Key"
        when "http" then "HTTP #{scheme.http_scheme&.capitalize}"
        when "oauth2" then "OAuth 2.0"
        else scheme.type
        end
      end

      def action_label(action)
        {
          reject: "отклонить",
          retry: "повторить",
          retry_with_backoff: "повторить с задержкой",
          alert_and_block: "заблокировать провайдера",
          unresolved: "требует ручной проверки"
        }.fetch(action, action.to_s)
      end

      # одна строка на найденный эндпоинт
      # имя берётся из operationId и переводится в snake_case
      def method_rows
        [
          row_for(@analysis.create, "Создание операции", idempotency: @analysis.idempotency_header),
          row_for(@analysis.status, "Статус"),
          row_for(@analysis.cancel, "Отмена"),
          row_for(@analysis.callback, "Webhook", idempotency: @analysis.webhook_signature_header && "подпись в #{@analysis.webhook_signature_header}"),
          row_for(@analysis.balance, "Баланс провайдера")
        ].compact
      end

      def row_for(analysis_entry, default_purpose, idempotency: nil)
        return nil unless analysis_entry

        endpoint = analysis_entry.endpoint
        {
          name: method_name(endpoint),
          http: "#{endpoint.method} #{endpoint.path}",
          purpose: endpoint.summary || default_purpose,
          idempotency: idempotency || "-"
        }
      end

      def method_name(endpoint)
        return underscore(endpoint.operation_id) if endpoint.operation_id

        "#{endpoint.method.downcase}_#{endpoint.path.gsub(%r{[/{}]}, "_").squeeze("_")}"
      end

      def underscore(str)
        str.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
