# frozen_string_literal: true

require "multi_compress/codec"

begin
  require "active_model/type"
rescue LoadError => e
  raise LoadError, "multi_compress/active_record requires activemodel (#{e.message}). " \
                   "Add activerecord/activemodel to your bundle, or use MultiCompress::Codec directly."
end

module MultiCompress
  module ActiveRecordSupport
    class Type < ActiveModel::Type::Value
      def initialize(mutable: false, **codec_opts)
        @codec   = MultiCompress::Codec.new(**codec_opts)
        @mutable = mutable
        super()
      end

      def type
        :multi_compress
      end

      # user assignment -> in-memory value (no compression here)
      def cast(value)
        value
      end

      # DB -> in-memory (unwrap)
      def deserialize(value)
        @codec.load(value)
      end

      # in-memory -> DB (compress)
      def serialize(value)
        @codec.dump(value)
      end

      def changed_in_place?(raw_old_value, new_value)
        return false unless @mutable

        deserialize(raw_old_value) != new_value
      end
    end

    class Coder
      def initialize(**codec_opts)
        @codec = MultiCompress::Codec.new(**codec_opts)
      end

      def dump(value)
        @codec.dump(value)
      end

      def load(value)
        @codec.load(value)
      end
    end
  end
end
