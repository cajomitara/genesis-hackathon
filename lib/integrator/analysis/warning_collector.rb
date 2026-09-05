require_relative "models"

module Integrator
  module Analysis
    # Accumulates Warning records across every analyzer. Never raises, never
    # drops a record — the whole point is that "couldn't decide" is always
    # visible, both in the CLI's stdout and in the generated INTEGRATION.md,
    # instead of failing the run or being silently skipped.
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
