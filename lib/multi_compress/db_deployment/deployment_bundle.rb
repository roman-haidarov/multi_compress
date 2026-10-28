# frozen_string_literal: true

require "multi_compress/db_deployment/bundle_stager"
require "multi_compress/db_deployment/bundle_metadata"
require "multi_compress/db_deployment/bundle_archiver"

module MultiCompress
  module DBDeployment
    class DeploymentBundle
      attr_reader :target, :output, :force, :root_name
      private :target, :output, :force, :root_name

      DEFAULT_ARCHIVE_EPOCH = 315_619_200

      TARGETS = {
        "postgres" => {
          source_paths: %w[
            db_core
            postgres_extension
            ext/multi_compress/vendor/zstd
            docs/database-envelope-v1.md
            docs/database-envelope-v2.md
            docs/rfcs/0002-mcdb2-dictionaries.md
            LICENSE.txt
            THIRD_PARTY_NOTICES.md
          ],
          template_path: "db_deployment/postgres"
        },
        "mysql" => {
          source_paths: %w[
            db_core
            mysql_udf
            ext/multi_compress/vendor/zstd
            docs/database-envelope-v1.md
            docs/database-envelope-v2.md
            docs/rfcs/0002-mcdb2-dictionaries.md
            LICENSE.txt
            THIRD_PARTY_NOTICES.md
          ],
          template_path: "db_deployment/mysql"
        }
      }.freeze

      def initialize(target, output, force:)
        @target = target
        @output = File.expand_path(output)
        @force = force
        @root_name = "multi_compress-#{target}-#{MultiCompress::VERSION}"
      end

      def write!
        validate_sources!
        validate_output!
        Dir.mktmpdir("multi-compress-db-package") { |directory| build_bundle(directory) }
      end

      private

      def validate_sources!
        return if File.directory?(ROOT)

        raise Error, "deployment sources are unavailable from #{ROOT}"
      end

      def validate_output!
        return unless File.exist?(output) && !force

        raise Error, "#{output} already exists (use --force to overwrite)"
      end

      def build_bundle(directory)
        bundle_root = File.join(directory, root_name)
        FileUtils.mkdir_p(bundle_root)
        BundleStager.new(ROOT, TARGETS.fetch(target)).stage!(bundle_root)
        BundleMetadata.new(target).write!(bundle_root)
        BundleArchiver.new(output, root_name).write!(directory)
      end
    end
  end
end
