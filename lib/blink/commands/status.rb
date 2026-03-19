# frozen_string_literal: true

require "json"

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
        result = Operations::Status.new(manifest: manifest, service_name: @service, target_name: @target_name).call

        unless result[:reachable]
          if @json
            puts Response.dump(
              success: false,
              summary: "Target '#{result[:target_name]}' is unreachable",
              details: { target: result[:target], services: [] },
              next_steps: ["Run `blink doctor#{@target_name ? " --target #{@target_name}" : ""}` to check connectivity."]
            )
            exit 1
          end

          Output.fatal("Cannot reach target '#{result[:target_name]}' (#{result[:target]})")
        end

        if @json
          puts Response.dump(
            success: result[:down].zero?,
            summary: "#{result[:healthy]}/#{result[:total]} service(s) healthy on #{result[:target]}",
            details: { target: result[:target], services: result[:services] },
            next_steps: result[:down].zero? ? [] : ["Inspect unhealthy services with `blink logs <service>` or rerun deploy."]
          )
          exit 1 unless result[:down].zero?
          return
        end

        Output.header("Status  (#{result[:target]})")
        puts

        result[:services].each do |r|
          color = r[:healthy] ? Output::GREEN : Output::RED
          status_str = r[:healthy] ? "up" : "down"
          Output.label_row("  #{r[:name]}:", "#{color}#{status_str}#{Output::RESET}  #{Output::GRAY}#{r[:detail]}#{Output::RESET}")
        end

        puts

        # Always show docker containers if target is SSH
        target = manifest.target!(result[:target_name])
        if target.is_a?(Targets::SSHTarget)
          puts "#{Output::BOLD}  Containers#{Output::RESET}"
          show_docker(target)
          puts
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the manifest or target selection and rerun `blink status`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue SSHError => e
        if @json
          puts Response.dump(
            success: false,
            summary: "SSH error: #{e.message}",
            details: { service: @service, error: e.message },
            next_steps: ["Run `blink doctor` to confirm target connectivity."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end

      private
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
