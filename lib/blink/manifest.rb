# frozen_string_literal: true

require "find"

module Blink
  class Manifest
    Error = Class.new(StandardError)
    ValidationError = Class.new(Error)

    USER_CONFIG_PATH = File.join(Dir.home, ".config", "blink", "blink.toml")
    SEARCH_SKIP_DIRS = %w[
      .git
      .Trash
      Library
      node_modules
      vendor
      tmp
      dist
      build
      zig-out
    ].freeze

    attr_reader :data, :path

    # Load a manifest from an explicit path, BLINK_MANIFEST env var, or the
    # default search path (blink.toml from CWD upward, then ~/.config/blink/blink.toml).
    def self.load(path = nil, start_dir: Dir.pwd)
      new(resolve_path(path, start_dir: start_dir))
    end

    def self.resolve_path(path = nil, start_dir: Dir.pwd)
      candidates = [path, ENV["BLINK_MANIFEST"], *project_search_paths(start_dir), USER_CONFIG_PATH].compact.uniq
      found      = candidates.find { |p| File.exist?(p) }
      raise Error, "No blink.toml found. Searched:\n  #{candidates.join("\n  ")}" unless found

      File.expand_path(found)
    end

    def self.load_for_service!(service_name, start_dir: Dir.pwd)
      matches = discover_all(start_dir: start_dir).select { _1.service(service_name) }
      return matches.first if matches.one?

      if matches.empty?
        raise Error, "No blink.toml found for service '#{service_name}' under #{start_dir}"
      end

      listed = matches.map(&:path).join("\n  ")
      raise Error, "Service '#{service_name}' is defined in multiple manifests:\n  #{listed}"
    end

    def self.discover_all(start_dir: Dir.pwd)
      manifests = []
      seen      = {}

      begin
        manifest = load(nil, start_dir: start_dir)
        manifests << manifest
        seen[manifest.path] = true
      rescue Error
        nil
      end

      workspace_manifest_paths(start_dir).each do |path|
        abs = File.expand_path(path)
        next if seen[abs]

        begin
          manifest = new(abs)
          manifests << manifest
          seen[manifest.path] = true
        rescue Error, TOML::ParseError
          next
        end
      end

      manifests
    end

    def self.project_search_paths(start_dir = Dir.pwd)
      dir   = File.expand_path(start_dir)
      paths = []

      loop do
        paths << File.join(dir, "blink.toml")
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end

      paths
    end

    def self.workspace_manifest_paths(start_dir = Dir.pwd)
      paths = []

      discovery_roots(start_dir).each do |base|
        Find.find(base) do |path|
          if File.directory?(path)
            Find.prune if SEARCH_SKIP_DIRS.include?(File.basename(path))
            next
          end

          paths << path if File.basename(path) == "blink.toml"
        rescue Errno::EACCES, Errno::EPERM
          Find.prune
        end
      end

      paths
    end

    def self.discovery_roots(start_dir = Dir.pwd)
      base = File.expand_path(start_dir)
      return [base] unless base == "/"

      roots = %w[Projects Code Workspace src work].map { |name| File.join(Dir.home, name) }
      roots.select! { |path| Dir.exist?(path) }
      return roots unless roots.empty?

      [Dir.home]
    end

    def initialize(path)
      @path = File.expand_path(path)
      load_dotenv(File.join(dir, ".env"))
      @data = TOML.parse(File.read(@path, encoding: "utf-8"))
      validate!
    rescue TOML::ParseError => e
      raise ValidationError, "TOML parse error in #{@path}: #{e.message}"
    end

    def self.validate_file(path = nil, start_dir: Dir.pwd)
      manifest_path = resolve_path(path, start_dir: start_dir)
      data = TOML.parse(File.read(manifest_path, encoding: "utf-8"))
      Schema.validate(data, manifest_path: manifest_path)
    rescue TOML::ParseError => e
      Schema::Result.new(
        manifest_path: manifest_path || path,
        errors: [Schema::Issue.new(path: "toml", message: e.message, severity: "error")],
        warnings: [],
        data: {}
      )
    end

    # ── Services ────────────────────────────────────────────────────────────

    def service(name)
      @data.dig("services", name)
    end

    def service!(name)
      service(name) || raise(Error, "Unknown service '#{name}'. Available: #{service_names.join(", ")}")
    end

    def service_names
      (@data["services"] || {}).keys
    end

    # ── Targets ─────────────────────────────────────────────────────────────

    def target(name)
      cfg = @data.dig("targets", name)
      return nil unless cfg
      build_target(name, cfg)
    end

    def target!(name)
      cfg = @data.dig("targets", name)
      raise Error, "Unknown target '#{name}'. Available: #{target_names.join(", ")}" unless cfg
      build_target(name, cfg)
    end

    def default_target_name
      target_names.first
    end

    def target_names
      (@data["targets"] || {}).keys
    end

    # ── Manifest dir (used to resolve relative suite paths) ─────────────────

    def dir
      File.dirname(@path)
    end

    private

    def validate!
      result = Schema.validate(@data, manifest_path: @path)
      return if result.valid?

      lines = result.errors.map { |issue| "#{issue.path}: #{issue.message}" }.join("\n  - ")
      raise ValidationError, "Manifest validation failed for #{@path}:\n  - #{lines}"
    end

    def build_target(name, cfg)
      case cfg["type"]
      when "ssh"   then Targets::SSHTarget.new(name, cfg)
      when "local" then Targets::LocalTarget.new(name, cfg)
      else raise Error, "Unknown target type '#{cfg["type"]}' for target '#{name}'"
      end
    end

    # Load a .env file from the manifest directory into ENV.
    # Only sets variables that are not already present in the environment,
    # so shell-exported vars always take precedence.
    def load_dotenv(dotenv_path)
      return unless File.exist?(dotenv_path)

      File.foreach(dotenv_path, encoding: "utf-8") do |raw|
        line = raw.strip
        next if line.empty? || line.start_with?("#")
        next unless line.include?("=")

        key, _, value = line.partition("=")
        key   = key.strip
        value = value.strip
        # Strip surrounding single or double quotes
        value = value.gsub(/\A(['"])(.*)\1\z/m, '\2')
        ENV[key] ||= value
      end
    end
  end
end
