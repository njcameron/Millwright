class Orchestrator
  # Moves issues currently marked "In progress" to their next project-board
  # status based on observable side-effects: a "needs review" label means
  # the plan is ready (→ cc-planning), an open PR means implementation is
  # done (→ In review). Also clears any dispatch locks for those issues/PRs
  # so re-dispatch can proceed in the next tick.
  class StatusTransitions
    def initialize(context)
      @ctx = context
    end

    def call
      in_progress = @ctx.issue_tracker.issues_by_status(@ctx.statuses["building"])
      return if in_progress.empty?

      in_progress.each do |issue|
        repo = issue[:repo]
        number = issue[:number]
        next unless repo

        if @ctx.issue_tracker.flag_for_review?(repo, number)
          @ctx.log "Issue ##{number}: plan ready, moving to cc-planning"
          @ctx.issue_tracker.set_status(number, @ctx.statuses["planning"], repo: repo)
          @ctx.dispatch_lock.unlock(number)
          pr = @ctx.vcs.find_pr_for_issue(repo, number)
          @ctx.dispatch_lock.unlock("pr-#{pr[:number]}") if pr
          @ctx.update_channel.plan_ready(number, issue[:title], repo)
          next
        end

        pr = @ctx.vcs.find_pr_for_issue(repo, number)
        next unless pr

        @ctx.log "Issue ##{number}: PR found, moving to In review"
        @ctx.issue_tracker.set_status(number, @ctx.statuses["pr"], repo: repo)
        @ctx.dispatch_lock.unlock(number)
        @ctx.dispatch_lock.unlock("pr-#{pr[:number]}")
      end
    end
  end
end
