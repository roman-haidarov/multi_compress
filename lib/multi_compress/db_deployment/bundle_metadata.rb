# frozen_string_literal: true

module MultiCompress
  module DBDeployment
    class BundleMetadata
      attr_reader :target
      private :target

      def initialize(target)
        @target = target
      end

      def write!(bundle_root)
        write_manifest(bundle_root, manifest_files(bundle_root))
        write_checksums(bundle_root)
      end

      private

      def manifest_files(root)
        regular_files(root).reject { |path| %w[manifest.json SHA256SUMS].include?(File.basename(path)) }
                           .sort.map { |path| file_record(root, path) }
      end

      def file_record(root, path)
        { "path" => relative_to(root, path), "sha256" => Digest::SHA256.file(path).hexdigest }
      end

      def write_manifest(root, files)
        manifest = {
          "bundle_format_version" => BUNDLE_FORMAT_VERSION,
          "gem" => { "name" => "multi_compress", "version" => MultiCompress::VERSION },
          "database_target" => target,
          "database_envelope" => FORMAT,
          "files" => files
        }
        File.write(File.join(root, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
      end

      def write_checksums(root)
        checksums = regular_files(root).reject { |path| File.basename(path) == "SHA256SUMS" }.sort.map do |path|
          "#{Digest::SHA256.file(path).hexdigest}  #{relative_to(root, path)}"
        end
        File.write(File.join(root, "SHA256SUMS"), "#{checksums.join("\n")}\n")
      end

      def regular_files(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      end

      def relative_to(root, path)
        Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      end
    end
  end
end
