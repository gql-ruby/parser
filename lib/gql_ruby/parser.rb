# frozen_string_literal: true

require 'gql_ruby/parser/version'
require 'gql_ruby/lexer'
require 'gql_ruby/iterator'
require 'gql_ruby/parser/ast_node'
require 'gql_ruby/parser/kinds'
require 'gql_ruby/parser/errors'
require 'dry/initializer'

require 'pry'

module GqlRuby
  class Parser
    extend Dry::Initializer
    include Dry::Monads[:maybe, :result, :try]
    include GqlRuby::Parser::Errors

    param :source
    option :lexer_class, default: -> { GqlRuby::Lexer }
    option :tokens_config, default: -> {
      {
        eof: GqlRuby::Lexer::Token::EOF,
        ellipsis: GqlRuby::Lexer::Token::ELLIPSIS,
        exclamation: GqlRuby::Lexer::Token::EXCLAMATION,
        dollar: GqlRuby::Lexer::Token::DOLLAR,
        paren_open: GqlRuby::Lexer::Token::PAREN_OPEN,
        paren_close: GqlRuby::Lexer::Token::PAREN_CLOSE,
        curly_open: GqlRuby::Lexer::Token::CURLY_OPEN,
        curly_close: GqlRuby::Lexer::Token::CURLY_CLOSE,
        bracket_open: GqlRuby::Lexer::Token::BRACKET_OPEN,
        bracket_close: GqlRuby::Lexer::Token::BRACKET_CLOSE,
        colon: GqlRuby::Lexer::Token::COLON,
        equals: GqlRuby::Lexer::Token::EQUALS,
        at: GqlRuby::Lexer::Token::AT,
        pipe: GqlRuby::Lexer::Token::PIPE,
        amp: GqlRuby::Lexer::Token::AMP,
        name_class: GqlRuby::Lexer::Token::Name,
        scalar_class: GqlRuby::Lexer::Token::Scalar
      }
    }

    DIRECTIVE_LOCATIONS = %w(
      QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION
      SCHEMA SCALAR OBJECT FIELD_DEFINITION ARGUMENT_DEFINITION INTERFACE UNION ENUM ENUM_VALUE INPUT_OBJECT
      INPUT_FIELD_DEFINITION
    )

    attr_reader :tokens_iterator, :lexer

    class << self
      def parse(source)
        new(source).parse
      end

      def parse_value(source)
        parser = new(source)
        parser.parse_tokens
        parser.parse_value_literal(false)
      end

      def parse_type(source)
        parser = new(source)
        parser.parse_tokens
        parser.parse_type_reference
      end
    end

    def parse_tokens
      tokens = []
      @lexer = lexer_class.new(source)
      while (token = lexer.next).to_result.success?
        tokens << token
      end
      @tokens_iterator = GqlRuby::Iterator.new(tokens.map(&:flatten).map(&:value!))
    end

    def parse
      raise IncorrectSource unless source.is_a?(String)

      parse_tokens
      parse_document
    end

    # Document: Definition+

    def parse_document
      definitions = []

      while Maybe(definition = parse_definition).to_result.success?
        definitions << definition
      end

      ASTNode.new(kind: Kinds::DOCUMENT, params: {
        definitions: definitions
      })
    end

    # Definition:
    # - ExecutableDefinition
    # - TypeSystemDefinition
    # - TypeSystemExtension
    #
    # ExecutableDefinition
    # - OperationDefinition
    # - FragmentDefinition

    def parse_definition
      return if (value = tokens_iterator.peek).to_result.failure?

      _, span = value.value!
      return if span.item == tokens_config[:eof]

      if span.item.is_a?(tokens_config[:name_class])
        case span.item.value
        when 'query', 'mutation', 'subscription' then return parse_operation_definition
        when 'fragment' then return parse_fragment_definition
        when 'schema', 'scalar', 'type', 'interface', 'union', 'enum', 'input', 'directive'
          return parse_type_system_definition
        when 'extend' then return parse_type_system_extension
        end
      elsif span.item == tokens_config[:curly_open]
        return parse_operation_definition
      elsif span.item.is_a?(tokens_config[:scalar_class]) && span.item.value.is_a?(Types::String)
        return parse_type_system_definition
      end

      raise UnexpectedToken.new(source: source, start: span.start, token: span.item)
    end

    # TypeSystemDefinition:
    # - SchemaDefinition
    # - TypeDefinition
    # - DirectiveDefinition
    #
    # TypeDefinition:
    # - ScalarTypeDefinition
    # - ObjectTypeDefinition
    # - InterfaceTypeDefinition
    # - UnionTypeDefinition
    # - EnumTypeDefinition
    # - InputObjectTypeDefinition

    def parse_type_system_definition
      _, keyword_span = (peek_description ? tokens_iterator.lookahead : tokens_iterator.peek).value!
      keyword_token = keyword_span.item
      return Failure() unless token_is?(keyword_token, tokens_config[:name_class])
      case keyword_token.value
      when 'schema' then parse_schema_definition
      when 'scalar' then parse_scalar_type_definition
      when 'type' then parse_object_type_definition
      when 'interface' then parse_interface_type_definition
      when 'union' then parse_union_type_definition
      when 'enum' then parse_enum_type_definition
      when 'input' then parse_input_object_type_definition
      when 'directive' then parse_directive_definition
      end
    end

    # ObjectTypeDefinition:
    #   Description?
    #   type Name ImplementsInterfaces? Directives[Const]? FieldsDefinition?

    def parse_object_type_definition
      description = parse_description
      expect_keyword('type')
      ASTNode.new(kind: Kinds::OBJECT_TYPE_DEFINITION, params: {
        description: description,
        name: parse_name,
        interfaces: parse_implements_interfaces,
        directives: parse_directives(true),
        fields: parse_fields_definition
      })
    end

    # FragmentDefinition:
    # - fragment FragmentName on TypeCondition Directives? SelectionSet
    #
    # TypeCondition : NamedType

    def parse_fragment_definition
      expect_keyword('fragment')
      ASTNode.new(kind: Kinds::FRAGMENT_DEFINITION, params: {
        name: parse_fragment_name,
        type_condition: (expect_keyword('on') && parse_named_type),
        directives: parse_directives(false),
        selection_set: parse_selection_set
      })
    end

    # EnumTypeDefinition :
    # - Description? enum Name Directives[Const]? EnumValuesDefinition?
    def parse_enum_type_definition
      description = parse_description
      expect_keyword('enum')
      ASTNode.new(kind: Kinds::ENUM_TYPE_DEFINITION, params: {
        description: description,
        name: parse_name,
        directives: parse_directives(true),
        values: parse_enum_values_definition
      })
    end

    # EnumValuesDefinition : { EnumValueDefinition+ }

    def parse_enum_values_definition
      many(
        tokens_config[:curly_open],
        method(:parse_enum_value_definition),
        tokens_config[:curly_close]
      )
    end

    # EnumValueDefinition : Description? EnumValue Directives[Const]?
    # EnumValue : Name

    def parse_enum_value_definition
      ASTNode.new(kind: Kinds::ENUM_VALUE_DEFINITION, params: {
        description: parse_description,
        name: parse_name,
        directives: parse_directives(true)
      })
    end

    # OperationDefinition:
    # - SelectionSet
    # - OperationType Name? VariableDefinitions? Directives? SelectionSet

    def parse_operation_definition
      if current_token_is?(tokens_config[:curly_open])
        return ASTNode.new(kind: Kinds::OPERATION_DEFINITION, params: {
          operation: 'query',
          name: nil,
          variable_definitions: [],
          directives: [],
          selection_set: parse_selection_set
        })
      end
      operation = parse_operation_type
      name = parse_name if current_token_is?(tokens_config[:name_class])

      ASTNode.new(kind: Kinds::OPERATION_DEFINITION, params: {
        operation: operation,
        name: name,
        variable_definitions: parse_variable_definitions,
        directives: parse_directives(false),
        selection_set: parse_selection_set
      })
    end

    # SelectionSet: { Selection+ }

    def parse_selection_set
      ASTNode.new(
        kind: Kinds::SELECTION_SET,
        params: {
          selections: many(tokens_config[:curly_open], method(:parse_selection), tokens_config[:curly_close])
        }
      )
    end

    # Selection:
    # - Field
    # - FragmentSpread
    # - InlineFragment

    def parse_selection
      return parse_fragment if current_token_is?(tokens_config[:ellipsis])
      parse_field
    end

    # FragmentSpread : ... FragmentName Directives?
    # InlineFragment : ... TypeCondition? Directives? SelectionSet

    def parse_fragment
      start = current_token
      expect_token(tokens_config[:ellipsis])

      has_type_condition = expect_optional_keyword('on').success?
      if !has_type_condition && current_token_is?(tokens_config[:name_class])
        return ASTNode.new(kind: Kinds::FRAGMENT_SPREAD, params: {
          name: parse_fragment_name,
          directives: parse_directives(false)
        })
      end

      ASTNode.new(kind: Kinds::INLINE_FRAGMENT, params: {
        type_condition: has_type_condition ? parse_named_type : nil,
        directives: parse_directives(false),
        selection_set: parse_selection_set
      })

    end

    def parse_fragment_name
      if current_token_is?(tokens_config[:name_class]) && current_token.item.value == 'on'
        raise UnexpectedToken.new(
          token: current_token.item,
          start: current_token.start,
          source: source
        )
      end

      parse_name
    end

    # FieldsDefinition: { FieldDefinition+ }

    def parse_fields_definition
      optional_many(tokens_config[:curly_open], method(:parse_field_definition), tokens_config[:curly_close])
    end

    # FieldDefinition:
    # - Description? Name ArgumentsDefinition? : Type Directives[Const]?

    def parse_field_definition
      description = parse_description
      name = parse_name
      arguments = parse_arguments_definition
      expect_token(tokens_config[:colon])
      ASTNode.new(kind: Kinds::FIELD_DEFINITION, params: {
        description: description,
        name: name,
        arguments: arguments,
        type: parse_type_reference,
        directives: parse_directives(true)
      })
    end

    # ArgumentsDefinition : ( InputValueDefinition+ )

    def parse_arguments_definition
      optional_many(tokens_config[:paren_open], method(:parse_input_value_definition), tokens_config[:paren_close])
    end

    # Type:
    # - NamedType
    # - ListType
    # - NonNullType

    def parse_type_reference
      type = nil
      if expect_optional_token(tokens_config[:bracket_open]).success?
        type = parse_type_reference
        expect_token(tokens_config[:bracket_close])
        type = ASTNode.new(kind: Kinds::LIST_TYPE, params: { type: type })
      else
        type = parse_named_type
      end

      if expect_optional_token(tokens_config[:exclamation]).success?
        return ASTNode.new(kind: Kinds::NON_NULL_TYPE, params: { type: type })
      end

      type
    end

    # SchemaDefinition : schema Directives[Const]? { OperationTypeDefinition+ }
    def parse_schema_definition
      expect_keyword('schema')
      ASTNode.new(kind: Kinds::SCHEMA_DEFINITION, params: {
        directives: parse_directives(true),
        operation_types: many(
          tokens_config[:curly_open],
          method(:parse_operation_type_definition),
          tokens_config[:curly_close]
        )
      })
    end

    # OperationTypeDefinition : OperationType : NamedType
    def parse_operation_type_definition
      operation = parse_operation_type
      expect_token(tokens_config[:colon])
      type = parse_named_type
      ASTNode.new(kind: Kinds::OPERATION_TYPE_DEFINITION, params: {
        operation: operation,
        type: type
      })
    end

    # OperationType : one of query mutation subscription
    def parse_operation_type
      operation_token = expect_token(tokens_config[:name_class])
      case operation_token.fmap(&:value).to_maybe
      when Some("query") then 'query'
      when Some("mutation") then 'mutation'
      when Some("subscription") then 'subscription'
      end
    end

    # NamedType : Name

    def parse_named_type
      ASTNode.new(kind: Kinds::NAMED_TYPE, params: { name: parse_name })
    end

    # ScalarTypeDefinition : Description? scalar Name Directives[Const]?

    def parse_scalar_type_definition
      description = parse_description
      expect_keyword('scalar')
      ASTNode.new(kind: Kinds::SCALAR_TYPE_DEFINITION, params: {
        description: description,
        name: parse_name,
        directives: parse_directives(true)
      })
    end

    # InputValueDefinition :
    #   - Description? Name : Type DefaultValue? Directives[Const]?

    def parse_input_value_definition
      description = parse_description
      name = parse_name
      expect_token(tokens_config[:colon])
      type = parse_type_reference
      default_value = parse_value_literal(true) if expect_optional_token(tokens_config[:equals]).success?
      directives = parse_directives(true)
      ASTNode.new(kind: Kinds::INPUT_VALUE_DEFINITION, params: {
        description: description,
        name: name,
        type: type,
        default_value: default_value,
        directives: directives
      })
    end

    def parse_value_literal(is_const)
      token = current_token.item
      case
      when current_token_is?(tokens_config[:bracket_open]) then return parse_list(is_const)
      when current_token_is?(tokens_config[:curly_open]) then return parse_object(is_const)
      when current_token_is?(tokens_config[:scalar_class])
        case token.value
        when Integer
          tokens_iterator.next
          return ASTNode.new(kind: Kinds::INT, params: { value: token.value })
        when Float
          tokens_iterator.next
          return ASTNode.new(kind: Kinds::FLOAT, params: { value: token.value })
        when String
          return parse_string_literal
        end
      when current_token_is?(tokens_config[:name_class])
        case token.value
        when 'true', 'false'
          tokens_iterator.next
          return ASTNode.new(kind: Kinds::BOOLEAN, params: { value: token.value == 'true' })
        when 'null'
          tokens_iterator.next
          return ASTNode.new(kind: Kinds::NULL)
        else
          tokens_iterator.next
          return ASTNode.new(kind: Kinds::ENUM, params: { value: token.value })
        end
      when current_token_is?(tokens_config[:dollar])
        return parse_variable unless is_const
      end
    end

    # Field: Alias? Name Arguments? Directives? SelectionSet?
    # Alias: Name :

    def parse_field
      name_or_alias = parse_name
      name_alias = nil
      if expect_optional_token(tokens_config[:colon]).to_result.success?
        name_alias = name_or_alias
        name = parse_name
      else
        name = name_or_alias
      end

      ASTNode.new(kind: Kinds::FIELD, params: {
        alias: name_alias,
        name: name,
        arguments: parse_arguments(false),
        directives: parse_directives(false),
        selection_set: (parse_selection_set if current_token_is?(tokens_config[:curly_open])),
      })
    end

    # Directive[Const] : @ Name Arguments[?Const]?

    def parse_directive(is_const)
      expect_token(tokens_config[:at])
      ASTNode.new(kind: Kinds::DIRECTIVE, params: { name: parse_name, arguments: parse_arguments(is_const) })
    end

    # DirectiveDefinition :
    # - Description? directive @ Name ArgumentsDefinition? `repeatable`? on DirectiveLocations

    def parse_directive_definition
      description = parse_description
      expect_keyword('directive')
      expect_token(tokens_config[:at])
      name = parse_name
      arguments = parse_arguments_definition
      repeatable = expect_optional_keyword('repeatable').to_result.success?
      expect_keyword('on')
      locations = parse_directive_locations
      ASTNode.new(kind: Kinds::DIRECTIVE_DEFINITION, params: {
        description: description,
        name: name,
        arguments: arguments,
        repeatable: repeatable,
        locations: locations
      })
    end

    # DirectiveLocations :
    # - `|`? DirectiveLocation
    # - DirectiveLocations | DirectiveLocation

    def parse_directive_locations
      expect_optional_token(tokens_config[:pipe])
      locations = []
      loop do
        locations << parse_directive_location
        break unless expect_optional_token(tokens_config[:pipe]).to_result.success?
      end
      locations
    end

    # DirectiveLocation :
    # - ExecutableDirectiveLocation
    # - TypeSystemDirectiveLocation
    # ExecutableDirectiveLocation : QUERY | MUTATION | SUBSCRIPTION | FIELD | FRAGMENT_DEFINITION | FRAGMENT_SPREAD | INLINE_FRAGMENT
    # TypeSystemDirectiveLocation : SCHEMA | SCALAR | OBJECT | FIELD_DEFINITION | ARGUMENT_DEFINITION | INTERFACE | UNION | ENUM | ENUM_VALUE | INPUT_OBJECT | INPUT_FIELD_DEFINITION

    def parse_directive_location
      name = parse_name
      return name if DIRECTIVE_LOCATIONS.include?(name.value)
    end

    def parse_name
      token = expect_token(tokens_config[:name_class]).value!
      ASTNode.new(kind: Kinds::NAME, params: { value: token.value })
    end

    def parse_arguments(is_const)
      parse_fn = is_const ? :parse_const_argument : :parse_argument
      optional_many(tokens_config[:paren_open], method(parse_fn), tokens_config[:paren_close])
    end

    # Argument[Const] : Name : Value[?Const]

    def parse_argument
      name = parse_name
      expect_token(tokens_config[:colon])
      ASTNode.new(
        kind: Kinds::ARGUMENT,
        params: {
          name: name,
          value: parse_value_literal(false)
        }
      )
    end

    def parse_const_argument
      ASTNode.new(kind: Kinds::ARGUMENT, params: {
        name: parse_name,
        value: (expect_token(tokens_config[:colon]).to_result.success? && parse_value_literal(true))
      })
    end

    def parse_directives(is_const)
      directives = []
      while current_token_is?(tokens_config[:at])
        directives << parse_directive(is_const)
      end
      directives
    end

    def parse_description
      return parse_string_literal if peek_description
    end

    def parse_string_literal
      token = current_token.item
      tokens_iterator.next
      ASTNode.new(kind: Kinds::STRING, params: { value: token.value })
    end

    # ImplementsInterfaces:
    # - implements '&'? NamedType
    # - ImplementsInterfaces & NamedType

    def parse_implements_interfaces
      types = []
      return types unless expect_optional_keyword('implements').to_result.success?
      expect_optional_token(tokens_config[:amp])
      loop do
        types << parse_named_type
        break unless expect_optional_token(tokens_config[:amp]).to_result.success?
      end
      types
    end

    # InterfaceTypeDefinition :
    # - Description? interface Name Directives[Const]? FieldsDefinition?

    def parse_interface_type_definition
      description = parse_description
      expect_keyword('interface')
      ASTNode.new(kind: Kinds::INTERFACE_TYPE_DEFINITION, params: {
        description: description,
        name: parse_name,
        interfaces: parse_implements_interfaces,
        directives: parse_directives(true),
        fields: parse_fields_definition
      })
    end

    def parse_object(is_const)
      item = -> { parse_object_field(is_const) }
      ASTNode.new(
        kind: Kinds::OBJECT,
        params: {
          fields: any(tokens_config[:curly_open], item, tokens_config[:curly_close])
        }
      )
    end

    def parse_object_field(is_const)
      name = parse_name
      expect_token(tokens_config[:colon])
      ASTNode.new(
        kind: Kinds::OBJECT_FIELD,
        params: {
          name: name,
          value: parse_value_literal(is_const)
        }
      )
    end

    def parse_list(is_const)
      item = -> { parse_value_literal(is_const) }
      ASTNode.new(
        kind: Kinds::LIST,
        params: {
          values: any(tokens_config[:bracket_open], item, tokens_config[:bracket_close])
        }
      )
    end

    def parse_variable_definitions
      optional_many(tokens_config[:paren_open], method(:parse_variable_definition), tokens_config[:paren_close])
    end

    def parse_variable_definition
      ASTNode.new(kind: Kinds::VARIABLE_DEFINITION, params: {
        variable: parse_variable,
        type: expect_token(tokens_config[:colon]).to_result.success? && parse_type_reference,
        default_value: expect_optional_token(tokens_config[:equals]).to_result.success? ? parse_value_literal(true) : nil,
        directives: parse_directives(true)
      })
    end

    def parse_variable
      expect_token(tokens_config[:dollar])
      ASTNode.new(
        kind: Kinds::VARIABLE,
        params: {
          name: parse_name
        }
      )
    end

    private

    def peek_description
      token = current_token.item
      return token_is?(token, tokens_config[:scalar_class]) && token.value.is_a?(Types::String)
    end

    def expect_token(kind)
      span = current_token
      token = span.item
      return tokens_iterator.next && Success(token) if token_is?(token, kind)

      raise SyntaxError.new(
        source: source,
        start: span.start,
        token: token,
        kind: kind
      )
    end

    def expect_keyword(value)
      token = current_token.item
      return Success(tokens_iterator.next) if token_is?(token, tokens_config[:name_class]) && token.value == value

      raise SyntaxError.new(source: source, kind: value, token: token, start: current_token.start)
    end

    def expect_optional_keyword(value)
      token = current_token.item
      if current_token_is?(tokens_config[:name_class]) && token.value == value
        tokens_iterator.next
        return Success()
      end
      Failure()
    end

    def expect_optional_token(kind)
      token = current_token
      return None() unless current_token_is?(kind)

      tokens_iterator.next
      Some(token)
    end

    def any(open, parse_method, close)
      expect_token(open)
      nodes = []
      while expect_optional_token(close).to_result.failure? do
        nodes << parse_method.()
      end
      nodes
    end

    def many(open, parse_method, close)
      expect_token(open)
      nodes = []
      loop do
        nodes << parse_method.()
        break if expect_optional_token(close).to_result.success?
      end
      nodes
    end

    def optional_many(open, parse_method, close)
      nodes = []
      return nodes unless expect_optional_token(open).to_result.success?

      loop do
        nodes << parse_method.()
        break if expect_optional_token(close).to_result.success?
      end
      nodes
    end

    def current_token_is?(kind)
      token_is?(current_token.item, kind)
    end

    def token_is?(token, kind)
      return token.is_a?(kind) if kind.class == Class
      token == kind
    end

    def current_token
      _, span = tokens_iterator.peek.value!
      span
    end
  end
end
