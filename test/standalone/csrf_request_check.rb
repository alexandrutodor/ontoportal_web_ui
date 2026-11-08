# frozen_string_literal: true

# ONTO-T-B02: CSRF handling through the real middleware stack and controller callbacks.
# Boots the application (RAILS_ENV=test, no network, no DB use) with forgery protection enabled as
# in production, then drives the consent-cookie form: a same-session form token is accepted, while
# a missing, wrong or foreign-session token leaves the permanent cookie unwritten
# (ApplicationController uses protect_from_forgery's :null_session strategy).

ENV['RAILS_ENV'] = 'test'
require_relative '../../config/application'
# Sessions use CacheStore; the test environment points Rails.cache at a local memcached that is not
# running here, so give the harness a process-local cache before Rails builds it.
Rails.application.class.initializer('csrf_check.memory_cache', before: :initialize_cache) do
  Rails.application.config.cache_store = :memory_store
end
Rails.application.initialize!
abort 'refusing to run outside RAILS_ENV=test' unless Rails.env.test?
ActionController::Base.allow_forgery_protection = true # config/environments/test.rb disables it
ApplicationController # load the class first: its body resets the trial flag
$trial_license_initialized = true # no trial bootstrap DB write during these requests

$failures = []
def check(ok, message)
  puts "#{ok ? 'PASS' : 'FAIL'} #{message}"
  $failures << message unless ok
end

def session_for
  s = ActionDispatch::Integration::Session.new(Rails.application)
  s.host! 'localhost'
  s
end

def form_token(s)
  s.get '/cookies'
  s.response.body[/name="authenticity_token" value="([^"]+)"/, 1]
end

def consent_written?(s)
  s.response.headers['Set-Cookie'].to_s.include?('cookies_accepted=')
end

check ActionController::Base.allow_forgery_protection, 'forgery protection enabled for the run'
check ApplicationController.forgery_protection_strategy == ActionController::RequestForgeryProtection::ProtectionMethods::NullSession,
      'ApplicationController uses the :null_session strategy'

a = session_for
token = form_token(a)
check a.response.status == 200 && token.present?, 'GET /cookies renders the consent form with a form token'
a.post '/cookies', params: { cookies: 'true', authenticity_token: token }
check a.response.status == 200 && consent_written?(a), 'POST /cookies with the same-session form token writes the consent cookie'

b = session_for
form_token(b)
b.post '/cookies', params: { cookies: 'true' }
check !consent_written?(b), 'POST /cookies without a token does not write the cookie'

c = session_for
form_token(c)
c.post '/cookies', params: { cookies: 'true', authenticity_token: 'not-a-valid-token' }
check !consent_written?(c), 'POST /cookies with a wrong token does not write the cookie'

d = session_for
form_token(d)
d.post '/cookies', params: { cookies: 'true', authenticity_token: token } # token from session a
check !consent_written?(d), "POST /cookies with another session's token does not write the cookie"

e = session_for
e.get '/cookies', params: { cookies: 'true' }
check !consent_written?(e), 'GET /cookies with cookies=true does not write the cookie'

if $failures.empty?
  puts 'PASS csrf request check'
else
  exit 1
end
