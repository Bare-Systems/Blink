# frozen_string_literal: true

require "json"
require "stringio"

module Blink
  # MCP server — stdio transport (JSON-RPC 2.0).
  #
  # Start with:  blink --mcp
  #
  # Reads one JSON object per line from stdin, writes one JSON object per
  # line to stdout. Stderr is reserved for server-side diagnostics.
  #
  # All tool responses include:
  #   success            Boolean
  #   summary            Human-readable one-liner (safe for agent reasoning)
  #   suggested_next_step  What the agent should do next (always present)
  #   data               Structured result payload (tool-specific)
  class MCPServer
    PROTOCOL_VERSION = "2024-11-05"

    TOOLS = [
      {
        name: "blink_list_services",
        description: "List all services declared in blink.toml with their description and configured pipeline.",
        inputSchema: {
          type: "object",
          properties: {},
          required: []
        }
      },
      {
        name: "blink_plan",
        description: "Show what `blink deploy` would do for a service without executing anything. " \
                     "Returns the pipeline steps, target, source, and rollback plan.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name from blink.toml" },
            target:  { type: "string", description: "Override the target declared in blink.toml" },
            build:   { type: "string", description: "Named build to select when source defines multiple builds (e.g. 'linux-amd64')" },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_build",
        description: "Build a service artifact using its declared source strategy (fetch/compile only — does not deploy). " \
                     "Returns the local path to the built artifact on success.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string",  description: "Service name from blink.toml" },
            build:   { type: "string",  description: "Named build strategy to use (e.g. 'local_docker', 'github')" },
            dry_run: { type: "boolean", description: "Preview without executing (default: false)" },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_deploy",
        description: "Deploy a service using its declared pipeline (fetch → stop → backup → install → start → health_check → verify). " \
                     "Automatically rolls back on failure. Returns per-step results and records a .blink history entry.",
        inputSchema: {
          type: "object",
          properties: {
            service:     { type: "string",  description: "Service name from blink.toml" },
            target:      { type: "string",  description: "Override the target declared in blink.toml" },
            version:     { type: "string",  description: "Release version to deploy (default: latest)" },
            build:       { type: "string",  description: "Named build to select when source defines multiple builds (e.g. 'linux-amd64')" },
            dry_run:     { type: "boolean", description: "Preview pipeline without executing (default: false)" },
            skip_build:  { type: "boolean", description: "Skip the fetch_artifact/build step and use the most recently cached artifact (default: false). " \
                                                          "Use this when the image is already in the registry from a prior blink_build call." },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_test",
        description: "Run verification test suites for a service. Returns per-test pass/fail results. " \
                     "Use tags to scope the run (e.g. 'smoke', 'health', 'e2e').",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name; omit to run all services" },
            tags:    { type: "array",  items: { type: "string" }, description: "Filter by tag (e.g. ['smoke', 'health'])" },
            target:  { type: "string", description: "Override the target to run tests against" },
            list:    { type: "boolean", description: "Return test metadata without running (default: false)" },
          },
          required: []
        }
      },
      {
        name: "blink_status",
        description: "Get the current operational status of one or all services on a target. " \
                     "Checks health endpoints and Docker container state.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name; omit for all services" },
            target:  { type: "string", description: "Override the target" },
          },
          required: []
        }
      },
      {
        name: "blink_logs",
        description: "Fetch recent log output for a service. Returns the last N lines as a string.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string",  description: "Service name" },
            lines:   { type: "integer", description: "Number of lines to return (default: 100)" },
            target:  { type: "string",  description: "Override the target" },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_restart",
        description: "Restart a service using its configured stop/start or restart command.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name" },
            target:  { type: "string", description: "Override the target" },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_ps",
        description: "Show running Docker containers on a target.",
        inputSchema: {
          type: "object",
          properties: {
            target:  { type: "string", description: "Override the target" },
          },
          required: []
        }
      },
      {
        name: "blink_steps",
        description: "List Blink's built-in step definitions and capability metadata.",
        inputSchema: {
          type: "object",
          properties: {
            step: { type: "string", description: "Specific step name to inspect" },
          },
          required: []
        }
      },
      {
        name: "blink_state",
        description: "Read the current persisted .blink state for one or all services.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name; omit for all services" },
          },
          required: []
        }
      },
      {
        name: "blink_history",
        description: "Read recent persisted .blink runs, or inspect a single run by run_id.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name; omit for all services" },
            limit: { type: "integer", description: "Maximum number of runs to return" },
            run_id: { type: "string", description: "Specific run id to inspect" },
          },
          required: []
        }
      },
      {
        name: "blink_rollback",
        description: "Execute a service rollback pipeline and persist the result to .blink history.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string", description: "Service name" },
            target:  { type: "string", description: "Override the target" },
            dry_run: { type: "boolean", description: "Preview rollback without executing it" },
          },
          required: ["service"]
        }
      },
      {
        name: "blink_doctor",
        description: "Run connectivity and health checks against all configured targets. " \
                     "Returns pass/fail results for each check.",
        inputSchema: {
          type: "object",
          properties: {
            target: { type: "string", description: "Run checks for a specific target only" },
          },
          required: []
        }
      },
    ].freeze

    def run
      $stdout.sync = true
      $stderr.sync = true
      $stdout.set_encoding("UTF-8")
      $stdin.set_encoding("UTF-8")
      log("blink MCP server started (v#{Blink::VERSION})")

      loop do
        line = $stdin.gets
        break unless line
        line = line.strip
        next if line.empty?

        begin
          request  = JSON.parse(line)
          response = dispatch(request)
          $stdout.puts(JSON.generate(response)) if response
        rescue JSON::ParserError => e
          $stdout.puts(JSON.generate(error_response(nil, -32_700, "Parse error: #{e.message}")))
        rescue => e
          log("Unhandled error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          $stdout.puts(JSON.generate(error_response(nil, -32_603, "Internal error: #{e.message}")))
        end
      end
    end

    private

    # ── JSON-RPC dispatch ────────────────────────────────────────────────────

    def dispatch(request)
      id     = request["id"]
      method = request["method"]
      params = request["params"] || {}

      case method
      when "initialize"
        ok_response(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: "blink", version: Blink::VERSION }
        })

      when "initialized"
        nil # notification — no response

      when "notifications/initialized"
        nil

      when "ping"
        ok_response(id, {})

      when "tools/list"
        ok_response(id, { tools: TOOLS })

      when "tools/call"
        tool_name = params["name"]
        arguments = params["arguments"] || {}
        log("tool call: #{tool_name}  args=#{arguments.inspect}")

        text = call_tool(tool_name, arguments)
        ok_response(id, { content: [{ type: "text", text: text }] })

      else
        error_response(id, -32_601, "Method not found: #{method}")
      end
    rescue Manifest::Error => e
      error_response(id, -32_602, "Manifest error: #{e.message}")
    rescue => e
      log("tool error: #{e.class}: #{e.message}")
      error_response(id, -32_603, "Tool error: #{e.message}")
    end

    # ── Tool dispatch ────────────────────────────────────────────────────────

    def call_tool(name, args)
      case name
      when "blink_list_services" then tool_list_services(args)
      when "blink_plan"          then tool_plan(args)
      when "blink_build"         then tool_build(args)
      when "blink_deploy"        then tool_deploy(args)
      when "blink_test"          then tool_test(args)
      when "blink_status"        then tool_status(args)
      when "blink_logs"          then tool_logs(args)
      when "blink_restart"       then tool_restart(args)
      when "blink_ps"            then tool_ps(args)
      when "blink_steps"         then tool_steps(args)
      when "blink_state"         then tool_state(args)
      when "blink_history"       then tool_history(args)
      when "blink_rollback"      then tool_rollback(args)
      when "blink_doctor"        then tool_doctor(args)
      else raise "Unknown tool '#{name}'. Available: #{TOOLS.map { _1[:name] }.join(", ")}"
      end
    end

    # ── Tool implementations ─────────────────────────────────────────────────

    def tool_list_services(_args)
      details = Operations::ListServices.new(start_dir: Dir.pwd).call

      JSON.generate({
        success:             true,
        summary:             "#{details[:services].size} service(s) across #{details[:manifests].size} manifest(s)",
        suggested_next_step: "Use blink_plan or blink_deploy to operate on a specific service.",
        data:                details
      })
    end

    def tool_plan(args)
      service    = require_arg!(args, "service")
      build_name = args["build"]
      manifest   = manifest_for_service(service)
      plan = Planner.new(manifest).build(service, target_name: args["target"], build_name: build_name)

      deploy_cmd = "blink_deploy with service='#{service}'#{build_name ? ", build='#{build_name}'" : ""}"

      JSON.generate({
        success:             plan.executable?,
        summary:             "Deploy #{service} via #{plan.pipeline.size}-step pipeline on #{plan.target["description"]}",
        suggested_next_step: "Run #{deploy_cmd} to execute this plan.",
        data:                plan.to_h
      })
    end

    def tool_build(args)
      service    = require_arg!(args, "service")
      dry_run    = args.fetch("dry_run", false)
      build_name = args["build"]

      manifest = manifest_for_service(service)
      runner   = Runner.new(manifest)

      output, result = capture_output do
        runner.run(
          service,
          operation:  "build",
          dry_run:    dry_run,
          json_mode:  false,
          build_name: build_name
        )
      end

      artifact = result.step_results
                       .find { |s| s[:step] == "fetch_artifact" }
                       &.dig(:output, "artifact_path")

      next_step = if result.success?
        dry_run ? "Run blink_build without dry_run=true to execute the build." \
                : "Run blink_deploy with service='#{service}'#{build_name ? ", build='#{build_name}'" : ""} to deploy this artifact."
      else
        "Check the failed step '#{result.failed_at}'. Inspect the build command and retry with blink_build."
      end

      JSON.generate({
        success:             result.success?,
        summary:             result.summary,
        suggested_next_step: next_step,
        data:                result.to_h.merge(output: output, artifact_path: artifact, manifest: manifest.path)
      })
    end

    def tool_deploy(args)
      service     = require_arg!(args, "service")
      dry_run     = args.fetch("dry_run", false)
      version     = args.fetch("version", "latest")
      build_name  = args["build"]
      skip_build  = args.fetch("skip_build", false)

      manifest = manifest_for_service(service)
      runner   = Runner.new(manifest)

      output, result = capture_output do
        runner.run(
          service,
          target_name: args["target"],
          dry_run:     dry_run,
          json_mode:   false,
          version:     version,
          build_name:  build_name,
          skip_build:  skip_build
        )
      end

      next_step = if result.success?
        dry_run ? "Run blink_deploy without dry_run=true to execute the deployment." \
                : "Run blink_test with service='#{service}' to verify the deployment."
      else
        "Check the failed step '#{result.failed_at}'. You can retry with blink_deploy or inspect logs with blink_logs."
      end

      JSON.generate({
        success:             result.success?,
        summary:             result.summary,
        suggested_next_step: next_step,
        data:                result.to_h.merge(output: output, manifest: manifest.path)
      })
    end

    def tool_test(args)
      service  = args["service"]
      tags     = Array(args["tags"] || []).map(&:to_sym)
      list_only = args.fetch("list", false)

      manifest = service ? manifest_for_service(service) : workspace_manifest
      operation = Operations::TestRun.new(
        manifest: manifest,
        service_name: service,
        tags: tags,
        target_name: args["target"]
      )

      unless operation.available?
        return JSON.generate({
          success:             false,
          summary:             "No suites found#{service ? " for '#{service}'" : ""}",
          suggested_next_step: "Ensure verify.suite is configured in blink.toml for this service.",
          data:                {}
        })
      end

      if list_only
        details = operation.list
        return JSON.generate({
          success:             true,
          summary:             "#{details[:tests].size} test(s) available",
          suggested_next_step: "Run blink_test without list=true to execute these tests.",
          data:                details.merge(manifest: manifest.path)
        })
      end

      run = operation.run
      result = run[:result]

      next_step = if result.success?
        "All tests passed. Deployment is verified."
      else
        failed_names = result.records.select { |r| %i[fail error].include?(r.status) }.map(&:name)
        "#{result.failed + result.errored} test(s) failed: #{failed_names.join(", ")}. Check logs or re-deploy."
      end

      JSON.generate({
        success:             result.success?,
        summary:             "#{result.passed}/#{result.total} passed#{result.failed > 0 ? ", #{result.failed} failed" : ""}",
        suggested_next_step: next_step,
        data:                result.to_h.merge(manifest: manifest.path, target: run[:target], service: service)
      })
    end

    def tool_status(args)
      manifest = args["service"] ? manifest_for_service(args["service"]) : workspace_manifest
      result = Operations::Status.new(
        manifest: manifest,
        service_name: args["service"],
        target_name: args["target"]
      ).call

      unless result[:reachable]
        return JSON.generate({
          success:             false,
          summary:             "Target '#{result[:target_name]}' (#{result[:target]}) is unreachable",
          suggested_next_step: "Check SSH connectivity with blink_doctor.",
          data:                { target: result[:target], services: [] }
        })
      end

      next_step = if result[:down] > 0
        down_names = result[:services].select { _1[:healthy] == false }.map { _1[:name] }
        "#{result[:down]} service(s) are down: #{down_names.join(", ")}. Use blink_logs or blink_deploy to investigate."
      else
        "All #{result[:healthy]} service(s) are healthy."
      end

      JSON.generate({
        success:             result[:down] == 0,
        summary:             "#{result[:healthy]}/#{result[:total]} service(s) healthy on #{result[:target]}",
        suggested_next_step: next_step,
        data:                { target: result[:target], services: result[:services], manifest: manifest.path }
      })
    end

    def tool_logs(args)
      service = require_arg!(args, "service")
      lines   = (args["lines"] || 100).to_i

      manifest = manifest_for_service(service)
      details = Operations::Logs.new(
        manifest: manifest,
        service_name: service,
        lines: lines,
        target_name: args["target"]
      ).call

      JSON.generate({
        success:             true,
        summary:             "Last #{lines} lines of #{service} logs",
        suggested_next_step: "Look for ERROR or WARN lines. Use blink_deploy to redeploy if broken.",
        data:                details.merge(manifest: manifest.path)
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not fetch logs for #{service}: #{e.message}",
        suggested_next_step: "Verify the service is running with blink_status.",
        data:                {}
      })
    end

    def tool_restart(args)
      service = require_arg!(args, "service")
      manifest = manifest_for_service(service)
      details = Operations::Restart.new(
        manifest: manifest,
        service_name: service,
        target_name: args["target"]
      ).call

      JSON.generate({
        success:             true,
        summary:             "#{service} restarted",
        suggested_next_step: "Run blink_status with service='#{service}' to confirm it is healthy.",
        data:                details.merge(manifest: manifest.path)
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not restart #{service}: #{e.message}",
        suggested_next_step: "Check the service configuration and target connectivity, then retry.",
        data:                {}
      })
    end

    def tool_ps(args)
      manifest = workspace_manifest
      details = Operations::Ps.new(manifest: manifest, target_name: args["target"]).call

      JSON.generate({
        success:             true,
        summary:             "#{details[:container_count]} container(s) listed on #{details[:target]}",
        suggested_next_step: "Inspect the container list for unhealthy or missing services.",
        data:                details
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not list containers: #{e.message}",
        suggested_next_step: "Check the target with blink_doctor and verify Docker is available.",
        data:                {}
      })
    end

    def tool_steps(args)
      details = Operations::StepCatalog.new(step_name: args["step"]).call

      JSON.generate({
        success:             true,
        summary:             args["step"] ? "Step definition loaded for #{args["step"]}" : "#{details[:steps].size} step definition(s) loaded",
        suggested_next_step: args["step"] ? "Use this step in a pipeline or rollback_pipeline in blink.toml." :
                                            "Use blink_steps with step='<name>' to inspect a specific step.",
        data:                details
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not inspect steps: #{e.message}",
        suggested_next_step: "Call blink_steps without arguments to list the available built-in steps.",
        data:                {}
      })
    end

    def tool_state(args)
      manifest = args["service"] ? manifest_for_service(args["service"]) : workspace_manifest
      details = Operations::State.new(manifest: manifest, service_name: args["service"]).call

      JSON.generate({
        success:             true,
        summary:             args["service"] ? "State loaded for #{args["service"]}" : "#{details[:services].size} service state record(s) loaded",
        suggested_next_step: "Use blink_history to inspect recent runs behind this state.",
        data:                details
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not read state: #{e.message}",
        suggested_next_step: "Run blink_deploy or blink_test first so Blink has persisted state to inspect.",
        data:                {}
      })
    end

    def tool_history(args)
      manifest = args["service"] ? manifest_for_service(args["service"]) : workspace_manifest
      details = Operations::History.new(
        manifest: manifest,
        service_name: args["service"],
        limit: args["limit"] || 20,
        run_id: args["run_id"]
      ).call

      JSON.generate({
        success:             true,
        summary:             args["run_id"] ? "History loaded for run #{args["run_id"]}" : "#{details[:count]} run(s) loaded",
        suggested_next_step: args["run_id"] ? "Use blink_state to compare this run with current persisted state." :
                                              "Use blink_history with run_id to inspect a specific run in detail.",
        data:                details
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not read history: #{e.message}",
        suggested_next_step: "Run blink_deploy or blink_test first so Blink has persisted runs to inspect.",
        data:                {}
      })
    end

    def tool_rollback(args)
      service = require_arg!(args, "service")
      manifest = manifest_for_service(service)
      output, result = capture_output do
        Operations::Rollback.new(
          manifest: manifest,
          service_name: service,
          target_name: args["target"],
          dry_run: args.fetch("dry_run", false),
          json_mode: false
        ).call
      end

      JSON.generate({
        success:             result.success?,
        summary:             result.summary,
        suggested_next_step: result.success? ? "Run blink_status with service='#{service}' to confirm recovery." :
                                              "Inspect the failed rollback step and review blink_history for the recorded run.",
        data:                result.to_h.merge(output: output, manifest: manifest.path)
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not rollback #{service}: #{e.message}",
        suggested_next_step: "Define a rollback pipeline and verify target connectivity, then retry.",
        data:                {}
      })
    end

    def tool_doctor(args)
      manifest = workspace_manifest
      result = Operations::Doctor.new(manifest: manifest, target_name: args["target"]).call

      next_step = if result[:failed] > 0
        failing = result[:checks].select { _1[:status] == "fail" }.map { _1[:check] }
        "Fix failing checks: #{failing.join(", ")}."
      elsif result[:warnings] > 0
        "All checks pass with #{result[:warnings]} warning(s). Monitor disk/memory usage."
      else
        "All #{result[:passed]} checks passed. System looks healthy."
      end

      JSON.generate({
        success:             result[:failed] == 0,
        summary:             "#{result[:passed]} passed, #{result[:failed]} failed, #{result[:warnings]} warnings",
        suggested_next_step: next_step,
        data:                result
      })
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def require_arg!(args, key)
      args[key] || raise("Missing required argument: '#{key}'")
    end

    def manifest_for_service(service_name)
      Manifest.load_for_service!(service_name, start_dir: Dir.pwd)
    end

    # Load the primary workspace manifest. Falls back to discover_all when
    # Dir.pwd is not within a project (e.g. when the MCP server runs from /).
    def workspace_manifest
      Manifest.load(start_dir: Dir.pwd)
    rescue Manifest::Error
      manifests = Manifest.discover_all(start_dir: Dir.pwd)
      raise Manifest::Error, "No blink.toml found" if manifests.empty?
      manifests.max_by { |m| m.service_names.size }
    end

    # Run a block, capture all stdout, strip ANSI codes, and return
    # [plain_string, block_return_value].
    ANSI_STRIP = /\e\[[0-9;]*[mGKHF]/

    def capture_output
      old_stdout = $stdout
      $stdout    = StringIO.new
      result     = yield
      raw        = $stdout.string.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      $stdout    = old_stdout
      plain      = raw.gsub(ANSI_STRIP, "")
      [plain, result]
    rescue => e
      $stdout = old_stdout if old_stdout
      raise e
    end

    def ok_response(id, result)
      { jsonrpc: "2.0", id: id, result: result }
    end

    def error_response(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end

    def log(msg)
      $stderr.puts("[blink-mcp] #{msg}")
    end
  end
end
