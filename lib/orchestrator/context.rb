require "fileutils"
require "time"
require_relative "dispatch_lock"
require_relative "cooldown"
require_relative "worker_runner"
require_relative "sweeper"
require_relative "../adapters/registry"

class Orchestrator
  # Bundle of shared dependencies passed into each handler so they don't
  # all reach back into the Orchestrator. Owns state_dir + logs_dir on
  # disk and the small infrastructure objects (lock, cooldown, runner).
  class Context
    attr_reader :config, :statuses,
                :issue_tracker, :vcs, :update_channel, :coding_agent,
                :state_dir, :logs_dir,
                :dispatch_lock, :cooldown, :worker_runner, :sweeper
    attr_accessor :dry_run

    def initialize(config:,
                   issue_tracker: nil, vcs: nil, update_channel: nil,
                   coding_agent: nil, worker_runner: nil,
                   dry_run: false, state_dir: nil, logs_dir: nil)
      @config = config
      @statuses = config["statuses"]
      adapters = config["adapters"] || {}

      @issue_tracker = issue_tracker || Adapters::Registry.build(
        :issue_tracker, (adapters["issue_tracker"] || "github_projects").to_sym, config
      )
      @vcs = vcs || Adapters::Registry.build(
        :version_control, (adapters["version_control"] || "github").to_sym, config
      )
      @update_channel = update_channel || Adapters::Registry.build(
        :update_channel, (adapters["update_channel"] || "slack").to_sym, config
      )
      @coding_agent = coding_agent || Adapters::Registry.build(
        :coding_agent, (adapters["coding_agent"] || "claude_code").to_sym, config
      )

      @dry_run = dry_run

      @state_dir = state_dir || File.expand_path("../../state", __dir__)
      FileUtils.mkdir_p(@state_dir)
      @logs_dir = logs_dir || File.expand_path("../../logs", __dir__)

      @dispatch_lock = DispatchLock.new(@state_dir)
      @cooldown = Cooldown.new(@state_dir)
      @worker_runner = worker_runner || WorkerRunner.new(
        config: config, vcs: @vcs, coding_agent: @coding_agent,
        update_channel: @update_channel, logs_dir: @logs_dir
      )
      @sweeper = Sweeper.new(
        state_dir: @state_dir, logs_dir: @logs_dir,
        retention_days: config["retention_days"]
      )
    end

    def log(message)
      puts "[#{Time.now.utc.iso8601}] #{message}"
    end

    # Logs an operational error AND surfaces it to the update channel (Slack).
    # The log line is always written; the notification is gated through
    # Cooldown so a recurring error (e.g. a missing checkout hit every minute)
    # notifies at most once per backoff window instead of spamming the channel.
    # `key` groups occurrences for throttling — pass a stable value (not the
    # full message) when the same condition can recur. Never raises: a failed
    # notification must not break the orchestrator run.
    def error(message, key: message, detail: nil, fields: {})
      log "ERROR: #{message}"
      cooldown.notify("error_#{key.to_s.gsub(/[^\w]+/, "_")}") do
        update_channel.error(message, detail: detail, fields: fields)
      end
    rescue => e
      log "Warning: failed to send error notification: #{e.message}"
    end
  end
end
