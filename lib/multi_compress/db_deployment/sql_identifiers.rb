# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    module SqlIdentifiers
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      private

      def identifier!(value, option)
        string = value.to_s
        return string if IDENTIFIER.match?(string)

        raise Error, "#{option} must use letters, digits and underscores and cannot start with a digit"
      end

      def optional_identifier(options, key, label)
        identifier!(options.fetch(key), label) if options.key?(key) && options[key]
      end

      def qualified_identifier!(value, option)
        pieces = value.to_s.split(".", -1)
        return pieces if pieces.length.between?(1, 2) && pieces.all? { |piece| IDENTIFIER.match?(piece) }

        raise Error, "#{option} must be NAME or SCHEMA.NAME using letters, digits and underscores"
      end

      def pg_quote(identifier)
        %("#{identifier}")
      end

      def mysql_quote(identifier)
        "`#{identifier}`"
      end

      def pg_qualified(pieces)
        pieces.map { |piece| pg_quote(piece) }.join(".")
      end

      def mysql_qualified(pieces)
        pieces.map { |piece| mysql_quote(piece) }.join(".")
      end
    end
  end
end
