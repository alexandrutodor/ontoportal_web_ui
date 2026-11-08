#!/usr/bin/env python3
"""Isolated rehearsal of the Compose `production` profile (ONTO-T-Q03).

Runs db, cache and app containers built from a *rendered* `docker compose config --format json`
on an existing internal Docker network, with test-only secrets. Nothing is published to the host.

  compose_production_rehearsal.py up RENDERED.json IMAGE   # (re)create the app; db/cache kept
  compose_production_rehearsal.py probe IMAGE              # JSON: HTTP, DB, cache, served code
  compose_production_rehearsal.py mark                     # insert a DB row that must survive
  compose_production_rehearsal.py down                     # remove containers and volumes
"""
import json, subprocess, sys, time

NET = "onto-ui-remediation-20261107-q06_backend"  # existing internal network: no outside access
P = "q03-rehearsal"
SECRET = "fake-secret-q03-rehearsal-only"
# shortcut: memcached:latest is not available offline, 1.6 is; same protocol for this check.
CACHE_IMAGE = "memcached:1.6"
OVERRIDES = {"API_URL": "http://api:9393", "SECRET_KEY_BASE": SECRET}
CODE_PROBES = ["app/mailers/subscribe_mailer.rb", "public/widgets/jquery.ncbo.tree.css"]


def sh(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True, timeout=600)
    if check and r.returncode:
        sys.exit(f"FAILED {' '.join(args)}\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip()


def exists(name):
    return subprocess.run(["docker", "inspect", name], capture_output=True).returncode == 0


def vol(src):
    return f"{P}_{src}"


def up(rendered, image):
    svc = json.load(open(rendered))["services"]
    if not exists(f"{P}-db"):
        db = svc["db"]
        sh("docker", "run", "-d", "--name", f"{P}-db", "--network", NET, "--network-alias", "db",
           *[a for k, v in db["environment"].items() for a in ("-e", f"{k}={v}")],
           *[a for v in db["volumes"] for a in ("-v", f"{vol(v['source'])}:{v['target']}")], db["image"])
        sh("docker", "run", "-d", "--name", f"{P}-cache", "--network", NET, "--network-alias", "cache",
           CACHE_IMAGE, *svc["cache"]["command"])
        for _ in range(60):
            if subprocess.run(["docker", "exec", f"{P}-db", "mysqladmin", "ping", "-uroot", "-proot", "--silent"],
                              capture_output=True).returncode == 0:
                break
            time.sleep(2)
        time.sleep(5)
    app = svc["production"]
    env = {**app["environment"], **OVERRIDES}
    args = ["--network", NET, "--network-alias", "app",
            *[a for k, v in env.items() for a in ("-e", f"{k}={v}")],
            *[a for t in app.get("tmpfs", []) for a in ("--tmpfs", t)],
            *[a for v in app.get("volumes", []) for a in ("-v", f"{vol(v['source'])}:{v['target']}")]]
    sh("docker", "rm", "-f", f"{P}-app", check=False)
    # One-off schema setup on the profile's own DB settings; repeated runs keep existing data.
    sh("docker", "run", "--rm", *args, image, "sh", "-c",
       "bin/rails db:create >/dev/null 2>&1; bin/rails runner 'exit(ActiveRecord::Base.connection.table_exists?(:licenses) ? 0 : 3)' "
       "|| DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:schema:load")
    sh("docker", "run", "-d", "--name", f"{P}-app", *args, image, *app["command"])
    for _ in range(90):
        if http("/")[0] not in ("000", ""):
            return
        time.sleep(2)
    sys.exit("app did not answer on tcp 3000:\n" + sh("docker", "logs", "--tail", "40", f"{P}-app", check=False))


def http(path):
    out = subprocess.run(["docker", "run", "--rm", "--network", NET, "curlimages/curl", "-s", "-m", "60",
                          "-w", "\n%{http_code}", f"http://app:3000{path}"], capture_output=True, text=True, timeout=120).stdout
    body, _, code = out.rpartition("\n")
    return code, body


def probe(image):
    import re
    code, body = http("/")
    sheets = sorted(set(re.findall(r'/assets/application-[0-9a-f]+\.css', body)))
    served = {f: sh("docker", "exec", f"{P}-app", "sha256sum", f).split()[0] for f in CODE_PROBES}
    in_image = {f: sh("docker", "run", "--rm", "--network", "none", "--entrypoint", "sha256sum", image, f).split()[0]
                for f in CODE_PROBES}
    image_sheet = sh("docker", "run", "--rm", "--network", "none", "--entrypoint", "sh", image, "-c",
                     "ls public/assets | grep -E '^application-[0-9a-f]+\\.css$'")
    cache = sh("docker", "exec", f"{P}-app", "bin/rails", "runner",
               "Rails.cache.write('q03_probe', 'ok'); puts [Rails.cache.class, Rails.cache.read('q03_probe')].join(' ')")
    db = sh("docker", "exec", f"{P}-db", "mysql", "-uroot", "-proot", "-N", "-e",
            "SELECT COUNT(*) FROM bioportal_ui_production.licenses WHERE encrypted_key='trial'; "
            "SELECT COUNT(*) FROM bioportal_ui_production.licenses WHERE encrypted_key='q03-marker'")
    print(json.dumps({
        "image": image,
        "image_revision": sh("docker", "image", "inspect", image, "--format",
                             '{{index .Config.Labels "org.opencontainers.image.revision"}}'),
        "http_root_status": code,
        "served_stylesheets": sheets,
        "image_stylesheet": image_sheet,
        "served_code_matches_image": {f: served[f] == in_image[f] for f in CODE_PROBES},
        "cache": cache,
        "db_trial_rows_and_marker_rows": db.split(),
        "puma_listen": "Listening on http://0.0.0.0:3000" in logs(),
    }, indent=1))


def logs():
    r = subprocess.run(["docker", "logs", f"{P}-app"], capture_output=True, text=True)
    return r.stdout + r.stderr


def mark():
    # Persistent state stand-in: a row that must survive image replacement and rollback.
    sh("docker", "exec", f"{P}-db", "mysql", "-uroot", "-proot", "-e",
       "INSERT INTO bioportal_ui_production.licenses (encrypted_key, created_at, updated_at) VALUES ('q03-marker', NOW(), NOW())")


def down():
    for c in ("app", "cache", "db"):
        sh("docker", "rm", "-f", "-v", f"{P}-{c}", check=False)
    for v in sh("docker", "volume", "ls", "-q", "--filter", f"name={P}_").split():
        sh("docker", "volume", "rm", v, check=False)


if __name__ == "__main__":
    cmd = sys.argv[1]
    {"up": lambda: up(sys.argv[2], sys.argv[3]), "probe": lambda: probe(sys.argv[2]),
     "mark": mark, "down": down}[cmd]()
