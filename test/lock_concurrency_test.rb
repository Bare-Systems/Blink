# frozen_string_literal: true

require_relative "test_helper"

# Sprint B guardrail: ensure `Blink::Lock`'s shared-state writes are safe under
# concurrent threads.
#
# The contract we're proving:
#   1. Atomic writes: readers never see partial/torn JSON during a write.
#   2. Flock-serialized read-modify-write: N concurrent writers each contribute
#      one entry to the shared list and none are lost.
class LockConcurrencyTest < BlinkTestCase
  THREADS = 16
  ITERATIONS_PER_THREAD = 10

  def test_write_json_is_atomic_and_leaves_no_tmp_files
    with_tmp_workspace do |dir|
      path = File.join(dir, "state.json")

      readers_saw_invalid_json = false
      stop = false
      reader = Thread.new do
        until stop
          if File.exist?(path)
            begin
              JSON.parse(File.read(path))
            rescue JSON::ParserError
              readers_saw_invalid_json = true
            end
          end
        end
      end

      threads = Array.new(THREADS) do |i|
        Thread.new do
          ITERATIONS_PER_THREAD.times do |j|
            Blink::Lock.send(:write_json, path, { "thread" => i, "iter" => j, "payload" => "x" * 500 })
          end
        end
      end
      threads.each(&:join)
      stop = true
      reader.join

      refute readers_saw_invalid_json, "concurrent reader observed torn JSON during writes"
      leftover = Dir.glob(File.join(dir, "state.json.tmp.*"))
      assert_empty leftover, "tmp files were left behind: #{leftover.inspect}"
      assert_kind_of Hash, JSON.parse(File.read(path))
    end
  end

  def test_with_state_lock_serializes_read_modify_write
    with_tmp_workspace do |dir|
      path = File.join(dir, ".blink", "state", "shared.json")
      FileUtils.mkdir_p(File.dirname(path))
      Blink::Lock.send(:write_json, path, [])

      threads = Array.new(THREADS) do |i|
        Thread.new do
          ITERATIONS_PER_THREAD.times do |j|
            Blink::Lock.send(:with_state_lock, dir) do
              current = JSON.parse(File.read(path))
              current << { "thread" => i, "iter" => j }
              Blink::Lock.send(:write_json, path, current)
            end
          end
        end
      end
      threads.each(&:join)

      final = JSON.parse(File.read(path))
      assert_equal THREADS * ITERATIONS_PER_THREAD, final.size,
                   "lost updates under flock — expected #{THREADS * ITERATIONS_PER_THREAD}, got #{final.size}"
    end
  end
end
