#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'time'

# Brakeman CI Summary and Gate Helper
# Evaluates Brakeman SARIF output and scanner status in CI pipelines.
# Distinguishes scanner execution errors, missing reports, malformed reports,
# and security findings. Preserves non-blocking findings as baseline.

sarif_path = 'output.sarif.json'
scanner_status = 0
diagnostics_path = 'brakeman-diagnostics.json'
policy = 'nonblocking'

OptionParser.new do |opts|
  opts.banner = 'Usage: bin/brakeman_ci_summary.rb [options]'

  opts.on('--sarif PATH', 'Path to SARIF report file') { |v| sarif_path = v }
  opts.on('--scanner-status CODE', Integer, 'Exit code from brakeman scanner process') { |v| scanner_status = v }
  opts.on('--diagnostics-out PATH', 'Path to write diagnostics JSON') { |v| diagnostics_path = v }
  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit 0
  end
end.parse!

# Allow positional argument as fallback for sarif path
sarif_path = ARGV[0] if ARGV[0] && !ARGV[0].empty?

diagnostics = {
  'timestamp' => Time.now.utc.iso8601,
  'sarif_file' => sarif_path,
  'scanner_exit_code' => scanner_status,
  'policy' => policy,
  'gate_status' => 'unknown',
  'findings_count' => 0,
  'severity_counts' => {},
  'rule_counts' => {},
  'errors' => []
}

def write_diagnostics_and_exit(path, diagnostics, exit_code)
  File.write(path, JSON.pretty_generate(diagnostics))
  if (step_summary = ENV['GITHUB_STEP_SUMMARY']) && !step_summary.empty?
    begin
      File.open(step_summary, 'a') do |f|
        f.puts "## Brakeman Scan Status: #{diagnostics['gate_status']&.upcase}"
        f.puts "- **Scanner Exit Code:** #{diagnostics['scanner_exit_code']}"
        f.puts "- **Findings Count:** #{diagnostics['findings_count']}"
        f.puts "- **Policy:** #{diagnostics['policy']}"
        if (errs = diagnostics['errors']) && !errs.empty?
          f.puts "\n### Errors"
          errs.each { |err| f.puts "- #{err}" }
        end
      end
    rescue StandardError => e
      warn "Failed to write GITHUB_STEP_SUMMARY: #{e.message}"
    end
  end

  if (github_out = ENV['GITHUB_OUTPUT']) && !github_out.empty?
    begin
      File.open(github_out, 'a') do |f|
        f.puts "gate_status=#{diagnostics['gate_status']}"
        f.puts "findings_count=#{diagnostics['findings_count']}"
      end
    rescue StandardError => e
      warn "Failed to write GITHUB_OUTPUT: #{e.message}"
    end
  end

  exit exit_code
end

# Check 1: Scanner process execution failure
if scanner_status != 0
  error_msg = "Scanner execution failed with exit code #{scanner_status}"
  warn "[Brakeman CI Error] #{error_msg}"
  diagnostics['gate_status'] = 'scanner_failed'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 1)
end

# Check 2: Missing or empty report
unless File.exist?(sarif_path) && File.size?(sarif_path)
  error_msg = "SARIF report file '#{sarif_path}' does not exist or is empty"
  warn "[Brakeman CI Error] Missing SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'missing_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 2)
end

# Check 3: JSON parsing
sarif_data = nil
begin
  sarif_data = JSON.parse(File.read(sarif_path))
rescue JSON::ParserError => e
  error_msg = "SARIF report is not valid JSON: #{e.message}"
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

# Check 4: Root object check
unless sarif_data.is_a?(Hash)
  error_msg = 'Invalid SARIF structure: root must be a JSON object'
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

# Check 5: SARIF version check (must be 2.1.0)
unless sarif_data['version'] == '2.1.0'
  error_msg = "Invalid SARIF structure: expected version '2.1.0', got #{sarif_data['version'].inspect}"
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

# Check 6: SARIF runs array validation
runs = sarif_data['runs']
unless runs.is_a?(Array) && !runs.empty? && runs.first.is_a?(Hash)
  error_msg = "Invalid SARIF structure: 'runs' array is missing or empty"
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

run = runs.first

# Check 7: Tool driver name validation (must be Brakeman)
tool = run['tool']
tool_driver = tool.is_a?(Hash) ? tool['driver'] : nil
tool_name = tool_driver.is_a?(Hash) ? tool_driver['name'] : nil
tool_version = tool_driver.is_a?(Hash) ? tool_driver['version'] : nil

unless tool_name.is_a?(String) && !tool_name.strip.empty? && tool_name == 'Brakeman'
  error_msg = "Invalid SARIF structure: expected tool driver name 'Brakeman', got #{tool_name.inspect}"
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

tool_version = (tool_version.is_a?(String) && !tool_version.strip.empty?) ? tool_version : 'unknown'

# Check 8: Results array and elements validation
results = run['results']
unless results.is_a?(Array)
  error_msg = "Invalid SARIF structure: 'results' must be an array"
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

unless results.all? { |r| r.is_a?(Hash) }
  error_msg = 'Invalid SARIF structure: each result entry must be an object'
  warn "[Brakeman CI Error] Malformed SARIF report: #{error_msg}"
  diagnostics['gate_status'] = 'malformed_report'
  diagnostics['errors'] << error_msg
  write_diagnostics_and_exit(diagnostics_path, diagnostics, 3)
end

# Extract findings and severity breakdown
severity_counts = Hash.new(0)
rule_counts = Hash.new(0)
results.each do |res|
  level = res['level'] || 'warning'
  severity_counts[level] += 1
  rule_id = res['ruleId'] || 'unknown'
  rule_counts[rule_id] += 1
end

diagnostics['findings_count'] = results.size
diagnostics['severity_counts'] = severity_counts
diagnostics['rule_counts'] = rule_counts
diagnostics['tool_name'] = tool_name
diagnostics['tool_version'] = tool_version

puts '=== Brakeman CI Summary ==='
puts "Scanner status: OK (exit code #{scanner_status})"
puts "Report: #{sarif_path} (valid SARIF 2.1.0)"
puts "Tool: #{tool_name} #{tool_version}"
puts "Total findings: #{results.size}"
if severity_counts.any?
  breakdown = severity_counts.map { |k, v| "#{k}: #{v}" }.join(', ')
  puts "Severity breakdown: #{breakdown}"
end
puts "Gate policy: #{policy} baseline"

puts '[Brakeman CI Gate] PASSED: Non-blocking findings baseline accepted.'
diagnostics['gate_status'] = 'passed'
write_diagnostics_and_exit(diagnostics_path, diagnostics, 0)
