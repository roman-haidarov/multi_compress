# frozen_string_literal: true

module MultiCompress
  module StreamIO
    module_function

    def resolve_io(path_or_io, algo, mode:)
      return [path_or_io, algo, false] unless path_or_io.is_a?(String)

      [File.open(path_or_io, mode), algo || MultiCompress.algo_from_ext(path_or_io), true]
    end
  end
end
