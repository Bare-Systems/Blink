# frozen_string_literal: true

module Blink
  # Blink's "semantic nucleus" — a small set of plain data structs that
  # describe an operation end-to-end. The goal is a *single source of truth*
  # that both the CLI renderer and the MCP server serialize from, so human
  # output and machine output never drift.
  #
  # These are intentionally dumb data containers:
  #
  #   - `OperationPlan`   — what the engine intends to do (before execute).
  #   - `StepResult`      — outcome of a single pipeline step, including the
  #                         Ansible-style `changed` / `idempotent` flags.
  #   - `OperationResult` — the aggregate outcome of an entire operation,
  #                         composed of step results + diagnostics.
  #   - `ArtifactRef`     — a pointer to a cached build output (path + digest
  #                         + provenance). Returned by fetch_artifact / build.
  #   - `Diagnostics`     — the warnings / notes / errors surfaced by the
  #                         planner or validator, normalized into one shape.
  #
  # Migration strategy: new code paths construct these directly; existing
  # paths can incrementally adopt them via `.from_legacy(...)` helpers (added
  # as we migrate each callsite). Until every callsite is migrated, both the
  # old hash-shaped payloads and these structs coexist — nothing is forcibly
  # rewritten in a single sprint.
  module Semantic
    # A diagnostic issue surfaced by the planner or schema validator.
    # `severity` is one of :error / :warning / :note.
    Diagnostic = Struct.new(:severity, :path, :message, keyword_init: true) do
      def to_h
        { severity: severity.to_s, path: path, message: message }
      end

      def error?   = severity.to_sym == :error
      def warning? = severity.to_sym == :warning
      def note?    = severity.to_sym == :note
    end

    # Bag of diagnostics attached to a plan or result.
    Diagnostics = Struct.new(:issues, keyword_init: true) do
      def self.empty = new(issues: [])

      def errors   = issues.select(&:error?)
      def warnings = issues.select(&:warning?)
      def notes    = issues.select(&:note?)

      def add(severity:, path:, message:)
        issues << Diagnostic.new(severity: severity.to_sym, path: path, message: message)
        self
      end

      def empty? = issues.empty?

      def to_h
        { errors: errors.map(&:to_h), warnings: warnings.map(&:to_h), notes: notes.map(&:to_h) }
      end
    end

    # A reference to a built / fetched artifact — the handoff between a
    # `source` (local/remote build) and the deploy pipeline's `install` step.
    ArtifactRef = Struct.new(:path, :filename, :sha256, :size_bytes, :provenance, :metadata,
                             keyword_init: true) do
      def to_h
        {
          path:        path.to_s,
          filename:    filename,
          sha256:      sha256,
          size_bytes:  size_bytes,
          provenance:  provenance,
          metadata:    metadata || {},
        }
      end
    end

    # A single step's outcome. `changed` is the Ansible-style "did this step
    # actually mutate state?" flag. `idempotent` is "is it safe to re-run this
    # step and expect the same result?" (declared by the step's definition,
    # not by the run). `data` is an optional per-step payload (e.g. the
    # health_check's HTTP status, the install step's remote path).
    StepResult = Struct.new(:name, :status, :changed, :idempotent, :elapsed, :message, :data,
                            keyword_init: true) do
      STATUSES = %i[ok skipped failed dry_run].freeze

      def ok?      = status.to_sym == :ok
      def failed?  = status.to_sym == :failed
      def skipped? = status.to_sym == :skipped

      def to_h
        {
          name:       name,
          status:     status.to_s,
          changed:    changed ? true : false,
          idempotent: idempotent ? true : false,
          elapsed:    elapsed,
          message:    message,
          data:       data || {},
        }
      end
    end

    # What the engine intends to do, produced by the planner before the
    # operation runs. This is what `blink plan` renders and what `blink
    # deploy` / `blink build` consumes.
    OperationPlan = Struct.new(:operation, :service, :target, :pipeline, :rollback_pipeline,
                               :config_hash, :diagnostics, :source, keyword_init: true) do
      def to_h
        {
          operation:         operation.to_s,
          service:           service,
          target:            target,
          pipeline:          pipeline,
          rollback_pipeline: rollback_pipeline,
          config_hash:       config_hash,
          diagnostics:       (diagnostics || Diagnostics.empty).to_h,
          source:            source || {},
        }
      end
    end

    # Aggregate outcome of an operation (deploy, build, rollback, test, …).
    OperationResult = Struct.new(:operation, :service, :status, :steps, :artifact, :diagnostics,
                                 :elapsed, :summary, :next_step, keyword_init: true) do
      def ok?     = status.to_sym == :ok
      def failed? = status.to_sym == :failed
      def changed?    = Array(steps).any? { |s| s.respond_to?(:changed) && s.changed }
      def no_op?      = Array(steps).none? { |s| s.respond_to?(:changed) && s.changed }

      def to_h
        {
          operation:    operation.to_s,
          service:      service,
          status:       status.to_s,
          changed:      changed?,
          steps:        Array(steps).map { |s| s.respond_to?(:to_h) ? s.to_h : s },
          artifact:     artifact&.to_h,
          diagnostics:  (diagnostics || Diagnostics.empty).to_h,
          elapsed:      elapsed,
          summary:      summary,
          next_step:    next_step,
        }
      end
    end
  end
end
