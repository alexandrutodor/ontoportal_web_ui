#!/usr/bin/env bash
set -euo pipefail

run_api="$(cd "$(dirname "$0")/../.." && pwd)/bin/run_api"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/stubs"
export PATH="$tmp_dir/stubs:$PATH"
export API_IMAGE_REPOSITORY= API_IMAGE_TAG= OP_API_KEY= STARTER_ONTOLOGY= OP_API_URL=

cat > "$tmp_dir/stubs/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'clone --depth=1 -b development https://github.com/ontoportal-lirmm/ontoportal_docker.git tmp/ontoportal_docker' ]]
mkdir -p tmp/ontoportal_docker
printf '%s\n' 'IMAGE_TAG=latest' "${HELPER_COMPOSE_LINE:-COMPOSE_API_FILE_PATH=/ontologies_api/development/docker-compose.yml}" > tmp/ontoportal_docker/.env.sample
cat > tmp/ontoportal_docker/run <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
cp .env.sample .env
cp .env "$TEST_CASE_DIR/helper.env"
exit "${HELPER_EXIT_STATUS:-0}"
RUN
chmod +x tmp/ontoportal_docker/run
STUB

cat > "$tmp_dir/stubs/curl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

cat > "$tmp_dir/stubs/docker" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == 'compose ls -a --filter name=ontoportal_docker' ]]
STUB
chmod +x "$tmp_dir/stubs/"{git,curl,docker}

run_case() {
  local name=$1 expected_status=$2 expected_path=$3
  shift 3
  local case_dir="$tmp_dir/$name" status=0
  mkdir -p "$case_dir/bin"
  cp "$run_api" "$case_dir/bin/run_api"
  rm -f "$case_dir/helper.env"
  (
    cd "$case_dir"
    export TEST_CASE_DIR="$case_dir"
    bash bin/run_api -k test-key -s STY -u http://example.invalid "$@"
  ) > "$case_dir/output" 2>&1 || status=$?

  if [ "$status" -ne "$expected_status" ]; then
    cat "$case_dir/output" >&2
    echo "FAIL: $name returned $status, expected $expected_status" >&2
    exit 1
  fi
  if [ -n "$expected_path" ]; then
    grep -Fxq "COMPOSE_API_FILE_PATH=$expected_path" "$case_dir/helper.env"
    grep -Fxq 'IMAGE_TAG=latest' "$case_dir/helper.env"
  else
    [ ! -e "$case_dir/helper.env" ]
    grep -Fq 'Error: Failed to select master API compose' "$case_dir/output"
  fi
  echo "PASS: $name (status $status)"
}

run_case master 0 /ontologies_api/master/docker-compose.yml -r agroportal -t master
# Reusing the helper must also work after its sample has already been updated.
run_case master 0 /ontologies_api/master/docker-compose.yml -r agroportal -t master
run_case nonmaster 0 /ontologies_api/development/docker-compose.yml -r agroportal -t development
run_case other-repository 0 /ontologies_api/development/docker-compose.yml -r bioportal -t master
run_case defaults 0 /ontologies_api/development/docker-compose.yml
API_IMAGE_REPOSITORY=agroportal API_IMAGE_TAG=master \
  run_case environment-master 0 /ontologies_api/master/docker-compose.yml
HELPER_EXIT_STATUS=37 \
  run_case helper-error 37 /ontologies_api/master/docker-compose.yml -r agroportal -t master
HELPER_COMPOSE_LINE=UNEXPECTED_CONFIG=value \
  run_case missing-compose-config 1 '' -r agroportal -t master
