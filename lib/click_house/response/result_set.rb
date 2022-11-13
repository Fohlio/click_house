# frozen_string_literal: true

module ClickHouse
  module Response
    class ResultSet
      extend Forwardable
      include Enumerable

      PLACEHOLDER_D = '%d'
      PLACEHOLDER_S = '%s'

      def_delegators :to_a,
                     :inspect, :each, :fetch, :length, :count, :size,
                     :first, :last, :[], :to_h

      attr_reader :meta, :data, :totals, :statistics, :rows_before_limit_at_least

      # @param meta [Array]
      # @param data [Array]
      # @param totals [Array|Hash|NilClass] Support for 'GROUP BY WITH TOTALS' modifier
      #   https://clickhouse.tech/docs/en/sql-reference/statements/select/group-by/#with-totals-modifier
      #   Hash in JSON format and Array in JSONCompact
      def initialize(meta:, data:, totals: nil, statistics: nil, rows_before_limit_at_least: nil)
        @meta = meta
        @data = data
        @totals = totals
        @rows_before_limit_at_least = rows_before_limit_at_least
        @statistics = Hash(statistics)
      end

      def to_a
        @to_a ||= data.each do |row|
          row.each do |name, value|
            row[name] = cast_type(types.fetch(name), value)
          end
        end
      end

      # @return [Hash<String, Ast::Statement>]
      def types
        @types ||= meta.each_with_object({}) do |row, object|
          object[row.fetch('name')] = begin
            current = Ast::Parser.new(row.fetch('type')).parse
            assign_type(current)
            current
          end
        end
      end

      private

      # @param stmt [Ast::Statement]
      def assign_type(stmt)
        stmt.caster = ClickHouse.types[stmt.name]

        if stmt.caster.is_a?(Type::UndefinedType)
          placeholders = stmt.arguments.map(&:placeholder)
          stmt.caster = ClickHouse.types["#{stmt.name}(#{placeholders.join(', ')})"]
        end

        stmt.arguments.each(&method(:assign_type))
      end

      # @param stmt [Ast::Statement]
      def cast_type(stmt, value)
        return cast_container(stmt, value) if stmt.caster.container?
        return cast_map(stmt, Hash(value)) if stmt.caster.map?
        return cast_tuple(stmt, Array(value)) if stmt.caster.tuple?

        stmt.caster.cast(value, *stmt.arguments.map(&:value))
      end

      # @return [Hash]
      # @param stmt [Ast::Statement]
      # @param hash [Hash]
      def cast_map(stmt, hash)
        raise ArgumentError, "expect hash got #{hash.class}" unless hash.is_a?(Hash)

        key_type, value_type = stmt.arguments
        hash.each_with_object({}) do |(key, value), object|
          object[cast_type(key_type, key)] = cast_type(value_type, value)
        end
      end

      # @param stmt [Ast::Statement]
      def cast_container(stmt, value)
        stmt.caster.cast_each(value) do |item|
          # TODO: raise an error if multiple arguments
          cast_type(stmt.arguments.first, item)
        end
      end

      # @param stmt [Ast::Statement]
      def cast_tuple(stmt, value)
        value.map.with_index do |item, ix|
          cast_type(stmt.arguments.fetch(ix), item)
        end
      end
    end
  end
end
