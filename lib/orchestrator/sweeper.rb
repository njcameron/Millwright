require "fileutils"
require "time"

class Orchestrator
  # Garbage-collects on-disk artefacts the orchestrator leaves behind.
  # - cleanup_logs: drops daily log directories (logs/YYYY-MM-DD) older
  #   than retention_days, by directory name.
  # - cleanup_state: drops top-level files in state/ whose mtime is older
  #   than retention_days. Subdirectories are skipped.
  # Both methods yield each deleted basename to the caller (if a block is
  # given) so progress can be logged.
  class Sweeper
    DEFAULT_RETENTION_DAYS = 7

    def initialize(state_dir:, logs_dir:, retention_days: nil)
      @state_dir = state_dir
      @logs_dir = logs_dir
      @retention_days = retention_days || DEFAULT_RETENTION_DAYS
    end

    def cleanup_logs
      cutoff = (Time.now.utc - @retention_days * 86400).strftime("%Y-%m-%d")
      Dir.glob(File.join(@logs_dir, "????-??-??")).each do |dir|
        next unless File.directory?(dir)
        next unless File.basename(dir) < cutoff

        FileUtils.rm_rf(dir)
        yield File.basename(dir) if block_given?
      end
    end

    def cleanup_state
      cutoff = Time.now - @retention_days * 86400
      Dir.glob(File.join(@state_dir, "*")).each do |path|
        next unless File.file?(path)
        next unless File.mtime(path) < cutoff

        File.delete(path)
        yield File.basename(path) if block_given?
      end
    end
  end
end
