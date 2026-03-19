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
        name: "blink_deploy",
        description: "Deploy a service using its declared pipeline (fetch → stop → backup → install → start → health_check → verify). " \
                     "Automatically rolls back on failure. Returns per-step results. Writes a blink.lock entry on completion.",
        inputSchema: {
          type: "object",
          properties: {
            service: { type: "string",  description: "Service name from blink.toml" },
            target:  { type: "string",  description: "Override the target declared in blink.toml" },
            version: { type: "string",  description: "Release version to deploy (default: latest)" },
            build:   { type: "string",  description: "Named build to select when source defines multiple builds (e.g. 'linux-amd64')" },
            dry_run: { type: "boolean", description: "Preview pipeline without executing (default: false)" },
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
      when "blink_deploy"        then tool_deploy(args)
      when "blink_test"          then tool_test(args)
      when "blink_status"        then tool_status(args)
      when "blink_logs"          then tool_logs(args)
      when "blink_doctor"        then tool_doctor(args)
      else raise "Unknown tool '#{name}'. Available: #{TOOLS.map { _1[:name] }.join(", ")}"
      end
    end

    # ── Tool implementations ─────────────────────────────────────────────────

    def tool_list_services(_args)
      manifests = Manifest.discover_all(start_dir: Dir.pwd)
      raise Manifest::Error, "No blink.toml found in or below #{Dir.pwd}" if manifests.empty?

      services = manifests.flat_map do |manifest|
        manifest.service_names.map do |name|
          svc      = manifest.service(name)
          t_name   = svc.dig("deploy", "target") || manifest.default_target_name
          pipeline = svc.dig("deploy", "pipeline") || Runner::DEFAULT_PIPELINES["deploy"]
          {
            name:        name,
            description: svc["description"],
            target:      t_name,
            source:      svc.dig("source", "type"),
            pipeline:    pipeline,
            manifest:    manifest.path,
          }
        end
      end

      JSON.generate({
        success:             true,
        summary:             "#{services.size} service(s) across #{manifests.size} manifest(s)",
        suggested_next_step: "Use blink_plan or blink_deploy to operate on a specific service.",
        data:                { services: services, manifests: manifests.map(&:path) }
      })
    end

    def tool_plan(args)
      service    = require_arg!(args, "service")
      build_name = args["build"]
      manifest   = manifest_for_service(service)

      registry = Registry.new(manifest)
      svc      = manifest.service!(service)
      target   = registry.target_for(service, override: args["target"])
      pipeline = registry.pipeline_for(service)
      rollback = registry.rollback_for(service)

      steps = pipeline.map do |step_name|
        cfg  = svc[step_name] || {}
        note = plan_note(step_name, cfg)
        { step: step_name, config: cfg, note: note }
      end

      deploy_cmd = "blink_deploy with service='#{service}'#{build_name ? ", build='#{build_name}'" : ""}"

      JSON.generate({
        success:             true,
        summary:             "Deploy #{service} via #{pipeline.size}-step pipeline on #{target.description}",
        suggested_next_step: "Run #{deploy_cmd} to execute this plan.",
        data: {
          service:     service,
          build_name:  build_name,
          target:      target.description,
          description: svc["description"],
          source:      svc["source"],
          manifest:    manifest.path,
          pipeline:    pipeline,
          rollback:    rollback,
          steps:       steps,
        }
      })
    end

    def tool_deploy(args)
      service    = require_arg!(args, "service")
      dry_run    = args.fetch("dry_run", false)
      version    = args.fetch("version", "latest")
      build_name = args["build"]

      manifest = manifest_for_service(service)
      runner   = Runner.new(manifest)

      output, result = capture_output do
        runner.run(
          service,
          target_name: args["target"],
          dry_run:     dry_run,
          json_mode:   false,
          version:     version,
          build_name:  build_name
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

      manifest = service ? manifest_for_service(service) : Manifest.load(start_dir: Dir.pwd)
      suites   = load_suites(manifest, service)

      if suites.empty?
        return JSON.generate({
          success:             false,
          summary:             "No suites found#{service ? " for '#{service}'" : ""}",
          suggested_next_step: "Ensure verify.suite is configured in blink.toml for this service.",
          data:                {}
        })
      end

      target = resolve_target(manifest, service, args["target"])
      runner = Testing::Runner.new(tags: tags, target: target, json_mode: false)
      suites.each { |klass| klass.register(runner) }

      if list_only
        filtered = runner.instance_variable_get(:@tests) # peek at registered tests
        test_list = filtered.map { |t| { name: t.name, suite: t.suite, tags: t.tags, desc: t.desc } }
        return JSON.generate({
          success:             true,
          summary:             "#{test_list.size} test(s) available",
          suggested_next_step: "Run blink_test without list=true to execute these tests.",
          data:                { tests: test_list, manifest: manifest.path }
        })
      end

      result = runner.run_collected

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
        data:                result.to_h.merge(manifest: manifest.path)
      })
    end

    def tool_status(args)
      manifest = args["service"] ? manifest_for_service(args["service"]) : Manifest.load(start_dir: Dir.pwd)

      service_names = args["service"] ? [args["service"]] : manifest.service_names
      target_name   = args["target"] || manifest.default_target_name
      target        = manifest.target!(target_name)

      unless target.reachable?
        return JSON.generate({
          success:             false,
          summary:             "Target '#{target_name}' (#{target.description}) is unreachable",
          suggested_next_step: "Check SSH connectivity with blink_doctor.",
          data:                { target: target.description, services: [] }
        })
      end

      services = service_names.map do |name|
        svc    = manifest.service!(name)
        hc_cfg = svc&.dig("health_check")
        if hc_cfg&.dig("url")
          url  = hc_cfg["url"]
          code = target.capture(
            "curl -sfk --max-time 5 --output /dev/null --write-out '%{http_code}' #{url} 2>/dev/null || echo 000"
          ).to_i
          healthy = (200..299).cover?(code)
          { name: name, healthy: healthy, http_code: code, url: url }
        else
          { name: name, healthy: nil, note: "no health_check.url configured" }
        end
      rescue => e
        { name: name, healthy: false, error: e.message }
      end

      up    = services.count { _1[:healthy] == true }
      down  = services.count { _1[:healthy] == false }
      total = services.size

      next_step = if down > 0
        down_names = services.select { _1[:healthy] == false }.map { _1[:name] }
        "#{down} service(s) are down: #{down_names.join(", ")}. Use blink_logs or blink_deploy to investigate."
      else
        "All #{up} service(s) are healthy."
      end

      JSON.generate({
        success:             down == 0,
        summary:             "#{up}/#{total} service(s) healthy on #{target.description}",
        suggested_next_step: next_step,
        data:                { target: target.description, services: services, manifest: manifest.path }
      })
    end

    def tool_logs(args)
      service = require_arg!(args, "service")
      lines   = (args["lines"] || 100).to_i

      manifest    = manifest_for_service(service)
      svc         = manifest.service!(service)
      target_name = args["target"] || svc.dig("deploy", "target") || manifest.default_target_name
      target      = manifest.target!(target_name)

      logs_cfg    = svc["logs"] || {}
      container   = logs_cfg["container"] || svc.dig("docker", "container") || service
      cmd = if logs_cfg["command"]
        logs_cfg["command"]
      else
        "docker logs --tail #{lines} #{container} 2>&1 || journalctl -u #{service} -n #{lines} --no-pager 2>&1"
      end

      output = target.capture(cmd)

      JSON.generate({
        success:             true,
        summary:             "Last #{lines} lines of #{service} logs",
        suggested_next_step: "Look for ERROR or WARN lines. Use blink_deploy to redeploy if broken.",
        data:                { service: service, target: target.description, lines: output, manifest: manifest.path }
      })
    rescue => e
      JSON.generate({
        success:             false,
        summary:             "Could not fetch logs for #{service}: #{e.message}",
        suggested_next_step: "Verify the service is running with blink_status.",
        data:                {}
      })
    end

    def tool_doctor(args)
      manifest = Manifest.load
      targets  = args["target"] ? [manifest.target!(args["target"])] : manifest.target_names.map { manifest.target!(_1) }

      all_checks = []

      targets.each do |target|
        checks = []

        reachable = target.reachable?
        checks << { target: target.name, check: "connectivity", status: reachable ? "pass" : "fail",
                    detail: target.description }

        if reachable && target.is_a?(Targets::SSHTarget)
          # Docker
          docker_ok = begin
            target.capture("docker info > /dev/null 2>&1 && echo ok || echo fail") == "ok"
          rescue SSHError
            false
          end
          checks << { target: target.name, check: "docker daemon", status: docker_ok ? "pass" : "fail" }

          # Disk
          begin
            out  = target.capture("df -h / | awk 'NR==2 {print $5, $4}'")
            pct  = out.split.first.to_i
            ok   = pct < 80
            checks << { target: target.name, check: "disk /", status: ok ? "pass" : "warn",
                        detail: "#{100 - pct}% free" }
          rescue SSHError => e
            checks << { target: target.name, check: "disk /", status: "error", detail: e.message }
          end

          # Memory
          begin
            out  = target.capture("free -m | awk 'NR==2 {printf \"%d %d\", $3, $2}'")
            used, total = out.split.map(&:to_i)
            pct  = total > 0 ? (used * 100 / total) : 0
            ok   = pct < 85
            checks << { target: target.name, check: "memory", status: ok ? "pass" : "warn",
                        detail: "#{used}MB / #{total}MB (#{pct}%)" }
          rescue SSHError => e
            checks << { target: target.name, check: "memory", status: "error", detail: e.message }
          end
        end

        # Service health checks
        manifest.service_names.each do |name|
          svc    = manifest.service(name)
          url    = svc&.dig("health_check", "url")
          next unless url

          ok = begin
            code = target.capture(
              "curl -sfk --max-time 5 --output /dev/null --write-out '%{http_code}' #{url} 2>/dev/null || echo 000"
            ).to_i
            (200..299).cover?(code)
          rescue
            false
          end
          checks << { target: target.name, check: "#{name} health", status: ok ? "pass" : "fail", detail: url }
        end

        all_checks.concat(checks)
      end

      passed = all_checks.count { _1[:status] == "pass" }
      failed = all_checks.count { _1[:status] == "fail" }
      warned = all_checks.count { _1[:status] == "warn" }

      next_step = if failed > 0
        failing = all_checks.select { _1[:status] == "fail" }.map { _1[:check] }
        "Fix failing checks: #{failing.join(", ")}."
      elsif warned > 0
        "All checks pass with #{warned} warning(s). Monitor disk/memory usage."
      else
        "All #{passed} checks passed. System looks healthy."
      end

      JSON.generate({
        success:             failed == 0,
        summary:             "#{passed} passed, #{failed} failed, #{warned} warnings",
        suggested_next_step: next_step,
        data:                { checks: all_checks }
      })
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def require_arg!(args, key)
      args[key] || raise("Missing required argument: '#{key}'")
    end

    def manifest_for_service(service_name)
      Manifest.load_for_service!(service_name, start_dir: Dir.pwd)
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

    def load_suites(manifest, service_name)
      if service_name
        svc        = manifest.service!(service_name)
        suite_path = svc&.dig("verify", "suite")
        return [] unless suite_path
        suite_abs = File.expand_path(suite_path, manifest.dir)
        return [] unless File.exist?(suite_abs)
        paths = [suite_abs]
      else
        paths = manifest.service_names.filter_map do |name|
          path = manifest.service(name)&.dig("verify", "suite")
          next unless path
          abs = File.expand_path(path, manifest.dir)
          abs if File.exist?(abs)
        end
      end

      Testing::Suite.with_clean_registry { paths.each { |p| load p } }
      Testing::Suite.registered
    end

    def resolve_target(manifest, service_name, override)
      name = override ||
             (service_name && manifest.service(service_name)&.dig("deploy", "target")) ||
             manifest.default_target_name
      manifest.target!(name)
    end

    def plan_note(step_name, cfg)
      case step_name
      when "stop", "start", "shell" then cfg["command"].to_s
      when "remote_script"          then cfg["path"].to_s
      when "install"                then "→ #{cfg["dest"]}" if cfg["dest"]
      when "health_check"           then cfg["url"].to_s
      when "verify"                 then "suite: #{cfg["suite"]}  tags: #{Array(cfg["tags"]).join(", ")}"
      else ""
      end.to_s
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
