# frozen_string_literal: true

require "json"
require "digest"

module Blink
  # Writes and reads blink.lock — a per-service deploy history record.
  #
  # The lock file lives next to blink.toml and is a JSON object keyed by
  # service name. Each deploy updates only the entry for its service, so
  # concurrent services in the same workspace don't clobber each other.
  #
  # Format:
  #
  #   {
  #     "bearclaw": {
  #       "status":        "success" | "failure",
  #       "deployed_at":   "2026-03-18T12:00:00Z",
  #       "operation":     "deploy",
  #       "build_name":    "linux-amd64",          // null when not using multi-build
  #       "artifact": {
  #         "path":        "/abs/path/to/binary",
  #         "sha256":      "abc123..."              // null if file no longer present
  #       },
  #       "git": {
  #         "commit":      "abcdef1234567890",
  #         "ref":         "main",
  #         "dirty":       false
  #       },
  #       "target": {
  #         "name":        "homelab",
  #         "description": "admin@blink",
  #         "install_path": "/home/admin/baresystems/runtime/blink-homelab/bin/bearclaw"
  #       },
  #       "runtime": {
  #         "health_url":    "http://127.0.0.1:8080/health",
  #         "service_name":  "bearclaw"
  #       },
  #       "pipeline": {
  #         "total_elapsed": 18.4,
  #         "failed_at":     null,
  #         "steps": [
  #           { "step": "fetch_artifact", "status": "pass", "elapsed": 3.1 },
  #           ...
  #         ]
  #       }
  #     }
  #   }
  #
  module Lock
    FILENAME = "blink.lock"

    # Record a completed pipeline run into blink.lock.
    # Called by Runner#run after every non-dry-run execution.
    def self.record(manifest, result, ctx, started_at)
      lock_path = File.join(manifest.dir, FILENAME)

      existing = {}
      if File.exist?(lock_path)
        begin
          existing = JSON.parse(File.read(lock_path))
        rescue JSON::ParserError
          # Corrupt lock file — start fresh rather than aborting the deploy.
        end
      end

      existing[result.service] = build_entry(result, ctx, started_at)

      File.write(lock_path, JSON.pretty_generate(existing) + "\n")
    rescue => e
      # Lock write failure is non-fatal — warn but don't abort.
      Output.info("Warning: could not write blink.lock: #{e.message}")
    end

    # ── Private helpers ───────────────────────────────────────────────────────

    def self.build_entry(result, ctx, started_at)
      total_elapsed = result.step_results.sum { _1[:elapsed] || 0 }.round(3)

      {
        "status"      => result.success? ? "success" : "failure",
        "deployed_at" => started_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "operation"   => result.operation,
        "build_name"  => ctx.build_name,
        "artifact"    => artifact_info(ctx.artifact_path),
        "git"         => git_info(ctx.manifest.dir),
        "target"      => target_info(ctx),
        "runtime"     => runtime_info(ctx),
        "pipeline"    => {
          "total_elapsed" => total_elapsed,
          "failed_at"     => result.failed_at,
          "steps"         => result.step_results.map { stringify_keys(_1) },
        },
      }
    end
    private_class_method :build_entry

    def self.artifact_info(path)
      return { "path" => nil, "sha256" => nil } if path.nil?
      sha = if File.exist?(path)
        Digest::SHA256.file(path).hexdigest
      end
      { "path" => path, "sha256" => sha }
    end
    private_class_method :artifact_info

    def self.git_info(workdir)
      commit = capture_git("git -C #{workdir} rev-parse HEAD 2>/dev/null")
      ref    = capture_git("git -C #{workdir} symbolic-ref --short HEAD 2>/dev/null") ||
               capture_git("git -C #{workdir} describe --tags --exact-match HEAD 2>/dev/null")
      dirty  = !capture_git("git -C #{workdir} status --porcelain 2>/dev/null").to_s.strip.empty?

      { "commit" => commit, "ref" => ref, "dirty" => dirty }
    rescue
      { "commit" => nil, "ref" => nil, "dirty" => nil }
    end
    private_class_method :git_info

    def self.capture_git(cmd)
      out = `#{cmd}`.strip
      out.empty? ? nil : out
    rescue
      nil
    end
    private_class_method :capture_git

    def self.target_info(ctx)
      t   = ctx.target
      cfg = t.respond_to?(:config) ? t.config : {}
      {
        "name"         => cfg["host"] || t.description,
        "description"  => t.description,
        "install_path" => ctx.service_config.dig("install", "dest"),
      }
    end
    private_class_method :target_info

    def self.runtime_info(ctx)
      svc = ctx.service_config
      {
        "health_url"   => svc.dig("health_check", "url"),
        "service_name" => svc.dig("start", "service_name") ||
                          ctx.target.respond_to?(:config) && ctx.target.config["service_name"] ||
                          ctx.service_name,
      }
    end
    private_class_method :runtime_info

    def self.stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
    private_class_method :stringify_keys
  end
end
