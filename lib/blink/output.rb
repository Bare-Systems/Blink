# frozen_string_literal: true

module Blink
  module Output
    RESET  = "\e[0m"
    BOLD   = "\e[1m"
    RED    = "\e[31m"
    GREEN  = "\e[32m"
    YELLOW = "\e[33m"
    BLUE   = "\e[34m"
    CYAN   = "\e[36m"
    GRAY   = "\e[90m"

    module_function

    def header(text)
      puts "\n#{BOLD}#{BLUE}==> #{text}#{RESET}"
    end

    def step(text)
      puts "#{CYAN}  →  #{RESET}#{text}"
    end

    def success(text)
      puts "#{GREEN}  ✓  #{RESET}#{text}"
    end

    def warn(text)
      puts "#{YELLOW}  ⚠  #{RESET}#{text}"
    end

    def error(text)
      $stderr.puts "#{RED}  ✗  #{RESET}#{text}"
    end

    def info(text)
      puts "#{GRAY}     #{text}#{RESET}"
    end

    def label_row(label, value, color: RESET)
      printf "  %-24s#{color}%s#{RESET}\n", label, value
    end

    def fatal(text)
      error(text)
      exit 1
    end

    def check(label, ok, ok_msg: "ok", fail_msg: "FAIL")
      if ok
        label_row("#{label}:", "#{GREEN}#{ok_msg}#{RESET}")
      else
        label_row("#{label}:", "#{RED}#{fail_msg}#{RESET}")
      end
      ok
    end

    # Suppress ANSI codes when not writing to a TTY or when --json is active.
    def plain?
      !$stdout.tty?
    end
  end
end
