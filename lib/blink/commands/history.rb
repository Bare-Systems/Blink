# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class History
      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @service = @argv.reject { _1.start_with?("-") }.first

        limit_idx = @argv.index("--limit")
        @limit = if limit_idx
          @argv.delete_at(limit_idx)
          (@argv.delete_at(limit_idx) || "20").to_i
        else
          20
        end

        run_idx = @argv.index("--run")
        @run_id = if run_idx
          @argv.delete_at(run_idx)
          @argv.delete_at(run_idx)
        end
      end

      def run
        manifest = Manifest.load
        details = Operations::History.new(
          manifest: manifest,
          service_name: @service,
          limit: @limit,
          run_id: @run_id
        ).call

        if @json
          puts Response.dump(
            success: true,
            summary: summary_for(details),
            details: details,
            next_steps: next_steps_for(details)
          )
          return
        end

        if @run_id
          Output.header("Run: #{@run_id}")
          puts
          puts JSON.pretty_generate(details[:run])
          return
        end

        Output.header(@service ? "History: #{@service}" : "History")
        puts

        if details[:runs].empty?
          Output.warn("No runs recorded")
          return
        end

        details[:runs].each do |run|
          Output.label_row("  #{run["run_id"]}:", "#{run["operation"]}  #{run["status"]}  #{run["summary"]}")
          Output.label_row("    Completed:", run["completed_at"].to_s)
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { service: @service, run_id: @run_id, error: e.message },
            next_steps: ["Run a deploy or test first, then retry `blink history`."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private

      def summary_for(details)
        return "History loaded for run #{@run_id}" if @run_id
        return "#{details[:count]} run(s) for #{@service}" if @service

        "#{details[:count]} run(s) loaded"
      end

      def next_steps_for(details)
        return ["Run `blink state#{@service ? " #{@service}" : ""}` to inspect the latest persisted state."] if @run_id
        return ["Use `blink history #{@service} --run <run_id>` to inspect a specific run."] if @service

        ["Use `blink history <service>` to filter to a single service."]
      end
    end
  end
end
