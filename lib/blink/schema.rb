# frozen_string_literal: true

require "pathname"

module Blink
  class Schema
    # Target types are structural — Schema validates their config shape
    # directly — so this list is hand-maintained rather than registry-derived.
    KNOWN_TARGET_TYPES = %w[local ssh].freeze
    SECRET_KEY_PATTERN = /(token|secret|password|api[_-]?key|authorization|webhook|private[_-]?key)/i.freeze
    ENV_REF_ONLY_PATTERN = /\A\$\{[A-Z0-9_]+\}\z/.freeze

    # Source types and inline test types are derived from their runtime
    # registries (`Blink::Sources::REGISTRY`, `Blink::Testing::InlineRunner::REGISTRY`)
    # so plugins can extend the manifest vocabulary without touching Schema.
    # See `known_source_types`, `known_inline_test_types`, `known_steps` below.

    Issue = Struct.new(:path, :message, :severity, keyword_init: true) do
      def to_h
        { path: path, message: message, severity: severity }
      end
    end

    Result = Struct.new(:manifest_path, :errors, :warnings, :data, keyword_init: true) do
      def valid?
        errors.empty?
      end

      def invalid?
        !valid?
      end

      def summary
        valid? ? "Manifest is valid" : "#{errors.size} validation error(s)"
      end

      def service_count
        data.fetch("services", {}).size
      end

      def target_count
        data.fetch("targets", {}).size
      end

      def to_h
        {
          success: valid?,
          summary: summary,
          manifest: manifest_path,
          targets: target_count,
          services: service_count,
          errors: errors.map(&:to_h),
          warnings: warnings.map(&:to_h),
        }
      end
    end

    class << self
      def validate(data, manifest_path: nil, service_target_catalogs: {}, service_dirs: {})
        Validator.new(
          data,
          manifest_path: manifest_path,
          service_target_catalogs: service_target_catalogs,
          service_dirs: service_dirs
        ).validate
      end
    end

    class Validator
      def initialize(data, manifest_path:, service_target_catalogs: {}, service_dirs: {})
        @data = data.is_a?(Hash) ? data : {}
        @manifest_path = manifest_path
        @service_target_catalogs = service_target_catalogs || {}
        @service_dirs = service_dirs || {}
        @errors = []
        @warnings = []
      end

      def validate
        validate_root

        Result.new(
          manifest_path: @manifest_path,
          errors: @errors,
          warnings: @warnings,
          data: @data
        )
      end

      private

      def validate_root
        validate_blink_section

        targets = @data["targets"]
        if targets.nil?
          targets = {}
        elsif !targets.is_a?(Hash)
          error("targets", "targets must be a TOML table.")
          targets = {}
        end
        validate_targets(targets) if targets.any?

        services = @data["services"]
        if services.nil?
          services = {}
        elsif !services.is_a?(Hash)
          error("services", "services must be a TOML table.")
          services = {}
        end
        validate_services(services, targets || {}) if services.any?
        validate_service_target_catalogs

        error("targets", "A manifest must define at least one target.") if targets.empty? && all_service_targets.empty?
        error("services", "A manifest must define at least one service.") if services.empty?
      end

      def validate_blink_section
        blink = require_hash(@data, "blink", "A manifest must include a [blink] section.")
        return unless blink

        version = blink["version"]
        if version.nil?
          error("blink.version", "blink.version is required and must currently be set to \"1\".")
        elsif version.to_s != "1"
          error("blink.version", "Unsupported manifest version #{version.inspect}. Expected \"1\".")
        end

        validate_manifest_includes(blink)
      end

      def validate_targets(targets)
        if targets.empty?
          error("targets", "Define at least one target under [targets.<name>].")
          return
        end

        targets.each do |name, cfg|
          path = "targets.#{name}"
          unless cfg.is_a?(Hash)
            error(path, "Target definitions must be TOML tables.")
            next
          end

          type = cfg["type"]
          if !stringish?(type)
            error("#{path}.type", "Target type is required.")
            next
          end

          unless KNOWN_TARGET_TYPES.include?(type)
            error("#{path}.type", "Unknown target type #{type.inspect}. Supported types: #{KNOWN_TARGET_TYPES.join(', ')}.")
            next
          end

          case type
          when "ssh"
            require_string(cfg, "#{path}.host", "SSH targets require a host name or IP address.")
            optional_string(cfg, "#{path}.user")
            optional_string(cfg, "#{path}.base")
            validate_target_env(cfg, path)
          when "local"
            optional_string(cfg, "#{path}.base")
            validate_target_env(cfg, path)
          end
        end
      end

      def validate_services(services, targets)
        if services.empty?
          error("services", "Define at least one service under [services.<name>].")
          return
        end

        services.each do |name, svc|
          path = "services.#{name}"
          unless svc.is_a?(Hash)
            error(path, "Service definitions must be TOML tables.")
            next
          end

          optional_string(svc, "#{path}.description")

          source = svc["source"]
          deploy_cfg = svc["deploy"]
          deploy_path = "#{path}.deploy"
          if !deploy_cfg.nil? && !deploy_cfg.is_a?(Hash)
            error(deploy_path, "deploy must be a TOML table.")
            deploy_cfg = {}
          end
          deploy_cfg ||= {}

          pipeline = deploy_cfg["pipeline"] || Runner::DEFAULT_PIPELINES["deploy"]
          rollback = deploy_cfg["rollback_pipeline"] || []

          validate_pipeline(name, pipeline, "#{deploy_path}.pipeline", allow_empty: false)
          validate_pipeline(name, rollback, "#{deploy_path}.rollback_pipeline", allow_empty: true)

          priority = deploy_cfg["priority"]
          if !priority.nil? && (!priority.is_a?(Integer) || priority.negative?)
            error("#{deploy_path}.priority", "deploy.priority must be a non-negative integer (higher value deploys first).")
          end

          target_name = deploy_cfg["target"]
          available_targets = targets_for_service(name, targets)

          if target_name
            if !stringish?(target_name)
              error("#{deploy_path}.target", "deploy.target must be a target name.")
            elsif !available_targets.key?(target_name)
              error("#{deploy_path}.target", "deploy.target references unknown target #{target_name.inspect}.")
            end
          elsif available_targets.size > 1
            warn("#{deploy_path}.target", "No deploy.target set; Blink will use the first declared target by default.")
          end

          if pipeline.include?("fetch_artifact")
            if source.nil?
              error("#{path}.source", "This service needs a [services.#{name}.source] table because deploy.pipeline includes fetch_artifact.")
            elsif !source.is_a?(Hash)
              error("#{path}.source", "source must be a TOML table.")
            else
              validate_source(name, source, "#{path}.source")
            end
          elsif source
            if !source.is_a?(Hash)
              error("#{path}.source", "source must be a TOML table.")
            else
              validate_source(name, source, "#{path}.source")
            end
          end

          if rollback.empty?
            warn("#{deploy_path}.rollback_pipeline", "No rollback_pipeline declared. Deploy failures will not have an automatic recovery path.")
          end

          validate_step_sections(name, svc, pipeline, rollback, path)
        end
      end

      def validate_target_env(cfg, path)
        env = cfg["env"]
        return unless env

        unless env.is_a?(Hash)
          error("#{path}.env", "target env must be a TOML table of string values.")
          return
        end

        env.each do |key, value|
          validate_env_value("#{path}.env.#{key}", key, value, label: "target env")
        end
      end

      def validate_manifest_includes(blink)
        includes = blink["includes"]
        return if includes.nil?

        unless includes.is_a?(Array)
          error("blink.includes", "blink.includes must be an array of manifest paths.")
          return
        end

        includes.each_with_index do |entry, idx|
          path = "blink.includes.#{idx}"
          if !entry.is_a?(String) || entry.strip.empty?
            error(path, "blink.includes entries must be non-empty strings.")
            next
          end

          next unless @manifest_path

          resolved = File.expand_path(entry, File.dirname(@manifest_path))
          error(path, "Included manifest not found: #{entry}") unless File.exist?(resolved)
        end
      end

      def targets_for_service(service_name, root_targets)
        service_targets = @service_target_catalogs[service_name]
        return service_targets if service_targets.is_a?(Hash) && !service_targets.empty?

        root_targets
      end

      def all_service_targets
        @service_target_catalogs.values.select { |targets| targets.is_a?(Hash) && !targets.empty? }
      end

      def validate_service_target_catalogs
        @service_target_catalogs.each do |service_name, targets|
          next unless targets.is_a?(Hash) && !targets.empty?

          validate_targets(targets.transform_keys(&:to_s))
        end
      end

      def validate_source(service_name, source, path)
        type = source["type"]

        # Multi-source pattern: no top-level type, named builds each carry their own type
        if type.nil? && source["builds"].is_a?(Hash) && !source["builds"].empty?
          validate_multi_source(service_name, source, path)
          return
        end

        unless stringish?(type)
          error("#{path}.type", "source.type is required (or use source.builds with per-build type for multi-source).")
          return
        end

        unless known_source_types.include?(type)
          error("#{path}.type", "Unknown source type #{type.inspect}. Supported types: #{known_source_types.join(', ')}.")
          return
        end

        optional_string(source, "#{path}.workdir")
        validate_source_env(source, path)
        validate_source_cache(source, path)

        case type
        when "containerized_local_build"
          require_string(source, "#{path}.image", "containerized_local_build sources require image.")
          require_string_or_string_array(source, "#{path}.mount", "containerized_local_build sources require mount = \"host:container\" or an array of mount specs.")
          require_string(source, "#{path}.workdir", "containerized_local_build sources require workdir.")
          require_string(source, "#{path}.command", "containerized_local_build sources require command.")
          require_string(source, "#{path}.artifact", "containerized_local_build sources require artifact.")
          optional_string(source, "#{path}.platform")
          optional_string(source, "#{path}.entrypoint")
          optional_string(source, "#{path}.user")
          optional_boolean(source, "#{path}.docker_socket")
          optional_boolean(source, "#{path}.pull")
          optional_string_or_array_of_strings(source, "#{path}.env_file", "containerized_local_build env_file must be a string or array of strings.")
        when "github_release"
          require_string(source, "#{path}.repo", "github_release sources require repo = \"owner/name\".")
          require_string(source, "#{path}.asset", "github_release sources require asset = \"artifact-name\".")
          optional_string(source, "#{path}.token_env")
          optional_sha256(source, "#{path}.sha256")
          optional_string(source, "#{path}.checksum_asset")
          optional_string(source, "#{path}.signature_asset")
          optional_string(source, "#{path}.verify_command")
          optional_string(source, "#{path}.public_key_path")
          optional_boolean(source, "#{path}.allow_insecure")
          require_string(source, "#{path}.verify_command", "github_release signature verification requires verify_command.") if source["signature_asset"]
        when "local_build"
          builds = source["builds"]

          if builds && !builds.is_a?(Hash)
            error("#{path}.builds", "source.builds must be a table of named builds.")
            return
          end

          if builds && !builds.empty?
            default_build = source["default"]
            if default_build && !builds.key?(default_build)
              error("#{path}.default", "source.default references unknown build #{default_build.inspect}.")
            end

            builds.each do |build_name, build_cfg|
              build_path = "#{path}.builds.#{build_name}"
              unless build_cfg.is_a?(Hash)
                error(build_path, "Each named build must be a TOML table.")
                next
              end

              require_string(build_cfg, "#{build_path}.command", "Each local_build build requires a command.")
              require_string(build_cfg, "#{build_path}.artifact", "Each local_build build requires an artifact path.")
              validate_source_env(build_cfg, build_path)
            end
          else
            require_string(source, "#{path}.command", "local_build sources require command unless named builds are configured.")
            require_string(source, "#{path}.artifact", "local_build sources require artifact unless named builds are configured.")
          end
        when "url"
          require_string(source, "#{path}.url", "url sources require url = \"https://...\" or file:///path.")
          optional_string(source, "#{path}.artifact")
          optional_string(source, "#{path}.token_env")
          optional_sha256(source, "#{path}.sha256")
          optional_string(source, "#{path}.checksum_url")
          optional_string(source, "#{path}.signature_url")
          optional_string(source, "#{path}.verify_command")
          optional_string(source, "#{path}.public_key_path")
          optional_boolean(source, "#{path}.allow_insecure")
          validate_string_table(source["headers"], "#{path}.headers", "url source headers") if source["headers"]
          optional_positive_integer(source, "#{path}.timeout_seconds", allow_zero: false)
          optional_positive_integer(source, "#{path}.retry_count", allow_zero: true)
          optional_positive_integer(source, "#{path}.retry_backoff_seconds", allow_zero: true)
          require_string(source, "#{path}.verify_command", "url signature verification requires verify_command.") if source["signature_url"]
        end
      end

      def validate_source_env(cfg, path)
        env = cfg["env"]
        return unless env

        unless env.is_a?(Hash)
          error("#{path}.env", "source env must be a TOML table of string values.")
          return
        end

        env.each do |key, value|
          validate_env_value("#{path}.env.#{key}", key, value, label: "source env")
        end
      end

      def validate_source_cache(cfg, path)
        cache = cfg["cache"]
        return unless cache

        unless cache.is_a?(Hash)
          error("#{path}.cache", "source cache must be a TOML table.")
          return
        end

        enabled = cache["enabled"]
        if !enabled.nil? && enabled != true && enabled != false
          error("#{path}.cache.enabled", "source cache.enabled must be a boolean.")
        end

        ttl = cache["ttl_seconds"]
        if !ttl.nil? && (!ttl.is_a?(Integer) || ttl.negative?)
          error("#{path}.cache.ttl_seconds", "source cache.ttl_seconds must be a non-negative integer.")
        end
      end

      def validate_string_table(value, path, label)
        unless value.is_a?(Hash)
          error(path, "#{label} must be a TOML table.")
          return
        end

        value.each do |key, item|
          error("#{path}.#{key}", "#{label} values must be strings.") unless stringish?(item)
        end
      end

      def optional_positive_integer(cfg, path, allow_zero:)
        key = path.split(".").last
        value = cfg[key]
        return if value.nil?

        invalid = !value.is_a?(Integer) || value.negative? || (!allow_zero && value.zero?)
        return unless invalid

        message = allow_zero ? "must be a non-negative integer." : "must be a positive integer."
        error(path, "#{path} #{message}")
      end

      def optional_sha256(cfg, path)
        key = path.split(".").last
        value = cfg[key]
        return if value.nil?

        unless stringish?(value) && value.match?(/\A[0-9a-fA-F]{64}\z/)
          error(path, "#{path} must be a 64-character hex SHA-256 string.")
        end
      end

      def optional_boolean(cfg, path)
        key = path.split(".").last
        value = cfg[key]
        return if value.nil?

        error(path, "#{path} must be a boolean.") unless value == true || value == false
      end

      def validate_pipeline(service_name, pipeline, path, allow_empty:)
        unless pipeline.is_a?(Array)
          error(path, "Pipeline definitions must be arrays of step names for service #{service_name.inspect}.")
          return
        end

        if pipeline.empty? && !allow_empty
          error(path, "Pipelines must contain at least one step.")
          return
        end

        pipeline.each_with_index do |step_name, idx|
          step_path = "#{path}[#{idx}]"
          unless stringish?(step_name)
            error(step_path, "Pipeline entries must be step names.")
            next
          end

          next if known_step?(step_name)

          error(step_path, "Unknown step #{step_name.inspect}. Supported steps: #{known_steps.join(', ')}.")
        end
      end

      def validate_step_sections(service_name, svc, pipeline, rollback, service_path)
        active_steps = (pipeline + rollback).uniq

        active_steps.each do |step_name|
          step_path = "#{service_path}.#{step_name}"
          cfg = svc[step_name]

          if !cfg.nil? && !cfg.is_a?(Hash)
            error(step_path, "#{step_name} configuration must be a TOML table.")
            next
          end

          cfg ||= {}
          step_class = Blink::Steps.lookup!(step_name)
          step_class.validate_config(cfg, service_config: svc, service_name: service_name, path: step_path).each do |issue|
            issue[:severity] == "warning" ? warn(issue[:path], issue[:message]) : error(issue[:path], issue[:message])
          end

          case step_name
          when "verify"
            validate_verify(service_name, cfg, step_path)
          when "remote_script"
            validate_remote_script(service_name, cfg, step_path)
          when "provision"
            validate_provision(cfg, step_path)
          when "docker"
            validate_docker(cfg, step_path)
          when "backup"
            warn(step_path, "backup will be a no-op unless install.dest is also configured.") unless svc.dig("install", "dest")
          when "rollback"
            warn(step_path, "rollback will be a no-op unless backup runs earlier in the deploy pipeline.") unless pipeline.include?("backup")
          end
        end
      end

      def validate_verify(service_name, cfg, path)
        _ = service_name
        has_suite = cfg["suite"]
        has_tests = cfg["tests"]

        if !has_suite && !has_tests
          error(path, "verify requires either suite = \"path/to/suite.rb\" or verify.tests.* entries.")
        end

        if has_suite
          require_string(cfg, "#{path}.suite", "verify.suite must point to a Ruby file.")
          suite_abs = absolute_path(has_suite, service_name: service_name)
          error("#{path}.suite", "Suite file not found: #{suite_abs}") unless suite_abs && File.exist?(suite_abs)
        end

        if cfg["tags"] && !array_of_strings?(cfg["tags"])
          error("#{path}.tags", "verify.tags must be an array of strings.")
        end

        return unless has_tests

        unless has_tests.is_a?(Hash)
          error("#{path}.tests", "verify.tests must be a table of named tests.")
          return
        end

        has_tests.each do |test_name, spec|
          test_path = "#{path}.tests.#{test_name}"
          unless spec.is_a?(Hash)
            error(test_path, "Inline tests must be TOML tables.")
            next
          end

          type = spec["type"]
          unless stringish?(type)
            error("#{test_path}.type", "Inline tests require a type.")
            next
          end

          unless known_inline_test_types.include?(type)
            error("#{test_path}.type", "Unknown inline test type #{type.inspect}. Supported types: #{known_inline_test_types.join(', ')}.")
            next
          end

          case type
          when "api", "http", "mcp", "ui"
            require_string(spec, "#{test_path}.url", "#{type} tests require a url.")
          when "shell"
            require_string(spec, "#{test_path}.command", "shell tests require a command.")
          when "script"
            script_rel = spec["path"]
            require_string(spec, "#{test_path}.path", "script tests require a local script path.")
            script_abs = absolute_path(script_rel, service_name: service_name)
            error("#{test_path}.path", "Script test file not found: #{script_abs}") unless script_abs && File.exist?(script_abs)
          end

          validate_inline_httpish_test(spec, test_path) if %w[api http mcp ui].include?(type)
          validate_inline_checks(spec["checks"], "#{test_path}.checks", test_type: type) if spec.key?("checks")

          if spec["tags"] && !array_of_strings?(spec["tags"])
            error("#{test_path}.tags", "Inline test tags must be an array of strings.")
          end
        end
      end

      def validate_inline_httpish_test(spec, path)
        optional_string(spec, "#{path}.method") if spec.key?("method")
        validate_string_table(spec["headers"], "#{path}.headers", "inline test headers") if spec["headers"]
        optional_positive_integer(spec, "#{path}.expect_status", allow_zero: false) if spec.key?("expect_status")
        optional_string(spec, "#{path}.expect_body") if spec.key?("expect_body")
        optional_string(spec, "#{path}.expect_json") if spec.key?("expect_json")
        optional_string(spec, "#{path}.selector") if spec.key?("selector")
        optional_string(spec, "#{path}.selector_type") if spec.key?("selector_type")
        optional_string(spec, "#{path}.expect_text") if spec.key?("expect_text")
        optional_boolean(spec, "#{path}.tls_insecure") if spec.key?("tls_insecure")
        warn(path, "tls_insecure = true — TLS verification disabled for this test.") if spec["tls_insecure"] == true
      end

      def validate_inline_checks(checks, path, test_type:)
        unless checks.is_a?(Hash) || checks.is_a?(Array)
          error(path, "Inline test checks must be a table of named checks.")
          return
        end

        entries = if checks.is_a?(Hash)
          checks.map { |name, check| ["#{path}.#{name}", check] }
        else
          checks.each_with_index.map { |check, idx| ["#{path}[#{idx}]", check] }
        end

        entries.each do |check_path, check|
          unless check.is_a?(Hash)
            error(check_path, "Each inline test check must be a TOML table.")
            next
          end

          type = check["type"]
          unless stringish?(type)
            error("#{check_path}.type", "Each inline test check requires type.")
            next
          end

          case type
          when "status"
            unless check["equals"].is_a?(Integer) && check["equals"].positive?
              error("#{check_path}.equals", "status checks require a positive integer equals value.")
            end
          when "body", "text"
            validate_check_value(check, check_path)
          when "header"
            require_string(check, "#{check_path}.name", "header checks require name.")
            validate_check_value(check, check_path, allow_present: true)
          when "json"
            require_string(check, "#{check_path}.path", "json checks require path.")
            validate_check_value(check, check_path, allow_present: true)
          when "selector"
            require_string(check, "#{check_path}.selector", "selector checks require selector.")
            engine = check["engine"] || check["selector_type"] || "css"
            unless %w[css xpath].include?(engine)
              error("#{check_path}.engine", "selector checks require engine = \"css\" or \"xpath\".")
            end
            optional_boolean(check, "#{check_path}.present") if check.key?("present")
            optional_positive_integer(check, "#{check_path}.count", allow_zero: true) if check.key?("count")
            unless test_type == "ui"
              error(check_path, "selector checks are only supported for ui tests.")
            end
          else
            error("#{check_path}.type", "Unknown inline test check type #{type.inspect}.")
          end
        end
      end

      def validate_check_value(check, path, allow_present: false)
        has_equals = check.key?("equals")
        has_contains = check.key?("contains")
        has_matches = check.key?("matches")
        has_present = check.key?("present")

        optional_boolean(check, "#{path}.present") if has_present
        optional_string(check, "#{path}.matches") if has_matches

        if has_contains
          value = check["contains"]
          valid = stringish?(value) || value.is_a?(Integer) || value == true || value == false
          error("#{path}.contains", "contains must be a string, integer, or boolean.") unless valid
        end

        return if has_equals || has_contains || has_matches || (allow_present && has_present)

        error(path, "Check must declare at least one matcher: equals, contains, matches#{allow_present ? ', or present' : ''}.")
      end

      def validate_remote_script(service_name, cfg, path)
        has_path = stringish?(cfg["path"])
        has_inline = stringish?(cfg["inline"])

        if has_path && has_inline
          error(path, "remote_script must declare either path or inline, not both.")
          return
        end

        unless has_path || has_inline
          error(path, "remote_script requires either path or inline.")
          return
        end

        return unless has_path

        script_abs = absolute_path(cfg["path"], service_name: service_name)
        error("#{path}.path", "Script file not found: #{script_abs}") unless script_abs && File.exist?(script_abs)
      end

      def validate_provision(cfg, path)
        if cfg["dirs"] && !array_of_strings?(cfg["dirs"])
          error("#{path}.dirs", "provision.dirs must be an array of strings.")
        end

        env_file = cfg["env_file"]
        return unless env_file

        unless env_file.is_a?(Hash)
          error("#{path}.env_file", "provision.env_file must be a TOML table.")
          return
        end

        require_string(env_file, "#{path}.env_file.path", "provision.env_file.path is required.")
        if env_file["seed"] && !env_file["seed"].is_a?(Hash)
          error("#{path}.env_file.seed", "provision.env_file.seed must be a TOML table.")
        end
        if env_file["seed"].is_a?(Hash)
          env_file["seed"].each do |key, value|
            validate_env_value("#{path}.env_file.seed.#{key}", key, value, label: "provision env_file seed")
          end
        end
        if env_file["always_update"]
          unless env_file["always_update"].is_a?(Array) && env_file["always_update"].all? { |v| v.is_a?(String) }
            error("#{path}.env_file.always_update", "provision.env_file.always_update must be an array of strings.")
          end
        end
      end

      def validate_docker(cfg, path)
        require_string(cfg, "#{path}.name", "docker.name is required.")

        build = cfg["build"]
        image = cfg["image"]

        if build
          unless build.is_a?(Hash)
            error("#{path}.build", "docker.build must be a TOML table.")
            return
          end

          require_string(build, "#{path}.build.dockerfile", "docker.build.dockerfile is required.")
        elsif !stringish?(image)
          error("#{path}.image", "docker.image is required when docker.build is absent.")
        end

        env_file = cfg["env_file"]
        if env_file && !env_file.is_a?(Hash)
          error("#{path}.env_file", "docker.env_file must be a TOML table.")
        elsif env_file
          require_string(env_file, "#{path}.env_file.path", "docker.env_file.path is required.")
        end
      end

      def require_hash(hash, key, message)
        value = hash[key]
        if !value.is_a?(Hash)
          error(key, message)
          return nil
        end
        value
      end

      def require_string(hash, path, message)
        value = hash[path.split(".").last]
        error(path, message) unless stringish?(value)
      end

      def optional_string(hash, path)
        value = hash[path.split(".").last]
        return if value.nil? || stringish?(value)

        error(path, "Expected a string value.")
      end

      def require_string_or_string_array(hash, path, message)
        value = hash[path.split(".").last]
        return if stringish?(value)
        return if array_of_strings?(value) && !value.empty?

        error(path, message)
      end

      def optional_string_or_array_of_strings(hash, path, message)
        value = hash[path.split(".").last]
        return if value.nil?
        return if stringish?(value)
        return if array_of_strings?(value)

        error(path, message)
      end

      def array_of_strings?(value)
        value.is_a?(Array) && value.all? { |item| stringish?(item) }
      end

      def validate_env_value(path, key, value, label:)
        unless stringish?(value)
          error(path, "#{label} values must be strings.")
          return
        end

        return unless secretish_key?(key)
        return if env_ref_only?(value)

        suggested = key.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")
        error(path, "#{label} secret values must use an env reference like ${#{suggested}} instead of a hardcoded literal.")
      end

      def secretish_key?(key)
        key.to_s.match?(SECRET_KEY_PATTERN)
      end

      def env_ref_only?(value)
        value.to_s.match?(ENV_REF_ONLY_PATTERN)
      end

      def stringish?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def known_step?(name)
        known_steps.include?(name)
      end

      def known_steps
        (defined?(Blink::Steps::REGISTRY) ? Blink::Steps::REGISTRY.keys : []).sort
      end

      def known_source_types
        (defined?(Blink::Sources::REGISTRY) ? Blink::Sources::REGISTRY.keys : []).sort
      end

      def known_inline_test_types
        (defined?(Blink::Testing::InlineRunner::REGISTRY) ? Blink::Testing::InlineRunner::REGISTRY.keys : []).sort
      end

      def validate_multi_source(service_name, source, path)
        builds = source["builds"]
        default_build = source["default"]

        if default_build && !builds.key?(default_build)
          error("#{path}.default", "source.default references unknown build #{default_build.inspect}.")
        end

        builds.each do |build_name, build_cfg|
          build_path = "#{path}.builds.#{build_name}"
          unless build_cfg.is_a?(Hash)
            error(build_path, "Each named build must be a TOML table.")
            next
          end

          # Each build entry in multi-source must have its own type — validate it as a full source config
          validate_source(service_name, build_cfg, build_path)
        end
      end

      def error(path, message)
        @errors << Issue.new(path: path, message: message, severity: "error")
      end

      def warn(path, message)
        @warnings << Issue.new(path: path, message: message, severity: "warning")
      end

      def absolute_path(relative, service_name: nil)
        return nil unless stringish?(relative)
        return relative if Pathname.new(relative).absolute?

        base = @service_dirs[service_name] || (@manifest_path ? File.dirname(@manifest_path) : Dir.pwd)
        File.expand_path(relative, base)
      end
    end
  end
end
