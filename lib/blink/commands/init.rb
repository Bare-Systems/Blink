# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Blink
  module Commands
    class Init
      DEFAULT_OUTPUT = "blink.toml"

      def initialize(argv)
        @argv = argv.dup
        @json = !!@argv.delete("--json")
        @force = !!@argv.delete("--force")
        @output = option_value("--output")
        @service = option_value("--service")
      end

      def run
        if @argv.include?("--help") || @argv.include?("-h")
          show_help
          return
        end

        output_path = File.expand_path(@output || DEFAULT_OUTPUT, Dir.pwd)
        if File.exist?(output_path) && !@force
          return fail_with("Refusing to overwrite existing manifest at #{output_path}. Use --force to replace it.")
        end

        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, scaffold_manifest)

        if @json
          puts Response.dump(
            success: true,
            summary: "Scaffolded #{File.basename(output_path)}",
            details: {
              output: output_path,
              service: inferred_service_name
            },
            next_steps: [
              "Edit the generated manifest for your build, install, and runtime commands.",
              "Run `blink validate #{Shellwords.escape(output_path)}` once the placeholders are filled in."
            ]
          )
          return
        end

        Output.success("Wrote #{output_path}")
        puts
        puts "Next:"
        puts "  1. Fill in your source, install, and start commands."
        puts "  2. Adjust the example API/UI checks under [services.#{inferred_service_name}.verify.tests.*]."
        puts "  3. Run `blink validate #{output_path}`."
      end

      private

      def show_help
        puts "#{Output::BOLD}Usage:#{Output::RESET}  blink init [--output PATH] [--service NAME] [--force] [--json]\n\n"
        puts "  --output   Write the scaffold to a custom manifest path (default: ./blink.toml)"
        puts "  --service  Override the default service name inferred from the current directory"
        puts "  --force    Overwrite an existing manifest"
        puts "  --json     Emit machine-readable JSON output"
      end

      def option_value(flag)
        idx = @argv.index(flag)
        return nil unless idx

        @argv.delete_at(idx)
        @argv.delete_at(idx)
      end

      def fail_with(message)
        if @json
          puts Response.dump(
            success: false,
            summary: message,
            details: { output: File.expand_path(@output || DEFAULT_OUTPUT, Dir.pwd) },
            next_steps: ["Choose a different output path or rerun with `--force`."]
          )
          exit 1
        end

        Output.fatal(message)
      end

      def inferred_service_name
        raw = (@service || File.basename(Dir.pwd)).downcase
        normalized = raw.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
        normalized.empty? ? "app" : normalized
      end

      def scaffold_manifest
        service = inferred_service_name

        <<~TOML
          [blink]
          version = "1"

          [targets.local]
          type = "local"

          [services.#{service}]
          description = "Replace this with a short service description"
          port = "3000"

          [services.#{service}.source]
          type = "local_build"
          command = "make build"
          artifact = "dist/#{service}"

          [services.#{service}.deploy]
          target = "local"
          pipeline = ["fetch_artifact", "stop", "install", "start", "health_check", "verify"]
          rollback_pipeline = ["stop", "rollback", "start"]

          [services.#{service}.install]
          dest = "/opt/#{service}/#{service}"

          [services.#{service}.stop]
          command = "systemctl stop #{service}"

          [services.#{service}.start]
          command = "systemctl start #{service}"

          [services.#{service}.health_check]
          url = "http://127.0.0.1:{{port}}/health"

          [services.#{service}.verify]
          tags = ["smoke"]

          [services.#{service}.verify.tests.api-health]
          type = "api"
          url = "http://127.0.0.1:{{port}}/health"
          tags = ["smoke", "api"]

          [services.#{service}.verify.tests.api-health.checks.status]
          type = "status"
          equals = 200

          [services.#{service}.verify.tests.api-health.checks.json_status]
          type = "json"
          path = "$.status"
          equals = "ok"

          [services.#{service}.verify.tests.ui-home]
          type = "ui"
          url = "http://127.0.0.1:{{port}}/"
          tags = ["smoke", "ui"]

          [services.#{service}.verify.tests.ui-home.checks.root]
          type = "selector"
          engine = "css"
          selector = "#app"

          [services.#{service}.verify.tests.ui-home.checks.welcome]
          type = "text"
          contains = "Welcome"

          # Load testing is planned, but it is intentionally not scaffolded yet.
        TOML
      end
    end
  end
end
