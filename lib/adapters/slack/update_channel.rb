require "net/http"
require "uri"
require "json"
require_relative "../update_channel"
require_relative "prompts"

module Adapters
  module Slack
    # Concrete UpdateChannel that posts to a Slack incoming webhook.
    # Bodies ported verbatim from the legacy lib/notifier.rb.
    class UpdateChannel < Adapters::UpdateChannel
      def initialize(config)
        @webhook_url = ENV["SLACK_WEBHOOK"] || config["slack_webhook"]
        @prompts = Adapters::Slack::Prompts.new
      end

      def prompts
        @prompts
      end

      # Hands the webhook to the worker via $SLACK_WEBHOOK so the
      # send_message prompt fragment can reference it without the secret
      # being written into the on-disk prompt file. Empty when no webhook
      # is configured (notifications simply disabled).
      def worker_env
        @webhook_url.to_s.empty? ? {} : { "SLACK_WEBHOOK" => @webhook_url }
      end

      def issue_picked_up(issue_number, title, repo, mode)
        post(
          text: "🚀 *Picked up issue* <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>: #{title}",
          fields: { "Repo" => repo, "Mode" => mode }
        )
      end

      def plan_ready(issue_number, title, repo)
        post(
          text: "📋 *Plan ready for review* <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>: #{title}",
          fields: { "Repo" => repo }
        )
      end

      def pr_created(issue_number, repo, pr_number)
        post(
          text: "🔀 *PR ready for review* <https://github.com/#{repo}/pull/#{pr_number}|##{pr_number}> for issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>",
          fields: { "Repo" => repo }
        )
      end

      def pr_comments_found(issue_number, repo, pr_number, count)
        post(
          text: "💬 *Found #{count} unaddressed comment#{"s" if count != 1}* on <https://github.com/#{repo}/pull/#{pr_number}|PR ##{pr_number}> (issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>)",
          fields: { "Repo" => repo }
        )
      end

      def plan_comments_found(issue_number, repo, count)
        post(
          text: "💬 *Revising plan* — #{count} new comment#{"s" if count != 1} on <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}> in cc-planning",
          fields: { "Repo" => repo }
        )
      end

      def pr_comments_addressed(issue_number, repo, pr_number)
        post(
          text: "✅ *Finished responding to comments* on <https://github.com/#{repo}/pull/#{pr_number}|PR ##{pr_number}> (issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>)",
          fields: { "Repo" => repo }
        )
      end

      def worker_failed(issue_number, repo, error)
        post(
          text: "🔴 *Worker failed* for issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>",
          fields: { "Repo" => repo, "Error" => error.to_s[0..200] }
        )
      end

      def review_queue_full(in_review_count, max_review)
        post(
          text: "📥 *Review queue full* — #{in_review_count}/#{max_review} PRs waiting for review, not picking up new issues"
        )
      end

      def ci_fix_dispatched(issue_number, repo, pr_number, attempt, max_attempts)
        post(
          text: "🔴 *CI failed* on <https://github.com/#{repo}/pull/#{pr_number}|PR ##{pr_number}> (issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>) — dispatching fix (attempt #{attempt}/#{max_attempts})",
          fields: { "Repo" => repo }
        )
      end

      def ci_fix_gave_up(issue_number, repo, pr_number, attempts)
        post(
          text: "⚠️ *CI still failing* on <https://github.com/#{repo}/pull/#{pr_number}|PR ##{pr_number}> (issue <https://github.com/#{repo}/issues/#{issue_number}|##{issue_number}>) after #{attempts} auto-fix attempts — needs human attention",
          fields: { "Repo" => repo }
        )
      end

      def doctor_detected(signals)
        lines = signals.map { |s| "• *#{s[:kind]}* (#{s[:target]}) — #{s[:detail]}" }
        post(
          text: "🩺 *Doctor: detected #{signals.size} issue#{"s" if signals.size != 1}* — investigating\n#{lines.join("\n")}"
        )
      end

      def doctor_gave_up(target, attempts)
        post(
          text: "🩺 *Doctor gave up on `#{target}`* after #{attempts} auto-remediation attempt#{"s" if attempts != 1} — needs human attention"
        )
      end

      def doctor_recovered(target)
        post(
          text: "🩺 *Doctor: `#{target}` recovered* — back to healthy"
        )
      end

      def weekly_digest(content, pr_count)
        header = "📰 *Weekly Digest* — #{pr_count} PR#{"s" if pr_count != 1} shipped this week"
        full_text = "#{header}\n\n#{content}"

        chunks = split_for_slack(content, 2800)
        blocks = [{ type: "section", text: { type: "mrkdwn", text: header } }]
        chunks.each do |chunk|
          blocks << { type: "section", text: { type: "mrkdwn", text: chunk } }
        end
        blocks << { type: "divider" }

        send_blocks(blocks, full_text)
      rescue => e
        $stderr.puts "[Slack::UpdateChannel] Failed to send weekly digest: #{e.message}"
      end

      def security_scan(repo, counts, report = nil, report_path = nil)
        total = counts[:critical] + counts[:high] + counts[:medium] + counts[:low]
        header = "🔒 *Weekly Security Scan* — #{repo}"
        summary = "CRITICAL: #{counts[:critical]} | HIGH: #{counts[:high]} " \
                  "| MEDIUM: #{counts[:medium]} | LOW: #{counts[:low]}"

        if report
          slack_report = markdown_to_slack(report)
          full_text = "#{header}\n\n#{slack_report}"
          chunks = split_for_slack(slack_report, 2800)
          blocks = [{ type: "section", text: { type: "mrkdwn", text: header } }]
          blocks << { type: "section", text: { type: "mrkdwn", text: summary } }
          chunks.each do |chunk|
            blocks << { type: "section", text: { type: "mrkdwn", text: chunk } }
          end
          if report_path && File.exist?(report_path)
            blocks << { type: "section", text: { type: "mrkdwn",
                                                  text: "📎 Full report saved to `#{report_path}`" } }
          end
          blocks << { type: "divider" }

          send_blocks(blocks, full_text)
        else
          if total.zero?
            body = "#{header}\n✅ No security issues found."
          else
            body = "#{header}\n#{summary}"
          end
          post(text: body)
        end
      rescue => e
        $stderr.puts "[Slack::UpdateChannel] Failed to send security scan: #{e.message}"
      end

      def no_slots(active_count, max_workers)
        post(
          text: "⏸️ *No available slots* — #{active_count}/#{max_workers} workers active"
        )
      end

      # Operational error (missing checkout, failed gh call, ...). `post`
      # already swallows send failures, so this never raises.
      def error(message, detail: nil, fields: {})
        all_fields = fields.dup
        unless detail.to_s.empty?
          all_fields["Detail"] = "`#{detail.to_s[0..400]}`"
        end
        post(text: "⚠️ *Millwright error* — #{message}", fields: all_fields)
      end

      # Posts a single innocuous message and returns the Net::HTTPResponse.
      # Unlike the event methods above, this deliberately does NOT swallow
      # errors — `bin/doctor` needs to see the real outcome (2xx vs failure /
      # exception) to verify the webhook actually works during setup.
      def test_post(text = "✅ Millwright setup check — your Slack webhook is working.")
        blocks = [
          { type: "section", text: { type: "mrkdwn", text: text } },
          { type: "divider" }
        ]
        send_blocks(blocks, text)
      end

      private

      def post(text:, fields: {})
        blocks = [
          { type: "section", text: { type: "mrkdwn", text: text } }
        ]

        if fields.any?
          field_blocks = fields.map do |label, value|
            { type: "mrkdwn", text: "*#{label}:* #{value}" }
          end
          blocks << { type: "section", fields: field_blocks }
        end

        blocks << { type: "divider" }
        send_blocks(blocks, text)
      rescue => e
        $stderr.puts "[Slack::UpdateChannel] Failed to send: #{e.message}"
      end

      def send_blocks(blocks, fallback_text)
        payload = { blocks: blocks, text: fallback_text }
        uri = URI(@webhook_url)
        req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
        req.body = JSON.generate(payload)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        http.request(req)
      end

      def markdown_to_slack(text)
        text
          .gsub(/^###\s+(.+)/, '*\1*')
          .gsub(/^##\s+(.+)/, '*\1*')
          .gsub(/^#\s+(.+)/, '*\1*')
          .gsub(/\*\*(.+?)\*\*/, '*\1*')
          .gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
          .gsub(/<details>.*?<\/details>/m, "")
          .gsub(/---/, "─" * 20)
          # Collapse runs of 3+ blank lines (left behind by stripping details
          # blocks) down to a single blank line — but DO preserve `\n\n`
          # paragraph breaks so split_for_slack can chunk on them. The
          # original code used `squeeze("\n")` here which collapsed every
          # `\n\n` to `\n`, leaving split_for_slack with one giant paragraph
          # and producing a single >3000-char Slack block (which Slack rejects
          # with `400 invalid_blocks`).
          .gsub(/\n{3,}/, "\n\n")
      end

      # Chunk text into pieces no larger than max_length, preferring to break
      # on paragraph (\n\n) boundaries. If a single paragraph is already over
      # max_length (e.g. a long finding description), hard-split it on the
      # nearest line break under the limit so no chunk ever exceeds it.
      def split_for_slack(text, max_length)
        chunks = []
        current = ""
        text.split("\n\n").each do |paragraph|
          # A single paragraph longer than the cap must be hard-split first.
          sub_paragraphs = paragraph.length <= max_length ? [paragraph] : hard_split(paragraph, max_length)
          sub_paragraphs.each do |p|
            if current.empty?
              current = p
            elsif (current.length + 2 + p.length) <= max_length
              current += "\n\n#{p}"
            else
              chunks << current
              current = p
            end
          end
        end
        chunks << current unless current.empty?
        chunks
      end

      def hard_split(text, max_length)
        out = []
        remaining = text
        while remaining.length > max_length
          # Prefer to break on the last newline under the limit; otherwise
          # the last space; otherwise a hard byte split.
          window = remaining[0, max_length]
          cut = window.rindex("\n") || window.rindex(" ") || max_length
          out << remaining[0, cut]
          remaining = remaining[cut..].to_s.sub(/\A[\s]+/, "")
        end
        out << remaining unless remaining.empty?
        out
      end
    end
  end
end
