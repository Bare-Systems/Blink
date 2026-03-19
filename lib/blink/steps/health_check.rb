# frozen_string_literal: true

module Blink
  module Steps
    # Poll a URL until the service responds successfully.
    # Config:
    #   url:      required — URL to poll (supports {{var}} interpolation)
    #   timeout:  seconds to wait before failing (default: 30)
    #   interval: seconds between polls (default: 2)
    class HealthCheck < Base
      def call(ctx)
        cfg      = ctx.section("health_check").merge(@config)
        url      = cfg["url"] || raise(Manifest::Error, "No health_check.url configured for '#{ctx.service_name}'")
        url      = ctx.resolve(url)
        timeout  = (cfg["timeout"]  || 30).to_i
        interval = (cfg["interval"] || 2).to_i

        if dry_run?(ctx)
          dry_log(ctx, "would poll #{url} (timeout: #{timeout}s)")
          return
        end

        Output.step("Polling #{url}  (timeout: #{timeout}s)")
        deadline = Time.now + timeout

        loop do
          result = ctx.target.capture(
            "curl -sfk --max-time 5 --output /dev/null --write-out '%{http_code}' #{url} 2>/dev/null || echo 000"
          )
          code = result.to_i
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
