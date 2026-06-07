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
end
