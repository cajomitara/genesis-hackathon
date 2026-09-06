module Integrator
  module Spec
    # разворачивает локальные $ref в обычное дерево hash/array без ссылок
    class RefResolver
      # возникает только при ссылке, которую нельзя разрешить
      # циклические ссылки обрабатываются отдельно
      class UnresolvableRefError < StandardError; end

      def initialize(document)
        @document = document
      end

      # возвращает копию node с разрешёнными локальными $ref
      # path_stack используется для обнаружения циклов
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

        # при циклической ссылке останавливаем разворачивание и оставляем маркер
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

      # экранирование json pointer
      def unescape_pointer_segment(segment)
        segment.gsub("~1", "/").gsub("~0", "~")
      end
    end
  end
end
