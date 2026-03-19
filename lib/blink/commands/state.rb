# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class State
      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @service = @argv.reject { _1.start_with?("-") }.first
      end

      def run
        manifest = Manifest.load
        details = Operations::State.new(manifest: manifest, service_name: @service).call

        if @json
          puts Response.dump(
            success: true,
            summary: summary_for(details),
            details: details,
            next_steps: next_steps_for(details)
          )
          return
        end

        Output.header(@service ? "State: #{@service}" : "State")
        puts
        Output.label_row("Manifest:", details[:manifest])
        Output.label_row("Updated:", details[:updated_at].to_s)

        if @service
          puts
          if details[:state].empty?
            Output.warn("No state recorded for #{@service}")
          else
            pretty_print_hash(details[:state])
          end
        else
          puts
          services = details[:services]
          if services.empty?
            Output.warn("No services recorded yet")
          else
            services.each do |name, state|
              puts "  #{Output::BOLD}#{name}#{Output::RESET}"
              pretty_print_hash(state, indent: "    ")
              puts
            end
          end
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, error: e.message },
            next_steps: ["Run a deploy or test first, then retry `blink state`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private

      def summary_for(details)
        return "State loaded for #{@service}" if @service

        "#{details[:services].size} service state record(s) loaded"
      end

      def next_steps_for(details)
        return ["Run `blink history#{@service ? " #{@service}" : ""}` to inspect recent runs."] if @service
        ["Run `blink state <service>` to inspect a specific service."]
      end

      def pretty_print_hash(hash, indent: "  ")
        hash.each do |key, value|
          rendered = value.is_a?(Hash) || value.is_a?(Array) ? JSON.pretty_generate(value) : value.to_s
          Output.label_row("#{indent}#{key}:", rendered)
        end
      end
    end
  end
end
