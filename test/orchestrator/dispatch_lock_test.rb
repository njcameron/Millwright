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
