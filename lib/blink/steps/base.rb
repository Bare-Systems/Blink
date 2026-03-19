# frozen_string_literal: true

module Blink
  module Steps
    # Global step registry: name (String) → Class
    REGISTRY = {}

    StepDefinition = Struct.new(
      :name,
      :klass,
      :description,
      :config_section,
      :required_keys,
      :supported_target_types,
      :rollback_strategy,
      :mutates_context,
      keyword_init: true
    ) do
      def rollback_supported?
        rollback_strategy != "none"
      end

      def to_h
        {
          name: name,
          class_name: klass.name,
          description: description,
          config_section: config_section,
          required_keys: required_keys,
          supported_target_types: supported_target_types,
          rollback_supported: rollback_supported?,
          rollback_strategy: rollback_strategy,
          mutates_context: mutates_context,
        }
      end
    end

    def self.register(name, klass)
      klass.registered_name = name.to_s if klass.respond_to?(:registered_name=)
      REGISTRY[name.to_s] = klass
    end

    def self.lookup!(name)
      REGISTRY[name.to_s] ||
        raise(Manifest::Error, "Unknown step '#{name}'. Available: #{REGISTRY.keys.join(", ")}")
    end

    def self.definition_for(name)
      lookup!(name).definition
    end

    def self.catalog
      REGISTRY.keys.sort.map { |name| definition_for(name).to_h }
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
      class << self
        attr_writer :registered_name

        def registered_name
          @registered_name || name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end

        def step_definition(description:, config_section: nil, required_keys: [], supported_target_types: %w[local ssh], rollback_strategy: "same", mutates_context: [])
          @step_definition = {
            description: description,
            config_section: config_section || registered_name,
            required_keys: Array(required_keys).map(&:to_s),
            supported_target_types: Array(supported_target_types).map(&:to_s),
            rollback_strategy: rollback_strategy.to_s,
            mutates_context: Array(mutates_context).map(&:to_s),
          }
        end

        def definition
          attrs = {
            description: "",
            config_section: registered_name,
            required_keys: [],
            supported_target_types: %w[local ssh],
            rollback_strategy: "same",
            mutates_context: [],
          }.merge(@step_definition || {})

          StepDefinition.new(name: registered_name, klass: self, **attrs)
        end

        def supports_target?(target)
          definition.supported_target_types.include?(target.config["type"].to_s)
        end

        def validate_config(config, service_config:, service_name:, path:)
          issues = []
          definition.required_keys.each do |key|
            value = config[key]
            next if value.is_a?(String) && !value.strip.empty?

            issues << {
              path: "#{path}.#{key}",
              message: "#{registered_name} requires #{key}.",
              severity: "error"
            }
          end
          issues
        end

        def plan_note(config, service_config: nil)
          _ = service_config
          return "" if config.nil? || config.empty?

          if config["command"].is_a?(String)
            config["command"]
          elsif config["dest"].is_a?(String)
            "→ #{config["dest"]}"
          elsif config["url"].is_a?(String)
            config["url"]
          elsif config["suite"].is_a?(String)
            "suite: #{config["suite"]}"
          else
            ""
          end
        end
      end

      # config: the step-specific config hash from the manifest
      #         (e.g. service_config["install"]), or {} if absent.
      def initialize(config = {})
        @config = config
      end

      # Execute the step. Must mutate ctx as needed and raise on failure.
      def call(ctx)
        validate(ctx)
        execute(ctx)
      end

      def validate(ctx)
        return if self.class.supports_target?(ctx.target)

        raise Manifest::Error,
          "Step '#{step_name}' does not support target type '#{ctx.target.config["type"]}'"
      end

      def plan(ctx)
        cfg = effective_config(ctx)
        {
          step: step_name,
          note: self.class.plan_note(cfg, service_config: ctx.service_config),
          definition: self.class.definition.to_h
        }
      end

      def execute(_ctx)
        raise NotImplementedError, "#{self.class}#execute is not implemented"
      end

      def rollback(ctx)
        if self.class.definition.rollback_strategy == "same"
          execute(ctx)
        else
          raise Manifest::Error, "Step '#{step_name}' does not support rollback execution"
        end
      end

      protected

      def dry_run?(ctx) = ctx.dry_run

      def effective_config(ctx)
        ctx.section(step_name).merge(@config)
      end

      def step_name
        self.class.registered_name
      end

      def dry_log(ctx, msg)
        Output.info("[dry-run] #{msg}") if ctx.dry_run
      end
    end
  end
end
