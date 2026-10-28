# frozen_string_literal: true

require "multi_compress/version"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "rubygems/package"
require "securerandom"
require "tmpdir"
require "zlib"

module MultiCompress
  module DBDeployment
    ROOT = File.expand_path("../..", __dir__)
    FORMAT = "MCDB1 + MCDB2"
    BUNDLE_FORMAT_VERSION = 2
    MAX_DICTIONARY_BYTES = 256 * 1024

    class Error < StandardError; end

    require "multi_compress/db_deployment/sql_identifiers"
    require "multi_compress/db_deployment/commands"
    require "multi_compress/db_deployment/dictionary_registry"
    require "multi_compress/db_deployment/readable_view_options"
    require "multi_compress/db_deployment/readable_view"
    require "multi_compress/db_deployment/deterministic_tar_writer"
    require "multi_compress/db_deployment/bundle_stager"
    require "multi_compress/db_deployment/bundle_metadata"
    require "multi_compress/db_deployment/bundle_archiver"
    require "multi_compress/db_deployment/deployment_bundle"
  end
end
