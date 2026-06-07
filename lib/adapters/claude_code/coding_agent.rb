require_relative "../coding_agent"

module Adapters
  module ClaudeCode
    # Coding agent adapter for the `claude` CLI. Resolved via PATH by default;
    # override with `coding_agent.bin` in config.yml if needed.
    # Reads the prompt from stdin via `-p`, runs with permission-mode
    # bypassPermissions, and needs the CLAUDECODE / CLAUDE_CODE_* env
    # vars cleared so the worker doesn't think it's running inside the
    # orchestrator's own Claude session.
    #
    # Adapter-specific settings come from the top-level `coding_agent:` key
    # in config.yml:
    #   coding_agent:
    #     bin: /path/to/claude       # override the binary (optional)
    #     remote_control: true       # true (default) | false | "session-name"
    class CodingAgent < Adapters::CodingAgent
      DEFAULT_BIN = "claude"

      def initialize(config = {})
        agent_cfg = begin
          config["coding_agent"]
        rescue StandardError
          nil
        end
        agent_cfg = {} unless agent_cfg.is_a?(Hash)
        @bin = agent_cfg["bin"] || DEFAULT_BIN
        # Whether to start new worker sessions with Remote Control enabled.
        # Defaults to on ("always include"); set `remote_control: false` to
        # opt out, or a string to name the Remote Control session.
        @remote_control = agent_cfg.fetch("remote_control", true)
      end

      def command(prompt_path:)
        argv = [@bin, "--permission-mode", "bypassPermissions"]
        argv.concat(remote_control_args)
        argv << "-p"
        argv
      end

      def env_overrides
        {
          "CLAUDECODE" => nil,
          "CLAUDE_CODE_ENTRYPOINT" => nil,
          "CLAUDE_CODE_SESSION_ACCESS_TOKEN" => nil
        }
      end

      def stdin_mode
        :prompt_file
      end

      private

      # `--remote-control [name]` argv for #command. `true` → bare flag,
      # a string → named session, anything falsy → omitted.
      def remote_control_args
        case @remote_control
        when nil, false then []
        when true then ["--remote-control"]
        else ["--remote-control", @remote_control.to_s]
        end
      end
    end
  end
end
