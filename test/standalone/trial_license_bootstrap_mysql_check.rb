# frozen_string_literal: true

# ONTO-T-B03: the trial license must be created once per installation even when several app
# processes boot at the same moment. Run with `rails runner` against a disposable MySQL database
# (DB_HOST, RAILS_ENV=test); it deletes trial rows in that database only.
#
# Forks PROCESSES workers that start together and each call the real
# ApplicationController#init_trial_license with a fresh per-process flag, then counts trial rows.

abort 'refusing to run outside RAILS_ENV=test' unless Rails.env.test?

PROCESSES = Integer(ENV.fetch('PROCESSES', '12'))
ROUNDS = Integer(ENV.fetch('ROUNDS', '5'))

results = ROUNDS.times.map do |round|
  License.where(encrypted_key: 'trial').delete_all
  ActiveRecord::Base.connection_handler.clear_all_connections!
  start_at = Time.now.to_f + 1.5

  pids = PROCESSES.times.map do
    fork do
      ActiveRecord::Base.establish_connection
      License.connection.execute('SELECT 1')
      $trial_license_initialized = false
      sleep([start_at - Time.now.to_f, 0].max)
      ApplicationController.new.send(:init_trial_license)
      exit!(0)
    rescue StandardError => e
      warn "worker error: #{e.class}: #{e.message}"
      exit!(1)
    end
  end
  statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

  ActiveRecord::Base.establish_connection
  count = License.where(encrypted_key: 'trial').count
  puts "round #{round + 1}: #{PROCESSES} processes, worker failures #{statuses.count { |s| s != 0 }}, trial rows #{count}"
  [count, statuses]
end

counts = results.map(&:first)
failures = results.sum { |_, s| s.count { |x| x != 0 } }
puts "trial row counts per round: #{counts.inspect}"
if counts.all? { |c| c == 1 } && failures.zero?
  puts 'PASS exactly one trial license per round'
else
  puts 'FAIL duplicate, missing trial license or worker failure'
  exit 1
end
