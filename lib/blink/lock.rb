# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module Blink
  # Persists Blink run history in `.blink/`.
  module Lock
    BLINK_DIR = ".blink"
    CURRENT_STATE = File.join(BLINK_DIR, "state", "current.json")
    RECENT_RUNS = File.join(BLINK_DIR, "state", "recent_runs.json")
    HISTORY_DIR = File.join(BLINK_DIR, "history")
    LOCK_FILE = File.join(BLINK_DIR, ".lock")
    DEFAULT_RETENTION = 100

    def self.record(manifest, result, ctx, started_at, plan: nil)
      finished_at = Time.now
      run_id = generate_run_id(started_at)
      result.run_id = run_id if result.respond_to?(:run_id=)

      entry = build_deploy_entry(run_id, manifest, result, ctx, started_at, finished_at, plan)
      persist(manifest, entry)
    rescue => e
      Output.info("Warning: could not write .blink history: #{e.message}")
    end

    def self.record_test(manifest:, service_name:, target:, result:, tags:, started_at:, completed_at: Time.now)
      run_id = generate_run_id(started_at)
      entry = build_test_entry(
        run_id: run_id,
        manifest: manifest,
        service_name: service_name,
        target: target,
        result: result,
        tags: tags,
        started_at: started_at,
        completed_at: completed_at
      )
      persist(manifest, entry)
      run_id
    rescue => e
      Output.info("Warning: could not write test history: #{e.message}")
      nil
    end

    def self.persist(manifest, entry)
      ensure_dirs(manifest.dir)

      # Per-run history file is uniquely named — safe to write outside the lock.
      write_json(history_path(manifest.dir, entry["run_id"]), entry)

      # Shared state files (recent_runs.json, current.json) are read-modify-written.
      # Hold an exclusive flock so concurrent Blink processes (parallel deploy
      # threads, multiple operators) don't clobber each other. The read happens
      # INSIDE the lock so we never merge against a stale snapshot.
      trimmed = nil
      with_state_lock(manifest.dir) do
        recent = load_json(File.join(manifest.dir, RECENT_RUNS), default: [])
        recent.unshift(recent_summary(entry))
        recent = recent.uniq { |item| item["run_id"] }

        retention = retention_limit(manifest)
        trimmed = recent.first(retention)
        write_json(File.join(manifest.dir, RECENT_RUNS), trimmed)

        current = load_json(File.join(manifest.dir, CURRENT_STATE), default: { "updated_at" => nil, "services" => {} })
        update_current_state(current, entry)
        write_json(File.join(manifest.dir, CURRENT_STATE), current)
      end

      prune_history(manifest.dir, trimmed)
    end
    private_class_method :persist

    # Hold an exclusive OS-level file lock for the duration of the block.
    # The lockfile lives at `.blink/.lock`; threads within one process and
    # separate Blink processes both serialize through it.
    def self.with_state_lock(base_dir)
      FileUtils.mkdir_p(File.join(base_dir, BLINK_DIR))
      File.open(File.join(base_dir, LOCK_FILE), File::RDWR | File::CREAT, 0o644) do |lockfile|
        lockfile.flock(File::LOCK_EX)
        begin
          yield
        ensure
          lockfile.flock(File::LOCK_UN)
        end
      end
    end
    private_class_method :with_state_lock

    def self.current_state(manifest)
      load_json(File.join(base_dir(manifest), CURRENT_STATE), default: { "updated_at" => nil, "services" => {} })
    end

    def self.recent_runs(manifest, service: nil, limit: nil)
      runs = load_json(File.join(base_dir(manifest), RECENT_RUNS), default: [])
      runs = runs.select { |entry| entry["service"] == service } if service
      limit ? runs.first(limit.to_i) : runs
    end

    def self.history_entry(manifest, run_id)
      load_json(history_path(base_dir(manifest), run_id), default: nil)
    end

    def self.ensure_dirs(base_dir)
      FileUtils.mkdir_p(File.join(base_dir, BLINK_DIR, "state"))
      FileUtils.mkdir_p(File.join(base_dir, HISTORY_DIR))
    end
    private_class_method :ensure_dirs

    def self.build_deploy_entry(run_id, manifest, result, ctx, started_at, finished_at, plan)
      plan_hash = deep_stringify(plan.respond_to?(:to_h) ? plan.to_h : plan || {})

      {
        "run_id" => run_id,
        "manifest" => manifest.path,
        "service" => result.service,
        "operation" => result.operation,
        "status" => result.success? ? "success" : "failure",
        "summary" => result.summary,
        "started_at" => iso8601(started_at),
        "completed_at" => iso8601(finished_at),
        "duration" => (finished_at - started_at).round(3),
        "dry_run" => result.dry_run,
        "version" => ctx&.version,
        "build_name" => ctx&.build_name,
        "artifact" => artifact_info(ctx&.artifact_path),
        "git" => git_info(manifest.dir),
        "target" => target_info(ctx),
        "runtime" => runtime_info(ctx),
        "pipeline" => {
          "declared" => result.pipeline,
          "failed_at" => result.failed_at,
          "warnings" => Array(result.warnings),
          "blockers" => Array(result.blockers),
          "steps" => deep_stringify(result.step_results),
          "rollback_steps" => deep_stringify(result.rollback_results),
        },
        "plan" => plan_hash,
        "config_hash" => fetch_config_hash(plan_hash),
      }
    end
    private_class_method :build_deploy_entry

    def self.build_test_entry(run_id:, manifest:, service_name:, target:, result:, tags:, started_at:, completed_at:)
      entry = {
        "run_id" => run_id,
        "manifest" => manifest.path,
        "service" => service_name || "__all__",
        "operation" => "test",
        "status" => result.success? ? "success" : "failure",
        "summary" => test_summary_line(result),
        "started_at" => iso8601(started_at),
        "completed_at" => iso8601(completed_at),
        "duration" => (completed_at - started_at).round(3),
        "dry_run" => false,
        "tags" => Array(tags).map(&:to_s),
        "target" => {
          "name" => target&.name,
          "description" => target&.description,
          "type" => target&.config&.dig("type"),
        },
        "test_summary" => deep_stringify(result.to_h),
      }

      entry["config_hash"] = Digest::SHA256.hexdigest(JSON.generate(entry["test_summary"]))
      entry
    end
    private_class_method :build_test_entry

    def self.update_current_state(current, entry)
      service_state = current["services"][entry["service"]] ||= {}
      service_state["last_run_id"] = entry["run_id"]
      service_state["last_run"] = recent_summary(entry)
      current["updated_at"] = entry["completed_at"]

      case entry["operation"]
      when "deploy"
        return unless entry["status"] == "success"

        service_state["last_successful_run_id"] = entry["run_id"]
        service_state["last_deploy"] = {
          "run_id" => entry["run_id"],
          "completed_at" => entry["completed_at"],
          "target" => entry.dig("target", "description"),
          "target_name" => entry.dig("target", "name"),
          "version" => entry["version"],
          "build_name" => entry["build_name"],
          "summary" => entry["summary"],
          "artifact" => entry["artifact"],
          "git" => entry["git"],
          "config_hash" => entry["config_hash"],
        }
      when "test"
        service_state["last_test"] = {
          "run_id" => entry["run_id"],
          "completed_at" => entry["completed_at"],
          "target" => entry.dig("target", "description"),
          "tags" => entry["tags"],
          "summary" => entry["summary"],
          "success" => entry["status"] == "success",
          "result" => entry["test_summary"],
        }
      when "rollback"
        service_state["last_rollback"] = {
          "run_id" => entry["run_id"],
          "completed_at" => entry["completed_at"],
          "target" => entry.dig("target", "description"),
          "target_name" => entry.dig("target", "name"),
          "summary" => entry["summary"],
          "success" => entry["status"] == "success",
          "config_hash" => entry["config_hash"],
        }
      end
    end
    private_class_method :update_current_state

    def self.prune_history(base_dir, recent)
      keep = recent.map { |item| item["run_id"] }
      Dir.glob(File.join(base_dir, HISTORY_DIR, "*.json")).each do |path|
        run_id = File.basename(path, ".json")
        File.delete(path) unless keep.include?(run_id)
      end
    end
    private_class_method :prune_history

    def self.retention_limit(manifest)
      explicit = manifest.data.dig("blink", "history", "retention") ||
                 manifest.data.dig("blink", "retention", "max_runs")

      explicit.is_a?(Integer) && explicit.positive? ? explicit : DEFAULT_RETENTION
    end
    private_class_method :retention_limit

    def self.history_path(base_dir, run_id)
      File.join(base_dir, HISTORY_DIR, "#{run_id}.json")
    end
    private_class_method :history_path

    def self.base_dir(manifest)
      manifest.respond_to?(:dir) ? manifest.dir : File.dirname(manifest.to_s)
    end
    private_class_method :base_dir

    def self.generate_run_id(started_at)
      "#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    end
    private_class_method :generate_run_id

    def self.iso8601(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
    private_class_method :iso8601

    def self.artifact_info(path)
      return { "path" => nil, "sha256" => nil, "size" => nil, "cached" => false } if path.nil?

      exists = File.exist?(path)
      sha = Digest::SHA256.file(path).hexdigest if exists
      size = File.size(path) if exists
      metadata = load_json("#{path}.json", default: nil)
      http = metadata.is_a?(Hash) ? metadata["http"] : nil
      integrity = metadata.is_a?(Hash) ? metadata["integrity"] : nil
      signature = metadata.is_a?(Hash) ? metadata["signature"] : nil
      {
        "path" => path,
        "sha256" => sha,
        "size" => size,
        "cached" => path.include?("/.blink/artifacts/"),
        "source_type" => metadata.is_a?(Hash) ? metadata["source_type"] : nil,
        "cache_key" => metadata.is_a?(Hash) ? metadata["cache_key"] : nil,
        "http" => http,
        "integrity" => integrity,
        "signature" => signature,
        "cache_summary" => artifact_cache_summary(path, metadata, http, integrity, signature),
        "cache" => metadata,
      }
    end
    private_class_method :artifact_info

    def self.artifact_cache_summary(path, metadata, http, integrity, signature)
      parts = []
      parts << (path.include?("/.blink/artifacts/") ? "cached" : "ephemeral")
      parts << metadata["source_type"] if metadata.is_a?(Hash) && metadata["source_type"]
      if http.is_a?(Hash)
        parts << (http["revalidated"] ? "revalidated" : "downloaded")
        parts << "etag=#{http["etag"]}" if http["etag"]
        parts << "last_modified=#{http["last_modified"]}" if http["last_modified"]
      end
      if integrity.is_a?(Hash) && integrity["verified"]
        parts << "sha256-verified"
        parts << "via=#{integrity["source"]}" if integrity["source"]
      end
      if signature.is_a?(Hash) && signature["verified"]
        parts << "signature-verified"
        parts << "signed-via=#{signature["source"]}" if signature["source"]
      end
      parts.join(" | ")
    end
    private_class_method :artifact_cache_summary

    def self.git_info(workdir)
      commit = capture_git("git -C #{workdir} rev-parse HEAD 2>/dev/null")
      ref = capture_git("git -C #{workdir} symbolic-ref --short HEAD 2>/dev/null") ||
            capture_git("git -C #{workdir} describe --tags --exact-match HEAD 2>/dev/null")
      dirty = !capture_git("git -C #{workdir} status --porcelain 2>/dev/null").to_s.strip.empty?

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
      return { "name" => nil, "description" => nil, "type" => nil, "install_path" => nil } unless ctx

      {
        "name" => ctx.target.name,
        "description" => ctx.target.description,
        "type" => ctx.target.config["type"],
        "install_path" => ctx.service_config.dig("install", "dest"),
      }
    end
    private_class_method :target_info

    def self.runtime_info(ctx)
      return { "health_url" => nil, "service_name" => nil } unless ctx

      svc = ctx.service_config
      {
        "health_url" => svc.dig("health_check", "url"),
        "service_name" => svc.dig("start", "service_name") ||
                          ctx.target.config["service_name"] ||
                          ctx.service_name,
      }
    end
    private_class_method :runtime_info

    def self.test_summary_line(result)
      line = "#{result.passed}/#{result.total} passed"
      line += ", #{result.failed} failed" if result.failed.positive?
      line += ", #{result.errored} errored" if result.errored.positive?
      line
    end
    private_class_method :test_summary_line

    def self.fetch_config_hash(plan_hash)
      plan_hash["config_hash"] || plan_hash[:config_hash]
    end
    private_class_method :fetch_config_hash

    def self.recent_summary(entry)
      {
        "run_id" => entry["run_id"],
        "service" => entry["service"],
        "operation" => entry["operation"],
        "status" => entry["status"],
        "started_at" => entry["started_at"],
        "completed_at" => entry["completed_at"],
        "summary" => entry["summary"],
      }
    end
    private_class_method :recent_summary

    def self.load_json(path, default:)
      return default unless File.exist?(path)

      JSON.parse(File.read(path, encoding: "utf-8"))
    rescue JSON::ParserError
      default
    end
    private_class_method :load_json

    # Atomic write: serialize to a sibling tmp file, fsync, then rename into place.
    # Rename on POSIX is atomic, so readers never see a half-written JSON document.
    # A unique suffix on the tmp file keeps concurrent writers from colliding on the
    # tmp path (they still serialize at the shared-state level via `with_state_lock`,
    # but per-run history writes happen outside that lock).
    def self.write_json(path, payload)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(tmp, "w") do |f|
        f.write(JSON.pretty_generate(payload) + "\n")
        f.fsync
      end
      File.rename(tmp, path)
    ensure
      begin
        File.unlink(tmp) if tmp && File.exist?(tmp)
      rescue Errno::ENOENT
        # Raced with another cleanup; nothing to do.
      end
    end
    private_class_method :write_json

    def self.deep_stringify(value)
      JSON.parse(JSON.generate(value || {}))
    end
    private_class_method :deep_stringify
  end
end
