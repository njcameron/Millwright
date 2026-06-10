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
      [path(key), pid_path(key)].each { |f| File.delete(f) if File.exist?(f) }
    end

    # Records the worker process that owns this lock, so reap_if_finished can
    # release it the moment that process exits — instead of waiting out the
    # full TTL. Use when the lock guards a detached worker whose completion no
    # other code path observes (e.g. plan-revision / CI-fix workers, which —
    # unlike PR workers — aren't unlocked by StatusTransitions).
    def record_pid(key, pid)
      File.write(pid_path(key), pid)
    end

    # Releases the lock if its recorded owner process has exited. A lock with
    # no recorded pid is treated as ownerless and released. Returns true if it
    # reaped the lock. No-op (returns false) if the lock isn't currently held.
    def reap_if_finished(key)
      return false unless locked?(key)

      pid = owner_pid(key)
      return false if pid && process_alive?(pid)

      unlock(key)
      true
    end

    private

    def owner_pid(key)
      file = pid_path(key)
      File.exist?(file) ? File.read(file).to_i : nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true # exists but owned by another user
    end

    def path(key)
      File.join(@state_dir, "dispatch_#{key}.lock")
    end

    def pid_path(key)
      File.join(@state_dir, "dispatch_#{key}.pid")
    end
  end
end
