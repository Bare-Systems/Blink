# frozen_string_literal: true

module Blink
  module Steps
    # Poll a URL until the service responds successfully.
    # Config:
    #   url:      required — URL to poll (supports {{var}} interpolation)
    #   timeout:  seconds to wait before failing (default: 30)
    #   interval: seconds between polls (default: 2)
    class HealthCheck < Base
      step_definition(
        description: "Poll a service URL until it returns a successful response.",
        required_keys: ["url"],
        supported_target_types: %w[local ssh],
        rollback_strategy: "same"
      )

      def execute(ctx)
        cfg      = ctx.section("health_check").merge(@config)
        url      = cfg["url"] || raise(Manifest::Error, "No health_check.url configured for '#{ctx.service_name}'")
        url      = ctx.resolve(url)
        timeout  = (cfg["timeout"]  || 30).to_i
        interval = (cfg["interval"] || 2).to_i
        http_version = cfg["http_version"]
        tls_insecure = cfg.fetch("tls_insecure", false)

        if dry_run?(ctx)
          dry_log(ctx, "would poll #{url} (timeout: #{timeout}s)")
          return
        end

        Output.step("Polling #{url}  (timeout: #{timeout}s)")
        Output.warn("TLS verification disabled for #{url} (tls_insecure=true)") if tls_insecure
        deadline = Time.now + timeout

        loop do
          code = HTTP::Adapter.health_probe(
            ctx.target, url,
            http_version: http_version,
            tls_insecure: tls_insecure
          )
          if (200..299).cover?(code)
            Output.success("Health check passed (HTTP #{code})")
            return
          end

          raise "Health check timed out after #{timeout}s waiting for #{url}" if Time.now >= deadline

          sleep interval
        end
      end
    end

    Steps.register("health_check", HealthCheck)
  end
end
