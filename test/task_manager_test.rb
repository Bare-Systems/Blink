# frozen_string_literal: true

require_relative "test_helper"

# Sprint F.4 coverage: TaskManager lifecycle, concurrency, cancel, and GC.
class TaskManagerTest < Minitest::Test
  def setup
    @mgr = Blink::TaskManager.new
  end

  def test_submit_returns_pending_task_with_uuid
    task = @mgr.submit(tool: "blink_build", service: "demo")
    assert_match(/\A[0-9a-f-]{36}\z/, task.id)
    assert_equal :pending, task.status
    assert_equal "blink_build", task.tool
    assert_equal "demo", task.service
    assert_nil task.result
  end

  def test_run_task_transitions_to_completed
    task = @mgr.submit(tool: "blink_build", service: "demo")
    @mgr.run_task(task) do |t|
      t.log("step 1")
      t.log("step 2")
      { "success" => true, "summary" => "done" }
    end
    task.thread.join(5)

    assert_equal :completed, task.status
    assert_equal true, task.result["success"]
    assert_equal 2, task.progress.size
    assert_match "step 1", task.progress[0][:msg]
    refute_nil task.started_at
    refute_nil task.finished_at
  end

  def test_run_task_transitions_to_failed_on_exception
    task = @mgr.submit(tool: "blink_deploy", service: "demo")
    @mgr.run_task(task) { |_t| raise "boom" }
    task.thread.join(5)

    assert_equal :failed, task.status
    assert_equal false, task.result["success"]
    assert_match(/boom/, task.result["summary"])
  end

  def test_cancel_sets_cancelled_status
    barrier = Queue.new
    task = @mgr.submit(tool: "blink_deploy", service: "demo")
    @mgr.run_task(task) do |t|
      barrier.pop  # block until cancel is requested
      t.log("checking cancel")
      { "success" => true, "summary" => "done" }
    end

    # Task is running, request cancel
    assert @mgr.cancel(task.id)
    barrier.push(:go)
    task.thread.join(5)

    assert_equal :cancelled, task.status
    assert_equal false, task.result["success"]
  end

  def test_cancel_returns_false_for_finished_task
    task = @mgr.submit(tool: "blink_build", service: "demo")
    @mgr.run_task(task) { { "success" => true } }
    task.thread.join(5)

    refute @mgr.cancel(task.id)
  end

  def test_cancel_returns_false_for_unknown_id
    refute @mgr.cancel("nonexistent-id")
  end

  def test_find_returns_nil_for_unknown_id
    assert_nil @mgr.find("nonexistent-id")
  end

  def test_list_returns_all_tasks
    @mgr.submit(tool: "blink_build", service: "a")
    @mgr.submit(tool: "blink_deploy", service: "b")
    assert_equal 2, @mgr.list.size
  end

  def test_list_filters_by_status
    t1 = @mgr.submit(tool: "blink_build", service: "a")
    t2 = @mgr.submit(tool: "blink_build", service: "b")
    @mgr.run_task(t1) { { "ok" => true } }
    t1.thread.join(5)

    completed = @mgr.list(status: "completed")
    pending   = @mgr.list(status: "pending")
    assert_equal 1, completed.size
    assert_equal 1, pending.size
    assert_equal "a", completed[0][:service]
    assert_equal "b", pending[0][:service]
  end

  def test_to_h_includes_all_fields
    task = @mgr.submit(tool: "blink_build", service: "demo")
    h = task.to_h
    %i[id tool service status progress result created_at started_at finished_at].each do |key|
      assert h.key?(key), "expected to_h to include #{key}"
    end
  end
end
