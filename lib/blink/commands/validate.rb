# frozen_string_literal: true

require "json"

module Blink
  module Commands
    class Validate
      EXIT_VALIDATION_ERROR = 2

      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @path = @argv.shift
      end

      def run
        result = Manifest.validate_file(@path)

        if @json
          puts Response.dump(
            success: result.valid?,
            summary: result.summary,
            details: result.to_h,
            next_steps: result.valid? ? [] : ["Fix the reported manifest errors and run `blink validate` again."]
          )
        else
          render_human(result)
        end

        exit(EXIT_VALIDATION_ERROR) if result.invalid?
      rescue Manifest::Error => e
        if @json
          puts JSON.generate(
            Response.build(
              success: false,
              summary: e.message,
              details: {
                manifest: @path,
                errors: [{ path: "manifest", message: e.message, severity: "error" }],
                warnings: []
              },
              next_steps: ["Check the manifest path and fix the reported error."]
            )
          )
          exit(EXIT_VALIDATION_ERROR)
        end

        Output.fatal(e.message)
      end

      private

      def render_human(result)
        if result.valid?
          Output.success("#{result.summary}: #{result.manifest_path}")
          Output.info("#{result.service_count} service(s), #{result.target_count} target(s)")
        else
          Output.error("#{result.summary}: #{result.manifest_path}")
          puts
          result.errors.each do |issue|
            puts "  - #{issue.path}: #{issue.message}"
          end
        end

        return if result.warnings.empty?

        puts
        Output.warn("#{result.warnings.size} warning(s)")
        result.warnings.each do |issue|
          puts "  - #{issue.path}: #{issue.message}"
        end
      end
    end
  end
end
