# frozen_string_literal: true

module MultiCompress
  class Reader
    module ReadOperations
      private

      def read_all
        return nil if @eof && buffer_empty?

        result = consume_buffer
        result = +"".b if result.empty?
        append_remaining_stream(result)
        result.empty? ? nil : result
      end

      def append_remaining_stream(result)
        until @eof
          chunk = read_compressed_chunk
          break unless chunk && !chunk.empty?

          decompressed = @inflater.write(chunk)
          result << decompressed if decompressed
        end

        final = @inflater.finish
        result << final if final && !final.empty?
      end

      def read_exactly(length)
        return nil if @eof && buffer_empty?

        fill_buffer_until { buffer_size >= length }
        return read_buffer_slice(length) if buffer_size >= length

        consume_buffer unless buffer_empty?
      end

      def read_buffer_slice(length)
        result = @buffer.byteslice(@buffer_pos, length)
        @buffer_pos += length
        compact_buffer_if_needed
        result
      end

      def fill_buffer_until
        until yield || @eof
          chunk = read_compressed_chunk
          if chunk.nil? || chunk.empty?
            @eof = true
            break
          end
          decompressed = @inflater.write(chunk)
          buffer_append(decompressed) if decompressed
        end
      end

      def read_compressed_chunk
        @io.read(CHUNK_SIZE)
      rescue EOFError
        nil
      end
    end

    private_constant :ReadOperations
  end
end
