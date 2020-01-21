module GqlRuby
  class Parser
    module Kinds
      # Name
      NAME = 'Name'

      # Document
      DOCUMENT = 'Document'
      OPERATION_DEFINITION = 'OperationDefinition'
      VARIABLE_DEFINITION = 'VariableDefinition'
      SELECTION_SET = 'SelectionSet'
      FIELD = 'Field'
      ARGUMENT = 'Argument'

      # Fragments
      FRAGMENT_SPREAD = 'FragmentSpread'
      FRAGMENT_DEFINITION = 'FragmentDefinition'
      INLINE_FRAGMENT = 'InlineFragment'

      # Values
      VARIABLE = 'Variable'
      INT = 'IntValue'
      FLOAT =  'FloatValue'
      STRING = 'StringValue'
      BOOLEAN = 'BooleanValue'
      NULL = 'NullValue'
      ENUM = 'EnumValue'
      LIST = 'ListValue'
      OBJECT = 'ObjectValue'
      OBJECT_FIELD = 'ObjectField'

      # Directives
      DIRECTIVE = 'Directive'

      # Types
      NAMED_TYPE = 'NamedType'
      LIST_TYPE = 'ListType'
      NON_NULL_TYPE = 'NonNullType'

      # Type System Definitions
      SCHEMA_DEFINITION = 'SchemaDefinition'
      OPERATION_TYPE_DEFINITION = 'OperationTypeDefinition'

      # Type Definitions
      SCALAR_TYPE_DEFINITION = 'ScalarTypeDefinition'
      OBJECT_TYPE_DEFINITION = 'ObjectTypeDefinition'
      FIELD_DEFINITION = 'FieldDefinition'
      INPUT_VALUE_DEFINITION = 'InputValueDefinition'
      INTERFACE_TYPE_DEFINITION = 'InterfaceTypeDefinition'
      UNION_TYPE_DEFINITION = 'UnionTypeDefinition'
      ENUM_TYPE_DEFINITION = 'EnumTypeDefinition'
      ENUM_VALUE_DEFINITION = 'EnumValueDefinition'
      INPUT_OBJECT_TYPE_DEFINITION = 'InputObjectTypeDefinition'

      # Directive Definitions
      DIRECTIVE_DEFINITION = 'DirectiveDefinition'

      # Type System Extensions

      # Type Extensions
    end
  end
end
