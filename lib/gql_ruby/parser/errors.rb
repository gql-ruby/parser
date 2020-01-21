require 'gql_ruby/utils'

module GqlRuby
  class Parser
    module Errors
      class IncorrectSource < StandardError; end

      class UnexpectedToken < StandardError
        extend Dry::Initializer
        include Dry::Equalizer(:token, :start)

        option :token
        option :start
        option :source
      end

      class SyntaxError < StandardError
        extend Dry::Initializer
        include Dry::Equalizer(:kind, :token, :start)

        option :kind
        option :token
        option :start
        option :source

        def message
          "Syntax error. Got token #{token} instead of #{kind} at position #{start.line + 1}:#{start.col + 1}"
        end

        alias :to_s :message
      end
    end
  end
end
