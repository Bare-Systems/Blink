# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class Restart
      def initialize(argv)
        @argv    = argv.dup
        @json    = !!@argv.delete("--json")
        @service = @argv.reject { _1.start_with?("-") }.first

        target_idx = @argv.index("--target")
        @target_name = if target_idx
          @argv.delete_at(target_idx)
          @argv.delete_at(target_idx)
        end
      end

      def run
        if @service.nil?
          Output.fatal("Usage: blink restart <service> [--target NAME]")
        end

        manifest = Manifest.load
        details = Operations::Restart.new(
          manifest: manifest,
          service_name: @service,
          target_name: @target_name
        ).call

        unless @json
          Output.header("Restart: #{@service}")
        end

        if @json
          puts Response.dump(
            success: true,
            summary: "#{@service} restarted",
            details: details,
            next_steps: ["Run `blink status #{@service}` to confirm the service is healthy."]
          )
        else
          details[:steps].each { |step| Output.step(step[:step]) }
          Output.success("#{@service} restarted")
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Fix the service restart configuration and rerun `blink restart`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      rescue TargetError => e
        if @json
          puts Response.dump(
            success: false,
            summary: "SSH error: #{e.message}",
            details: { service: @service, error: e.message },
            next_steps: ["Check target connectivity with `blink doctor` and retry."]
          )
          exit 1
        end
        Output.fatal("SSH error: #{e.message}")
      end
    end
  end
end
