# frozen_string_literal: true

module Blink
  module Commands
    class Status
      def initialize(argv)
        @argv    = argv.dup
        @json    = !!@argv.delete("--json")
        @service = @argv.first unless @argv.first&.start_with?("-")

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        manifest = Manifest.load
        services = @service ? [manifest.service!(@service)].compact : manifest.service_names.map { manifest.service(_1) }
        service_names = @service ? [@service] : manifest.service_names

        target_name = @target_name || manifest.default_target_name
        target      = manifest.target!(target_name)

        unless target.reachable?
          Output.fatal("Cannot reach target '#{target_name}' (#{target.description})")
        end

        results = service_names.map.with_index do |name, i|
          svc = services[i]
          check_service(name, svc, target)
        end

        if @json
          require "json"
          puts JSON.generate(target: target.description, services: results)
          return
        end

        Output.header("Status  (#{target.description})")
        puts

        results.each do |r|
          color = r[:healthy] ? Output::GREEN : Output::RED
          status_str = r[:healthy] ? "up" : "down"
          Output.label_row("  #{r[:name]}:", "#{color}#{status_str}#{Output::RESET}  #{Output::GRAY}#{r[:detail]}#{Output::RESET}")
        end

        puts

        # Always show docker containers if target is SSH
        if target.is_a?(Targets::SSHTarget)
          puts "#{Output::BOLD}  Containers#{Output::RESET}"
          show_docker(target)
          puts
        end
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue SSHError => e
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def check_service(name, svc, target)
        hc_cfg = svc&.dig("health_check")
        if hc_cfg&.dig("url")
          url    = hc_cfg["url"]
          result = target.capture(
            "curl -sfk --max-time 5 --output /dev/null --write-out '%{http_code}' #{url} 2>/dev/null || echo 000"
          )
          code    = result.to_i
          healthy = (200..299).cover?(code)
          { name: name, healthy: healthy, detail: "HTTP #{code}  #{url}" }
        else
          { name: name, healthy: nil, detail: "no health_check.url configured" }
        end
      rescue => e
        { name: name, healthy: false, detail: e.message }
      end

      def show_docker(target)
        raw = target.capture('docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1')
        lines = raw.lines
        if lines.size <= 1
          Output.warn("  No containers running")
          return
        end
        lines.each_with_index do |line, i|
          line = line.chomp
          if i == 0
            Output.info("  " + line)
          elsif line.include?("Up")
            puts "  #{Output::GREEN}#{line}#{Output::RESET}"
          else
            puts "  #{Output::YELLOW}#{line}#{Output::RESET}"
          end
        end
      rescue SSHError
        Output.warn("  Docker not reachable")
      end
    end
  end
end
