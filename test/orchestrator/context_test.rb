require_relative "test_helper"

class ContextErrorTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("context-error-test")
    @channel = RecordingUpdateChannel.new
    @ctx = build_context(@tmpdir, update_channel: @channel)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_error_logs_and_notifies
    out, = capture_io { @ctx.error("boom", key: "k1", detail: "stack trace") }

    assert_match(/ERROR: boom/, out)
    assert_equal 1, @channel.errors.size
    assert_equal "boom", @channel.errors[0][:message]
    assert_equal "stack trace", @channel.errors[0][:detail]
  end

  def test_repeated_error_same_key_is_throttled
    capture_io do
      @ctx.error("boom", key: "same")
      @ctx.error("boom again", key: "same")
    end

    assert_equal 1, @channel.errors.size, "second error with same key should be throttled"
  end

  def test_distinct_keys_each_notify
    capture_io do
      @ctx.error("a", key: "ka")
      @ctx.error("b", key: "kb")
    end

    assert_equal 2, @channel.errors.size
  end

  def test_log_is_written_even_when_notification_is_throttled
    out, = capture_io do
      @ctx.error("first", key: "same")
      @ctx.error("second", key: "same")
    end

    assert_match(/ERROR: first/, out)
    assert_match(/ERROR: second/, out, "throttled error must still be logged")
  end

  def test_notification_failure_does_not_raise
    def @channel.error(*) = raise "slack is down"

    out, = capture_io { @ctx.error("boom", key: "k") }

    assert_match(/failed to send error notification/, out)
  end
end
