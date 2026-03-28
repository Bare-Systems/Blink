# frozen_string_literal: true

require "json"
require "time"

module Blink
  # Executes a named pipeline (deploy, etc.) for a service.
  #
  # The runner:
  #   1. Resolves the target and pipeline from the manifest/registry
  #   2. Executes steps sequentially, building a shared StepContext
  #   3. On any step failure, executes the rollback pipeline
  #   4. Returns a RunResult (success/failure + per-step detail)
  #   5. Writes `.blink/` state + history unless dry_run is true
  class Runner
    DEFAULT_PIPELINES = {
      "deploy"   => %w[fetch_artifact stop backup install start health_check verify],
      "build"    => %w[fetch_artifact],
      "rollback" => [],
    }.freeze

    def initialize(manifest)
      @manifest = manifest
      @registry = Registry.new(manifest)
      @planner = Planner.new(manifest)
    end

    # Run a pipeline for a service.
    #
    # operation:    "deploy" (the only built-in; others can be added)
    # target_name:  override the target declared in the manifest
    # dry_run:      print what would happen without executing
    # json_mode:    emit machine-readable JSON output
    # version:      artifact version ("latest" or a tag string)
    # build_name:   named build to use (multi-build local_build source)
    def run(service_name, operation: "deploy", target_name: nil, dry_run: false, json_mode: false, version: "latest", build_name: nil)
      svc    = @manifest.service!(service_name)
      target = @registry.target_for(service_name, operation: operation, override: target_name)
      plan   = @planner.build(service_name, operation: operation, target_name: target_name, build_name: build_name)

      pipeline = plan.pipeline
      rollback = plan.rollback

      ctx = Steps::StepContext.new(
        manifest:      @manifest,
        service_name:  service_name,
        target:        target,
        dry_run:       dry_run,
        json_mode:     json_mode,
        version:       version,
        build_name:    build_name,
        artifact_path: nil,
        backup_path:   nil
      )

      step_results = []
      rollback_results = []
      failed_at    = nil
      run_started  = Time.now

      unless json_mode
        Output.header("#{operation.capitalize}: #{service_name}  →  #{target.description}")
        Output.info(svc["description"]) if svc["description"]
        Output.info("[dry-run mode]") if dry_run
        puts
      end

      if plan.blockers.any?
        failed_at = "plan"
        unless json_mode
          plan.blockers.each { |blocker| Output.error("Plan blocker: #{blocker}") }
        end
      end

      pipeline.each do |step_name|
        break if failed_at

        step_class = Steps.lookup!(step_name)
        step_cfg   = svc[step_name] || {}
        step       = step_class.new(step_cfg)

        Output.step(step_name) unless json_mode
        started = Time.now
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          output = normalize_output(step.call(ctx))
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3)
          step_results << {
            step: step_name,
            status: "pass",
            started_at: started.utc.iso8601,
            completed_at: Time.now.utc.iso8601,
            elapsed: elapsed,
            output: output,
            definition: step.class.definition.to_h
          }
        rescue => e
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3)
          step_results << {
            step: step_name,
            status: "fail",
            started_at: started.utc.iso8601,
            completed_at: Time.now.utc.iso8601,
            error: e.message,
            elapsed: elapsed,
            definition: step.class.definition.to_h
          }
          Output.error("Step '#{step_name}' failed: #{e.message}") unless json_mode
          failed_at = step_name
        end
      end

      # Rollback on failure
      if failed_at && failed_at != "plan" && rollback.any?
        unless json_mode
          puts
          Output.header("Rolling back #{service_name}...")
        end

        rollback.each do |step_name|
          step_class = Steps.lookup!(step_name)
          step_cfg   = svc[step_name] || {}
          step       = step_class.new(step_cfg)
          Output.step("rollback: #{step_name}") unless json_mode
          started = Time.now
          t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            output = normalize_output(step.rollback(ctx))
            rollback_results << {
              step: step_name,
              status: "pass",
              started_at: started.utc.iso8601,
              completed_at: Time.now.utc.iso8601,
              elapsed: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3),
              output: output,
              definition: step.class.definition.to_h
            }
          rescue => e
            rollback_results << {
              step: step_name,
              status: "fail",
              started_at: started.utc.iso8601,
              completed_at: Time.now.utc.iso8601,
              elapsed: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3),
              error: e.message,
              definition: step.class.definition.to_h
            }
            Output.error("rollback step '#{step_name}' failed: #{e.message}") unless json_mode
          end
        end
      end

      result = RunResult.new(
        service:      service_name,
        operation:    operation,
        target:       target.description,
        pipeline:     pipeline,
        step_results: step_results,
        rollback_results: rollback_results,
        failed_at:    failed_at,
        dry_run:      dry_run,
        warnings:     plan.warnings,
        blockers:     plan.blockers,
        plan:         plan.to_h
      )

      Lock.record(@manifest, result, ctx, run_started, plan: plan) unless dry_run

      result
    end

    private

    def normalize_output(value)
      return nil if value.nil?

      JSON.parse(JSON.generate(value))
    rescue
      { "value" => value.to_s }
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # RunResult — immutable record of a pipeline execution.
  # ─────────────────────────────────────────────────────────────────────────
  RunResult = Struct.new(
    :service, :operation, :target, :pipeline, :step_results, :rollback_results,
    :failed_at, :dry_run, :warnings, :blockers, :plan, :run_id,
    keyword_init: true
  ) do
    def success? = failed_at.nil? && Array(blockers).empty?
    def failure? = !success?

    def summary
      if blockers&.any?
        "#{operation.capitalize} blocked: #{blockers.join('; ')}"
      elsif success?
        dry_run ? "Plan complete (dry-run)" : "#{operation.capitalize} succeeded"
      else
        "#{operation.capitalize} failed at step: #{failed_at}"
      end
    end

    def to_h
      {
        success:   success?,
        summary:   summary,
        service:   service,
        operation: operation,
        target:    target,
        dry_run:   dry_run,
        steps:     step_results,
        rollback_steps: rollback_results,
        failed_at: failed_at,
        warnings:  warnings,
        blockers:  blockers,
        run_id:    run_id,
        plan:      plan,
      }
    end

    def to_json(*) = JSON.generate(to_h)
  end
end
