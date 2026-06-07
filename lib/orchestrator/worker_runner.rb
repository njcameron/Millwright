require "fileutils"
require "time"

class Orchestrator
  # Spawns detached coding-agent worker processes. Provider-specific
  # bits — argv, env tweaks, stdin shape — come from a CodingAgent
  # adapter; auth + git identity come from the VCS adapter. This
  # class only knows how to write the prompt to disk and call
  # Process.spawn with the composed env and argv.
  class WorkerRunner
    def initialize(config:, vcs:, coding_agent:, logs_dir:, update_channel: nil)
      @config = config
      @vcs = vcs
      @coding_agent = coding_agent
      @update_channel = update_channel
      @logs_dir = logs_dir
    end

    def spawn_worker(prompt:, chdir:, log_file:)
      prompt_path = "#{log_file}.prompt"
      File.write(prompt_path, prompt)

      argv = @coding_agent.command(prompt_path: prompt_path)
      env = @vcs.worker_env.merge(@coding_agent.env_overrides)
      env = env.merge(@update_channel.worker_env) if @update_channel

      spawn_opts = { chdir: chdir, out: log_file, err: log_file }
      case @coding_agent.stdin_mode
      when :prompt_file
        spawn_opts[:in] = prompt_path
      when :inline_arg
        argv = argv + [File.read(prompt_path)]
      end

      pid = Process.spawn(env, *argv, **spawn_opts)
      Process.detach(pid)
      pid
    end

    def daily_log_path(filename)
      dir = File.join(@logs_dir, Time.now.utc.strftime("%Y-%m-%d"))
      FileUtils.mkdir_p(dir)
      File.join(dir, filename)
    end
  end
end
