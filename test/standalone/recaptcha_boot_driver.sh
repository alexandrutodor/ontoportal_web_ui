#!/bin/bash
# ONTO-T-Q04 driver: run inside onto-q02-proof:af254f34 with the repo at /app (read-only) and --network none:
#   docker run --rm --network none -v $(pwd):/app:ro -v $(pwd)/test/standalone/recaptcha_boot_driver.sh:/driver.sh:ro -e GEM_PATH=/usr/local/bundle/ruby/3.1.0 onto-q02-proof:af254f34 bash /driver.sh
# Copies the app to /work so synthetic test credentials can be written; the repository is never modified.
set -u
mkdir -p /work && tar -C /app --exclude=./.git --exclude=./tmp --exclude=./log -cf - . | tar -C /work -xf - && mkdir -p /work/tmp /work/log
cd /work
run() { echo "--- $1"; shift; env "$@" RAILS_ENV=test bundle exec rails runner test/standalone/recaptcha_boot_check.rb 2>&1 | grep -E 'USE_RECAPTCHA=|PASS|FAIL|KeyError' | head -4; }
run 'unset' EXPECT_ENABLED=false
run 'false' USE_RECAPTCHA=false EXPECT_ENABLED=false
echo '--- true, no credentials (boot must fail clearly)'
out=$(USE_RECAPTCHA=true RAILS_ENV=test EXPECT_ENABLED=true bundle exec rails runner 'puts :booted' 2>&1); echo "$out" | grep -o 'KeyError.*\|reCAPTCHA is enabled[^)]*)[^\n]*' | head -2; echo "$out" | grep -q booted && echo 'FAIL booted without credentials' || echo 'PASS boot refused without credentials'
ruby -ractive_support -ractive_support/encrypted_configuration -e '
key = ActiveSupport::EncryptedConfiguration.generate_key
Dir.mkdir("config/credentials") unless Dir.exist?("config/credentials")
File.write("config/credentials/test.key", key)
ActiveSupport::EncryptedConfiguration.new(config_path: "config/credentials/test.yml.enc", key_path: "config/credentials/test.key", env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true).write("recaptcha:\n  site_key: fake-site-key\n  secret_key: fake-secret\n")
puts "synthetic credentials written"'
run 'true with synthetic credentials' USE_RECAPTCHA=true EXPECT_ENABLED=true EXPECT_SITE_KEY=fake-site-key
