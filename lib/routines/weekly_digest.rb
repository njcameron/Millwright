require "yaml"
require "json"
require "open3"
require "fileutils"
require "time"
require_relative "../routine_env"

class WeeklyDigest
  def initialize
    @config = YAML.load_file(File.expand_path("../../../config.yml", __FILE__))
    @env = RoutineEnv.new(@config)
    @repo = @config.dig("routines", "weekly_digest", "repo") or
      raise "routines.weekly_digest.repo must be set in config.yml"
  end

  def run
    log "Weekly digest started"
    merged_prs = fetch_merged_prs
    if merged_prs.empty?
      log "No PRs merged in the last 7 days, skipping digest"
      return
    end
    log "Found #{merged_prs.size} merged PR(s)"

    enriched = merged_prs.map { |pr| enrich_pr(pr) }
    prompt = build_prompt(enriched)
    digest = run_claude(prompt)

    save_digest(digest)
    post_to_slack(digest, enriched)
    log "Weekly digest complete"
  end

  private

  def fetch_merged_prs
    since = (Time.now.utc - 7 * 86400).strftime("%Y-%m-%d")
    output, status = Open3.capture2(
      gh_env,
      "gh", "pr", "list", "-R", @repo,
      "--state", "merged",
      "--json", "number,title,headRefName,mergedAt,body,url",
      "--search", "merged:>=#{since}"
    )
    return [] unless status.success?
    prs = JSON.parse(output)
    cutoff = Time.now.utc - 7 * 86400
    prs.select { |pr| Time.parse(pr["mergedAt"]) >= cutoff }
      .map do |pr|
        {
          number: pr["number"],
          title: pr["title"],
          branch: pr["headRefName"],
          merged_at: pr["mergedAt"],
          body: pr["body"],
          url: pr["url"],
          issue_number: extract_issue_number(pr["headRefName"])
        }
      end
  end

  def extract_issue_number(branch_name)
    match = branch_name&.match(/\A(\d+)-/)
    match ? match[1].to_i : nil
  end

  def enrich_pr(pr)
    issue_number = pr[:issue_number]
    return pr.merge(issue_title: nil, issue_body: nil, issue_comments: []) unless issue_number

    body_output, body_status = Open3.capture2(
      gh_env,
      "gh", "issue", "view", issue_number.to_s, "-R", @repo,
      "--json", "body,title"
    )
    issue_data = if body_status.success?
      JSON.parse(body_output)
    else
      {}
    end

    comments_output, comments_status = Open3.capture2(
      gh_env,
      "gh", "issue", "view", issue_number.to_s, "-R", @repo,
      "--json", "comments",
      "--jq", "[.comments[] | {author: .author.login, body: .body}]"
    )
    comments = if comments_status.success? && !comments_output.strip.empty?
      JSON.parse(comments_output)
    else
      []
    end

    pr.merge(
      issue_title: issue_data["title"],
      issue_body: issue_data["body"],
      issue_comments: comments
    )
  rescue => e
    log "Warning: failed to enrich PR ##{pr[:number]}: #{e.message}"
    pr.merge(issue_title: nil, issue_body: nil, issue_comments: [])
  end

  def build_prompt(enriched_prs)
    pr_sections = enriched_prs.map { |pr| format_pr_section(pr) }.join("\n\n---\n\n")

    <<~PROMPT
      You are a product communications specialist. Below is data about all pull requests
      merged into the #{@repo} repository in the past week, along with the original issue
      briefs and planning comments for each.

      Write a polished weekly product update suitable for posting on LinkedIn or sending
      in a customer-facing email. The update should:

      - Focus on PRODUCT impact and user value, not technical implementation details
      - Give each distinct feature or improvement its own entry with a bold heading
      - Group closely related PRs into a single entry, but don't over-consolidate — each
        user-visible change should be called out separately
      - Minor fixes and internal changes can be grouped into a single "Bug fixes & polish" entry
      - Use clear, professional language accessible to non-technical readers
      - Include a brief intro and sign-off
      - Use markdown formatting

      Do NOT include PR numbers, issue numbers, branch names, or other internal references.
      Do NOT mention Claude, AI, bots, or automation.
      Write as if a product team member is sharing the update.

      Output ONLY the weekly update text, nothing else.

      ---

      MERGED PULL REQUESTS (last 7 days):

      #{pr_sections}
    PROMPT
  end

  def format_pr_section(pr)
    parts = []
    parts << "## PR ##{pr[:number]}: #{pr[:title]}"
    parts << "Branch: #{pr[:branch]}"
    parts << "Merged: #{pr[:merged_at]}"
    parts << "PR Description:\n#{pr[:body]}" if pr[:body] && !pr[:body].strip.empty?

    if pr[:issue_number]
      parts << "\nLinked Issue ##{pr[:issue_number]}: #{pr[:issue_title]}"
      parts << "Issue Brief:\n#{pr[:issue_body]}" if pr[:issue_body] && !pr[:issue_body].strip.empty?

      if pr[:issue_comments]&.any?
        parts << "\nIssue Comments (contains plan and discussion):"
        pr[:issue_comments].each do |c|
          parts << "[#{c["author"]}]: #{c["body"]}"
        end
      end
    end

    parts.join("\n")
  end

  def run_claude(prompt)
    log "Running Claude to generate digest..."
    argv = @env.coding_agent.command(prompt_path: nil)
    output, status = Open3.capture2(
      claude_env,
      *argv,
      stdin_data: prompt
    )
    unless status.success?
      raise "Claude exited with status #{status.exitstatus}: #{output[0..500]}"
    end
    output.strip
  end

  def save_digest(digest)
    dir = File.expand_path("../../logs/weekly", __FILE__)
    FileUtils.mkdir_p(dir)
    date = Time.now.utc.strftime("%Y-%m-%d")
    path = File.join(dir, "#{date}.md")
    File.write(path, digest)
    log "Saved digest to #{path}"
  end

  def post_to_slack(digest, enriched_prs)
    slack_digest = markdown_to_slack(digest)
    @env.update_channel.weekly_digest(slack_digest, enriched_prs.size)
    log "Posted digest to Slack"
  end

  def markdown_to_slack(text)
    text
      .gsub(/^###\s+(.+)/, '*\1*')       # ### heading → *bold*
      .gsub(/^##\s+(.+)/, '*\1*')        # ## heading → *bold*
      .gsub(/^#\s+(.+)/, '*\1*')         # # heading → *bold*
      .gsub(/\*\*(.+?)\*\*/, '*\1*')     # **bold** → *bold*
      .gsub(/\[([^\]]+)\]\([^)]+\)/, '\1') # [text](url) → text
  end

  def gh_env
    @env.vcs.worker_env
  end

  def claude_env
    @env.vcs.worker_env.merge(@env.coding_agent.env_overrides)
  end

  def log(message)
    puts "[#{Time.now.utc.iso8601}] #{message}"
  end
end

if __FILE__ == $PROGRAM_NAME
  WeeklyDigest.new.run
end
