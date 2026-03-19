# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "tmpdir"

module Blink
  module Sources
    class GithubRelease < Base
      API_BASE = "https://api.github.com"

      # Returns the local path to the downloaded artifact.
      # build_name is ignored for github_release — releases already produce a single asset.
      def fetch(version: "latest", build_name: nil)
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

        download_asset(asset)
      end

      private

      def latest_release(repo)
        uri = URI("#{API_BASE}/repos/#{repo}/releases/latest")
        res = api_get(uri)
        raise "GitHub API error #{res.code} for #{repo}" unless res.code == "200"
        JSON.parse(res.body)
      end

      def release_by_tag(repo, tag)
        uri = URI("#{API_BASE}/repos/#{repo}/releases/tags/#{tag}")
        res = api_get(uri)
        raise "GitHub API error #{res.code} for #{repo}@#{tag}" unless res.code == "200"
        JSON.parse(res.body)
      end

      def find_asset(release, pattern)
        pat = pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/i
        release["assets"].find { |a| a["name"].match?(pat) }
      end

      def download_asset(asset)
        url      = asset["browser_download_url"]
        filename = asset["name"]
        dest     = File.join(Dir.tmpdir, filename)

        Output.step("Downloading #{filename} (#{humanize_bytes(asset["size"])})...")
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
        File.open(dest, "wb") do |f|
          loop do
            res = api_get(uri)
            if %w[301 302 307 308].include?(res.code)
              uri = URI(res["location"])
              next
            end
            raise "Download failed: HTTP #{res.code} for #{url}" unless res.code == "200"
            f.write(res.body)
            break
          end
        end
        dest
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
  end
end
