# frozen_string_literal: true

require "find"

module Blink
  class Manifest
    Error = Class.new(StandardError)

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
      candidates = [path, ENV["BLINK_MANIFEST"], *project_search_paths(start_dir), USER_CONFIG_PATH].compact.uniq
      found      = candidates.find { |p| File.exist?(p) }
      raise Error, "No blink.toml found. Searched:\n  #{candidates.join("\n  ")}" unless found

      new(found)
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
      @data = TOML.parse(File.read(@path, encoding: "utf-8"))
      validate!
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
      raise Error, "blink.toml must have a [blink] section" unless @data.key?("blink")
    end

    def build_target(name, cfg)
      case cfg["type"]
      when "ssh"   then Targets::SSHTarget.new(name, cfg)
      when "local" then Targets::LocalTarget.new(name, cfg)
      else raise Error, "Unknown target type '#{cfg["type"]}' for target '#{name}'"
      end
    end
  end
end
