# frozen_string_literal: true

require "shellwords"

module Blink
  module Steps
    # Build a Docker image and run a container from declarative TOML config.
    #
    # This step replaces the combination of a custom start command and a
    # provision script that writes a Dockerfile. Everything needed to go from
    # a binary on disk to a running container is expressed in the TOML.
    #
    # Minimal example (binary already installed by the `install` step):
    #
    #   [services.polar.docker]
    #   name    = "polar"
    #   restart = "unless-stopped"
    #
    #   [services.polar.docker.build]
    #   context    = "{{runtime_dir}}/staging"
    #   dockerfile = """
    #   FROM debian:bookworm-slim
    #   RUN apt-get update && apt-get install -y ca-certificates curl \
    #       && rm -rf /var/lib/apt/lists/*
    #   COPY polar /usr/local/bin/polar
    #   RUN chmod +x /usr/local/bin/polar
    #   CMD ["/usr/local/bin/polar"]
    #   """
    #
    #   [services.polar.docker.ports]
    #   rest = "127.0.0.1:{{port}}:{{port}}"
    #   mcp  = "127.0.0.1:{{mcp_port}}:{{mcp_port}}"
    #
    #   [services.polar.docker.volumes]
    #   data = "{{runtime_dir}}/data:/data"
    #
    #   [services.polar.docker.env]
    #   POLAR_LISTEN_ADDR = ":{{port}}"
    #   POLAR_SQLITE_PATH = "/data/polar.db"
    #
    #   [services.polar.docker.env_file]
    #   path = "{{runtime_dir}}/polar.env"
    #
    #   [services.polar.docker.networks]
    #   main = "baresystems"
    #
    # When docker.build is omitted, docker.image must be set and the image
    # is used as-is (no build step).
    #
    # The `stop` step in the pipeline handles `docker stop + rm` — this step
    # only handles build + run.
    class Docker < Base
      step_definition(
        description: "Build or run a Docker container from declarative service config.",
        config_section: "docker",
        required_keys: ["name"],
        supported_target_types: %w[local ssh],
        rollback_strategy: "same"
      )

      def execute(ctx)
        cfg  = ctx.section("docker").merge(@config)
        name = ctx.resolve(cfg["name"] || raise(Manifest::Error, "docker.name is required for '#{ctx.service_name}'"))

        if dry_run?(ctx)
          image = cfg["build"] ? "#{name}:local" : cfg["image"]
          dry_log(ctx, "would docker build+run container '#{name}' from #{image || "?"}")
          return
        end

        image = build_image(cfg, ctx, name)
        run_container(cfg, ctx, name, image)
      end

      private

      def self.validate_config(config, service_config:, service_name:, path:)
        issues = super
        build = config["build"]
        image = config["image"]

        if build && !build.is_a?(Hash)
          issues << { path: "#{path}.build", message: "docker.build must be a TOML table.", severity: "error" }
        elsif build && !(build["dockerfile"].is_a?(String) && !build["dockerfile"].strip.empty?)
          issues << { path: "#{path}.build.dockerfile", message: "docker.build.dockerfile is required.", severity: "error" }
        elsif !build && !(image.is_a?(String) && !image.strip.empty?)
          issues << { path: "#{path}.image", message: "docker.image is required when docker.build is absent.", severity: "error" }
        end

        issues
      end

      # Write the Dockerfile to the remote context dir and run `docker build`.
      # Returns the image tag to use for `docker run`.
      def build_image(cfg, ctx, name)
        build = cfg["build"]
        return ctx.resolve(cfg["image"] || raise(Manifest::Error,
          "docker.image is required when docker.build is absent for '#{ctx.service_name}'")) unless build

        context    = ctx.resolve(build["context"] || ".")
        dockerfile = build["dockerfile"] || raise(Manifest::Error,
          "docker.build.dockerfile is required for '#{ctx.service_name}'")
        content    = ctx.resolve(dockerfile)
        tag        = "#{name}:local"

        # Write Dockerfile to remote context directory
        ctx.target.run("mkdir -p #{Shellwords.escape(context)}")
        ctx.target.script(
          "cat > #{Shellwords.escape(File.join(context, "Dockerfile"))} <<'__BLINK_EOF__'\n#{content}\n__BLINK_EOF__"
        )

        ctx.target.run("docker build -t #{Shellwords.escape(tag)} #{Shellwords.escape(context)}")
        Output.info("Docker image built: #{tag}")

        tag
      end

      # Construct and execute `docker run` from the config sections.
      def run_container(cfg, ctx, name, image)
        restart = cfg["restart"] || "unless-stopped"
        parts   = ["docker", "run", "-d", "--name", name, "--restart", restart]

        # Ports: values are "host_ip:host_port:container_port"
        (cfg["ports"] || {}).each_value do |mapping|
          parts += ["-p", ctx.resolve(mapping)]
        end

        # Volumes: values are "host_path:container_path[:options]"
        (cfg["volumes"] || {}).each_value do |vol|
          parts += ["-v", ctx.resolve(vol)]
        end

        # Inline env vars
        (cfg["env"] || {}).each do |key, val|
          parts += ["-e", "#{key}=#{ctx.resolve(val.to_s)}"]
        end

        # Env file (secrets managed outside Blink — seeded by provision step)
        if (ef = cfg["env_file"])
          parts += ["--env-file", ctx.resolve(ef["path"])]
        end

        # Docker networks
        (cfg["networks"] || {}).each_value do |net|
          parts += ["--network", ctx.resolve(net)]
        end

        parts << image

        cmd = parts.map { |p| Shellwords.escape(p) }.join(" ")
        ctx.target.run(cmd)
        Output.success("Container started: #{name}")
      end
    end

    Steps.register("docker", Docker)
  end
end
