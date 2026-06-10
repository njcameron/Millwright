# Copy into `lib/adapters/<provider>/update_channel.rb`, fill TODOs,
# register: `Adapters::Registry.register(:update_channel, :discord, ...)`.
# Set `update_channel: discord` in config.yml.

require_relative "../update_channel"

module Adapters
  module Example
    class UpdateChannel < Adapters::UpdateChannel
      def initialize(config)
        @config = config
        @prompts = Prompts.new(config)
      end

      def prompts
        @prompts
      end

      # IMPORTANT: All event methods below MUST rescue and log failures
      # internally — a failed notification must NEVER break the orchestrator.

      # TODO for every method below: send the appropriate notification.

      def issue_picked_up(issue_number, title, repo, mode); raise NotImplementedError; end
      def plan_ready(issue_number, title, repo); raise NotImplementedError; end
      def pr_created(issue_number, repo, pr_number); raise NotImplementedError; end
      def pr_comments_found(issue_number, repo, pr_number, count); raise NotImplementedError; end
      def plan_comments_found(issue_number, repo, count); raise NotImplementedError; end
      def pr_comments_addressed(issue_number, repo, pr_number); raise NotImplementedError; end
      def worker_failed(issue_number, repo, error); raise NotImplementedError; end
      def review_queue_full(in_review_count, max_review); raise NotImplementedError; end
      def ci_fix_dispatched(issue_number, repo, pr_number, attempt, max_attempts); raise NotImplementedError; end
      def ci_fix_gave_up(issue_number, repo, pr_number, attempts); raise NotImplementedError; end
      def weekly_digest(content, pr_count); raise NotImplementedError; end
      def security_scan(repo, counts, report = nil, report_path = nil); raise NotImplementedError; end
      def no_slots(active_count, max_workers); raise NotImplementedError; end
    end

    class Prompts
      def initialize(config)
        @config = config
      end

      # TODO: Worker-side CLI command that sends a one-shot status update.
      # Substitutes `<message>` (or the supplied placeholder) with text.
      def send_message(text_placeholder: "<message>")
        raise NotImplementedError
      end
    end
  end
end
