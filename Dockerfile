# Keep in line with mise.toml and the CI ruby-version (Ruby 3.1 series)
ARG RUBY_VERSION=3.1
FROM ruby:${RUBY_VERSION}-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
     build-essential libxml2 libxslt-dev libmariadb-dev libyaml-dev \
     git curl libffi-dev pkg-config \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /etc/apt/keyrings/nodesource.asc \
  && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_20.x nodistro main' | tee /etc/apt/sources.list.d/nodesource.list \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && corepack enable \
  && apt-get clean && rm -rf /var/lib/apt/lists/* /usr/share/{doc,man}

ENV RAILS_LOG_TO_STDOUT="1" \
    RAILS_SERVE_STATIC_FILES="true" \
    RAILS_ENV="production" \
    NODE_ENV="production" \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development test"

COPY Gemfile* .
# Bundler version from Gemfile.lock (BUNDLED WITH); frozen installs fail instead of rewriting the lockfile
RUN gem install bundler -v 2.6.3
RUN bundle config set frozen true && bundle install

COPY package.json *yarn* ./
RUN mkdir /node_modules
RUN yarn install --frozen-lockfile

COPY . .

RUN cp config/bioportal_config_env.rb.sample config/bioportal_config_production.rb \
 && cp config/bioportal_config_env.rb.sample config/bioportal_config_development.rb \
 && cp config/bioportal_config_env.rb.sample config/bioportal_config_test.rb \
 && cp config/database.yml.sample config/database.yml

RUN if [ "${RAILS_ENV}" != "development" ]; then \
  bundle exec bootsnap precompile --gemfile app/ lib/ && \
  SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
  rm -f tmp/development_secret.txt; fi

EXPOSE 3000

CMD ["rails", "s"]
