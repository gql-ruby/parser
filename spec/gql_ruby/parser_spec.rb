# frozen_string_literal: true

RSpec.describe GqlRuby::Parser do
  it 'has a version number' do
    expect(GqlRuby::Parser::VERSION).not_to be nil
  end

  context '#parse' do
    let(:parser) { described_class.new(source) }
    subject { -> { parser.parse } }

    context 'source checks' do
      context 'nil source' do
        let(:source) { nil }

        it { is_expected.to raise_exception(described_class::IncorrectSource) }
      end

      context 'wrong class source' do
        let(:source) { {} }

        it { is_expected.to raise_exception(described_class::IncorrectSource) }
      end

      context 'error formatting' do
        let(:source) { '{' }
        let(:error) do
          described_class::SyntaxError.new(
            start: GqlRuby::SourcePosition.new(1, 0, 1),
            source: source,
            token: parser.tokens_config[:eof],
            kind: parser.tokens_config[:name_class]
          )
        end

        it 'should raise proper error' do
          expect(subject).to raise_exception(error)
        end

        xit 'should render full error message' do
          exception = GqlRuby::Utils.dedent(<<-GQL
            Syntax Error: Expected token GqlRuby::Lexer::Token::Name, got token eof

            Source:1:2
            1 | {
              |  ^
          GQL
        )
          expect(error.with_source).to eq(exception)
        end
      end

      context 'syntax errors' do
        context 'fragment missing on' do
          let(:source) { '{ ...MissingOn } fragment MissingOn Type' }
          let(:error) do
            described_class::SyntaxError.new(
              start: GqlRuby::SourcePosition.new(36, 0, 36),
              source: source,
              token: parser.tokens_config[:name_class].new('Type'),
              kind: 'on'
            )
          end

          it { is_expected.to raise_exception(error) }
        end

        context 'field missing selection set' do
          let(:source) { '{ field: {} }' }
          let(:error) do
            described_class::SyntaxError.new(
              start: GqlRuby::SourcePosition.new(9, 0, 9),
              source: source,
              token: parser.tokens_config[:curly_open],
              kind: parser.tokens_config[:name_class]
            )
          end

          it { is_expected.to raise_exception(error) }
        end

        context 'wrong operation keyword' do
          let(:source) { 'notAnOperation Foo { field }' }
          let(:error) do
            described_class::UnexpectedToken.new(
              start: GqlRuby::SourcePosition.new(0, 0, 0),
              source: source,
              token: parser.tokens_config[:name_class].new('notAnOperation'),
            )
          end

          it { is_expected.to raise_exception(error) }
        end

        context 'unexpected spread' do
          let(:source) { '...' }
          let(:error) do
            described_class::UnexpectedToken.new(
              start: GqlRuby::SourcePosition.new(0, 0, 0),
              source: source,
              token: parser.tokens_config[:ellipsis]
            )
          end

          it { is_expected.to raise_exception(error) }
        end

        context 'unexpected String' do
          let(:source) { '{ ""' }
          let(:error) do
            described_class::SyntaxError.new(
              start: GqlRuby::SourcePosition.new(2, 0, 2),
              source: source,
              token: parser.tokens_config[:scalar_class].new(""),
              kind: parser.tokens_config[:name_class]
            )
          end

          it { is_expected.to raise_exception(error) }
        end
      end
    end

    context 'correct source' do
      context 'variable inline values' do
        let(:source) { '{ field(complex: { a: { b: [ $var ] } }) }' }

        it { is_expected.not_to raise_exception }
      end

      context 'variable definition directives' do
        let(:source) { 'query Foo($x: Boolean = false @bar) { field }' }

        it { is_expected.not_to raise_exception }
      end

      context 'does not allow to name fragment `on`' do
        let(:source) { 'fragment on on on { on }' }
        let(:error) do
          described_class::UnexpectedToken.new(
            token: parser.tokens_config[:name_class].new('on'),
            start: GqlRuby::SourcePosition.new(9, 0, 9),
            source: source
          )
        end

        it { is_expected.to raise_exception(error) }
      end

      context 'does not accept fragments spread of `on`' do
        let(:source) { '{ ...on }'}
        let(:error) do
          described_class::SyntaxError.new(
            start: GqlRuby::SourcePosition.new(8, 0, 8),
            token: parser.tokens_config[:curly_close],
            kind: parser.tokens_config[:name_class],
            source: source
          )
        end

        it { is_expected.to raise_exception(error) }
      end

      context 'parses multi-byte characters' do
        let(:source) do
          <<-GQL
          # This comment has a \u0A0A multi-byte character.
          { field(arg: "Has a \u0A0A multi-byte character.") }
          GQL
        end
        let(:string) { "Has a \u0A0A multi-byte character." }

        it do
          path = subject.call.to_h[:definitions][0][:selection_set][:selections][0][:arguments][0][:value][:value]
          expect(path).to eq(string)
        end
      end

      context 'it parses kitchen sink' do
        let(:source) do
          # TODO: Replace string with block in fixture when it will be supported by lexer
          File.read('spec/fixtures/kitchen_sink.gql')
        end

        it { is_expected.not_to raise_exception }
      end

      context 'allows non-keywords anywhere a Name is allowed' do
        %w(on fragment query mutation subscription true false).each do |keyword|
          let(:fragment_name) { keyword != 'on' ? keyword : 'a' }
          let(:source) do
            <<-GQL
              query #{keyword} {
                ... #{fragment_name}
                ... on #{keyword} { field }
              }
              fragment #{fragment_name} on Type {
                #{keyword}(#{keyword}: $#{keyword})
                  @#{keyword}(#{keyword}: #{keyword})
              }
            GQL
          end

          it "#{keyword}" do
            is_expected.not_to raise_exception
          end
        end
      end

      context 'parses anonymous mutation operations' do
        let(:source) { 'mutation { mutationField }'}

        it { is_expected.not_to raise_exception }
      end

      context 'parses anonymous subscription operations' do
        let(:source) { 'subscription { subscriptionField }'}

        it { is_expected.not_to raise_exception }
      end

      context 'parses named mutation operations' do
        let(:source) { 'mutation Foo { mutationField }'}

        it { is_expected.not_to raise_exception }
      end

      context 'parses named subscription operations' do
        let(:source) { 'subscription Foo { subscriptionField }'}

        it { is_expected.not_to raise_exception }
      end

      context 'creates AST' do
        let(:source) { '{ node(id: 4) { id, name } }'}
        let(:hash) do
          {
            kind: 'Document',
            definitions: [
              {
                kind: 'OperationDefinition',
                name: nil,
                operation: 'query',
                directives: [],
                selection_set: {
                  kind: 'SelectionSet',
                  selections: [{
                    kind: 'Field',
                    name: { kind: 'Name', value: 'node' },
                    arguments: [
                      {
                        kind: 'Argument',
                        name: { kind: 'Name', value: 'id' },
                        value: { kind: 'IntValue', value: 4 }
                      }
                    ],
                    directives: [],
                    alias: nil,
                    selection_set: {
                      kind: 'SelectionSet',
                      selections: [
                        {
                          kind: 'Field',
                          name: { kind: 'Name', value: 'id' },
                          arguments: [],
                          directives: [],
                          alias: nil,
                          selection_set: nil
                        },
                        {
                          kind: 'Field',
                          name: { kind: 'Name', value: 'name' },
                          arguments: [],
                          directives: [],
                          alias: nil,
                          selection_set: nil
                        }
                      ]
                    }
                  }]
                },
                variable_definitions: []
              }
            ]
          }
        end

        it do
          expect(subject.call.to_h).to eq(hash)
        end
      end

      context 'creates ast from nameless query without variables' do
        let(:source) { 'query { node { id } }' }
        let(:hash) do
          {
            kind: 'Document',
            definitions: [
              {
                kind: 'OperationDefinition',
                name: nil,
                operation: 'query',
                directives: [],
                selection_set: {
                  kind: 'SelectionSet',
                  selections: [{
                    kind: 'Field',
                    name: { kind: 'Name', value: 'node' },
                    arguments: [],
                    directives: [],
                    alias: nil,
                    selection_set: {
                      kind: 'SelectionSet',
                      selections: [
                        {
                          kind: 'Field',
                          name: { kind: 'Name', value: 'id' },
                          arguments: [],
                          directives: [],
                          alias: nil,
                          selection_set: nil
                        }
                      ]
                    }
                  }]
                },
                variable_definitions: []
              }
            ]
          }
        end

        it do
          expect(subject.call.to_h).to eq(hash)
        end
      end
    end
  end

  context '#parse_value' do
    subject { described_class.parse_value(source).to_h }

    context 'parses null value' do
      let(:source) { 'null' }
      let(:ast) { { kind: 'NullValue' } }

      it { should eq(ast) }
    end

    context 'parses list values' do
      let(:source) { '[123 "abc"]' }
      let(:ast) do
        {
          kind: 'ListValue',
          values: [
            { kind: 'IntValue', value: 123 },
            { kind: 'StringValue', value: 'abc' }
          ]
        }
      end

      it { should eq(ast) }
    end

    context 'parses block string' do
      let(:source) { '["""long""" "short"]' }
      let(:ast) do
        {
          kind: 'ListValue',
          values: [
            { kind: 'StringValue', value: 'long' },
            { kind: 'StringValue', value: 'short' }
          ]
        }
      end

      xit { should eq(ast) }
    end
  end

  context '#parse_type' do
    subject { described_class.parse_type(source).to_h }

    context 'parses well known types' do
      let(:source) { 'String' }
      let(:ast) do
        {
          kind: 'NamedType',
          name: { kind: 'Name', value: 'String' }
        }
      end

      it { should eq(ast) }
    end

    context 'parses custom types' do
      let(:source) { 'MyType' }
      let(:ast) do
        {
          kind: 'NamedType',
          name: { kind: 'Name', value: 'MyType' }
        }
      end

      it { should eq(ast) }
    end

    context 'parses list types' do
      let(:source) { '[MyType]' }
      let(:ast) do
        {
          kind: 'ListType',
          type: {
            kind: 'NamedType',
            name: { kind: 'Name', value: 'MyType' }
          }
        }
      end

      it { should eq(ast) }
    end

    context 'parses non-null types' do
      let(:source) { 'MyType!' }
      let(:ast) do
        {
          kind: 'NonNullType',
          type: {
            kind: 'NamedType',
            name: { kind: 'Name', value: 'MyType' }
          }
        }
      end

      it { should eq(ast) }
    end

    context 'parses nested types' do
      let(:source) { '[MyType!]' }
      let(:ast) do
        {
          kind: 'ListType',
          type: {
            kind: 'NonNullType',
            type: {
              kind: 'NamedType',
              name: { kind: 'Name', value: 'MyType' }
            }
          }
        }
      end

      it { should eq(ast) }
    end
  end
end
