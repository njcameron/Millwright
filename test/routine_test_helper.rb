class StubRoutineEnv
  class StubChannel
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  class StubVcs
    def worker_env = { "GH_TOKEN" => "fake-token" }
  end

  class StubAgent
    def command(prompt_path:) = ["/bin/echo"]
    def env_overrides = {}
    def stdin_mode = :prompt_file
  end

  attr_reader :update_channel, :vcs, :coding_agent, :issue_tracker

  def initialize
    @update_channel = StubChannel.new
    @vcs = StubVcs.new
    @coding_agent = StubAgent.new
    @issue_tracker = StubChannel.new
  end
end
