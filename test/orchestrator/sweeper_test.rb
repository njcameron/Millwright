require_relative "test_helper"

class SweeperTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("sweeper-test")
    @state_dir = File.join(@tmpdir, "state")
    @logs_dir = File.join(@tmpdir, "logs")
    FileUtils.mkdir_p(@state_dir)
    FileUtils.mkdir_p(@logs_dir)
    @sweeper = Orchestrator::Sweeper.new(state_dir: @state_dir, logs_dir: @logs_dir, retention_days: 7)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- cleanup_logs ---

  def test_cleanup_logs_deletes_old_dated_directories
    old = File.join(@logs_dir, "2026-01-01")
    fresh = File.join(@logs_dir, Time.now.utc.strftime("%Y-%m-%d"))
    FileUtils.mkdir_p(old)
    FileUtils.mkdir_p(fresh)

    @sweeper.cleanup_logs

    refute Dir.exist?(old), "old log dir should be deleted"
    assert Dir.exist?(fresh), "today's log dir should remain"
  end

  def test_cleanup_logs_yields_deleted_names
    FileUtils.mkdir_p(File.join(@logs_dir, "2026-01-01"))
    FileUtils.mkdir_p(File.join(@logs_dir, "2026-01-02"))

    yielded = []
    @sweeper.cleanup_logs { |name| yielded << name }

    assert_equal %w[2026-01-01 2026-01-02].sort, yielded.sort
  end

  def test_cleanup_logs_ignores_non_dated_entries
    rogue = File.join(@logs_dir, "README.txt")
    File.write(rogue, "leave me alone")

    @sweeper.cleanup_logs

    assert File.exist?(rogue), "non-dated entries should be left untouched"
  end

  # --- cleanup_state ---

  def test_cleanup_state_deletes_files_older_than_retention
    old = File.join(@state_dir, "dispatch_99.lock")
    fresh = File.join(@state_dir, "dispatch_100.lock")
    FileUtils.touch(old)
    FileUtils.touch(fresh)
    FileUtils.touch(old, mtime: Time.now - 8 * 86400)

    @sweeper.cleanup_state

    refute File.exist?(old), "old state file should be deleted"
    assert File.exist?(fresh), "fresh state file should remain"
  end

  def test_cleanup_state_keeps_files_within_retention
    recent = File.join(@state_dir, "ci_fix_count_42")
    FileUtils.touch(recent)
    FileUtils.touch(recent, mtime: Time.now - 6 * 86400)

    @sweeper.cleanup_state

    assert File.exist?(recent), "files within the retention window must be kept"
  end

  def test_cleanup_state_yields_deleted_names
    old = File.join(@state_dir, "notified_ci_gave_up_42")
    FileUtils.touch(old)
    FileUtils.touch(old, mtime: Time.now - 30 * 86400)

    yielded = []
    @sweeper.cleanup_state { |name| yielded << name }

    assert_equal ["notified_ci_gave_up_42"], yielded
  end

  def test_cleanup_state_ignores_subdirectories
    nested = File.join(@state_dir, "subdir")
    FileUtils.mkdir_p(nested)
    FileUtils.touch(nested, mtime: Time.now - 30 * 86400)

    @sweeper.cleanup_state

    assert Dir.exist?(nested), "directories inside state/ must not be deleted"
  end

  def test_retention_days_is_configurable
    sweeper = Orchestrator::Sweeper.new(state_dir: @state_dir, logs_dir: @logs_dir, retention_days: 1)

    old = File.join(@state_dir, "dispatch_5.lock")
    FileUtils.touch(old)
    FileUtils.touch(old, mtime: Time.now - 2 * 86400)

    sweeper.cleanup_state

    refute File.exist?(old), "shorter retention should delete files older than it"
  end
end
