# frozen_string_literal: true

require "securerandom"

module Blink
  # Thread-safe task manager for long-running MCP operations.
  #
  # When an MCP client calls `blink_build` or `blink_deploy` with `task: true`,
  # the server creates a Task here, spawns a background thread, and returns
  # the task handle immediately. The client can poll `blink_task_status` for
  # progress and inspect the final result when the task completes.
  #
  # Task lifecycle:
  #
  #   :pending  →  :running  →  :completed | :failed | :cancelled
  #
  # The manager holds tasks in memory (no disk persistence — tasks are scoped
  # to the lifetime of the MCP server process). A GC sweep removes completed
  # tasks older than `RETENTION_SECONDS` on every new submission.
  class TaskManager
    RETENTION_SECONDS = 3600  # keep finished tasks for 1 hour

    Task = Struct.new(
      :id, :tool, :service, :status, :progress, :result,
      :created_at, :started_at, :finished_at, :thread,
      :cancel_requested,
      keyword_init: true
    ) do
      def pending?    = status == :pending
      def running?    = status == :running
      def completed?  = status == :completed
      def failed?     = status == :failed
      def cancelled?  = status == :cancelled
      def finished?   = %i[completed failed cancelled].include?(status)

      # Thread-safe progress append. Workers call this between steps.
      def log(message)
        @mutex.synchronize { progress << { t: Time.now.utc.iso8601, msg: message } }
      end

      # Check if cancellation was requested (worker polls this between steps).
      def cancel_requested?
        @mutex.synchronize { cancel_requested }
      end

      # Request cancellation. The worker will pick this up before its next step.
      def request_cancel!
        @mutex.synchronize { self.cancel_requested = true }
      end

      # Called internally after Struct.new — initialize the per-task mutex.
      def init_mutex!
        @mutex = Mutex.new
        self
      end

      def to_h
        {
          id:           id,
          tool:         tool,
          service:      service,
          status:       status.to_s,
          progress:     progress,
          result:       result,
          created_at:   created_at,
          started_at:   started_at,
          finished_at:  finished_at,
        }
      end
    end

    def initialize
      @tasks = {}
      @mutex = Mutex.new
    end

    # Submit a new task. Returns the Task (already in :pending state).
    # Caller must call `run_task(task) { ... }` to start it.
    def submit(tool:, service:)
      gc!
      task = Task.new(
        id:               SecureRandom.uuid,
        tool:             tool,
        service:          service,
        status:           :pending,
        progress:         [],
        result:           nil,
        created_at:       Time.now.utc.iso8601,
        started_at:       nil,
        finished_at:      nil,
        thread:           nil,
        cancel_requested: false
      ).init_mutex!

      @mutex.synchronize { @tasks[task.id] = task }
      task
    end

    # Start the task in a background thread. The block receives the task
    # and should return the result hash. Exceptions are caught and recorded
    # as a :failed status.
    def run_task(task)
      task.status = :running
      task.started_at = Time.now.utc.iso8601

      task.thread = Thread.new do
        begin
          result = yield(task)
          if task.cancel_requested?
            task.status = :cancelled
            task.result = { "success" => false, "summary" => "Task cancelled by client." }
          else
            task.status = :completed
            task.result = result
          end
        rescue => e
          task.status = :failed
          task.result = { "success" => false, "summary" => "Task failed: #{e.message}", "error" => e.class.name }
        ensure
          task.finished_at = Time.now.utc.iso8601
        end
      end

      task
    end

    # Look up a task by ID.
    def find(id)
      @mutex.synchronize { @tasks[id] }
    end

    # List all tasks (optionally filtered by status).
    def list(status: nil)
      @mutex.synchronize do
        tasks = @tasks.values
        tasks = tasks.select { |t| t.status == status.to_sym } if status
        tasks.map(&:to_h)
      end
    end

    # Request cancellation. Returns true if the task was found and running.
    def cancel(id)
      task = find(id)
      return false unless task && task.running?

      task.request_cancel!
      true
    end

    private

    # Remove finished tasks older than RETENTION_SECONDS.
    def gc!
      cutoff = Time.now.utc - RETENTION_SECONDS
      @mutex.synchronize do
        @tasks.reject! do |_id, task|
          task.finished? && task.finished_at && Time.parse(task.finished_at) < cutoff
        end
      end
    rescue
      nil # Time.parse can fail on malformed timestamps; don't crash the GC.
    end
  end
end
