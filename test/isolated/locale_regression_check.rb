#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone isolated regression check for ONTO-AT-L01 and ONTO-AT-L02:
# Verifies YAML catalog parsing, metadata guidance token interpolation,
# language selector placeholder meaningfulness, French queued-deletion notice,
# and exact scalar-diff boundaries without booting Rails or running external services.

require 'yaml'
require 'open3'

failures = []

def assert(condition, message, failures)
  if condition
    puts "  [PASS] #{message}"
  else
    puts "  [FAIL] #{message}"
    failures << message
  end
end

repo_root = File.expand_path('../..', __dir__)
en_path = File.join(repo_root, 'config/locales/en.yml')
fr_path = File.join(repo_root, 'config/locales/fr.yml')

puts "=== Step 1: Parse YAML locale catalogs with Psych ==="
en_catalog = nil
fr_catalog = nil

begin
  en_catalog = YAML.load_file(en_path)
  assert(en_catalog.is_a?(Hash) && en_catalog.key?('en'), 'config/locales/en.yml parsed successfully', failures)
rescue StandardError => e
  assert(false, "Failed to parse config/locales/en.yml: #{e.message}", failures)
end

begin
  fr_catalog = YAML.load_file(fr_path)
  assert(fr_catalog.is_a?(Hash) && fr_catalog.key?('fr'), 'config/locales/fr.yml parsed successfully', failures)
rescue StandardError => e
  assert(false, "Failed to parse config/locales/fr.yml: #{e.message}", failures)
end

puts "\n=== Step 2: Check ONTO-AT-L01 metadata guidance interpolation ==="
synthetic_params = {
  portal_name: 'TestPortal',
  link: '<a href="https://example.org/guidelines">guidelines</a>'
}

# English metadata guidance
en_metadata_instr = en_catalog&.dig('en', 'submission_inputs', 'edit_metadata_instruction')
assert(!en_metadata_instr.nil?, 'en.submission_inputs.edit_metadata_instruction key exists', failures)

if en_metadata_instr
  begin
    interpolated_en = en_metadata_instr % synthetic_params
    has_portal = interpolated_en.include?('TestPortal')
    has_anchor = interpolated_en.include?('guidelines')
    no_malformed_token = !interpolated_en.include?('%{link)') && !interpolated_en.include?('%{link}')

    assert(has_portal && has_anchor && no_malformed_token,
           'English metadata guidance cleanly interpolates synthetic portal_name and link anchor',
           failures)
  rescue ArgumentError, KeyError => e
    assert(false, "English metadata guidance interpolation raised #{e.class}: #{e.message}", failures)
  end
end

# French metadata guidance (must also interpolate cleanly)
fr_metadata_instr = fr_catalog&.dig('fr', 'submission_inputs', 'edit_metadata_instruction')
assert(!fr_metadata_instr.nil?, 'fr.submission_inputs.edit_metadata_instruction key exists', failures)

if fr_metadata_instr
  begin
    interpolated_fr = fr_metadata_instr % synthetic_params
    has_portal = interpolated_fr.include?('TestPortal')
    has_anchor = interpolated_fr.include?('guidelines')
    no_raw_tokens = !interpolated_fr.include?('%{link}') && !interpolated_fr.include?('%{portal_name}')

    assert(has_portal && has_anchor && no_raw_tokens,
           'French metadata guidance cleanly interpolates synthetic portal_name and link anchor',
           failures)
  rescue ArgumentError, KeyError => e
    assert(false, "French metadata guidance interpolation raised #{e.class}: #{e.message}", failures)
  end
end

puts "\n=== Step 3: Check ONTO-AT-L01 components.select_anguage placeholder ==="
en_select_lang = en_catalog&.dig('en', 'components', 'select_anguage')
assert(!en_select_lang.nil?, 'en.components.select_anguage key exists under existing spelling', failures)
assert(en_select_lang != '/', 'English components.select_anguage is not a bare slash placeholder', failures)
assert(en_select_lang.to_s.strip.length > 3 && en_select_lang.to_s.match?(/select\s+a\s+language/i),
       "English components.select_anguage is a meaningful instruction: #{en_select_lang.inspect}",
       failures)

fr_select_lang = fr_catalog&.dig('fr', 'components', 'select_anguage')
assert(!fr_select_lang.nil?, 'fr.components.select_anguage key exists', failures)
assert(fr_select_lang.to_s.match?(/sélectionnez une langue/i),
       "French components.select_anguage resolves correctly: #{fr_select_lang.inspect}",
       failures)

