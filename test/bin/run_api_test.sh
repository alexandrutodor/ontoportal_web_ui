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
cp tmp/ontoportal_docker/.env.sample "$TEST_CASE_DIR/helper.env.sample.original"
cat > tmp/ontoportal_docker/run <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
cp .env.sample .env
cp .env "$TEST_CASE_DIR/helper.env"
: > "$TEST_CASE_DIR/helper.argv"
for arg in "$@"; do
  printf '%s\0' "$arg" >> "$TEST_CASE_DIR/helper.argv"
done
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
  if grep -Fq 'test-key' "$case_dir/output"; then
    echo "FAIL: $name leaked test-key in output" >&2
    exit 1
  fi
  if [ -n "$expected_path" ]; then
    grep -Fxq "COMPOSE_API_FILE_PATH=$expected_path" "$case_dir/helper.env"
    grep -Fxq 'IMAGE_TAG=latest' "$case_dir/helper.env"
    cmp "$case_dir/helper.env" "$case_dir/tmp/ontoportal_docker/.env"
  else
    [ ! -e "$case_dir/helper.env" ]
    grep -Fq 'Error: Failed to select master API compose' "$case_dir/output"
  fi
  if ! cmp -s "$case_dir/helper.env.sample.original" "$case_dir/tmp/ontoportal_docker/.env.sample"; then
    echo "FAIL: $name modified cached helper sample" >&2
    exit 1
  fi
  echo "PASS: $name (status $status; ${*:-default options})"
}

run_case master 0 /ontologies_api/master/docker-compose.yml -r agroportal -t master
# Cached master runs must leave the original selection for subsequent requests.
run_case master 0 /ontologies_api/master/docker-compose.yml -r agroportal -t master
run_case master 0 /ontologies_api/development/docker-compose.yml -r agroportal -t development
run_case master 0 /ontologies_api/development/docker-compose.yml
run_case nonmaster 0 /ontologies_api/development/docker-compose.yml -r agroportal -t development
run_case other-repository 0 /ontologies_api/development/docker-compose.yml -r bioportal -t master
run_case defaults 0 /ontologies_api/development/docker-compose.yml
API_IMAGE_REPOSITORY=agroportal API_IMAGE_TAG=master \
  run_case environment-master 0 /ontologies_api/master/docker-compose.yml
HELPER_EXIT_STATUS=37 \
  run_case helper-error 37 /ontologies_api/master/docker-compose.yml -r agroportal -t master
HELPER_COMPOSE_LINE=UNEXPECTED_CONFIG=value \
  run_case missing-compose-config 1 '' -r agroportal -t master

cat > "$tmp_dir/stubs/sed" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'PARTIAL_SED_UPDATE=1' >> "${@: -1}"
exit 1
STUB
chmod +x "$tmp_dir/stubs/sed"
run_case sed-error 1 '' -r agroportal -t master
rm -f "$tmp_dir/stubs/sed"

read_case_argv() {
  local case_dir=$1
  RECEIVED_ARGV=()
  [ -f "$case_dir/helper.argv" ] || return 0
  while IFS= read -r -d '' arg; do
    RECEIVED_ARGV+=("$arg")
  done < "$case_dir/helper.argv"
}

run_argv_case() {
  local name=$1 expected_status=$2 secret_key=$3 marker_file=$4
  shift 4
  local case_dir="$tmp_dir/$name" status=0
  mkdir -p "$case_dir/bin"
  cp "$run_api" "$case_dir/bin/run_api"
  rm -f "$case_dir/helper.env" "$case_dir/helper.argv"
  [ -z "$marker_file" ] || rm -f "$marker_file"
  (
    cd "$case_dir"
    export TEST_CASE_DIR="$case_dir"
    bash bin/run_api "$@"
  ) > "$case_dir/output" 2>&1 || status=$?

  if [ "$status" -ne "$expected_status" ]; then
    cat "$case_dir/output" >&2
    echo "FAIL: $name returned $status, expected $expected_status" >&2
    exit 1
  fi
  if [ -n "$secret_key" ] && grep -Fq -- "$secret_key" "$case_dir/output"; then
    echo "FAIL: $name leaked secret key in output" >&2
    exit 1
  fi
  if [ -n "$marker_file" ] && [ -e "$marker_file" ]; then
    echo "FAIL: $name executed injected marker command" >&2
    exit 1
  fi
  read_case_argv "$case_dir"
  echo "PASS: $name (status $status; argv verified)"
}

# Literal spaces and shell metacharacters delivered to ./run stub without evaluation
marker_spaces="$tmp_dir/marker-spaces"
synth_key_spaces='synth-key-!@#$ ;&| `echo bad` "quotes"'
synth_repo='agroportal repo with spaces'
synth_tag='master-tag;metachars&|'
synth_ont='ONT WITH SPACES & $(touch '"$marker_spaces"')'
synth_url='http://example.invalid/path with spaces?foo=1&bar=2;'

