# frozen_string_literal: true

require "uri"

module Blink
  # Generates a human-readable plan (like `terraform plan`) for a service
  # operation, without executing any steps.
  class Planner
    def initialize(manifest)
      @manifest = manifest
      @registry = Registry.new(manifest)
    end

    def build(service_name, operation: "deploy", target_name: nil, build_name: nil)
      svc      = @manifest.service!(service_name)
      target   = @registry.target_for(service_name, operation: operation, override: target_name)
      pipeline = @registry.pipeline_for(service_name, operation: operation)
      rollback = @registry.rollback_for(service_name, operation: operation)

      warnings, blockers = diagnostics_for(
        svc,
        pipeline,
        rollback,
        operation: operation,
        target: target,
        declared_target: svc.dig(operation, "target"),
        build_name: build_name
      )
      security = source_security_for(svc["source"], pipeline)

      steps = describe_steps(svc, pipeline)
      rollback_steps = describe_steps(svc, rollback)

      resolved_config = {
        "service" => service_name,
        "operation" => operation,
        "build_name" => build_name,
        "target" => {
          "name" => target.name,
          "type" => target.config["type"],
          "description" => target.description,
          "base" => target.base,
          "config" => target.config
        },
        "service_config" => svc,
        "source" => svc["source"],
        "security" => security,
        "pipeline" => pipeline,
        "rollback_pipeline" => rollback,
      }

      Plan.new(
        service: service_name,
        operation: operation,
        build_name: build_name,
        manifest_path: @manifest.path,
        description: svc["description"],
        target: {
          "name" => target.name,
          "type" => target.config["type"],
          "description" => target.description,
          "base" => target.base
        },
        source: svc["source"],
        pipeline: pipeline,
        rollback: rollback,
        steps: steps,
        rollback_steps: rollback_steps,
        warnings: warnings,
        blockers: blockers,
        security: security,
        resolved_config: resolved_config
      )
    end

    def plan(service_name, operation: "deploy", target_name: nil, build_name: nil, json_mode: false)
      plan = build(service_name, operation: operation, target_name: target_name, build_name: build_name)

      if json_mode
        puts plan.to_json
        return plan
      end

      Output.header("Plan: #{operation} #{service_name}")
      puts
      printf "  %-16s %s\n", "Service:", service_name
      printf "  %-16s %s\n", "Operation:", operation
      printf "  %-16s %s\n", "Target:", plan.target["description"]
      printf "  %-16s %s\n", "Description:", plan.description if plan.description

      source_cfg = plan.source
      if source_cfg
        builds = source_cfg["builds"]
        if builds && !builds.empty?
          resolved = build_name || source_cfg["default"] || (builds.size == 1 ? builds.keys.first : nil)
          if source_cfg["type"].nil?
            # Multi-source: each build has its own type
            printf "  %-16s %s\n", "Source:", "multi-source"
            builds.each do |name, bcfg|
              marker = name == resolved ? " ◀ selected" : ""
              printf "    %-14s %s (%s)%s\n", name + ":", bcfg["artifact"].to_s, bcfg["type"].to_s, marker
            end
          else
            # local_build named variants (all same type)
            printf "  %-16s %s (%s)\n", "Source:", source_cfg["type"], "multi-build"
            builds.each do |name, bcfg|
              marker = name == resolved ? " ◀ selected" : ""
              printf "    %-14s %s%s\n", name + ":", bcfg["artifact"].to_s, marker
            end
          end
        else
          printf "  %-16s %s (%s)\n", "Source:", source_cfg["repo"] || source_cfg["image"] || "?", source_cfg["type"]
        end
      end

      puts
      puts "  #{Output::BOLD}Pipeline (#{plan.pipeline.size} steps):#{Output::RESET}"
      plan.steps.each_with_index do |step, i|
        printf "    #{Output::CYAN}%2d.#{Output::RESET}  %-20s %s\n", i + 1, step[:step], step[:note]
      end

      if plan.rollback.any?
        puts
        puts "  #{Output::BOLD}Rollback pipeline (#{plan.rollback.size} steps):#{Output::RESET}"
        plan.rollback_steps.each_with_index do |step, i|
          printf "    #{Output::YELLOW}%2d.#{Output::RESET}  %-20s %s\n", i + 1, step[:step], step[:note]
        end
      end

      if plan.warnings.any?
        puts
        puts "  #{Output::BOLD}Warnings:#{Output::RESET}"
        plan.warnings.each { |warning| puts "    - #{warning}" }
      end

      if plan.security["applicable"]
        puts
        puts "  #{Output::BOLD}Source Security:#{Output::RESET}"
        printf "    %-18s %s\n", "Transport:", plan.security["transport"] || "n/a"
        printf "    %-18s %s\n", "Checksum:", plan.security.dig("integrity", "mode") || "none"
        printf "    %-18s %s\n", "Provenance:", plan.security.dig("provenance", "mode") || "none"
        printf "    %-18s %s\n", "Signature:", plan.security.dig("signature", "mode") || "none"
      end

      if plan.blockers.any?
        puts
        puts "  #{Output::BOLD}Blockers:#{Output::RESET}"
        plan.blockers.each { |blocker| puts "    - #{blocker}" }
      end

      puts
      printf "  %-16s %s\n", "Config hash:", plan.config_hash

      puts
      build_flag = build_name ? " --build #{build_name}" : ""
      Output.info("Run `blink deploy #{service_name}#{build_flag}` to execute this plan.")

      plan
    end

    private

    def describe_steps(svc, pipeline)
      pipeline.map do |step_name|
        cfg = svc[step_name] || {}
        definition = Steps.definition_for(step_name)
        {
          step: step_name,
          config: cfg,
          note: definition.klass.plan_note(cfg, service_config: svc).to_s,
          definition: definition.to_h
        }
      end
    end

    def diagnostics_for(svc, pipeline, rollback, operation:, target:, declared_target:, build_name:)
      warnings = []
      blockers = []
      security = source_security_for(svc["source"], pipeline)

      warnings << "No description provided for this service." if svc["description"].to_s.strip.empty?
      warnings << "No rollback pipeline declared." if operation == "deploy" && rollback.empty?
      warnings << "#{operation}.target is not set; Blink will use the default target." if declared_target.nil? && operation != "rollback"

      blockers << "Pipeline is empty." if pipeline.empty?
      blockers << "fetch_artifact requires a source definition." if pipeline.include?("fetch_artifact") && !svc["source"]
      blockers << "install requires install.dest." if pipeline.include?("install") && !svc.dig("install", "dest")
      blockers << "stop requires stop.command." if pipeline.include?("stop") && !svc.dig("stop", "command")
      blockers << "start requires start.command." if pipeline.include?("start") && !svc.dig("start", "command")
      blockers << "health_check requires health_check.url." if pipeline.include?("health_check") && !svc.dig("health_check", "url")
      blockers << "verify requires verify.suite or verify.tests." if pipeline.include?("verify") && !svc.dig("verify", "suite") && !svc.dig("verify", "tests")

      source_cfg = svc["source"] || {}
      if pipeline.include?("fetch_artifact")
        builds = source_cfg["builds"] || {}
        if builds.size > 1 && build_name.nil? && source_cfg["default"].nil?
          blockers << "Multiple builds defined (#{builds.keys.join(", ")}) but neither source.default nor --build was provided."
        end
      end

      if security["remote"] && !security.dig("integrity", "configured") && !security.dig("signature", "configured")
        warnings << "Remote source has no artifact verification configured."
      end

      if security.dig("provenance", "configured") && !security.dig("signature", "configured")
        warnings << "Published checksum provenance is not signed."
      end

      if security["transport"] == "http"
        if security["allow_insecure"]
          warnings << "Source URL uses insecure HTTP transport."
        else
          blockers << "Source URL uses insecure HTTP transport. Set source.allow_insecure = true to opt in explicitly."
        end
      end

      if security["checksum_transport"] == "http"
        if security["allow_insecure"]
          warnings << "Checksum source uses insecure HTTP transport."
        else
          blockers << "Checksum source uses insecure HTTP transport. Set source.allow_insecure = true to opt in explicitly."
        end
      end

      if security["signature_transport"] == "http"
        if security["allow_insecure"]
          warnings << "Signature source uses insecure HTTP transport."
        else
          blockers << "Signature source uses insecure HTTP transport. Set source.allow_insecure = true to opt in explicitly."
        end
      end

      (pipeline + rollback).uniq.each do |step_name|
        next if Steps.lookup!(step_name).supports_target?(target)

        blockers << "step #{step_name.inspect} does not support target type #{target.config["type"].inspect}."
      end

      [warnings.uniq, blockers.uniq]
    end

    def source_security_for(source_cfg, pipeline)
      return { "applicable" => false, "remote" => false } unless pipeline.include?("fetch_artifact") && source_cfg.is_a?(Hash)

      # Multi-source: security is per-build; report as non-applicable at the top level for now
      return { "applicable" => false, "remote" => false, "type" => "multi_source" } if source_cfg["type"].nil?

      type = source_cfg["type"]
      integrity_mode =
        if source_cfg["sha256"]
          "manifest.sha256"
        elsif source_cfg["checksum_url"]
          "checksum_url"
        elsif source_cfg["checksum_asset"]
          "checksum_asset"
        end
      provenance_mode =
        if source_cfg["checksum_url"]
          "checksum_url"
        elsif source_cfg["checksum_asset"]
          "checksum_asset"
        end
      signature_mode =
        if source_cfg["signature_url"]
          "signature_url"
        elsif source_cfg["signature_asset"]
          "signature_asset"
        end

      {
        "applicable" => true,
        "type" => type,
        "remote" => %w[url github_release].include?(type),
        "transport" => source_transport_for(type, source_cfg),
        "checksum_transport" => checksum_transport_for(type, source_cfg),
        "signature_transport" => signature_transport_for(type, source_cfg),
        "allow_insecure" => source_cfg["allow_insecure"] == true,
        "integrity" => {
          "configured" => !integrity_mode.nil? || !signature_mode.nil?,
          "mode" => integrity_mode || "none"
        },
        "provenance" => {
          "configured" => !provenance_mode.nil?,
          "mode" => provenance_mode || "none"
        },
        "signature" => {
          "configured" => !signature_mode.nil?,
          "mode" => signature_mode || "none"
        }
      }
    end

    def transport_for(value)
      return nil unless value.is_a?(String) && !value.strip.empty?

      URI(value).scheme
    rescue URI::InvalidURIError
      nil
    end

    def source_transport_for(type, source_cfg)
      case type
      when "github_release"
        transport_for(source_cfg["api_base"]) || "https"
      else
        transport_for(source_cfg["url"])
      end
    end

    def checksum_transport_for(type, source_cfg)
      return source_transport_for(type, source_cfg) if type == "github_release" && source_cfg["checksum_asset"]

      transport_for(source_cfg["checksum_url"])
    end

    def signature_transport_for(type, source_cfg)
      return source_transport_for(type, source_cfg) if type == "github_release" && source_cfg["signature_asset"]

      transport_for(source_cfg["signature_url"])
    end
  end
end
