require_relative "../orchestrator/test_helper"
require_relative "../../lib/routines/watchdog"

class WatchdogTest < Minitest::Test
  include OrchestratorTestHelper

  NOW = Time.utc(2026, 6, 10, 14, 0, 0)
  DATE = "2026-06-10".freeze

  # Records doctor_* events; inherits method_missing/prompts for the rest.
  class DoctorChannel < StubUpdateChannel
    attr_reader :detected, :gave_up, :recovered

    def initialize
      @detected = []
      @gave_up = []
      @recovered = []
    end

    def doctor_detected(signals) = @detected << signals
    def doctor_gave_up(target, attempts) = @gave_up << [target, attempts]
    def doctor_recovered(target) = @recovered << target
  end

  class RecordingWorkerRunner
    attr_reader :spawns

    def initialize = @spawns = []

    def spawn_worker(prompt:, chdir:, log_file:)
      @spawns << { prompt: prompt, chdir: chdir, log_file: log_file }
      4242
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("watchdog-test")
    @channel = DoctorChannel.new
    @runner = RecordingWorkerRunner.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- helpers -------------------------------------------------------------

  def ctx(config: TEST_CONFIG.dup)
    Orchestrator::Context.new(
      config: config,
      issue_tracker: StubIssueTracker.new,
      vcs: StubVersionControl.new,
      update_channel: @channel,
      worker_runner: @runner,
      state_dir: File.join(@tmpdir, "state"),
      logs_dir: File.join(@tmpdir, "logs")
    )
  end

  def watchdog(context: ctx, alive: [])
    Watchdog.new(context: context, now: NOW, pid_alive: ->(pid) { alive.include?(pid) })
  end

  def write_log(name, content, age_min:)
    dir = File.join(@tmpdir, "logs", DATE)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, content)
    t = NOW - (age_min * 60)
    File.utime(t, t, path)
    path
  end

  # A fresh, benign orchestrator.log so orchestrator-stalled / log-errors
  # don't fire unless a test wants them to.
  def healthy_orchestrator_log(extra = "")
    write_log("orchestrator.log", "[ok] Orchestrator run finished\n#{extra}", age_min: 0)
  end

  def write_lock(name, age_min:)
    dir = File.join(@tmpdir, "state")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "dispatch_#{name}.lock")
    FileUtils.touch(path)
    t = NOW - (age_min * 60)
    File.utime(t, t, path)
    path
  end

  # --- scan: workers -------------------------------------------------------

  def test_crashed_worker_detected
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)

    signals = watchdog(alive: []).scan # pid 111 not alive

    crashed = signals.select { |s| s[:kind] == "worker-crashed" }
    assert_equal 1, crashed.size
    assert_equal "issue-700", crashed[0][:target]
  end

  # The #530 case: 0-byte log, pid still alive, idle well past the hang window.
  def test_hung_worker_detected
    healthy_orchestrator_log("Spawned claude for issue #530 plan revision (pid: 222)")
    write_log("plan-530.log", "", age_min: 50)

    signals = watchdog(alive: [222]).scan

    hung = signals.select { |s| s[:kind] == "worker-hung" }
    assert_equal 1, hung.size
    assert_equal "plan-530", hung[0][:target]
  end

  def test_recent_worker_not_flagged
    healthy_orchestrator_log("Spawned claude for issue #800 (pid: 333)")
    write_log("issue-800.log", "", age_min: 5) # younger than stall_minutes

    assert_empty watchdog(alive: []).scan.select { |s| s[:kind].start_with?("worker-") }
  end

  def test_worker_with_output_not_flagged_as_stall
    healthy_orchestrator_log("Spawned claude for issue #801 (pid: 444)")
    write_log("issue-801.log", "did some work\n", age_min: 60)

    assert_empty watchdog(alive: []).scan.select { |s| s[:kind].start_with?("worker-") }
  end

  # --- scan: orchestrator + errors ----------------------------------------

  def test_orchestrator_stalled_when_log_is_old
    write_log("orchestrator.log", "[ok] run finished\n", age_min: 10)

    signals = watchdog.scan
    assert(signals.any? { |s| s[:kind] == "orchestrator-stalled" })
  end

  def test_orchestrator_stalled_when_log_missing
    # no orchestrator.log at all
    signals = watchdog.scan
    assert(signals.any? { |s| s[:kind] == "orchestrator-stalled" })
  end

  def test_new_error_lines_detected_and_cursored
    healthy_orchestrator_log("[t] ERROR: missing checkout\n")
    wd = watchdog

    first = wd.scan.select { |s| s[:kind] == "log-errors" }
    assert_equal 1, first.size

    # Re-scan with no new lines → cursor suppresses the already-seen error.
    assert_empty wd.scan.select { |s| s[:kind] == "log-errors" }

    # Append a new error → only the new one is reported.
    healthy_orchestrator_log("[t] ERROR: missing checkout\n[t] ERROR: gh 403 forbidden\n")
    third = wd.scan.select { |s| s[:kind] == "log-errors" }
    assert_equal 1, third.size
    assert_match(/403 forbidden/, third[0][:detail])
  end

  # --- scan: locks + cards -------------------------------------------------

  def test_stale_lock_detected
    healthy_orchestrator_log
    write_lock("pr-99", age_min: 90) # > 60m TTL

    stale = watchdog.scan.select { |s| s[:kind] == "stale-lock" }
    assert_equal 1, stale.size
    assert_equal "lock-pr-99", stale[0][:target]
  end

  def test_fresh_lock_not_flagged
    healthy_orchestrator_log
    write_lock("pr-99", age_min: 5)

    assert_empty watchdog.scan.select { |s| s[:kind] == "stale-lock" }
  end

  # Decoupled from the 60m blocking-TTL: a lock 50m old (still blocking) is now
  # flagged, where the old TTL-tied threshold would have waited until 60m.
  def test_stale_lock_fires_before_blocking_ttl
    healthy_orchestrator_log
    write_lock("plan-530", age_min: 50)

    stale = watchdog.scan.select { |s| s[:kind] == "stale-lock" }
    assert_equal 1, stale.size
    assert_equal "lock-plan-530", stale[0][:target]
  end

  # --- scan: detection-without-dispatch ------------------------------------

  def test_detection_without_dispatch_detected
    lines = Array.new(5) { |i| "[t#{i}] Issue #530: 1 unaddressed plan comment(s)" }
    write_log("orchestrator.log", "#{lines.join("\n")}\n", age_min: 0)

    gap = watchdog.scan.select { |s| s[:kind] == "detection-without-dispatch" }
    assert_equal 1, gap.size
    assert_equal "plan-530", gap[0][:target]
  end

  def test_detection_followed_by_spawn_not_flagged
    lines = Array.new(5) { |i| "[t#{i}] Issue #530: 1 unaddressed plan comment(s)" }
    lines << "[t6] Spawned claude for issue #530 plan revision (pid: 4242)"
    write_log("orchestrator.log", "#{lines.join("\n")}\n", age_min: 0)

    assert_empty watchdog.scan.select { |s| s[:kind] == "detection-without-dispatch" }
  end

  def test_detection_below_threshold_not_flagged
    lines = Array.new(2) { |i| "[t#{i}] Issue #530: 1 unaddressed plan comment(s)" }
    write_log("orchestrator.log", "#{lines.join("\n")}\n", age_min: 0)

    assert_empty watchdog.scan.select { |s| s[:kind] == "detection-without-dispatch" }
  end

  def test_stuck_card_detected
    healthy_orchestrator_log
    context = ctx
    context.issue_tracker.items = [
      { number: 900, status: "In progress", type: "ISSUE", repo: "u/r", title: "wedged" }
    ]

    stuck = watchdog(context: context).scan.select { |s| s[:kind] == "stuck-card" }
    assert_equal 1, stuck.size
    assert_equal "issue-900", stuck[0][:target]
  end

  # A crashed worker already covers its card — don't double-report it.
  def test_stuck_card_deduped_against_worker_signal
    healthy_orchestrator_log("Spawned claude for issue #900 (pid: 555)")
    write_log("issue-900.log", "", age_min: 30)
    context = ctx
    context.issue_tracker.items = [
      { number: 900, status: "In progress", type: "ISSUE", repo: "u/r", title: "wedged" }
    ]

    signals = watchdog(context: context, alive: []).scan
    assert_equal 1, signals.count { |s| s[:target] == "issue-900" }
    assert_equal "worker-crashed", signals.find { |s| s[:target] == "issue-900" }[:kind]
  end

  # --- call: escalation ----------------------------------------------------

  def test_call_dispatches_investigation
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    context = ctx
    wd = watchdog(context: context, alive: [])

    capture_io { wd.call }

    assert_equal 1, @runner.spawns.size
    assert_equal 1, @channel.detected.size
    assert_path_exists File.join(@runner.spawns[0][:chdir], "lib/routines/watchdog.rb")
    assert_match(/SAFE AUTO-REMEDIATION/, @runner.spawns[0][:prompt])
    assert context.dispatch_lock.locked?("doctor"), "should single-flight via doctor lock"
  end

  def test_call_single_flights_when_doctor_lock_held
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    context = ctx
    context.dispatch_lock.lock("doctor")

    capture_io { watchdog(context: context, alive: []).call }

    assert_empty @runner.spawns
  end

  def test_call_dry_run_does_not_dispatch
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    context = ctx
    context.dry_run = true

    capture_io { watchdog(context: context, alive: []).call }

    assert_empty @runner.spawns
    assert_equal 1, @channel.detected.size # still surfaced to Slack
  end

  def test_call_gives_up_after_max_attempts
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    context = ctx
    File.write(File.join(@tmpdir, "state", "doctor_fix_count_issue-700"), "2") # == max_fix_attempts

    capture_io { watchdog(context: context, alive: []).call }

    assert_empty @runner.spawns
    assert_equal [["issue-700", 2]], @channel.gave_up
  end

  def test_call_announces_recovery_and_clears_state
    healthy_orchestrator_log # healthy: scan returns no signals
    context = ctx
    count_file = File.join(@tmpdir, "state", "doctor_fix_count_issue-700")
    File.write(count_file, "1")

    capture_io { watchdog(context: context).call }

    assert_equal ["issue-700"], @channel.recovered
    refute_path_exists count_file
  end

  def test_call_detected_notification_is_throttled
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    context = ctx
    wd = watchdog(context: context, alive: [])

    capture_io do
      wd.call
      wd.call # same signals, within cooldown window
    end

    assert_equal 1, @channel.detected.size
    assert_equal 1, @runner.spawns.size
  end

  def test_diagnose_only_prompt_when_auto_remediate_false
    healthy_orchestrator_log("Spawned claude for issue #700 (pid: 111)")
    write_log("issue-700.log", "", age_min: 30)
    config = TEST_CONFIG.merge("routines" => { "watchdog" => { "auto_remediate" => false } })
    context = ctx(config: config)

    capture_io { watchdog(context: context, alive: []).call }

    assert_match(/DIAGNOSE-ONLY MODE/, @runner.spawns[0][:prompt])
    refute_match(/SAFE AUTO-REMEDIATION/, @runner.spawns[0][:prompt])
  end
end
