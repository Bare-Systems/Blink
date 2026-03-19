# frozen_string_literal: true

module Blink
  module Steps
    # Global step registry: name (String) → Class
    REGISTRY = {}

    def self.register(name, klass)
      REGISTRY[name.to_s] = klass
    end

    def self.lookup!(name)
      REGISTRY[name.to_s] ||
        raise(Manifest::Error, "Unknown step '#{name}'. Available: #{REGISTRY.keys.join(", ")}")
    end

    # ─────────────────────────────────────────────────────────────────────────
    # StepContext — mutable bag of state shared across steps in one pipeline run.
    # ─────────────────────────────────────────────────────────────────────────
    StepContext = Struct.new(
      :manifest,       # Blink::Manifest
      :service_name,   # String
      :target,         # Targets::Base subclass
      :dry_run,        # Boolean
      :json_mode,      # Boolean
      :version,        # String — "latest" or a tag
      :build_name,     # String|nil — named build to use (multi-build source)
      :artifact_path,  # String|nil — set by fetch_artifact
      :backup_path,    # String|nil — set by backup
      keyword_init: true
    ) do
      def service_config
        manifest.service(service_name)
      end

      # Config for a named sub-section of the service (e.g. "stop", "install").
      def section(key)
        service_config[key.to_s] || {}
      end

      # Interpolate {{var}} tokens.
      # Lookup order: service config → target config → leave unchanged.
      # Only string values are substituted; nested tables are skipped.
      def resolve(str)
        str.gsub(/\{\{(\w+)\}\}/) do
          key = $1
          val = service_config[key]
          val = target.config[key] unless val.is_a?(String)
          val.is_a?(String) ? val : $&
        end
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Base class for all steps.
    # ─────────────────────────────────────────────────────────────────────────
    class Base
      # config: the step-specific config hash from the manifest
      #         (e.g. service_config["install"]), or {} if absent.
      def initialize(config = {})
        @config = config
      end

      # Execute the step. Must mutate ctx as needed and raise on failure.
      def call(ctx)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      protected

      def dry_run?(ctx) = ctx.dry_run

      def dry_log(ctx, msg)
        Output.info("[dry-run] #{msg}") if ctx.dry_run
      end
    end
  end
end
