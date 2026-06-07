require "fileutils"

class Orchestrator
  # File-based dispatch locks. A lock prevents the same issue or PR from being
  # picked up twice while a Claude worker is already running for it. Locks
  # older than TTL_SECONDS are treated as stale and ignored.
  class DispatchLock
    TTL_SECONDS = 3600 # 1h — Claude should be done by then

    def initialize(state_dir)
      @state_dir = state_dir
    end

    def locked?(key)
      lock_file = path(key)
      return false unless File.exist?(lock_file)
      (Time.now - File.mtime(lock_file)) < TTL_SECONDS
    end

    def lock(key)
      FileUtils.touch(path(key))
    end

    def unlock(key)
      lock_file = path(key)
      File.delete(lock_file) if File.exist?(lock_file)
    end

    private

    def path(key)
      File.join(@state_dir, "dispatch_#{key}.lock")
    end
  end
end
