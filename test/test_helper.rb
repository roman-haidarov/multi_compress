# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/multi_compress"

module MultiCompressTestSupport
  module_function

  def async_available?
    return @async_available if defined?(@async_available)

    @async_available =
      if Fiber.respond_to?(:scheduler)
        require "async"
        require "async/barrier"
        true
      else
        false
      end
  rescue LoadError
    @async_available = false
  end
end
