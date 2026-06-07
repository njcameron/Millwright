require "fileutils"

class Orchestrator
  # Exponential-backoff notification gate. notify(:foo) { ... } yields only
  # if the cooldown for :foo has elapsed; each fire doubles the next cooldown
  # (1h, 2h, 4h, 8h, ...). reset(:foo) clears state.
  class Cooldown
    BASE_SECONDS = 3600

    def initialize(state_dir)
      @state_dir = state_dir
    end

    def notify(key)
      marker = path("notified_#{key}")
      count_file = path("notified_#{key}_count")
      count = File.exist?(count_file) ? File.read(count_file).to_i : 0
      cooldown = BASE_SECONDS * (2**count)

      return if File.exist?(marker) && (Time.now - File.mtime(marker)) < cooldown

      yield
      FileUtils.touch(marker)
      File.write(count_file, count + 1)
    end

    def reset(key)
      [path("notified_#{key}"), path("notified_#{key}_count")].each do |f|
        File.delete(f) if File.exist?(f)
      end
    end

    private

    def path(name)
      File.join(@state_dir, name)
    end
  end
end
