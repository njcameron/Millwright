require "yaml"
require "fileutils"
require "set"
require "time"
require_relative "../orchestrator"

# Runtime watchdog ("doctor"). Runs every minute from its own cron entry,
# INDEPENDENT of the orchestrator — a watchdog inside the orchestrator loop
# could never detect the orchestrator itself being dead.
#
# Two stages:
#   1. scan  — deterministic, side-effect-light detection of stalled/broken
#              state from logs + process liveness + locks + board. Returns a
#              list of Signal hashes. This is the bulk of the logic and is
#              fully unit-testable via injected `now:` / `pid_alive:`.
#   2. call  — throttles + single-flights, then spawns ONE detached Claude
#              worker to perform safe auto-remediation (or diagnose-and-propose
#              for anything touching code/config). Posts to Slack throughout.
#
# Reuses Orchestrator::Context as the dependency bundle (cooldown, dispatch_lock,
# worker_runner, update_channel, issue_tracker, state_dir, logs_dir, log).
class Watchdog
  # logs/<date>/ basenames that are NOT coding-agent workers.
  WORKER_NAME = /\A(?:issue|pr|ci-fix|plan)-\d+\z/

  # ERROR markers + stack-trace shapes worth surfacing from orchestrator.log.
  ERROR_PATTERN = /(?:\A|\] )ERROR:|Errno::|[\w\/]+\.rb:\d+:in |Traceback/

  DEFAULTS = {
    "stall_minutes" => 20,
    "hang_minutes" => 45,
    "orchestrator_tick_minutes" => 3,
    "stale_lock_minutes" => 45,
    "stuck_detection_ticks" => 5,
    "max_fix_attempts" => 2,
    "auto_remediate" => true
  }.freeze

  # orchestrator.log lines where a handler DETECTED actionable work, mapped to a
  # canonical target key. Pairs with SPAWN_PATTERNS: detection with no matching
  # spawn afterwards means dispatch is wedged (e.g. a stale lock, or a crash
  # between detect and spawn).
  DETECTION_PATTERNS = {
    /Issue #(\d+): \d+ unaddressed plan comment/ => "plan",
    /PR #(\d+) \(issue #\d+\): \d+ unaddressed comment/ => "pr",
    /PR #(\d+) \(issue #\d+\): CI failed/ => "ci",
    /Dispatching issue #(\d+)/ => "issue"
  }.freeze

  SPAWN_PATTERNS = {
    /Spawned claude for issue #(\d+) plan revision/ => "plan",
    /Spawned claude for PR #(\d+) review/ => "pr",
    /Spawned claude for CI fix on PR #(\d+)/ => "ci",
    /Spawned claude for issue #(\d+) \(pid/ => "issue"
  }.freeze

  def initialize(context: nil, now: nil, pid_alive: nil)
    @ctx = context || begin
      config = YAML.load_file(File.expand_path("../../../config.yml", __FILE__))
      Orchestrator::Context.new(config: config)
    end
    @injected_now = now
    @pid_alive = pid_alive || method(:process_alive?)
  end

  # --- Stage 1: deterministic detection ------------------------------------

  def scan
    workers = worker_signals
    flagged = workers.map { |s| s[:target][/\d+\z/]&.to_i }.compact.to_set

    workers +
      [orchestrator_signal].compact +
      error_signals +
      lock_signals +
      card_signals(flagged) +
      dispatch_gap_signals
  end

  # --- Stage 2: escalation -------------------------------------------------

  def call
    signals = scan
    announce_recoveries(signals)

    if signals.empty?
      @ctx.log "Watchdog: all healthy"
      return
    end

    @ctx.log "Watchdog: #{signals.size} signal(s): " \
             "#{signals.map { |s| "#{s[:kind]}/#{s[:target]}" }.join(", ")}"

    # Throttle the detected-notification so a persisting problem backs off
    # instead of pinging Slack every minute.
    @ctx.cooldown.notify("doctor_detected_#{signature(signals)}") do
      @ctx.update_channel.doctor_detected(signals)
    end

    return if @ctx.dry_run

    # Release the single-flight lock if the previous doctor worker has exited.
    # Without this, a doctor that dies on startup (e.g. an unavailable model)
    # leaves the lock held for the full TTL, wedging every retry for an hour.
    @ctx.dispatch_lock.reap_if_finished("doctor")
    return if @ctx.dispatch_lock.locked?("doctor") # single-flight investigation

    target = signals.first[:target]
    if fix_count(target) >= max_fix_attempts
      @ctx.cooldown.notify("doctor_gaveup_#{target}") do
        @ctx.update_channel.doctor_gave_up(target, fix_count(target))
      end
      return
    end

    dispatch_investigation(signals, target)
  end

  private

  # --- detection sub-checks ------------------------------------------------

  def worker_signals
    worker_logs.filter_map do |path|
      name = File.basename(path, ".log")
      next if File.size(path).positive? # has output — handled by error scan, not a stall

      age_min = (now - File.mtime(path)) / 60.0
      pid = find_pid(name)
      alive = pid && @pid_alive.call(pid)

      if !alive && age_min > threshold("stall_minutes")
        signal("worker-crashed", name,
               "0-byte log and process #{pid || "?"} not running, idle #{age_min.round}m",
               evidence: "log: #{path} (#{File.size(path)} bytes), pid: #{pid || "unknown"}")
      elsif alive && age_min > threshold("hang_minutes")
        signal("worker-hung", name,
               "process #{pid} alive but produced no output for #{age_min.round}m",
               evidence: "log: #{path}, pid: #{pid}")
      end
    end
  end

  def orchestrator_signal
    path = orchestrator_log
    unless File.exist?(path)
      return signal("orchestrator-stalled", "orchestrator",
                    "no orchestrator.log for today — cron may not be running")
    end

    age_min = (now - File.mtime(path)) / 60.0
    return nil unless age_min > threshold("orchestrator_tick_minutes")

    signal("orchestrator-stalled", "orchestrator",
           "no orchestrator.log activity for #{age_min.round}m (cron runs every minute)",
           evidence: "log: #{path}")
  end

  # New ERROR / stack-trace lines in orchestrator.log since the last scan,
  # tracked via a byte offset in state/. Resets the cursor if the file shrank
  # (daily rotation truncates to a fresh file).
  def error_signals
    path = orchestrator_log
    return [] unless File.exist?(path)

    offset_file = File.join(@ctx.state_dir, "watchdog_offset_orchestrator_#{date_str}")
    prev = File.exist?(offset_file) ? File.read(offset_file).to_i : 0
    size = File.size(path)
    prev = 0 if size < prev

    new_text = File.open(path, "r") { |f| f.seek(prev); f.read }.to_s
    File.write(offset_file, size)

    matches = new_text.lines.select { |l| l.match?(ERROR_PATTERN) }
    return [] if matches.empty?

    [signal("log-errors", "orchestrator",
            "#{matches.size} new error line(s); latest: #{matches.last.strip[0, 160]}",
            evidence: matches.last(5).join)]
  end

  # Locks held longer than `stale_lock_minutes`. Decoupled from the
  # DispatchLock TTL on purpose: the TTL is when the lock STOPS blocking, so a
  # threshold tied to it can only ever fire once the lock is already harmless.
  # A shorter threshold lets us catch a lock while it is still wedging dispatch.
  def lock_signals
    max_age = threshold("stale_lock_minutes") * 60
    Dir.glob(File.join(@ctx.state_dir, "dispatch_*.lock")).filter_map do |lock|
      name = File.basename(lock).sub(/\Adispatch_/, "").sub(/\.lock\z/, "")
      # The doctor's own single-flight lock is self-managed (lock / reap_if_finished
      # / record_pid) and has its own blocking TTL. Flagging it here makes the
      # watchdog spawn a doctor to investigate its own leftover lock — a self-
      # referential loop that re-touches the lock and repeats every ~45m forever.
      next if name == "doctor"

      age = now - File.mtime(lock)
      next unless age > max_age

      signal("stale-lock", "lock-#{name}",
             "dispatch lock held #{(age / 60).round}m (> #{threshold("stale_lock_minutes")}m)",
             evidence: lock)
    end
  end

  # A handler that logs "detected work" for the same target across many ticks
  # with no matching "Spawned claude ..." line afterwards is wedged — dispatch
  # is being skipped (stale lock, or a crash between detect and spawn). This is
  # the symptom-level check: it fires regardless of the underlying cause.
  def dispatch_gap_signals
    return [] unless File.exist?(orchestrator_log)

    detections = Hash.new { |h, k| h[k] = [] }
    last_spawn = {}
    File.foreach(orchestrator_log).with_index do |line, i|
      (t = match_target(line, DETECTION_PATTERNS)) && (detections[t] << i)
      (t = match_target(line, SPAWN_PATTERNS)) && (last_spawn[t] = i)
    end

    min_ticks = threshold("stuck_detection_ticks")
    detections.filter_map do |target, indexes|
      pending = indexes.count { |i| i > (last_spawn[target] || -1) }
      next if pending < min_ticks

      signal("detection-without-dispatch", target,
             "detected actionable work #{pending}x with no worker spawned " \
             "(likely a stuck lock or a crash between detect and dispatch)",
             evidence: "orchestrator.log; last spawn line: #{last_spawn[target] || "none"}")
    end
  end

  def match_target(line, patterns)
    patterns.each do |regex, kind|
      m = line.match(regex)
      return "#{kind}-#{m[1]}" if m
    end
    nil
  end

  # Cards parked in "In progress" with no live worker — wedged work. Skips
  # numbers already reported as crashed/hung workers to avoid double-noise.
  def card_signals(exclude_numbers)
    @ctx.issue_tracker.issues_by_status(@ctx.statuses["building"]).filter_map do |issue|
      number = issue[:number]
      next if exclude_numbers.include?(number)
      next if live_worker_for?(number)

      signal("stuck-card", "issue-#{number}",
             "card is 'In progress' but no live worker is running for it",
             evidence: "repo: #{issue[:repo]}, title: #{issue[:title]}")
    end
  end

  # --- escalation helpers --------------------------------------------------

  def dispatch_investigation(signals, target)
    FileUtils.mkdir_p(today_dir)
    log_file = File.join(today_dir, "doctor-#{target.gsub(/[^\w.-]/, "_")}.log")

    @ctx.dispatch_lock.lock("doctor")
    increment_fix_count(target)
    prompt = build_prompt(signals)
    pid = @ctx.worker_runner.spawn_worker(prompt: prompt, chdir: millwright_root, log_file: log_file)
    # Record the owner so reap_if_finished can release the lock the moment the
    # worker exits, rather than waiting out the full TTL.
    @ctx.dispatch_lock.record_pid("doctor", pid)

    @ctx.log "Watchdog: spawned doctor worker for #{target} " \
             "(pid: #{pid}, attempt #{fix_count(target)}/#{max_fix_attempts})"
  end

  # Targets that previously triggered a remediation (have a fix-count file) but
  # are healthy now — clear their state and announce recovery.
  def announce_recoveries(signals)
    active = signals.map { |s| s[:target] }.to_set
    Dir.glob(File.join(@ctx.state_dir, "doctor_fix_count_*")).each do |f|
      target = File.basename(f).sub("doctor_fix_count_", "")
      next if active.include?(target)

      File.delete(f)
      @ctx.cooldown.reset("doctor_gaveup_#{target}")
      @ctx.update_channel.doctor_recovered(target)
    end
  end

  def build_prompt(signals)
    remediate = threshold("auto_remediate")
    signal_block = signals.map do |s|
      "- [#{s[:kind]}] #{s[:target]}: #{s[:detail]}#{"\n    evidence: #{s[:evidence]}" if s[:evidence]}"
    end.join("\n")

    fix_policy =
      if remediate
        <<~POLICY
          SAFE AUTO-REMEDIATION — you MAY take these reversible, low-risk actions, then report what you did:
          - Delete a dispatch lock in `state/` ONLY after confirming it is stale (the worker it
            guarded is dead and its work is finished/abandoned).
          - Kill a worker process ONLY after confirming it is dead/hung (matches the evidence
            above) so the orchestrator respawns it next tick.
          - Move a card that is wedged in the wrong column back to the correct one via the
            issue tracker CLI.
          - Re-post a notification that was dropped.

          DIAGNOSE-ONLY — for anything that needs a CODE or CONFIG change, a cron change, a
          force-push, or that touches secrets: do NOT apply it. Post the root cause and a
          concrete proposed fix to Slack, then stop.
        POLICY
      else
        <<~POLICY
          DIAGNOSE-ONLY MODE (routines.watchdog.auto_remediate is false): do NOT change anything.
          Investigate, determine the root cause, and post a concrete proposed fix to Slack. Stop.
        POLICY
      end

    <<~PROMPT
      You are the Millwright runtime "doctor". The deterministic watchdog detected the problem(s)
      below on this Millwright host. You are running in the Millwright checkout (the current
      working directory). Investigate and resolve within the strict limits below.

      DETECTED SIGNALS:
      #{signal_block}

      HOW TO INVESTIGATE (cross-reference, like the debug-pr procedure):
      - Today's logs are under `logs/#{date_str}/`. Worker logs: `issue-<n>.log`, `pr-<n>.log`,
        `ci-fix-<n>.log`, `plan-<n>.log`. The orchestrator log is `logs/#{date_str}/orchestrator.log`.
      - The spawn line for a worker (with its `(pid: N)`) is in orchestrator.log.
      - A 0-byte worker log + dead pid = crashed on startup; + live pid = still running or hung.
      - Check process liveness with `ps -p <pid>` before concluding anything about a pid.
      - Dispatch locks live in `state/dispatch_*.lock`; the board state is in the GitHub Project.

      #{fix_policy}
      HARD GUARDRAILS (never violate):
      - NEVER delete a GitHub repository or run `gh repo delete`.
      - NEVER edit or commit code, and NEVER read or modify `config.yml` or `private-key.pem`.
      - Stay within Millwright's `state/`, `logs/`, and the project board. Do the MINIMAL safe
        action, then stop — do not loop or take broad action.

      KEEP SLACK UPDATED at each step (what you found → what you did or propose → done) using:
        #{@ctx.update_channel.prompts.send_message}
    PROMPT
  end

  # --- small utilities -----------------------------------------------------

  def now
    @injected_now || Time.now.utc
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true # exists but owned by another user
  end

  def signal(kind, target, detail, evidence: nil)
    { kind: kind, target: target, detail: detail, evidence: evidence }
  end

  def signature(signals)
    signals.map { |s| "#{s[:kind]}:#{s[:target]}" }.sort.join("|").gsub(/[^\w|]+/, "_")
  end

  def worker_logs
    Dir.glob(File.join(today_dir, "*.log")).select do |p|
      File.basename(p, ".log").match?(WORKER_NAME)
    end
  end

  def find_pid(name)
    return nil unless File.exist?(orchestrator_log)

    pattern =
      case name
      when /\Aissue-(\d+)\z/ then /Spawned claude for issue ##{Regexp.last_match(1)} \(pid: (\d+)\)/
      when /\Aplan-(\d+)\z/  then /issue ##{Regexp.last_match(1)} plan revision \(pid: (\d+)\)/
      when /\Apr-(\d+)\z/    then /PR ##{Regexp.last_match(1)} review \(pid: (\d+)\)/
      when /\Aci-fix-(\d+)\z/ then /CI fix on PR ##{Regexp.last_match(1)} \(pid: (\d+)\)/
      end
    return nil unless pattern

    pid = nil
    File.foreach(orchestrator_log) do |line|
      m = line.match(pattern)
      pid = m[1].to_i if m
    end
    pid
  end

  def live_worker_for?(number)
    %W[issue-#{number} plan-#{number} ci-fix-#{number} pr-#{number}].any? do |name|
      pid = find_pid(name)
      pid && @pid_alive.call(pid)
    end
  end

  def fix_count(target)
    path = fix_count_path(target)
    File.exist?(path) ? File.read(path).to_i : 0
  end

  def increment_fix_count(target)
    File.write(fix_count_path(target), fix_count(target) + 1)
  end

  def fix_count_path(target)
    File.join(@ctx.state_dir, "doctor_fix_count_#{target}")
  end

  def threshold(key)
    value = @ctx.config.dig("routines", "watchdog", key)
    value.nil? ? DEFAULTS[key] : value
  end

  def max_fix_attempts
    threshold("max_fix_attempts")
  end

  def date_str
    now.strftime("%Y-%m-%d")
  end

  def today_dir
    File.join(@ctx.logs_dir, date_str)
  end

  def orchestrator_log
    File.join(today_dir, "orchestrator.log")
  end

  def millwright_root
    File.expand_path("../..", __dir__)
  end
end

# Run when invoked directly (bin/watch).
Watchdog.new.call if __FILE__ == $PROGRAM_NAME
