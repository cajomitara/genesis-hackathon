require_relative "models"

module Integrator
  module Analysis
    # собирает предупреждения всех анализаторов
    class WarningCollector
      def initialize
        @warnings = []
      end

      def add(stage:, subject:, reason:)
        @warnings << Warning.new(stage: stage, subject: subject, reason: reason)
      end

      def to_a
        @warnings.dup
      end

      def empty?
        @warnings.empty?
      end

      def each(&block)
        @warnings.each(&block)
      end
    end
  end
end
