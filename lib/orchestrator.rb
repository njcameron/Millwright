require "yaml"

class Orchestrator
end

require_relative "orchestrator/context"
require_relative "orchestrator/status_transitions"
require_relative "orchestrator/dispatcher"
require_relative "orchestrator/pr_comment_handler"
require_relative "orchestrator/ci_failure_handler"

class Orchestrator
  def initialize(dry_run: false)
    config = YAML.load_file(File.expand_path("../../config.yml", __FILE__))
    @ctx = Context.new(config: config, dry_run: dry_run)

    @status_transitions = StatusTransitions.new(@ctx)
    @dispatcher = Dispatcher.new(@ctx)
    @pr_comment_handler = PrCommentHandler.new(@ctx)
    @ci_failure_handler = CiFailureHandler.new(@ctx)
  end

  def run
    @ctx.log "Orchestrator run started#{" (DRY RUN)" if @ctx.dry_run}"

    active_count = @ctx.issue_tracker.count_active_workers
    available_slots = @ctx.config["max_workers"] - active_count
    @ctx.log "Active workers: #{active_count}, available slots: #{available_slots}"

    # Always-run checks (regardless of available slots)
    @status_transitions.call
    @pr_comment_handler.call([1, available_slots].max)
    @ci_failure_handler.call([1, available_slots].max)

    if available_slots <= 0
      @ctx.log "No available slots, skipping dispatch"
    else
      dispatch_new_issues(available_slots)
    end

    @ctx.sweeper.cleanup_logs { |dir| @ctx.log "Deleted old log directory: #{dir}" }
    @ctx.sweeper.cleanup_state { |name| @ctx.log "Deleted stale state file: #{name}" }
    @ctx.log "Orchestrator run finished"
  end

  private

  def dispatch_new_issues(available_slots)
    max_review = @ctx.config["max_in_review"] || 5
    in_review_count = @ctx.issue_tracker.issues_by_status(@ctx.statuses["pr"]).size

    if in_review_count >= max_review
      @ctx.log "Review queue full: #{in_review_count}/#{max_review} PRs in review, skipping new issues"
      @ctx.cooldown.notify(:review_queue_full) do
        @ctx.update_channel.review_queue_full(in_review_count, max_review)
      end
      return
    end

    @ctx.cooldown.reset(:review_queue_full)

    ready_issues = @ctx.issue_tracker.issues_by_status(@ctx.statuses["ready"])
    approved_issues = @ctx.issue_tracker.issues_by_status(@ctx.statuses["planning_approved"])
    dispatchable = approved_issues + ready_issues

    if dispatchable.empty?
      @ctx.log "No dispatchable issues found"
      return
    end

    @ctx.log "Found #{ready_issues.size} ready, #{approved_issues.size} planning-approved issue(s)"
    dispatchable.first(available_slots).each { |issue| @dispatcher.dispatch(issue) }
  end
end

# Run when invoked directly
if __FILE__ == $PROGRAM_NAME
  dry_run = ARGV.include?("--dry-run")
  Orchestrator.new(dry_run: dry_run).run
end
