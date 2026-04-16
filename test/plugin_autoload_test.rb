# frozen_string_literal: true

require_relative "test_helper"

# Sprint F.3 coverage: plugin autoload picks up .rb files dropped into
# $BLINK_PLUGIN_PATH and makes whatever they register (sources, steps,
# inline tests) available via the registries — and transitively via the
# schema (see Sprint E).
class PluginAutoloadTest < Minitest::Test
  def test_autoload_loads_files_from_blink_plugin_path
    Dir.mktmpdir do |dir|
      marker = "__plugin_autoload_test_source__#{Process.pid}__"
      File.write(File.join(dir, "my_plugin.rb"), <<~RUBY)
        class TestPluginSource < Blink::Sources::Base
          def fetch(version: "latest", build_name: nil); end
        end
        Blink::Sources.register(#{marker.inspect}, TestPluginSource)
      RUBY

      begin
        ENV["BLINK_PLUGIN_PATH"] = dir
        Blink::Plugins.autoload!

        assert_includes Blink::Sources.known_types, marker
        # Schema derives its known source types from the registry — Sprint E
        # guarantees new registrations surface to the validator too.
        assert_includes Blink::Schema::Validator.allocate.send(:known_source_types), marker
      ensure
        ENV.delete("BLINK_PLUGIN_PATH")
        Blink::Sources::REGISTRY.delete(marker)
        Object.send(:remove_const, :TestPluginSource) if Object.const_defined?(:TestPluginSource)
      end
    end
  end

  def test_autoload_tolerates_broken_plugin_with_warning_not_crash
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "broken.rb"), "raise 'intentionally broken'")
      ENV["BLINK_PLUGIN_PATH"] = dir
      captured_err, _ = Blink::Runtime.capture_output(strip_ansi: false, capture_stderr: true) do
        Blink::Plugins.autoload!
      end
      assert_match(/failed to load plugin/, captured_err)
    ensure
      ENV.delete("BLINK_PLUGIN_PATH")
    end
  end
end
