require_relative "test_helper"

class DispatchLockTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("dispatch-lock-test")
    @ctx = build_context(@tmpdir)
    @lock = @ctx.dispatch_lock
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lock_and_unlock
    refute @lock.locked?(42)

    @lock.lock(42)
    assert @lock.locked?(42)

    @lock.unlock(42)
    refute @lock.locked?(42)
  end

  def test_stale_lock_is_not_locked
    @lock.lock(42)
    lock_file = File.join(@ctx.state_dir, "dispatch_42.lock")
    # Backdate past the TTL
    FileUtils.touch(lock_file, mtime: Time.now - (Orchestrator::DispatchLock::TTL_SECONDS + 60))

    refute @lock.locked?(42)
  end

  def test_unlock_nonexistent_is_noop
    @lock.unlock(999)
  end

  def test_reap_releases_lock_when_owner_dead
    @lock.lock("plan-7")
    @lock.record_pid("plan-7", 999_999) # dead pid

    assert @lock.reap_if_finished("plan-7")
    refute @lock.locked?("plan-7")
  end

  def test_reap_keeps_lock_when_owner_alive
    @lock.lock("plan-7")
    @lock.record_pid("plan-7", Process.pid) # alive

    refute @lock.reap_if_finished("plan-7")
    assert @lock.locked?("plan-7")
  end

  def test_reap_releases_ownerless_lock
    @lock.lock("plan-7") # locked, but no pid recorded

    assert @lock.reap_if_finished("plan-7")
    refute @lock.locked?("plan-7")
  end

  def test_reap_noop_when_not_locked
    refute @lock.reap_if_finished("plan-7")
  end

  # --- reap_finished_issue_locks: the fix for the recurring Doctor stale-lock
  # noise (issue #17). Issue-dispatch locks record a pid now, and this sweep
  # reaps them the moment the worker exits instead of ageing the full TTL. ---

  def test_reap_finished_issue_locks_reaps_dead_worker
    @lock.lock(678)
    @lock.record_pid(678, 999_999) # dead pid

    reaped = []
    @lock.reap_finished_issue_locks { |key| reaped << key }

    refute @lock.locked?(678), "a finished worker's issue lock must be released"
    assert_equal ["678"], reaped
  end

  def test_reap_finished_issue_locks_keeps_live_worker
    @lock.lock(42)
    @lock.record_pid(42, Process.pid) # alive

    @lock.reap_finished_issue_locks { |_| flunk "must not reap a live worker's lock" }

    assert @lock.locked?(42)
  end

  def test_reap_finished_issue_locks_skips_ownerless_lock
    # A legacy lock with no recorded pid must be left alone — reaping it could
    # free a still-running pre-fix worker's slot and cause a double dispatch.
    @lock.lock(99)

    @lock.reap_finished_issue_locks { |_| flunk "must not touch an ownerless lock" }

    assert @lock.locked?(99)
  end

  def test_reap_finished_issue_locks_ignores_prefixed_locks
    # pr-/ci-/plan-/doctor locks are reaped by their own handlers; the issue
    # sweep must only consider bare-numeric keys.
    %w[pr-5 ci-6 plan-7 doctor].each do |key|
      @lock.lock(key)
      @lock.record_pid(key, 999_999) # dead pid
    end

    @lock.reap_finished_issue_locks { |_| flunk "must not touch prefixed locks" }

    %w[pr-5 ci-6 plan-7 doctor].each { |key| assert @lock.locked?(key), "#{key} must survive" }
  end

  def test_unlock_removes_recorded_pid
    @lock.lock("plan-7")
    @lock.record_pid("plan-7", Process.pid)
    @lock.unlock("plan-7")

    # A fresh lock with no pid is ownerless → reaped, proving the old pid file
    # was cleared (a stale alive-pid would otherwise have kept it locked).
    @lock.lock("plan-7")
    assert @lock.reap_if_finished("plan-7")
  end
end
