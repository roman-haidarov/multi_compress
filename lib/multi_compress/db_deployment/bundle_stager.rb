# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    class BundleStager
      attr_reader :root, :target
      private :root, :target

      IGNORED_ENTRIES = [".DS_Store", ".git", "build", "test"].freeze

      def initialize(root, target)
        @root = root
        @target = target
      end

      def stage!(bundle_root)
        target.fetch(:source_paths).each { |relative| copy_path!(relative, bundle_root) }
        stage_template(bundle_root)
      end

      private

      def stage_template(bundle_root)
        template = target.fetch(:template_path)
        Dir.children(File.join(root, template)).sort.each do |entry|
          next if ignored?(entry)

          copy_path!(File.join(template, entry), bundle_root, destination: entry)
        end
      end

      def copy_path!(relative, bundle_root, destination: relative)
        source = File.join(root, relative)
        raise Error, "package source is missing: #{relative}" unless File.exist?(source)

        destination_path = File.join(bundle_root, destination)
        return copy_directory(source, relative, destination_path, destination, bundle_root) if File.directory?(source)

        copy_file(source, destination_path)
      end

      def copy_directory(source, relative, destination_path, destination, bundle_root)
        FileUtils.mkdir_p(destination_path)
        Dir.children(source).sort.each do |entry|
          next if ignored?(entry)

          copy_path!(File.join(relative, entry), bundle_root, destination: File.join(destination, entry))
        end
      end

      def copy_file(source, destination)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.copy_file(source, destination)
        File.chmod(File.stat(source).mode & 0o777, destination)
      end

      def ignored?(entry)
        IGNORED_ENTRIES.include?(entry)
      end
    end
  end
end
