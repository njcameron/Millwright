# Copy into `lib/adapters/<provider>/coding_agent.rb`, fill TODOs,
# register: `Adapters::Registry.register(:coding_agent, :codex, ...)`.
# Set `coding_agent: codex` in config.yml.
#
# Coding-agent adapters capture HOW to invoke the worker, not WHAT to ask —
# the prompt body stays adapter-neutral. So this adapter is small: argv,
# env tweaks, stdin shape. No #prompts accessor.

require_relative "../coding_agent"

module Adapters
  module Example
    class CodingAgent < Adapters::CodingAgent
      def initialize(config = {})
        @config = config
      end

      # TODO: Return the argv Process.spawn will run. The prompt file path
      # is provided in case your agent reads it as an argument (some do);
      # if your agent reads the prompt from stdin (Claude Code does), the
      # path is unused here and the runtime pipes the prompt in via stdin.
      def command(prompt_path:)
        raise NotImplementedError
      end

      # TODO: Hash merged into the worker's spawn env. Common uses:
      #   - PATH tweaks for nvm/asdf/etc.
      #   - Nil-out env vars that would confuse the agent if it thinks
      #     it's running inside the orchestrator's own session.
      def env_overrides
        raise NotImplementedError
      end

      # TODO: One of:
      #   :prompt_file  — Process.spawn receives the prompt file on stdin
      #   :inline_arg   — the prompt body is appended as the final argv element
      #   :stdin_data   — Open3.capture2 stdin_data: prompt (synchronous routines)
      def stdin_mode
        raise NotImplementedError
      end
    end
  end
end
