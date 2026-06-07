require_relative "adapters/registry"

# Bundle of adapters for standalone scheduled scripts (security_scan,
# weekly_digest, ...). Routines don't need the dispatch_lock / cooldown
# / worker_runner infrastructure that Orchestrator::Context owns — they
# just need a typed handle to the adapter trio + coding agent so they
# stop instantiating provider classes directly.
class RoutineEnv
  attr_reader :config, :issue_tracker, :vcs, :update_channel, :coding_agent

  def initialize(config)
    @config = config
    adapters = config["adapters"] || {}

    @issue_tracker = Adapters::Registry.build(
      :issue_tracker, (adapters["issue_tracker"] || "github_projects").to_sym, config
    )
    @vcs = Adapters::Registry.build(
      :version_control, (adapters["version_control"] || "github").to_sym, config
    )
    @update_channel = Adapters::Registry.build(
      :update_channel, (adapters["update_channel"] || "slack").to_sym, config
    )
    @coding_agent = Adapters::Registry.build(
      :coding_agent, (adapters["coding_agent"] || "claude_code").to_sym, config
    )
  end
end