run_argv_case spaces-and-metacharacters 0 "$synth_key_spaces" "$marker_spaces" \
  -k "$synth_key_spaces" -r "$synth_repo" -t "$synth_tag" -s "$synth_ont" -u "$synth_url"

[ ! -e "$marker_spaces" ]
[ "${#RECEIVED_ARGV[@]}" -eq 10 ]
[ "${RECEIVED_ARGV[0]}" = "-k" ] && [ "${RECEIVED_ARGV[1]}" = "$synth_key_spaces" ]
[ "${RECEIVED_ARGV[2]}" = "-r" ] && [ "${RECEIVED_ARGV[3]}" = "$synth_repo" ]
[ "${RECEIVED_ARGV[4]}" = "-t" ] && [ "${RECEIVED_ARGV[5]}" = "$synth_tag" ]
[ "${RECEIVED_ARGV[6]}" = "-s" ] && [ "${RECEIVED_ARGV[7]}" = "$synth_ont" ]
[ "${RECEIVED_ARGV[8]}" = "-u" ] && [ "${RECEIVED_ARGV[9]}" = "$synth_url" ]

# Injected marker inside API key is never executed and key is absent from output
marker_key="$tmp_dir/marker-key"
synth_key_injected='synth-key;touch '"$marker_key"';'
run_argv_case injected-marker-in-key 0 "$synth_key_injected" "$marker_key" \
  -k "$synth_key_injected" -s STY -u http://example.invalid

[ ! -e "$marker_key" ]
[ "${#RECEIVED_ARGV[@]}" -eq 10 ]
[ "${RECEIVED_ARGV[0]}" = "-k" ] && [ "${RECEIVED_ARGV[1]}" = "$synth_key_injected" ]

# Failure exits propagate child exit status while redacting secret key and restoring config
synth_key_fail='synth-failure-key-37' # gitleaks:allow
HELPER_EXIT_STATUS=37 \
  run_argv_case helper-failure-secret-absent 37 "$synth_key_fail" "" \
    -k "$synth_key_fail" -r agroportal -t master -s STY -u http://example.invalid

[ "${#RECEIVED_ARGV[@]}" -eq 10 ]
[ "${RECEIVED_ARGV[0]}" = "-k" ] && [ "${RECEIVED_ARGV[1]}" = "$synth_key_fail" ]
cmp -s "$tmp_dir/helper-failure-secret-absent/helper.env.sample.original" \
       "$tmp_dir/helper-failure-secret-absent/tmp/ontoportal_docker/.env.sample"

# Empty arguments preserved as distinct empty argv elements
run_argv_case empty-args-preserved 0 "" "" \
  -k "" -r "" -t "" -s "" -u ""

[ "${#RECEIVED_ARGV[@]}" -eq 10 ]
[ "${RECEIVED_ARGV[0]}" = "-k" ] && [ "${RECEIVED_ARGV[1]}" = "" ]
[ "${RECEIVED_ARGV[2]}" = "-r" ] && [ "${RECEIVED_ARGV[3]}" = "" ]
[ "${RECEIVED_ARGV[4]}" = "-t" ] && [ "${RECEIVED_ARGV[5]}" = "" ]
[ "${RECEIVED_ARGV[6]}" = "-s" ] && [ "${RECEIVED_ARGV[7]}" = "" ]
[ "${RECEIVED_ARGV[8]}" = "-u" ] && [ "${RECEIVED_ARGV[9]}" = "" ]

# Environment fallback preserves metacharacters, spaces, and keeps key absent from logs
marker_env="$tmp_dir/marker-env"
env_key='synth-env-key;& | `test`'
env_repo='env repo with spaces'
env_tag='env tag metachars;'
env_ont='env ont $(touch '"$marker_env"')'
env_url='http://example.invalid/env?q=1&v=2'

OP_API_KEY="$env_key" \
API_IMAGE_REPOSITORY="$env_repo" \
API_IMAGE_TAG="$env_tag" \
STARTER_ONTOLOGY="$env_ont" \
OP_API_URL="$env_url" \
  run_argv_case env-fallback-spaces-metachars 0 "$env_key" "$marker_env"

[ ! -e "$marker_env" ]
[ "${#RECEIVED_ARGV[@]}" -eq 10 ]
[ "${RECEIVED_ARGV[0]}" = "-k" ] && [ "${RECEIVED_ARGV[1]}" = "$env_key" ]
[ "${RECEIVED_ARGV[2]}" = "-r" ] && [ "${RECEIVED_ARGV[3]}" = "$env_repo" ]
[ "${RECEIVED_ARGV[4]}" = "-t" ] && [ "${RECEIVED_ARGV[5]}" = "$env_tag" ]
[ "${RECEIVED_ARGV[6]}" = "-s" ] && [ "${RECEIVED_ARGV[7]}" = "$env_ont" ]
[ "${RECEIVED_ARGV[8]}" = "-u" ] && [ "${RECEIVED_ARGV[9]}" = "$env_url" ]
