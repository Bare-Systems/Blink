# frozen_string_literal: true

require "digest"
require "json"

module Blink
  class Plan
    attr_reader :service, :operation, :build_name, :manifest_path, :description,
                    :target, :source, :pipeline, :rollback, :steps, :rollback_steps,
                    :warnings, :blockers, :security, :resolved_config, :config_hash

    def initialize(service:, operation:, build_name:, manifest_path:, description:, target:, source:,
                   pipeline:, rollback:, steps:, rollback_steps:, warnings:, blockers:, security:, resolved_config:)
      @service = service
      @operation = operation
      @build_name = build_name
      @manifest_path = manifest_path
      @description = description
      @target = target
      @source = source
      @pipeline = pipeline
      @rollback = rollback
      @steps = steps
      @rollback_steps = rollback_steps
      @warnings = warnings
      @blockers = blockers
      @security = security
      @resolved_config = sort_value(resolved_config)
      @config_hash = Digest::SHA256.hexdigest(JSON.generate(@resolved_config))
    end

    def executable?
      blockers.empty?
    end

    def to_h
      {
        success: executable?,
        service: service,
        operation: operation,
        build_name: build_name,
        manifest: manifest_path,
        description: description,
        target: target,
        source: source,
        pipeline: pipeline,
        rollback: rollback,
        steps: steps,
        rollback_steps: rollback_steps,
        warnings: warnings,
        blockers: blockers,
        security: security,
        config_hash: config_hash,
        resolved_config: resolved_config,
      }
    end

    def to_json(*)
      JSON.generate(to_h)
    end

    private

    def sort_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, sorted|
          sorted[key] = sort_value(value[key])
        end
      when Array
        value.map { |item| sort_value(item) }
      else
        value
      end
    end
  end
end
