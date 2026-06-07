module Adapters
  # Abstract base for the LLM-driven worker process the orchestrator spawns
  # (Claude Code, Codex, Cursor, Aider, ...).
  #
  # Captures HOW to invoke the agent (argv, env, stdin shape) — not WHAT to
  # ask. Prompt bodies stay adapter-neutral English; provider-specific verbs
  # live in the IssueTracker / VersionControl / UpdateChannel prompt fragments.
  class CodingAgent
    # Argv array for Process.spawn, given the path to a prompt file on disk.
    def command(prompt_path:)
      raise NotImplementedError
    end

    # Hash merged into the worker's spawn env (PATH tweaks, vars to clear, ...).
    def env_overrides
      raise NotImplementedError
    end

    # :prompt_file — Process.spawn(..., in: prompt_path)
    # :inline_arg  — prompt passed as final argv element
    def stdin_mode
      raise NotImplementedError
    end
  end
end
