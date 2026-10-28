# frozen_string_literal: true

module MultiCompress
  module Database
    ENGINE = Engine.new
    private_constant :ENGINE

    module_function

    def compress(text, dictionary: nil)
      ENGINE.compress(text, dictionary: dictionary)
    end

    def compress_v1(text)
      ENGINE.compress_v1(text)
    end

    def compress_v2(text, dictionary:)
      ENGINE.compress_v2(text, dictionary: dictionary)
    end

    def decompress(blob, dictionary: nil)
      ENGINE.decompress(blob, dictionary: dictionary)
    end

    def valid?(blob, dictionary: nil)
      ENGINE.valid?(blob, dictionary: dictionary)
    end

    def dictionary_ref(blob)
      ENGINE.dictionary_ref(blob)
    end

    def original_size(blob)
      ENGINE.original_size(blob)
    end

    def version_string
      ENGINE.version_string
    end
  end
end
