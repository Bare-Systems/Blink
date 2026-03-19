# frozen_string_literal: true

module Blink
  # Generates a human-readable plan (like `terraform plan`) for a service
  # operation, without executing any steps.
  class Planner
    def initialize(manifest)
      @manifest = manifest
      @registry = Registry.new(manifest)
    end

    def plan(service_name, operation: "deploy", target_name: nil, build_name: nil, json_mode: false)
      svc      = @manifest.service!(service_name)
      target   = @registry.target_for(service_name, operation: operation, override: target_name)
      pipeline = @registry.pipeline_for(service_name, operation: operation)
      rollback = @registry.rollback_for(service_name, operation: operation)

      if json_mode
        require "json"
        puts JSON.generate(
          service:    service_name,
          operation:  operation,
          build_name: build_name,
          target:     target.description,
          pipeline:   pipeline,
          rollback:   rollback,
          steps:      describe_steps(svc, pipeline)
        )
        return
      end

      Output.header("Plan: #{operation} #{service_name}")
      puts
      printf "  %-16s %s\n", "Service:", service_name
      printf "  %-16s %s\n", "Operation:", operation
      printf "  %-16s %s\n", "Target:", target.description
      printf "  %-16s %s\n", "Description:", svc["description"] if svc["description"]

      source_cfg = svc["source"]
      if source_cfg
        builds = source_cfg["builds"]
        if builds && !builds.empty?
          resolved = build_name || source_cfg["default"] || (builds.size == 1 ? builds.keys.first : nil)
          printf "  %-16s %s (%s)\n", "Source:", source_cfg["type"], "multi-build"
          builds.each do |name, bcfg|
            marker = name == resolved ? " ◀ selected" : ""
            printf "    %-14s %s%s\n", name + ":", bcfg["artifact"].to_s, marker
          end
        else
          printf "  %-16s %s (%s)\n", "Source:", source_cfg["repo"] || source_cfg["image"] || "?", source_cfg["type"]
        end
      end

      puts
      puts "  #{Output::BOLD}Pipeline (#{pipeline.size} steps):#{Output::RESET}"
      pipeline.each_with_index do |step_name, i|
        cfg = svc[step_name]
        note = step_note(step_name, cfg)
        printf "    #{Output::CYAN}%2d.#{Output::RESET}  %-20s %s\n", i + 1, step_name, note
      end

      if rollback.any?
        puts
        puts "  #{Output::BOLD}Rollback pipeline (#{rollback.size} steps):#{Output::RESET}"
        rollback.each_with_index do |step_name, i|
          cfg  = svc[step_name]
          note = step_note(step_name, cfg)
          printf "    #{Output::YELLOW}%2d.#{Output::RESET}  %-20s %s\n", i + 1, step_name, note
        end
      end

      puts
      build_flag = build_name ? " --build #{build_name}" : ""
      Output.info("Run `blink deploy #{service_name}#{build_flag}` to execute this plan.")
    end

    private

    def step_note(step_name, cfg)
      return "" unless cfg
      case step_name
      when "stop", "start"       then cfg["command"].to_s
      when "install"             then "→ #{cfg["dest"]}" if cfg["dest"]
      when "health_check"        then cfg["url"].to_s
      when "verify"              then "suite: #{cfg["suite"]}  tags: #{Array(cfg["tags"]).join(", ")}"
      else ""
      end.to_s
    end

    def describe_steps(svc, pipeline)
      pipeline.map do |step_name|
        cfg = svc[step_name] || {}
        { step: step_name, config: cfg }
      end
    end
  end
end
