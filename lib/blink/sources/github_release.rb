# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Blink
  module Sources
    class GithubRelease < Base
      API_BASE = "https://api.github.com"

      # Returns the local path to the downloaded artifact.
      # build_name is ignored for github_release — releases already produce a single asset.
      def fetch(version: "latest", build_name: nil)
        _ = build_name
        repo    = @config["repo"]  or raise Manifest::Error, "source.repo is required"
        pattern = @config["asset"] or raise Manifest::Error, "source.asset is required"

        Output.step("Fetching #{version == "latest" ? "latest" : version} release from #{repo}...")
        release = version == "latest" ? latest_release(repo) : release_by_tag(repo, version)
        tag = release["tag_name"]
        Output.info("Release: #{tag}")

        asset = find_asset(release, pattern)
        unless asset
          available = release["assets"].map { _1["name"] }.join(", ")
          raise "No asset matching #{pattern.inspect} in #{repo}@#{tag}. Available: #{available}"
        end

        cache_key = digest_for(
          type: "github_release",
          api_base: api_base,
          repo: repo,
          tag: tag,
          asset: asset["name"]
        )

        fetch_with_cache(
          cache_key: cache_key,
          filename: asset["name"],
          metadata: {
            "source_type" => "github_release",
            "repo" => repo,
            "tag" => tag,
            "asset" => asset["name"],
            "version" => version,
          },
          validate: lambda do |path, _existing_metadata|
            checksum, provenance = expected_checksum_details(release, asset["name"])
            checksum_metadata = verify_sha256!(path, checksum, provenance: provenance)
            signature_metadata = verify_signature_details(release, asset["name"], path)
            metadata_payload(checksum_metadata, signature_metadata)
          end
        ) do |destination|
          download_asset(asset, destination)
        end
      end

      private

      def api_base
        (@config["api_base"] || API_BASE).sub(%r{/\z}, "")
      end

      def latest_release(repo)
        uri = URI("#{api_base}/repos/#{repo}/releases/latest")
        res = api_get(uri)
        raise api_error("GitHub API error", res, repo) unless res.code == "200"
        JSON.parse(res.body)
      end

      def release_by_tag(repo, tag)
        uri = URI("#{api_base}/repos/#{repo}/releases/tags/#{tag}")
        res = api_get(uri)
        raise api_error("GitHub API error", res, "#{repo}@#{tag}") unless res.code == "200"
        JSON.parse(res.body)
      end

      def find_asset(release, pattern)
        pat = pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/i
        release["assets"].find { |a| a["name"].match?(pat) }
      end

      def download_asset(asset, dest)
        url      = asset["browser_download_url"]
        Output.step("Downloading #{asset["name"]} (#{humanize_bytes(asset["size"])})...")
        download_url(url, dest)
        dest
      end

      # GET with redirect following and GitHub auth headers.
      def api_get(uri, limit: 5)
        raise "Too many redirects" if limit.zero?

        req = Net::HTTP::Get.new(uri)
        req["User-Agent"]           = "blink/#{Blink::VERSION}"
        req["Accept"]               = "application/vnd.github+json"
        req["X-GitHub-Api-Version"] = "2022-11-28"
        req["Authorization"]        = "Bearer #{token}" if token

        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
        %w[301 302 307 308].include?(res.code) ? api_get(URI(res["location"]), limit: limit - 1) : res
      end

      def download_url(url, dest)
        uri = URI(url)
        res = api_get(uri)
        raise "Download failed: HTTP #{res.code} for #{url}" unless res.code == "200"

        File.binwrite(dest, res.body)
        dest
      end

      def expected_checksum_details(release, filename)
        return [@config["sha256"], { "source" => "manifest.sha256" }] if @config["sha256"]

        checksum_pattern = @config["checksum_asset"]
        return [nil, nil] unless checksum_pattern

        checksum_asset = find_asset(release, checksum_pattern)
        raise "No checksum asset matching #{checksum_pattern.inspect} in release #{release["tag_name"]}" unless checksum_asset

        checksum = sha256_from_document(download_text_asset(checksum_asset), filename: filename)
        [
          checksum,
          {
            "source" => "release.checksum_asset",
            "reference" => checksum_asset["name"],
            "subject" => filename,
            "tag" => release["tag_name"]
          }
        ]
      end

      def verify_signature_details(release, filename, artifact_path)
        signature_pattern = @config["signature_asset"]
        verify_command = @config["verify_command"]
        return nil if signature_pattern.to_s.strip.empty? || verify_command.to_s.strip.empty?

        signature_asset = find_asset(release, signature_pattern)
        raise "No signature asset matching #{signature_pattern.inspect} in release #{release["tag_name"]}" unless signature_asset

        signature_path = download_asset_to_temp(signature_asset)
        begin
          verify_signature!(
            artifact_path,
            verify_command: verify_command,
            signature_path: signature_path,
            public_key_path: @config["public_key_path"],
            provenance: {
              "source" => "release.signature_asset",
              "reference" => signature_asset["name"],
              "subject" => filename,
              "tag" => release["tag_name"]
            }
          )
        ensure
          FileUtils.rm_f(signature_path)
        end
      end

      def download_text_asset(asset)
        uri = URI(asset["browser_download_url"])
        res = api_get(uri)
        raise "Checksum download failed: HTTP #{res.code} for #{asset["name"]}" unless res.code == "200"

        res.body
      end

      def download_asset_to_temp(asset)
        path = temp_artifact_path("#{asset["name"]}.sig")
        download_url(asset["browser_download_url"], path)
      end

      def api_error(prefix, response, subject)
        detail = begin
          parsed = JSON.parse(response.body)
          parsed["message"] || response.body
        rescue JSON::ParserError
          response.body
        end
        "#{prefix} #{response.code} for #{subject}: #{detail}"
      end

      def token
        @config["token_env"]&.then { |e| ENV[e] } || ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
      end

      def humanize_bytes(b)
        return "#{b} B"                      if b < 1_024
        return "#{(b / 1_024.0).round(1)} KB" if b < 1_024**2
        "#{(b / 1_024.0**2).round(1)} MB"
      end
    end

    register("github_release", GithubRelease)
  end
end
