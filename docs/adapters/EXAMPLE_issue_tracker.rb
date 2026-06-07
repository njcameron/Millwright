# Copy this file into `lib/adapters/<your_provider>/issue_tracker.rb`,
# rename the module, fill in the TODOs, then register it in
# `lib/adapters/registry.rb`.
#
#   Adapters::Registry.register(:issue_tracker, :linear, Adapters::Linear::IssueTracker)
#
# Then under `adapters:` in `config.yml`, set:
#   issue_tracker: linear
#
# Run `bundle exec rake` — the IssueTrackerContract test module exercises
# the return-value shape of every method automatically.

require_relative "../issue_tracker"

module Adapters
  module Example
    class IssueTracker < Adapters::IssueTracker
      def initialize(config)
        # TODO: stash whatever credentials / project IDs you need from `config`.
        @config = config
        @prompts = Prompts.new
      end

      def prompts
        @prompts
      end

      # TODO: Return an Array of Hashes with these keys:
      #   { number:, repo:, title:, status:, type: }
      # `status` must be the human-readable string matching what the orchestrator
      # asks for (e.g. "Ready", "In progress" — see `config.yml#statuses`).
      # `type` is "ISSUE" for issues; tasks/PRs should be excluded.
      def issues_by_status(status)
        raise NotImplementedError
      end

      # TODO: Integer count of issues currently in any "actively-being-worked-on"
      # state (planning + building). Used to gate dispatcher slots.
      def count_active_workers
        raise NotImplementedError
      end

      # TODO: Move `issue_number` (in `repo:`) to `status`. MUST be idempotent —
      # calling with the issue already in `status` must be a no-op, not an error.
      def set_status(issue_number, status, repo:)
        raise NotImplementedError
      end

      # TODO: Return the issue body as a string. Used by the dispatcher to
      # scan for attachment URLs.
      def fetch_issue_body(issue_number, repo:)
        raise NotImplementedError
      end

      # TODO: True if the issue is currently flagged for human review.
      # GitHub uses a "needs review" label; Linear could use a state.
      def flag_for_review?(repo, issue_number)
        raise NotImplementedError
      end

      # TODO: Mark the issue as flagged for review. Idempotent. Only called
      # via the worker prompt fragment; orchestrator Ruby code doesn't call
      # it directly today — raise NotImplementedError if you don't need it.
      def mark_flagged_for_review(repo, issue_number)
        raise NotImplementedError
      end
    end

    # Prompt fragments — single-line CLI snippets the worker substitutes
    # into its prompt. Keep them adapter-neutral on inputs (issue_number,
    # repo) and provider-specific on output verbs.
    class Prompts
      # TODO: Worker-side command that flags the plan for review.
      # GitHub: `gh issue edit ## -R repo --add-label "needs review"`
      def mark_plan_ready(issue_number:, repo:)
        raise NotImplementedError
      end

      # TODO: Worker-side command that acknowledges plan approval.
      def acknowledge_approval(issue_number:, repo:)
        raise NotImplementedError
      end
    end
  end
end
