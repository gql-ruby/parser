require 'dry/initializer'
require 'dry/equalizer'

module GqlRuby
  class Parser
    class ASTNode
      extend Dry::Initializer
      include Dry::Equalizer(:kind, :params)

      option :kind, default: -> { Kinds::Name }
      option :params, default: -> { {} }

      def method_missing(name, *args, &block)
        return params[name] if params.keys.include?(name)

        super
      end

      def to_h
        { kind: kind }.merge(params).transform_values do |v|
          case v
          when ASTNode then v.to_h
          when Array then v.map(&:to_h)
          else v
          end
        end
      end
    end
  end
end
