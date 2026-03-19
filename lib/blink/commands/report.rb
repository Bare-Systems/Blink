# frozen_string_literal: true

require "fileutils"
require "json"

module Blink
  module Commands
    class Report
      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @subcommand = @argv.shift

        format_idx = @argv.index("--format")
        @format = if format_idx
          @argv.delete_at(format_idx)
          (@argv.delete_at(format_idx) || "html")
        else
          "html"
        end

        output_idx = @argv.index("--output")
        @output = if output_idx
          @argv.delete_at(output_idx)
          @argv.delete_at(output_idx)
        end

        limit_idx = @argv.index("--limit")
        @limit = if limit_idx
          @argv.delete_at(limit_idx)
          (@argv.delete_at(limit_idx) || "20").to_i
        else
          20
        end
      end

      def run
        unless @subcommand == "generate"
          show_help
          return
        end

        manifest = Manifest.load
        operation = Operations::Report.new(manifest: manifest, limit: @limit)
        body = render_body(operation)
        output_path = resolve_output_path(manifest.dir)
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, body)

        details = {
          manifest: manifest.path,
          format: @format,
          output: output_path,
          limit: @limit
        }

        if @json
          puts Response.dump(
            success: true,
            summary: "Report generated",
            details: details,
            next_steps: ["Open #{output_path} to inspect the generated report."]
          )
          return
        end

        Output.success("Report generated: #{output_path}")
      rescue Manifest::Error => e
        if @json
          puts Response.dump(
            success: false,
            summary: e.message,
            details: { format: @format, output: @output, error: e.message },
            next_steps: ["Generate state with `blink test` or `blink deploy`, then retry the report."]
          )
          exit 1
        end
        Output.fatal(e.message)
      end

      private

      def render_body(operation)
        case @format
        when "html"
          operation.render_html
        when "json"
          operation.render_json
        else
          raise Manifest::Error, "Unknown report format '#{@format}'. Supported formats: html, json"
        end
      end

      def resolve_output_path(base_dir)
        return File.expand_path(@output) if @output

        File.join(base_dir, Lock::BLINK_DIR, "reports", "latest.#{@format}")
      end

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink report generate [--format html|json] [--output PATH] [--limit N] [--json]\n\n"
        puts "Generate a static report from persisted .blink history and current state."
      end
    end
  end
end
