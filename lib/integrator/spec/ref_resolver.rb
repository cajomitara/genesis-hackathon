module Integrator
  module Spec
    # разворачивает спецификацию, заменяя все ссылки на то, на что они ссылаются

    # Resolves every local `$ref` (`#/components/...`) in a raw, Psych-loaded
    # OpenAPI document into a plain nested Hash/Array tree with no `$ref`
    # nodes left. This is the only place in the codebase that understands
    # JSON Pointer syntax — everything downstream works with plain data.
    class RefResolver
      # Raised only for malformed input (a $ref the resolver cannot follow
      # at all, e.g. an external file reference). Circular references are
      # NOT errors — they're broken deliberately, see #resolve_ref.
      class UnresolvableRefError < StandardError; end

      def initialize(document)
        @document = document
      end

      # Returns a deep copy of `node` with every {"$ref" => "#/a/b/c"} replaced
      # by its resolved target. `path_stack` tracks the chain of refs already
      # being resolved on the current branch, to detect cycles.
      def resolve(node, path_stack = [])
        case node
        when Hash
          if node.key?("$ref") && node["$ref"].is_a?(String)
            resolve_ref(node["$ref"], path_stack)
          else
            node.each_with_object({}) { |(k, v), out| out[k] = resolve(v, path_stack) }
          end
        when Array
          node.map { |item| resolve(item, path_stack) }
        else
          node
        end
      end

      private

      def resolve_ref(ref, path_stack)
        raise UnresolvableRefError, "only local refs (#/...) are supported: #{ref}" unless ref.start_with?("#/")

        return { "_circular_ref" => ref } if path_stack.include?(ref)

        target = dig_pointer(ref)
        resolved = resolve(target, path_stack + [ref])
        resolved.is_a?(Hash) ? resolved.merge("_source_ref" => ref) : resolved
      end

      def dig_pointer(ref)
        segments = ref.sub("#/", "").split("/").map { |s| unescape_pointer_segment(s) }
        segments.reduce(@document) do |node, segment|
          unless node.is_a?(Hash) && node.key?(segment)
            raise UnresolvableRefError, "broken $ref: #{ref} (no key '#{segment}')"
          end

          node[segment]
        end
      end

      # JSON Pointer escaping: ~1 -> /, ~0 -> ~ (order matters: ~1 first)
      def unescape_pointer_segment(segment)
        segment.gsub("~1", "/").gsub("~0", "~")
      end
    end
  end
end
