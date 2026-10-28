# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    module ReadableViewOptions
      private

      def load_options(options)
        load_source_options(options)
        load_dictionary_options(options)
      end

      def load_source_options(options)
        @table = qualified_identifier!(options.fetch(:table), "--table")
        @view = qualified_identifier!(options.fetch(:view), "--view")
        @column = identifier!(options.fetch(:column), "--column")
        @columns = Array(options.fetch(:columns)).reject(&:empty?).map { |value| identifier!(value, "--columns") }
        @decoded_name = identifier!(options.fetch(:as), "--as")
        @extension_schema = identifier!(options.fetch(:extension_schema, "multi_compress"), "--extension-schema")
      end

      def load_dictionary_options(options)
        @dictionary_table = qualified_identifier!(options.fetch(:dictionary_table), "--dictionary-table") if
          options[:dictionary_table]
        @dictionary_id_column = optional_identifier(options, :dictionary_id_column, "--dictionary-id-column")
        @registry_id_column = identifier!(options.fetch(:registry_id_column, "id"), "--registry-id-column")
        @dictionary_sha256_column = identifier!(options.fetch(:dictionary_sha256_column, "sha256"),
                                                "--dictionary-sha256-column")
        @dictionary_bytes_column = identifier!(options.fetch(:dictionary_bytes_column, "bytes"),
                                               "--dictionary-bytes-column")
      end

      def validate_options!
        validate_dictionary_options!
        validate_columns!
      end

      def validate_dictionary_options!
        return if dictionary_table.nil? == dictionary_id_column.nil?

        raise Error, "--dictionary-table and --dictionary-id-column must be used together for MCDB2"
      end

      def validate_columns!
        raise Error, "--columns must contain at least one plain column" if columns.empty?
        raise Error, "--columns must not contain duplicate names" unless columns.uniq.length == columns.length
        raise Error, "--as must not duplicate a selected column" if columns.include?(decoded_name)
      end
    end
  end
end
