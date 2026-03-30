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

    attr_reader :data, :path, :imported_paths, :service_target_catalogs

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
      imported  = {}

      begin
        manifest = load(nil, start_dir: start_dir)
        manifests << manifest
        seen[manifest.path] = true
        manifest.imported_paths.each { |path| imported[path] = true }
      rescue Error
        nil
      end

      workspace_manifest_paths(start_dir).each do |path|
        abs = File.expand_path(path)
        next if seen[abs] || imported[abs]

        begin
          manifest = new(abs)
          manifests << manifest
          seen[manifest.path] = true
          manifest.imported_paths.each do |imported_path|
            imported[imported_path] = true
            # If this path was loaded as a standalone manifest earlier in the
            # workspace scan, remove it — it is now subsumed by this manifest.
            manifests.reject! { |m| m.path == imported_path }
          end
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
      composed = compose_manifest(@path)
      @data = composed.fetch(:data)
      @service_origins = composed.fetch(:service_origins)
      @service_target_catalogs = composed.fetch(:service_target_catalogs)
      @imported_paths = composed.fetch(:imported_paths)
      validate!
    rescue TOML::ParseError => e
      raise ValidationError, "TOML parse error in #{@path}: #{e.message}"
    end

    def self.validate_file(path = nil, start_dir: Dir.pwd)
      manifest_path = resolve_path(path, start_dir: start_dir)
      manifest = allocate
      manifest.instance_variable_set(:@path, manifest_path)
      composed = manifest.send(:compose_manifest, manifest_path)
      Schema.validate(
        composed.fetch(:data),
        manifest_path: manifest_path,
        service_target_catalogs: composed.fetch(:service_target_catalogs),
        service_dirs: composed.fetch(:service_origins).transform_values { |origin| origin[:dir] }
      )
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

    def service_dir(name)
      service_origin(name).fetch(:dir)
    end

    def service_manifest_path(name)
      service_origin(name).fetch(:path)
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

    def target_for_service!(service_name, name)
      catalog = service_target_catalog(service_name)
      return target!(name) if catalog.equal?(@data["targets"]) || catalog == (@data["targets"] || {})

      cfg = catalog[name] || @data.dig("targets", name)
      raise Error, "Unknown target '#{name}' for service '#{service_name}'. Available: #{target_names_for_service(service_name).join(", ")}" unless cfg

      build_target(name, cfg)
    end

    def default_target_name_for(service_name)
      service_target_names = service_target_catalog(service_name).keys
      return service_target_names.first unless service_target_names.empty?

      default_target_name
    end

    def target_names_for_service(service_name)
      (service_target_catalog(service_name).keys + target_names).uniq
    end

    # ── Manifest dir (used to resolve relative suite paths) ─────────────────

    def dir
      File.dirname(@path)
    end

    private

    def validate!
      result = Schema.validate(
        @data,
        manifest_path: @path,
        service_target_catalogs: @service_target_catalogs,
        service_dirs: @service_origins.transform_values { |origin| origin[:dir] }
      )
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

    def service_origin(name)
      @service_origins[name] || { path: @path, dir: dir }
    end

    def service_target_catalog(name)
      @service_target_catalogs[name] || (@data["targets"] || {})
    end

    def compose_manifest(path, stack = [])
      abs = File.expand_path(path)
      cycle = stack + [abs]
      if stack.include?(abs)
        raise ValidationError, "Manifest include cycle detected:\n  #{cycle.join("\n  ")}"
      end

      load_dotenv(File.join(File.dirname(abs), ".env"))
      raw = TOML.parse(File.read(abs, encoding: "utf-8"))
      includes = extract_includes(raw, abs)

      data = deep_dup(raw)
      data["services"] ||= {}
      data["targets"] ||= {}

      service_origins = {}
      service_target_catalogs = {}
      imported_paths = []

      data["services"].each_key do |service_name|
        service_origins[service_name] = { path: abs, dir: File.dirname(abs) }
        service_target_catalogs[service_name] = deep_dup(data["targets"])
      end

      includes.each do |include_path|
        child = compose_manifest(include_path, stack + [abs])
        imported_paths << child[:path]
        imported_paths.concat(child[:imported_paths])

        child[:data].fetch("services", {}).each do |service_name, service_cfg|
          if data["services"].key?(service_name)
            raise ValidationError,
              "Manifest include conflict for service '#{service_name}' in #{abs} and #{child[:service_origins].dig(service_name, :path)}"
          end

          data["services"][service_name] = deep_dup(service_cfg)
          service_origins[service_name] = child[:service_origins].fetch(service_name)
          service_target_catalogs[service_name] = deep_dup(child[:service_target_catalogs].fetch(service_name))
        end
      end

      {
        path: abs,
        data: data,
        service_origins: service_origins,
        service_target_catalogs: service_target_catalogs,
        imported_paths: imported_paths.uniq
      }
    end

    def extract_includes(data, manifest_path)
      includes = data.dig("blink", "includes")
      return [] if includes.nil?

      unless includes.is_a?(Array) && includes.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        raise ValidationError, "Manifest validation failed for #{manifest_path}:\n  - blink.includes: blink.includes must be an array of non-empty relative manifest paths."
      end

      includes.map do |entry|
        resolved = File.expand_path(entry, File.dirname(manifest_path))
        raise ValidationError, "Manifest include not found: #{entry} (resolved to #{resolved})" unless File.exist?(resolved)

        resolved
      end
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, inner), out| out[key] = deep_dup(inner) }
      when Array
        value.map { |entry| deep_dup(entry) }
      else
        value
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
