# frozen_string_literal: true

require "erb"

module Integrator
  module Generation
    # рендерит шаблон сервиса по результату анализа
    # шаблон не содержит логики, специфичной для провайдера
    class ServiceGenerator
      TEMPLATE_PATH = File.join(__dir__, "templates", "service.rb.erb")

      def initialize(analysis)
        @analysis = analysis
      end

      def render
        template_source = File.read(TEMPLATE_PATH, encoding: Encoding::UTF_8)
        ERB.new(template_source, trim_mode: "-").result(binding)
      end

      def write(path)
        File.write(path, render)
      end

      private

      # заменяет параметры пути на operation.provider_operation_id
      def substitute_operation_id(path)
        path.gsub(/\{[^}]+\}/, '#{operation.provider_operation_id}')
      end

      def default_currency
        return nil unless @analysis.create && @analysis.field_mapping.currency_field

        schema = @analysis.create.endpoint.request_schema.properties[@analysis.field_mapping.currency_field]
        schema&.enum&.first
      end

      def amount_expression
        case @analysis.field_mapping.amount_unit
        when :minor then "(operation.amount * 100).to_i"
        when :major then "operation.amount"
        else "operation.amount"
        end
      end

      def amount_unit_unresolved?
        @analysis.field_mapping.amount_unit == :unresolved
      end

      def currency_expression
        default_currency ? "'#{default_currency}'" : "operation.currency"
      end

      def action_snippet(canonical)
        case canonical
        when :approved then "approve_operation(payload['payout_id'])"
        when :rejected then "reject_operation(payload['payout_id'], payload.dig('error', 'code'))"
        when :in_progress then "success # операция остаётся в процессе"
        else "failure(:unprocessable_entity, 'unhandled_status') # todo: событие не сопоставлено со статусом"
        end
      end
    end
  end
end
