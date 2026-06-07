require "yaml"
require "json"
require "open3"
require "fileutils"
require "time"
require_relative "../routine_env"

class SecurityScan
  def initialize
    @config = YAML.load_file(File.expand_path("../../../config.yml", __FILE__))
    @env = RoutineEnv.new(@config)
  end

  def run
    repos = configured_repos
    if repos.empty?
      log "No repos configured under routines.security_scan.repos — nothing to scan."
      return
    end

    log "Security scan started for #{repos.size} repo(s): #{repos.map { |r| r[:name] }.join(", ")}"

    overall_counts = { critical: 0, high: 0, medium: 0, low: 0 }
    repos.each do |r|
      counts = scan_repo(r[:name], r[:dir])
      overall_counts.each_key { |k| overall_counts[k] += counts[k] }
    rescue => e
      log "Scan failed for #{r[:name]}: #{e.message}"
    end

    log "Security scan complete — totals across #{repos.size} repo(s): " \
        "CRITICAL=#{overall_counts[:critical]} HIGH=#{overall_counts[:high]} " \
        "MEDIUM=#{overall_counts[:medium]} LOW=#{overall_counts[:low]}"
  end

  private

  def configured_repos
    raw = @config.dig("routines", "security_scan", "repos") || []
    workspace = @config.dig("routines", "security_scan", "workspace_dir") ||
                File.expand_path("../../..", __dir__)
    raw.map do |entry|
      case entry
      when String
        { name: entry, dir: File.join(workspace, entry.split("/").last) }
      when Hash
        name = entry["name"] || entry[:name]
        dir = entry["dir"] || entry[:dir] || File.join(workspace, name.split("/").last)
        { name: name, dir: dir }
      end
    end.compact
  end

  def scan_repo(repo, repo_dir)
    log "[#{repo}] Scanning..."
    ensure_repo_up_to_date(repo, repo_dir)
    prompt = build_prompt(repo)
    raw_output = run_claude(prompt, repo_dir)
    findings = parse_findings(raw_output)
    counts = severity_counts(findings["findings"] || [])
    report = build_report(repo, findings, raw_output)
    report_path = save_report(repo, report)
    post_to_slack(repo, findings, report, report_path)
    log "[#{repo}] Done — CRITICAL=#{counts[:critical]} HIGH=#{counts[:high]} " \
        "MEDIUM=#{counts[:medium]} LOW=#{counts[:low]}"
    counts
  end

  def ensure_repo_up_to_date(repo, repo_dir)
    if Dir.exist?(repo_dir)
      log "[#{repo}] Updating checkout at #{repo_dir}..."
      _, status = Open3.capture2(
        gh_env,
        "git", "-C", repo_dir, "pull", "--ff-only", "origin", "main"
      )
      log "[#{repo}] Warning: git pull failed, using existing checkout" unless status.success?
    else
      log "[#{repo}] Cloning into #{repo_dir}..."
      _, status = Open3.capture2(
        gh_env,
        "gh", "repo", "clone", repo, repo_dir
      )
      raise "Failed to clone #{repo}" unless status.success?
    end
  end

  def build_prompt(repo)
    <<~PROMPT
      You are a senior application security engineer performing a comprehensive security
      audit of the codebase at the current working directory (repo: #{repo}).

      Many of this owner's repositories already run automated security tooling on every
      PR — static analysis (SAST), dependency/CVE scanning for both server-side and
      client-side packages, and automated dependency-update bots. If this repo has that
      kind of tooling wired up, focus ONLY on vulnerability classes such tools CANNOT
      detect. If it doesn't, still skip the SQL-injection / XSS / known-CVE territory —
      your value-add is the higher-order stuff below.

      OBJECTIVE:
      Identify HIGH-CONFIDENCE security vulnerabilities with real exploitation potential.
      Only flag issues where you are >80% confident of actual exploitability.

      CRITICAL INSTRUCTIONS:
      1. MINIMIZE FALSE POSITIVES: Better to miss theoretical issues than flood the report
         with noise. Each finding should be something a security engineer would confidently
         raise in a review.
      2. DO NOT DUPLICATE: Skip anything a SAST scanner catches (SQL injection, XSS, mass
         assignment, unsafe redirects, etc.) or a dependency/CVE scanner catches (known
         vulnerable package versions).
      3. FOCUS ON IMPACT: Prioritize vulnerabilities leading to unauthorized access, data
         breaches, or system compromise.
      4. SKIP IRRELEVANT CATEGORIES: If a category below clearly doesn't apply to THIS
         codebase (e.g. Rails-specific advice on a TypeScript browser extension), skip it
         silently — don't produce empty-finding entries for it.

      SECURITY CATEGORIES TO EXAMINE:

      1. **IDOR & Broken Access Control** — Find controllers/actions where records are fetched
         by user-supplied ID without scoping to the current user/tenant. Check that all CRUD
         actions enforce authorization. Look for `find(params[:id])` (or equivalent) without
         ownership checks. This is the highest-value category for multi-tenant apps.

      2. **Authorization Gaps** — Missing auth callbacks, unprotected admin routes,
         privilege escalation paths, tenant data leaks between accounts.

      3. **Hardcoded Secrets** — API keys, passwords, tokens in source code, config files,
         initializers, or environment defaults. Check for AWS credentials, Slack webhooks,
         database URLs committed to the repo.

      4. **SSRF** — Unvalidated URLs passed to HTTP clients or AWS SDK calls. Check for user
         input flowing into HTTP-fetch calls (`Net::HTTP`, `open-uri`, Faraday, fetch(), axios)
         or SDK endpoints that could access internal network/metadata endpoints.

      5. **Business Logic Flaws** — Race conditions (especially around credits/billing), state
         machine bypasses, unsafe file uploads, TOCTOU issues, insecure direct object
         manipulation.

      6. **Security Configuration** — Review rate-limiting config, CORS policy, session
         settings, cookie flags, CSP headers, force_ssl/HSTS settings. For browser extensions,
         check manifest permissions, content-script injection scope, host_permissions.

      7. **Authentication Bypass** — Session management flaws, JWT vulnerabilities, password
         reset token weaknesses, authentication logic errors.

      8. **Cryptographic Failures** — Weak algorithms, improper key management, insecure
         randomness, certificate validation bypasses.

      EXCLUSIONS — DO NOT REPORT:
      - SQL injection, XSS, or mass assignment (existing SAST covers these)
      - Known dependency CVEs (existing dependency/CVE scanners cover these)
      - Denial of Service or resource exhaustion
      - Rate limiting concerns
      - Code style or non-security issues
      - Secrets stored on disk via environment variables (that's expected)

      ANALYSIS METHODOLOGY:

      Phase 1 — Repository Context Research:
      - Identify the language, framework, and security libraries in use
      - Look for established secure coding patterns in the codebase
      - Understand the authorization model and tenant isolation approach (if any)

      Phase 2 — Comparative Analysis:
      - Compare code against established security patterns in the codebase
      - Identify deviations from secure practices
      - Look for inconsistent authorization enforcement

      Phase 3 — Vulnerability Assessment:
      - Trace data flow from user inputs to sensitive operations
      - Look for privilege boundaries being crossed unsafely
      - Identify injection points and unsafe deserialization

      REQUIRED OUTPUT FORMAT:

      Output your findings as JSON with this exact schema:

      {
        "findings": [
          {
            "file": "path/to/file.rb",
            "line": 42,
            "severity": "HIGH",
            "category": "idor",
            "description": "Brief description of the vulnerability",
            "exploit_scenario": "How an attacker could exploit this",
            "recommendation": "Specific fix with code example",
            "confidence": 0.85
          }
        ],
        "analysis_summary": {
          "files_reviewed": 0,
          "critical_count": 0,
          "high_count": 0,
          "medium_count": 0,
          "low_count": 0,
          "review_completed": true
        }
      }

      SEVERITY GUIDELINES:
      - CRITICAL: Directly exploitable, leads to full system compromise or mass data breach
      - HIGH: Directly exploitable, leads to unauthorized access or significant data exposure
      - MEDIUM: Requires specific conditions but has significant impact
      - LOW: Defense-in-depth issue with limited direct impact

      CONFIDENCE SCORING:
      - 0.9-1.0: Certain exploit path identified
      - 0.8-0.9: Clear vulnerability pattern with known exploitation methods
      - 0.7-0.8: Suspicious pattern requiring specific conditions
      - Below 0.7: Do not report

      Your final reply must contain ONLY the JSON object and nothing else.
    PROMPT
  end

  def run_claude(prompt, repo_dir)
    log "Running Claude security audit in #{repo_dir}..."
    argv = @env.coding_agent.command(prompt_path: nil)
    output, status = Open3.capture2(
      claude_env,
      *argv,
      stdin_data: prompt,
      chdir: repo_dir
    )
    unless status.success?
      raise "Claude exited with status #{status.exitstatus}: #{output[0..500]}"
    end
    output.strip
  end

  def parse_findings(raw_output)
    json_match = raw_output.match(/\{[\s\S]*\}/)
    return default_findings unless json_match

    parsed = JSON.parse(json_match[0])
    return default_findings unless parsed.is_a?(Hash) && parsed["findings"].is_a?(Array)

    parsed
  rescue JSON::ParserError => e
    log "Warning: failed to parse Claude output as JSON: #{e.message}"
    default_findings
  end

  def default_findings
    {
      "findings" => [],
      "analysis_summary" => {
        "files_reviewed" => 0,
        "critical_count" => 0,
        "high_count" => 0,
        "medium_count" => 0,
        "low_count" => 0,
        "review_completed" => false
      }
    }
  end

  def build_report(repo, findings, raw_output)
    date = Time.now.utc.strftime("%Y-%m-%d")
    summary = findings["analysis_summary"] || {}
    items = findings["findings"] || []

    counts = severity_counts(items)

    lines = []
    lines << "# Weekly Security Scan — #{repo} — #{date}"
    lines << ""
    lines << "## Summary"
    lines << "- Files reviewed: #{summary["files_reviewed"] || "N/A"}"
    lines << "- CRITICAL: #{counts[:critical]} | HIGH: #{counts[:high]} " \
             "| MEDIUM: #{counts[:medium]} | LOW: #{counts[:low]}"
    lines << ""

    if items.empty?
      lines << "No security issues found."
    else
      lines << "## Findings"
      lines << ""
      items.each_with_index do |finding, i|
        lines << "### #{i + 1}. [#{finding["severity"]}] #{finding["category"]&.upcase}"
        lines << "- **File:** #{finding["file"]}:#{finding["line"]}"
        lines << "- **Confidence:** #{finding["confidence"]}"
        lines << "- **Description:** #{finding["description"]}"
        lines << "- **Attack scenario:** #{finding["exploit_scenario"]}"
        lines << "- **Recommendation:** #{finding["recommendation"]}"
        lines << ""
      end
    end

    lines << ""
    lines << "---"
    lines << ""
    lines << "<details><summary>Raw Claude output</summary>"
    lines << ""
    lines << "```json"
    lines << raw_output
    lines << "```"
    lines << "</details>"

    lines.join("\n")
  end

  def save_report(repo, report)
    slug = repo.gsub("/", "_")
    dir = File.expand_path("../../../logs/security/#{slug}", __FILE__)
    FileUtils.mkdir_p(dir)
    date = Time.now.utc.strftime("%Y-%m-%d")
    path = File.join(dir, "#{date}.md")
    File.write(path, report)
    log "Saved report to #{path}"
    path
  end

  def post_to_slack(repo, findings, report, report_path)
    items = findings["findings"] || []
    counts = severity_counts(items)
    @env.update_channel.security_scan(repo, counts, report, report_path)
    log "[#{repo}] Posted report to Slack"
  end

  def severity_counts(items)
    {
      critical: items.count { |f| f["severity"] == "CRITICAL" },
      high: items.count { |f| f["severity"] == "HIGH" },
      medium: items.count { |f| f["severity"] == "MEDIUM" },
      low: items.count { |f| f["severity"] == "LOW" }
    }
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
  SecurityScan.new.run
end
