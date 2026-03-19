# frozen_string_literal: true

module Blink
  module Testing
    # Suite DSL — declare tests in a class body, then register them into a Runner.
    #
    # Usage:
    #   class TardigradeSuite < Blink::Testing::Suite
    #     suite_name "Tardigrade"
    #
    #     test "responds on health endpoint",
    #          tags: [:smoke, :health],
    #          desc: "Ensures the service is up and returning 200." do
    #       res = http.get("https://127.0.0.1:8443/_health")
    #       assert_status res, 200
    #     end
    #   end
    class Suite
      @registry = []

      # ── Registry ──────────────────────────────────────────────────────────

      class << self
        def inherited(subclass)
          @registry << subclass
        end

        # All Suite subclasses defined since the last with_clean_registry call.
        def registered
          @registry.dup
        end

        # Load suites in a clean scope and return only the newly defined ones.
        def with_clean_registry
          prev = @registry.dup
          @registry = []
          yield
          newly = @registry.dup
          @registry = prev + newly
          newly
        end

        # ── DSL ─────────────────────────────────────────────────────────────

        def suite_name(name = nil)
          name ? (@suite_name = name) : (@suite_name || self.name.to_s)
        end

        # Declare a test case.
        #   name  — short label shown in output
        #   tags  — symbols used for filtering, e.g. [:smoke, :health]
        #   desc  — one-sentence description of what is verified and why
        def test(name, tags: [], desc: nil, &block)
          @tests ||= []
          @tests << { name: name, tags: Array(tags).map(&:to_sym), desc: desc, block: block }
        end

        # Push this suite's tests into a Runner.
        def register(runner)
          (@tests || []).each do |t|
            runner.register_test(t[:name], tags: t[:tags], suite: suite_name, desc: t[:desc], &t[:block])
          end
        end

        # Raw test metadata (for --list, docs, etc.)
        def tests = @tests || []
      end
    end
  end
end
