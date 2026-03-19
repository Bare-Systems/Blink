# frozen_string_literal: true

module Blink
  class CLI
    COMMANDS = {
      "deploy"  => Commands::Deploy,
      "plan"    => Commands::Plan,
      "test"    => Commands::Test,
      "status"  => Commands::Status,
      "doctor"  => Commands::Doctor,
      "logs"    => Commands::Logs,
      "restart" => Commands::Restart,
      "ps"      => Commands::Ps,
      "ssh"     => Commands::SshCmd,
    }.freeze

    DESCRIPTIONS = {
      "deploy  <service>"          => "Deploy a service using its declared pipeline",
      "plan    <service>"          => "Show what deploy would do without executing (dry-run)",
      "test    [service] [@tag]"   => "Run verification suites against a target",
      "status  [service]"          => "Show service health and container state",
      "doctor  [--target NAME]"    => "Run connectivity and health checks",
      "logs    <service> [-f]"     => "Tail service logs",
      "restart <service>"          => "Stop then start a service",
      "ps      [--target NAME]"    => "Show running Docker containers",
      "ssh     [--target NAME]"    => "Open an interactive SSH session",
    }.freeze

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      # Global flags handled before dispatch
      if @argv.delete("--mcp")
        require_relative "mcp_server"
        MCPServer.new.run
        return
      end

      cmd = @argv.shift

      case cmd
      when nil, "help", "--help", "-h"
        show_help
      when "--version", "-v", "version"
        puts "blink #{VERSION}"
      else
        klass = COMMANDS[cmd]
        if klass
          klass.new(@argv).run
        else
          Output.error("Unknown command: '#{cmd}'")
          puts
          show_help
          exit 1
        end
      end
    end

    private

    def show_help
      puts "#{Output::BOLD}blink#{Output::RESET} — declarative CI/CD operations CLI  #{Output::GRAY}v#{VERSION}#{Output::RESET}\n\n"
      puts "#{Output::BOLD}Usage:#{Output::RESET}  blink <command> [options]\n\n"
      puts "#{Output::BOLD}Commands:#{Output::RESET}"
      DESCRIPTIONS.each do |cmd, desc|
        printf "  #{Output::CYAN}%-28s#{Output::RESET}%s\n", cmd, desc
      end
      puts
      puts "#{Output::BOLD}Global options:#{Output::RESET}"
      puts "  #{Output::CYAN}--json#{Output::RESET}                       Machine-readable JSON output (most commands)"
      puts "  #{Output::CYAN}--dry-run#{Output::RESET}                    Preview changes without executing (deploy)"
      puts "  #{Output::CYAN}--target NAME#{Output::RESET}                Override the target declared in blink.toml"
      puts "  #{Output::CYAN}--mcp#{Output::RESET}                        Start the MCP server (stdio transport)"
      puts
      puts "#{Output::GRAY}Manifest: blink.toml in CWD, or set BLINK_MANIFEST to override.#{Output::RESET}"
      puts "#{Output::GRAY}Set GITHUB_TOKEN or GH_TOKEN for authenticated GitHub API requests.#{Output::RESET}"

      # Show services from manifest if available
      begin
        manifest = Manifest.load
        puts
        puts "#{Output::BOLD}Services (from #{File.basename(manifest.path)}):#{Output::RESET}"
        manifest.service_names.each do |name|
          svc = manifest.service(name)
          desc = svc["description"] || ""
          printf "  #{Output::CYAN}%-22s#{Output::RESET}%s\n", name, desc
        end
      rescue Manifest::Error
        # No manifest in CWD — that's fine at help time
      end
      puts
    end
  end
end
