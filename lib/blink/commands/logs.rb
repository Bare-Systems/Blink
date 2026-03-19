# frozen_string_literal: true

module Blink
  module Commands
    class Logs
      def initialize(argv)
        @argv    = argv.dup
        @follow  = !!@argv.delete("-f") || !!@argv.delete("--follow")
        @lines   = extract_flag_value("--lines") || "100"
        @service = @argv.reject { _1.start_with?("-") }.first

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        if @service.nil?
          show_help
          return
        end

        manifest = Manifest.load
        svc      = manifest.service!(@service)

        target_name = @target_name || svc.dig("deploy", "target") || manifest.default_target_name
        target      = manifest.target!(target_name)

        cmd = log_command(svc, @service, @lines, @follow)
        target.run(cmd)
      rescue Manifest::Error => e
        Output.fatal(e.message)
      rescue SSHError => e
        Output.fatal("SSH error: #{e.message}")
      end

      private

      def log_command(svc, service_name, lines, follow)
        logs_cfg = svc["logs"] || {}

        if logs_cfg["command"]
          logs_cfg["command"]
        elsif (container = logs_cfg["container"] || svc.dig("docker", "container") || service_name)
          follow_flag = follow ? " -f" : ""
          "docker logs --tail #{lines}#{follow_flag} #{container}"
        else
          "journalctl -u #{service_name} -n #{lines}#{follow ? " -f" : ""}"
        end
      end

      def extract_flag_value(flag)
        idx = @argv.index(flag)
        return nil unless idx
        @argv.delete_at(idx)
        @argv.delete_at(idx)
      end

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink logs <service> [-f] [--lines N] [--target NAME]"
      end
    end
  end
end
