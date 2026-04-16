# frozen_string_literal: true

require "cgi"
require "json"
require "time"

module Blink
  module Operations
    def self.step_context(manifest:, service_name:, target:)
      Steps::StepContext.new(
        manifest: manifest,
        service_name: service_name,
        target: target,
        dry_run: false,
        json_mode: false,
        version: "latest",
        build_name: nil,
        artifact_path: nil,
        backup_path: nil
      )
    end

    class StepCatalog
      def initialize(step_name: nil)
        @step_name = step_name
      end

      def call
        steps = Steps.catalog
        steps = steps.select { |step| step[:name] == @step_name } if @step_name
        raise Manifest::Error, "Unknown step '#{@step_name}'" if @step_name && steps.empty?

        { steps: steps }
      end
    end

    class ListServices
      def initialize(start_dir: Dir.pwd)
        @start_dir = start_dir
      end

      def call
        manifests = Manifest.discover_all(start_dir: @start_dir)
        raise Manifest::Error, "No blink.toml found in or below #{@start_dir}" if manifests.empty?

        services = manifests.flat_map do |manifest|
          manifest.service_names.map do |name|
            svc = manifest.service(name)
            {
              name: name,
              description: svc["description"],
              target: svc.dig("deploy", "target") || manifest.default_target_name,
              source: svc.dig("source", "type"),
              pipeline: svc.dig("deploy", "pipeline") || Runner::DEFAULT_PIPELINES["deploy"],
              manifest: manifest.path,
            }
          end
        end

        { manifests: manifests.map(&:path), services: services }
      end
    end

    class Status
      def initialize(manifest:, service_name: nil, target_name: nil)
        @manifest = manifest
        @service_name = service_name
        @target_name = target_name
      end

      def call
        service_names = @service_name ? [@service_name] : @manifest.service_names
        services = service_names.map { |name| check_service(name) }
        reachable = services.all? { |service| service[:reachable] != false }
        target_descriptions = services.map { |service| service[:target] }.compact.uniq
        target_names = services.map { |service| service[:target_name] }.compact.uniq

        {
          target: target_descriptions.one? ? target_descriptions.first : "multiple targets",
          target_name: target_names.one? ? target_names.first : nil,
          reachable: reachable,
          services: services,
          healthy: services.count { _1[:healthy] == true },
          down: services.count { _1[:healthy] == false },
          total: services.size,
        }
      end

      private

      def check_service(name)
        svc = @manifest.service!(name)
        target = Registry.new(@manifest).target_for(name, override: @target_name)
        reachable = target.reachable?
        return { name: name, healthy: false, reachable: false, target: target.description, target_name: target.name, detail: "target unreachable" } unless reachable

        hc_cfg = svc&.dig("health_check")
        if hc_cfg&.dig("url")
          url = Operations.step_context(manifest: @manifest, service_name: name, target: target).resolve(hc_cfg["url"])
          code = Blink::HTTP::Adapter.health_probe(
            target, url,
            http_version: hc_cfg["http_version"],
            tls_insecure: hc_cfg.fetch("tls_insecure", false)
          )
          healthy = (200..299).cover?(code)
          { name: name, healthy: healthy, reachable: true, detail: "HTTP #{code}  #{url}", url: url, code: code, target: target.description, target_name: target.name }
        else
          { name: name, healthy: nil, reachable: true, detail: "no health_check.url configured", target: target.description, target_name: target.name }
        end
      rescue => e
        { name: name, healthy: false, reachable: false, detail: e.message, target: target&.description, target_name: target&.name }
      end
    end

    class Doctor
      def initialize(manifest:, target_name: nil)
        @manifest = manifest
        @target_name = target_name
      end

      def call
        checks = []

        targets.each do |target|
          reachable = target.reachable?
          checks << { target: target.name, check: "connectivity", status: reachable ? "pass" : "fail",
                      detail: target.description }

          next unless reachable

          if target.is_a?(Targets::SSHTarget)
            docker_ok = begin
              target.capture("docker info > /dev/null 2>&1 && echo ok || echo fail") == "ok"
            rescue TargetError
              false
            end
            checks << { target: target.name, check: "docker daemon", status: docker_ok ? "pass" : "fail" }

            disk_check(target, checks)
            memory_check(target, checks)
          end

          @manifest.service_names.each do |name|
            svc = @manifest.service(name)
            service_target = target_for_service(name)
            next unless service_target.name == target.name && service_target.description == target.description
            url = svc&.dig("health_check", "url")
            next unless url

            url = Operations.step_context(manifest: @manifest, service_name: name, target: service_target).resolve(url)
            hc_cfg = svc["health_check"] || {}
            ok = begin
              code = Blink::HTTP::Adapter.health_probe(
                service_target, url,
                http_version: hc_cfg["http_version"],
                tls_insecure: hc_cfg.fetch("tls_insecure", false)
              )
              (200..299).cover?(code)
            rescue
              false
            end
            checks << { target: target.name, check: "#{name} health", status: ok ? "pass" : "fail", detail: url }
          end
        end

        {
          checks: checks,
          passed: checks.count { _1[:status] == "pass" },
          failed: checks.count { _1[:status] == "fail" },
          warnings: checks.count { _1[:status] == "warn" },
        }
      end

      private

      def targets
        return [@manifest.target!(@target_name)] if @target_name

        @manifest.service_names.map { |name| target_for_service(name) }.uniq { |target| [target.name, target.description] }
      end

      def target_for_service(service_name)
        Registry.new(@manifest).target_for(service_name, override: @target_name)
      end

      def disk_check(target, checks)
        out = target.capture("df -h / | awk 'NR==2 {print $5, $4}'")
        pct = out.split.first.to_i
        avail = out.split.last
        if pct < 80
          checks << { target: target.name, check: "disk (/)", status: "pass", detail: "#{100 - pct}% free (#{avail} avail)" }
        else
          detail = pct < 90 ? "#{100 - pct}% free - getting low" : "#{100 - pct}% free - critically low!"
          checks << { target: target.name, check: "disk (/)", status: "warn", detail: detail }
        end
      rescue TargetError => e
        checks << { target: target.name, check: "disk (/)", status: "fail", detail: e.message }
      end

      def memory_check(target, checks)
        out = target.capture("free -m | awk 'NR==2 {printf \"%d %d\", $3, $2}'")
        used, total = out.split.map(&:to_i)
        return checks << { target: target.name, check: "memory", status: "fail", detail: "could not read" } if total.zero?

        pct = (used * 100 / total)
        detail = "#{used}MB / #{total}MB (#{pct}%)"
        if pct < 85
          checks << { target: target.name, check: "memory", status: "pass", detail: detail }
        else
          checks << { target: target.name, check: "memory", status: "warn", detail: "#{detail} - high" }
        end
      rescue TargetError => e
        checks << { target: target.name, check: "memory", status: "fail", detail: e.message }
      end
    end

    class Logs
      def initialize(manifest:, service_name:, lines: 100, target_name: nil)
        @manifest = manifest
        @service_name = service_name
        @lines = lines.to_i
        @target_name = target_name
      end

      def call
        svc = @manifest.service!(@service_name)
        target = @manifest.target!(resolved_target_name(svc))
        cmd = command_for(svc, follow: false)

        {
          service: @service_name,
          target: target.description,
          target_name: target.name,
          lines: @lines,
          command: cmd,
          output: target.capture("#{cmd} 2>&1"),
        }
      end

      def stream_command(follow: false)
        command_for(@manifest.service!(@service_name), follow: follow)
      end

      def target
        @manifest.target!(resolved_target_name(@manifest.service!(@service_name)))
      end

      private

      def resolved_target_name(svc)
        @target_name || svc.dig("deploy", "target") || @manifest.default_target_name
      end

      def command_for(svc, follow:)
        logs_cfg = svc["logs"] || {}

        if logs_cfg["command"]
          logs_cfg["command"]
        else
          container = logs_cfg["container"] || svc.dig("docker", "container") || @service_name
          follow_flag = follow ? " -f" : ""
          "docker logs --tail #{@lines}#{follow_flag} #{container} || journalctl -u #{@service_name} -n #{@lines} --no-pager#{follow_flag}"
        end
      end
    end

    class Restart
      def initialize(manifest:, service_name:, target_name: nil)
        @manifest = manifest
        @service_name = service_name
        @target_name = target_name
      end

      def call
        svc = @manifest.service!(@service_name)
        target = @manifest.target!(resolved_target_name(svc))
        ctx = Operations.step_context(manifest: @manifest, service_name: @service_name, target: target)

        steps = if svc.dig("stop", "command") && svc.dig("start", "command")
          [
            { step: "stop", command: ctx.resolve(svc.dig("stop", "command")), abort_on_failure: false },
            { step: "start", command: ctx.resolve(svc.dig("start", "command")), abort_on_failure: true },
          ]
        elsif svc.dig("stop", "command") && svc["docker"].is_a?(Hash)
          [
            { step: "stop", command: ctx.resolve(svc.dig("stop", "command")), abort_on_failure: false },
            { step: "docker", managed: true, abort_on_failure: true },
          ]
        elsif (restart_cmd = svc.dig("restart", "command"))
          [
            { step: "restart", command: ctx.resolve(restart_cmd), abort_on_failure: true },
          ]
        else
          raise Manifest::Error, "No stop/start or restart commands configured for '#{@service_name}'"
        end

        steps.each do |step|
          if step[:managed] && step[:step] == "docker"
            Steps::Docker.new.call(ctx)
          else
            target.run(step[:command], abort_on_failure: step[:abort_on_failure])
          end
        end

        {
          service: @service_name,
          target: target.description,
          target_name: target.name,
          steps: steps.map { |step| step[:managed] ? { step: step[:step], command: "managed by Blink #{step[:step]} step" } : step.slice(:step, :command) }
        }
      end

      private

      def resolved_target_name(svc)
        @target_name || svc.dig("deploy", "target") || @manifest.default_target_name
      end
    end

    class Ps
      def initialize(manifest:, target_name: nil)
        @manifest = manifest
        @target_name = target_name
      end

      def call
        target = @manifest.target!(@target_name || @manifest.default_target_name)
        raw = target.capture('docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>&1')
        lines = raw.lines.map(&:chomp)

        {
          target: target.description,
          target_name: target.name,
          output: lines,
          container_count: [lines.size - 1, 0].max
        }
      end
    end

    class State
      def initialize(manifest:, service_name: nil)
        @manifest = manifest
        @service_name = service_name
      end

      def call
        current = Lock.current_state(@manifest)
        services = current["services"] || {}

        if @service_name
          {
            manifest: @manifest.path,
            updated_at: current["updated_at"],
            service: @service_name,
            state: services[@service_name] || {}
          }
        else
          {
            manifest: @manifest.path,
            updated_at: current["updated_at"],
            services: services
          }
        end
      end
    end

    class History
      def initialize(manifest:, service_name: nil, limit: 20, run_id: nil)
        @manifest = manifest
        @service_name = service_name
        @limit = limit.to_i
        @run_id = run_id
      end

      def call
        if @run_id
          entry = Lock.history_entry(@manifest, @run_id)
          raise Manifest::Error, "No history entry found for run_id '#{@run_id}'" unless entry

          return {
            manifest: @manifest.path,
            run: entry
          }
        end

        runs = Lock.recent_runs(@manifest, service: @service_name, limit: @limit)
        {
          manifest: @manifest.path,
          service: @service_name,
          count: runs.size,
          runs: runs
        }
      end
    end

    class Rollback
      def initialize(manifest:, service_name:, target_name: nil, dry_run: false, json_mode: false)
        @manifest = manifest
        @service_name = service_name
        @target_name = target_name
        @dry_run = dry_run
        @json_mode = json_mode
      end

      def call
        Runner.new(@manifest).run(
          @service_name,
          operation: "rollback",
          target_name: @target_name,
          dry_run: @dry_run,
          json_mode: @json_mode
        )
      end
    end

    class Report
      def initialize(manifest:, limit: 20)
        @manifest = manifest
        @limit = limit.to_i
      end

      def call
        recent = Lock.recent_runs(@manifest, limit: @limit)
        detailed_runs = recent.map { |run| Lock.history_entry(@manifest, run["run_id"]) || run }
        current = Lock.current_state(@manifest)

        {
          generated_at: Time.now.utc.iso8601,
          manifest: @manifest.path,
          updated_at: current["updated_at"],
          services: current["services"] || {},
          recent_runs: detailed_runs
        }
      end

      def render_json
        JSON.pretty_generate(call) + "\n"
      end

      def render_html
        data = call
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Blink Report</title>
              <style>
                :root { color-scheme: light; --bg: #f4f1ea; --panel: #fffdf9; --ink: #1f2328; --muted: #6a737d; --line: #d9d1c7; --accent: #a64b2a; --good: #1f7a4c; --bad: #b42318; }
                body { margin: 0; font-family: Georgia, "Iowan Old Style", serif; background: linear-gradient(180deg, #efe6d8 0%, var(--bg) 40%, #fbfaf7 100%); color: var(--ink); }
                main { max-width: 980px; margin: 0 auto; padding: 48px 20px 64px; }
                h1, h2 { margin: 0 0 16px; font-weight: 600; }
                p { color: var(--muted); }
                .meta, .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 16px; padding: 20px; box-shadow: 0 10px 30px rgba(31, 35, 40, 0.05); }
                .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 16px; margin: 24px 0; }
                .k { color: var(--muted); font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.08em; }
                .v { font-size: 1.05rem; margin-top: 8px; word-break: break-word; }
                table { width: 100%; border-collapse: collapse; }
                th, td { text-align: left; padding: 12px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
                th { color: var(--muted); font-size: 0.82rem; text-transform: uppercase; letter-spacing: 0.08em; }
                .status-success { color: var(--good); font-weight: 700; }
                .status-failure { color: var(--bad); font-weight: 700; }
                .services { display: grid; gap: 14px; }
                .service-card { border: 1px solid var(--line); border-radius: 14px; padding: 16px; background: #fff; }
                code { font-family: "SFMono-Regular", ui-monospace, monospace; font-size: 0.9em; }
              </style>
            </head>
            <body>
              <main>
                <h1>Blink Report</h1>
                <p>Generated #{h(data[:generated_at])} from #{h(data[:manifest])}</p>
                <section class="grid">
                  <div class="meta">
                    <div class="k">Last Updated</div>
                    <div class="v">#{h(data[:updated_at] || "Never")}</div>
                  </div>
                  <div class="meta">
                    <div class="k">Services</div>
                    <div class="v">#{data[:services].size}</div>
                  </div>
                  <div class="meta">
                    <div class="k">Recent Runs</div>
                    <div class="v">#{data[:recent_runs].size}</div>
                  </div>
                </section>
                <section class="panel">
                  <h2>Current State</h2>
                  <div class="services">
                    #{render_service_cards(data[:services])}
                  </div>
                </section>
                <section class="panel" style="margin-top: 24px;">
                  <h2>Recent Runs</h2>
                  #{render_runs_table(data[:recent_runs])}
                </section>
              </main>
            </body>
          </html>
        HTML
      end

      private

	      def render_service_cards(services)
	        return "<p>No persisted service state yet.</p>" if services.empty?

	        services.map do |name, state|
	          artifact = state.dig("last_deploy", "artifact")
	          <<~HTML
	            <article class="service-card">
	              <h3>#{h(name)}</h3>
	              <p>Last run: <code>#{h(state.dig("last_run", "operation") || "none")}</code> at #{h(state.dig("last_run", "completed_at") || "n/a")}</p>
	              <p>Last test: #{h(state.dig("last_test", "summary") || "none")}</p>
	              <p>Last deploy: #{h(state.dig("last_deploy", "summary") || "none")}</p>
	              #{render_artifact_card(artifact)}
	              <p>Last rollback: #{h(state.dig("last_rollback", "summary") || "none")}</p>
	            </article>
	          HTML
	        end.join
	      end

      def render_runs_table(runs)
        return "<p>No runs recorded yet.</p>" if runs.empty?

        rows = runs.map do |run|
          status_class = run["status"] == "success" ? "status-success" : "status-failure"
          <<~HTML
            <tr>
              <td><code>#{h(run["run_id"])}</code></td>
              <td>#{h(run["service"])}</td>
              <td>#{h(run["operation"])}</td>
              <td class="#{status_class}">#{h(run["status"])}</td>
              <td>#{h(run["completed_at"])}</td>
              <td>#{h(run["summary"])}</td>
            </tr>
          HTML
        end.join

        <<~HTML
          <table>
            <thead>
              <tr>
                <th>Run ID</th>
                <th>Service</th>
                <th>Operation</th>
                <th>Status</th>
                <th>Completed</th>
                <th>Summary</th>
              </tr>
            </thead>
            <tbody>#{rows}</tbody>
          </table>
        HTML
      end

      def h(value)
        CGI.escape_html(value.to_s)
      end

      def render_artifact_card(artifact)
        return "" unless artifact.is_a?(Hash) && artifact["path"]

        lines = []
        lines << "<p>Artifact: <code>#{h(artifact["source_type"] || "unknown")}</code> #{h(artifact["cache_summary"] || "")}</p>"
        lines << "<p>SHA256: <code>#{h(artifact["sha256"] || "n/a")}</code></p>"
        integrity = artifact["integrity"]
        if integrity.is_a?(Hash) && integrity["verified"]
          lines << "<p>Integrity: verified #{h(integrity["algorithm"] || "sha256")} at #{h(integrity["verified_at"] || "n/a")}</p>"
          if integrity["source"]
            lines << "<p>Integrity source: <code>#{h(integrity["source"])}</code> #{h(integrity["reference"] || "")}</p>"
          end
        end

        signature = artifact["signature"]
        if signature.is_a?(Hash) && signature["verified"]
          lines << "<p>Signature: verified #{h(signature["tool"] || "external verifier")} at #{h(signature["verified_at"] || "n/a")}</p>"
          if signature["source"]
            lines << "<p>Signature source: <code>#{h(signature["source"])}</code> #{h(signature["reference"] || "")}</p>"
          end
        end

        http = artifact["http"]
        if http.is_a?(Hash)
          lines << "<p>HTTP validators: #{render_http_validators(http)}</p>"
        end

        lines.join
      end

      def render_http_validators(http)
        parts = []
        parts << "ETag <code>#{h(http["etag"])}</code>" if http["etag"]
        parts << "Last-Modified <code>#{h(http["last_modified"])}</code>" if http["last_modified"]
        parts << "#{http["revalidated"] ? "revalidated" : "downloaded"} at #{h(http["validated_at"] || "n/a")}"
        parts.join(" | ")
      end
    end

    class TestRun
      def initialize(manifest:, service_name: nil, tags: [], target_name: nil)
        @manifest = manifest
        @service_name = service_name
        @tags = Array(tags).map(&:to_sym)
        @target_name = target_name
      end

      def suites
        @suites ||= testable_services.to_h do |entry|
          path = entry[:suite_path]
          next [entry[:name], []] unless path

          registered = Testing::Suite.with_clean_registry do
            load path
            Testing::Suite.registered.dup
          end
          [entry[:name], registered]
        end
      end

      def available?
        testable_services.any?
      end

      def list
        tests = testable_services.flat_map do |entry|
          list_service_tests(entry)
        end

        {
          service: @service_name,
          target: @service_name ? testable_services.first[:target].description : nil,
          tests: tests
        }
      end

      def run(persist: true)
        started_at = Time.now
        service_results = {}
        records = testable_services.flat_map do |entry|
          service_records = run_service(entry)
          service_results[entry[:name]] = Testing::RunResult.new(service_records).to_h
          service_records
        end
        result = Testing::RunResult.new(records)
        completed_at = Time.now

        if persist
          Lock.record_test(
            manifest: @manifest,
            service_name: @service_name,
            target: @service_name ? testable_services.first[:target] : nil,
            result: result,
            tags: @tags,
            started_at: started_at,
            completed_at: completed_at
          )
        end

        {
          service: @service_name,
          target: @service_name ? testable_services.first[:target].description : nil,
          service_results: service_results,
          result: result,
          started_at: started_at,
          completed_at: completed_at
        }
      end

      private

      def list_service_tests(entry)
        tests = []

        if entry[:tests]
          tests.concat(
            Testing::InlineRunner.new(entry[:tests], step_context_for(entry)).list(tags: @tags).map do |t|
              { name: t.name, suite: t.suite, tags: t.tags, desc: t.desc, service: entry[:name], type: "inline" }
            end
          )
        end

        if entry[:suite_path]
          runner = Testing::Runner.new(tags: @tags, target: entry[:target], json_mode: false)
          suites.fetch(entry[:name], []).each { |klass| klass.register(runner) }
          tests.concat(
            runner.instance_variable_get(:@tests).map do |t|
              { name: t.name, suite: t.suite, tags: t.tags, desc: t.desc, service: entry[:name], type: "suite" }
            end
          )
        end

        tests
      end

      def run_service(entry)
        records = []

        if entry[:tests]
          inline = Testing::InlineRunner.new(entry[:tests], step_context_for(entry))
          records.concat(inline.run(tags: @tags).records)
        end

        if entry[:suite_path]
          runner = Testing::Runner.new(tags: @tags, target: entry[:target], json_mode: false)
          suites.fetch(entry[:name], []).each { |klass| klass.register(runner) }
          records.concat(runner.run_collected.records)
        end

        records
      end

      def testable_services
        @testable_services ||= begin
          selected_service_names.filter_map do |name|
            service = @manifest.service!(name)
            verify = service["verify"] || {}
            suite_path = verify["suite"]
            suite_abs = suite_path ? File.expand_path(suite_path, @manifest.service_dir(name)) : nil
            tests = verify["tests"]

            next unless tests || (suite_abs && File.exist?(suite_abs))

            {
              name: name,
              service: service,
              target: target_for(name),
              tests: tests,
              suite_path: (suite_abs if suite_abs && File.exist?(suite_abs))
            }
          end
        end
      end

      def selected_service_names
        @service_name ? [@service_name] : @manifest.service_names
      end

      def target_for(service_name)
        name = @target_name ||
               @manifest.service(service_name)&.dig("deploy", "target") ||
               @manifest.default_target_name_for(service_name)
        @manifest.target_for_service!(service_name, name)
      end

      def step_context_for(entry)
        Operations.step_context(manifest: @manifest, service_name: entry[:name], target: entry[:target])
      end
    end
  end
end
