# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class Steps
      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @step_name = @argv.reject { _1.start_with?("-") }.first
      end

      def run
        details = Operations::StepCatalog.new(step_name: @step_name).call

        if @json
          puts Response.dump(
            success: true,
            summary: summary_for(details),
            details: details,
            next_steps: next_steps_for
          )
          return
        end

        Output.header(@step_name ? "Step: #{@step_name}" : "Steps")
        puts

        details[:steps].each do |step|
          Output.label_row("Name:", step[:name])
          Output.label_row("Description:", step[:description])
          Output.label_row("Config:", step[:config_section])
          Output.label_row("Targets:", step[:supported_target_types].join(", "))
          Output.label_row("Rollback:", step[:rollback_strategy])
          Output.label_row("Mutates:", step[:mutates_context].join(", "))
          puts
        end
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { step: @step_name, error: e.message },
            next_steps: ["Run `blink steps` to list the available built-in steps."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private

      def summary_for(details)
        return "Step definition loaded for #{@step_name}" if @step_name

        "#{details[:steps].size} step definition(s) loaded"
      end

      def next_steps_for
        return ["Use this step in deploy.pipeline or rollback_pipeline within blink.toml."] if @step_name

        ["Run `blink steps <name>` to inspect a specific step in more detail."]
      end
    end
  end
end
