# frozen_string_literal: true

module MultiCompress
  class Reader
    BUFFER_COMPACT_THRESHOLD = 64 * 1024

    module BufferOperations
      private

      def buffer_size
        @buffer.bytesize - @buffer_pos
      end

      def buffer_empty?
        @buffer_pos >= @buffer.bytesize
      end

      def buffer_append(data)
        compact_buffer_if_needed
        @buffer << data
      end

      def compact_buffer_if_needed
        return if @buffer_pos.zero?

        total = @buffer.bytesize
        return unless @buffer_pos >= BUFFER_COMPACT_THRESHOLD && @buffer_pos * 2 >= total

        @buffer = @buffer.byteslice(@buffer_pos, total - @buffer_pos)
        @buffer_pos = 0
      end

      def buffer_includes?(separator)
        idx = @buffer.index(separator, @buffer_pos)
        !idx.nil?
      end

      def extract_line(separator)
        idx = @buffer.index(separator, @buffer_pos)
        end_pos = idx + separator.bytesize
        result = @buffer.byteslice(@buffer_pos, end_pos - @buffer_pos)
        @buffer_pos = end_pos
        compact_buffer_if_needed
        result
      end

      def consume_buffer
        result = @buffer.byteslice(@buffer_pos, @buffer.bytesize - @buffer_pos) || +"".b
        @buffer.clear
        @buffer_pos = 0
        result
      end
    end

    private_constant :BufferOperations
  end
end