puts "\n=== Step 4: Check ONTO-AT-L02 submissions_deleted notice ==="
synthetic_submission_ids = '101,102'

en_sub_del = en_catalog&.dig('en', 'ontologies', 'admin', 'submissions', 'submissions_deleted')
assert(!en_sub_del.nil?, 'en.ontologies.admin.submissions.submissions_deleted exists', failures)
if en_sub_del
  interpolated_en_del = en_sub_del % { submission_ids: synthetic_submission_ids }
  assert(interpolated_en_del.include?(synthetic_submission_ids),
         'English deletion notice interpolates submission_ids',
         failures)
  assert(interpolated_en_del.match?(/queued/i),
         'English deletion notice describes queued operation certainty',
         failures)
end

fr_sub_del = fr_catalog&.dig('fr', 'ontologies', 'admin', 'submissions', 'submissions_deleted')
assert(!fr_sub_del.nil?, 'fr.ontologies.admin.submissions.submissions_deleted exists', failures)
if fr_sub_del
  interpolated_fr_del = fr_sub_del % { submission_ids: synthetic_submission_ids }
  assert(interpolated_fr_del.include?(synthetic_submission_ids),
         'French deletion notice interpolates submission_ids',
         failures)
  # Must preserve queued/accepted status qualifier, not assert completed deletion
  has_queue_qualifier = interpolated_fr_del.match?(/file d'attente|attente|accepté/i)
  assert(has_queue_qualifier,
         "French deletion notice retains queued/accepted status qualifier: #{interpolated_fr_del.inspect}",
         failures)
  assert(!interpolated_fr_del.match?(/\A\s*Soumissions\s+\d+.*supprimées\s*\z/i),
         'French deletion notice does not assert unconditional completed deletion',
         failures)
end

puts "\n=== Step 5: Verify exact scalar-diff boundaries against git baseline ==="
# Compare parsed baseline (HEAD or basebf5e3a51) against current working tree
def diff_hashes(base, current, prefix = [])
  diffs = []
  all_keys = (base.keys | current.keys).sort
  all_keys.each do |k|
    p = prefix + [k]
    b_val = base[k]
    c_val = current[k]
    if b_val.is_a?(Hash) && c_val.is_a?(Hash)
      diffs.concat(diff_hashes(b_val, c_val, p))
    elsif b_val != c_val
      diffs << { path: p.join('.'), before: b_val, after: c_val }
    end
  end
  diffs
end

# Find baseline commit (prefer merge-base with main or bf5e3a51, or HEAD if uncommitted)
baseline_ref = ENV['BASELINE_REF'] || 'bf5e3a51'
base_en_raw, = Open3.capture2('git', 'show', "#{baseline_ref}:config/locales/en.yml")
base_fr_raw, = Open3.capture2('git', 'show', "#{baseline_ref}:config/locales/fr.yml")

if base_en_raw.empty? || base_fr_raw.empty?
  puts "  [WARN] Could not retrieve git baseline at #{baseline_ref}, skipping scalar diff boundary check"
else
  base_en = YAML.safe_load(base_en_raw)
  base_fr = YAML.safe_load(base_fr_raw)

  en_diffs = diff_hashes(base_en, en_catalog)
  fr_diffs = diff_hashes(base_fr, fr_catalog)

  expected_en_diff_paths = [
    'en.submission_inputs.edit_metadata_instruction',
    'en.components.select_anguage'
  ].sort

  expected_fr_diff_paths = [
    'fr.ontologies.admin.submissions.submissions_deleted'
  ].sort

  actual_en_diff_paths = en_diffs.map { |d| d[:path] }.sort
  actual_fr_diff_paths = fr_diffs.map { |d| d[:path] }.sort

  assert(actual_en_diff_paths == expected_en_diff_paths,
         "Only expected English scalar keys changed: expected #{expected_en_diff_paths}, got #{actual_en_diff_paths}",
         failures)

  assert(actual_fr_diff_paths == expected_fr_diff_paths,
         "Only expected French scalar keys changed: expected #{expected_fr_diff_paths}, got #{actual_fr_diff_paths}",
         failures)
end

puts "\n=== Summary ==="
if failures.empty?
  puts "All locale regression checks passed successfully."
  exit 0
else
  puts "#{failures.size} check(s) failed:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
