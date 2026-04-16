# frozen_string_literal: true

module Blink
  module Sources
    # Artifact verification concern. Mixed into `Sources::Base`.
    #
    # Provides SHA-256 checksum and signature verification for fetched
    # artifacts, plus helpers for parsing multi-line checksum documents
    # (`SHA256SUMS`-style) and rendering signature-verify command templates.
    # Concrete sources call `verify_sha256!` / `verify_signature!` from their
    # `fetch` path; both return a metadata hash (suitable to merge into the
    # cache sidecar) on success and raise on failure.
    #
    # Before Sprint F this logic lived on `Sources::Base`. It was extracted
    # into its own module so that the verification surface is named and
    # testable in isolation, and so that sources which legitimately have
    # nothing to verify (e.g. `local_build`) can avoid inheriting dead code.
    module Verification
      def verify_sha256!(path, expected_sha256, provenance: nil)
        return nil if expected_sha256.nil? || expected_sha256.strip.empty?

        expected = expected_sha256.strip.downcase
        actual = Digest::SHA256.file(path).hexdigest
        raise "Checksum mismatch for #{path}: expected #{expected}, got #{actual}" unless actual == expected

        {
          "integrity" => {
            "algorithm" => "sha256",
            "expected" => expected,
            "actual" => actual,
            "verified" => true,
            "verified_at" => Time.now.utc.iso8601
          }.merge(normalize_metadata_result(provenance) || {})
        }
      end

      def verify_signature!(path, verify_command:, signature_path:, public_key_path: nil, provenance: nil)
        return nil if verify_command.to_s.strip.empty? || signature_path.to_s.strip.empty?

        rendered = render_verify_command(
          verify_command,
          artifact: path,
          signature: signature_path,
          public_key: public_key_path
        )
        stdout, stderr, status = Open3.capture3(rendered)
        raise "Signature verification failed: #{[stdout, stderr].join.strip}" unless status.success?

        {
          "signature" => {
            "verified" => true,
            "verified_at" => Time.now.utc.iso8601,
            "tool" => signature_tool_name(verify_command),
            "public_key_path" => public_key_path,
          }.merge(normalize_metadata_result(provenance) || {})
        }
      end

      def sha256_from_document(document, filename:)
        body = document.to_s.strip
        return body.downcase if body.match?(/\A[0-9a-fA-F]{64}\z/)

        body.each_line do |line|
          stripped = line.strip
          next if stripped.empty?

          if (match = stripped.match(/\A([0-9a-fA-F]{64})\s+\*?(.+)\z/))
            digest = match[1].downcase
            candidate = match[2].strip
            return digest if candidate == filename || File.basename(candidate) == filename
          elsif (match = stripped.match(/\ASHA256\s*\((.+)\)\s*=\s*([0-9a-fA-F]{64})\z/i))
            candidate = match[1].strip
            digest = match[2].downcase
            return digest if candidate == filename || File.basename(candidate) == filename
          end
        end

        raise "No SHA-256 entry for #{filename.inspect} in checksum document"
      end

      def render_verify_command(template, artifact:, signature:, public_key:)
        {
          "{{artifact}}" => Shellwords.escape(artifact.to_s),
          "{{signature}}" => Shellwords.escape(signature.to_s),
          "{{public_key}}" => Shellwords.escape(public_key.to_s)
        }.reduce(template.to_s) { |command, (needle, value)| command.gsub(needle, value) }
      end

      def signature_tool_name(template)
        Shellwords.split(template.to_s).first
      rescue ArgumentError
        template.to_s.split.first
      end
    end
  end
end
