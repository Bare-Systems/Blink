# frozen_string_literal: true

require "json"

module Blink
  # Executes a named pipeline (deploy, etc.) for a service.
  #
  # The runner:
  #   1. Resolves the target and pipeline from the manifest/registry
  #   2. Executes steps sequentially, building a shared StepContext
  #   3. On any step failure, executes the rollback pipeline
  #   4. Returns a RunResult (success/failure + per-step detail)
  #   5. Writes a blink.lock entry unless dry_run is true
  class Runner
    DEFAULT_PIPELINES = {
      "deploy" => %w[fetch_artifact stop backup install start health_check verify],
    }.freeze

    def initialize(manifest)
      @manifest = manifest
      @registry = Registry.new(manifest)
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

      pipeline = @registry.pipeline_for(service_name, operation: operation)
      rollback = @registry.rollback_for(service_name, operation: operation)

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
      failed_at    = nil
      run_started  = Time.now

      Output.header("#{operation.capitalize}: #{service_name}  →  #{target.description}")
      Output.info(svc["description"]) if svc["description"]
      Output.info("[dry-run mode]") if dry_run
      puts

      pipeline.each do |step_name|
        step_class = Steps.lookup!(step_name)
        step_cfg   = svc[step_name] || {}
        step       = step_class.new(step_cfg)

        Output.step(step_name)
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          step.call(ctx)
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3)
          step_results << { step: step_name, status: "pass", elapsed: elapsed }
        rescue => e
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(3)
          step_results << { step: step_name, status: "fail", error: e.message, elapsed: elapsed }
          Output.error("Step '#{step_name}' failed: #{e.message}")
          failed_at = step_name
          break
        end
      end

      # Rollback on failure
      if failed_at && rollback.any?
        puts
        Output.header("Rolling back #{service_name}...")
        rollback.each do |step_name|
          step_class = Steps.lookup!(step_name)
          step_cfg   = svc[step_name] || {}
          step       = step_class.new(step_cfg)
          Output.step("rollback: #{step_name}")
          begin
            step.call(ctx)
          rescue => e
            Output.error("rollback step '#{step_name}' failed: #{e.message}")
          end
        end
      end

      result = RunResult.new(
        service:      service_name,
        operation:    operation,
        target:       target.description,
        pipeline:     pipeline,
        step_results: step_results,
        failed_at:    failed_at,
        dry_run:      dry_run
      )

      Lock.record(@manifest, result, ctx, run_started) unless dry_run

      result
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # RunResult — immutable record of a pipeline execution.
  # ─────────────────────────────────────────────────────────────────────────
  RunResult = Struct.new(:service, :operation, :target, :pipeline, :step_results, :failed_at, :dry_run, keyword_init: true) do
    def success? = failed_at.nil?
    def failure? = !success?

    def summary
      if success?
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
        failed_at: failed_at,
      }
    end

    def to_json(*) = JSON.generate(to_h)
  end
end
