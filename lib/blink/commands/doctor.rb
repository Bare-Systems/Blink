# frozen_string_literal: true

module Blink
  module Commands
    # Run connectivity and health checks against all configured targets.
    class Doctor
      def initialize(argv)
        @argv    = argv.dup
        @json    = !!@argv.delete("--json")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        manifest = Manifest.load
        targets  = @target_name ? [manifest.target!(@target_name)] : all_targets(manifest)

        checks  = []
        @passed = 0
        @failed = 0

        targets.each do |target|
          Output.header("Doctor  (#{target.description})")
          puts

          # Connectivity
          ok = target.reachable?
          record(checks, "connectivity", ok, target: target.name,
                 ok_msg: "reachable", fail_msg: "unreachable")

          next unless ok

          # Docker (SSH targets only)
          if target.is_a?(Targets::SSHTarget)
            docker_ok = begin
              target.capture("docker info > /dev/null 2>&1 && echo ok || echo fail") == "ok"
            rescue SSHError
              false
            end
            record(checks, "docker daemon", docker_ok, target: target.name)

            # Disk
            check_disk(target, checks)

            # Memory
            check_memory(target, checks)
          end

          # Service health checks
          manifest.service_names.each do |name|
            svc    = manifest.service(name)
            hc_cfg = svc&.dig("health_check")
            next unless hc_cfg&.dig("url")

            url = hc_cfg["url"]
            ok  = begin
              code = target.capture(
                "curl -sfk --max-time 5 --output /dev/null --write-out '%{http_code}' #{url} 2>/dev/null || echo 000"
              ).to_i
              (200..299).cover?(code)
            rescue
              false
            end
            record(checks, "#{name} health", ok, target: target.name,
                   ok_msg: "up  #{url}", fail_msg: "down  #{url}")
          end
        end

        puts
        if @json
          require "json"
          puts JSON.generate(passed: @passed, failed: @failed, checks: checks)
        end

        if @failed.zero?
          Output.success("All #{@passed} checks passed")
        else
          Output.warn("#{@passed} passed, #{Output::RED}#{@failed} failed#{Output::RESET}")
          exit 1
        end
      rescue Manifest::Error => e
        Output.fatal(e.message)
      end

      private

      def all_targets(manifest)
        manifest.target_names.map { |n| manifest.target!(n) }
      end

      def record(checks, label, ok, target:, ok_msg: "ok", fail_msg: "FAIL")
        ok ? @passed += 1 : @failed += 1
        Output.check("  #{label}", ok, ok_msg: ok_msg, fail_msg: fail_msg)
        checks << { target: target, check: label, status: ok ? "pass" : "fail" }
      end

      def check_disk(target, checks)
        out     = target.capture("df -h / | awk 'NR==2 {print $5, $4}'")
        pct     = out.split.first.to_i
        avail   = out.split.last
        ok      = pct < 80
        msg     = "#{100 - pct}% free (#{avail} avail)"
        fail_m  = pct < 90 ? "#{100 - pct}% free — getting low" : "#{100 - pct}% free — critically low!"
        record(checks, "disk (/)", ok, target: target.name, ok_msg: msg, fail_msg: fail_m)
      rescue SSHError => e
        record(checks, "disk (/)", false, target: target.name, fail_msg: e.message)
      end

      def check_memory(target, checks)
        out      = target.capture("free -m | awk 'NR==2 {printf \"%d %d\", $3, $2}'")
        used, total = out.split.map(&:to_i)
        return record(checks, "memory", false, target: target.name, fail_msg: "could not read") if total.zero?
        pct  = (used * 100 / total)
        msg  = "#{used}MB / #{total}MB (#{pct}%)"
        ok   = pct < 85
        record(checks, "memory", ok, target: target.name, ok_msg: msg, fail_msg: "#{msg} — high")
      rescue SSHError => e
        record(checks, "memory", false, target: target.name, fail_msg: e.message)
      end
    end
  end
end
