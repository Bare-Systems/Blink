# frozen_string_literal: true

# The Registry resolves a target for a given service + operation at runtime.
# It is a thin facade over the Manifest that adds convenience methods used
# by commands.
module Blink
  class Registry
    def initialize(manifest)
      @manifest = manifest
    end

    # Resolve the target for a service operation, applying overrides.
    def target_for(service_name, operation: "deploy", override: nil)
      svc = @manifest.service!(service_name)
      name = override || svc.dig(operation, "target") || @manifest.default_target_name
      raise Manifest::Error, "No target configured for service '#{service_name}'" unless name
      @manifest.target!(name)
    end

    # Return the pipeline steps for a service operation.
    def pipeline_for(service_name, operation: "deploy")
      svc = @manifest.service!(service_name)
      svc.dig(operation, "pipeline") || Runner::DEFAULT_PIPELINES[operation] || []
    end

    # Return the rollback pipeline for a service operation.
    def rollback_for(service_name, operation: "deploy")
      svc = @manifest.service!(service_name)
      svc.dig(operation, "rollback_pipeline") || []
    end

    def manifest = @manifest
  end
end
