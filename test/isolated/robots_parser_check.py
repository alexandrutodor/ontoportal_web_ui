#!/usr/bin/env python3
"""
Compact stdlib offline robots parser regression check for ONTO-AT-L03.

Proves:
1. Syntax correctness of config/robots/*.txt files.
2. Fail-before behavior: uncorrected 'Disalow' and 'User agent' directives
   cause standard robots parser to fail widgets exclusion and fail MTRobot disallow-all.
3. Pass-after behavior on config/robots/appliance.txt:
   - Generic crawler (*) excludes /widgets and /widgets/*
   - Final named crawler (MTRobot) receives disallow-all group (disallowed from / and /ontologies)
   - Unaffected positive paths (/ontologies, /about) remain permitted for generic crawlers
   - Other named crawlers (SemrushBot, MJ12bot, etc.) retain disallow-all
   - Crawl-delay is preserved
4. Isolated Rails response fixtures (slice vs non-slice):
   - Slice fixture: controller-generated disallow-all policy blocks all crawlers
   - Non-slice fixture: appliance profile correctly enforces selective rules
5. Unaltered profiles (development, staging, production) retain expected policies.

Uses Python urllib.robotparser (stdlib only, no third-party dependencies).
Runs completely offline without network, services, database, or API calls.
"""

import os
import sys
import urllib.robotparser

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROBOTS_DIR = os.path.join(REPO_ROOT, "config", "robots")

failures = []


def assert_true(condition, message):
    if condition:
        print(f"  [PASS] {message}")
    else:
        print(f"  [FAIL] {message}")
        failures.append(message)


def parse_robots_text(content: str) -> urllib.robotparser.RobotFileParser:
    rp = urllib.robotparser.RobotFileParser()
    rp.parse(content.splitlines())
    return rp


def parse_robots_directives(content: str) -> urllib.robotparser.RobotFileParser:
    rp = urllib.robotparser.RobotFileParser()
    # Strip empty lines to isolate directive stream
    lines = [line.strip() for line in content.splitlines() if line.strip()]
    rp.parse(lines)
    return rp


def test_syntax_and_readability():
    print("=== Step 1: Validate profile files exist and have valid directive syntax ===")
    profiles = ["appliance.txt", "production.txt", "staging.txt", "development.txt"]
    for profile in profiles:
        path = os.path.join(ROBOTS_DIR, profile)
        assert_true(os.path.isfile(path), f"File exists: config/robots/{profile}")
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for idx, line in enumerate(lines, 1):
            line_s = line.strip()
            if not line_s or line_s.startswith("#"):
                continue
            assert_true(
                ":" in line_s,
                f"{profile}:{idx} contains valid directive key-value separator: '{line_s}'",
            )
            key = line_s.split(":", 1)[0].strip()
            # Directive keys in RFC 9309 / standard robots.txt format
            valid_keys = {"User-agent", "User-Agent", "Disallow", "Allow", "Crawl-delay", "Sitemap"}
            assert_true(
                key in valid_keys,
                f"{profile}:{idx} directive '{key}' is a recognized standard directive",
            )


def test_fail_before_behavior():
    print("\n=== Step 2: Prove fail-before behavior with uncorrected typos ===")
    # Simulate pre-fix appliance.txt containing the two typos
    path = os.path.join(ROBOTS_DIR, "appliance.txt")
    with open(path, "r", encoding="utf-8") as f:
        current_content = f.read()

    # Reintroduce the exact pre-fix typos
    pre_fix_content = current_content.replace("Disallow: /widgets", "Disalow: /widgets").replace(
        "User-agent: MTRobot", "User agent: MTRobot"
    )

    rp_pre = parse_robots_text(pre_fix_content)

    # Fail-before: 'Disalow: /widgets' is an unrecognized directive, so generic crawler is NOT blocked from /widgets
    widgets_fetch_pre = rp_pre.can_fetch("*", "http://example.org/widgets")
    assert_true(
        widgets_fetch_pre is True,
        "Pre-fix: generic crawler can_fetch /widgets is True (FAIL-BEFORE: exclusion not enforced)",
    )

    # Fail-before: 'User agent: MTRobot' has a space instead of hyphen, so MTRobot group is ignored
    # and falls back to generic '*' rules, meaning '/' is allowed (not disallowed-all)
    mtrobot_fetch_root_pre = rp_pre.can_fetch("MTRobot", "http://example.org/")
    assert_true(
        mtrobot_fetch_root_pre is True,
        "Pre-fix: MTRobot can_fetch / is True (FAIL-BEFORE: disallow-all not enforced)",
    )


def test_pass_after_appliance():
    print("\n=== Step 3: Prove pass-after behavior on corrected config/robots/appliance.txt ===")
    path = os.path.join(ROBOTS_DIR, "appliance.txt")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify the typos are absent and corrected forms are present
    assert_true("Disalow:" not in content, "No 'Disalow:' typo exists in appliance.txt")
    assert_true("User agent:" not in content, "No 'User agent:' typo exists in appliance.txt")
    assert_true("Disallow: /widgets" in content, "Directives contain 'Disallow: /widgets'")
    assert_true("User-agent: MTRobot" in content, "Directives contain 'User-agent: MTRobot'")

    rp = parse_robots_text(content)

    # 1. Generic crawler widgets exclusion
    assert_true(
        not rp.can_fetch("*", "http://example.org/widgets"),
        "Post-fix: generic crawler can_fetch /widgets is False (widgets excluded)",
    )
    assert_true(
        not rp.can_fetch("*", "http://example.org/widgets/foo"),
        "Post-fix: generic crawler can_fetch /widgets/foo is False (subpaths excluded)",
    )

    # 2. Final named crawler MTRobot disallow-all
    assert_true(
        not rp.can_fetch("MTRobot", "http://example.org/"),
        "Post-fix: MTRobot can_fetch / is False (disallow-all enforced)",
    )
    assert_true(
        not rp.can_fetch("MTRobot", "http://example.org/ontologies"),
        "Post-fix: MTRobot can_fetch /ontologies is False (disallow-all enforced)",
    )
    assert_true(
        not rp.can_fetch("MTRobot", "http://example.org/widgets"),
        "Post-fix: MTRobot can_fetch /widgets is False (disallow-all enforced)",
    )

    # 3. Unaffected positive paths remain accessible to generic crawlers
    assert_true(
        rp.can_fetch("*", "http://example.org/ontologies"),
        "Post-fix: generic crawler can_fetch /ontologies is True (positive path allowed)",
    )
    assert_true(
        rp.can_fetch("*", "http://example.org/about"),
        "Post-fix: generic crawler can_fetch /about is True (positive path allowed)",
    )

    # 4. Other disallowed paths and bots remain intact
    assert_true(
        not rp.can_fetch("*", "http://example.org/projects"),
        "Generic crawler can_fetch /projects is False",
    )
    assert_true(
        not rp.can_fetch("*", "http://example.org/login"),
        "Generic crawler can_fetch /login is False",
    )
    assert_true(
        not rp.can_fetch("SemrushBot", "http://example.org/"),
        "SemrushBot can_fetch / is False",
    )
    assert_true(
        not rp.can_fetch("AhrefsBot", "http://example.org/"),
        "AhrefsBot can_fetch / is False",
    )
    assert_true(
        rp.crawl_delay("*") == 5,
        "Crawl-delay for generic crawler is 5",
    )


def test_isolated_rails_response_fixtures():
    print("\n=== Step 4: Isolated Rails non-slice and slice response fixtures ===")
    # Exact non-slice appliance response as produced by RobotsController (File.read(Rails.root + "config/robots/appliance.txt"))
    with open(os.path.join(ROBOTS_DIR, "appliance.txt"), "r", encoding="utf-8") as f:
        non_slice_appliance_response = f.read()

    # Exact slice response as produced by RobotsController index when @subdomain_filter[:active] == true
    # robots = <<-EOF.gsub(/^\\s+/, "")
    #   User-agent: *\\n
    #   Disallow: /
    # EOF
    slice_response = "User-agent: *\n\nDisallow: /\n"

    # 1. Non-slice appliance response fixture verification
    rp_nonslice = parse_robots_text(non_slice_appliance_response)
    assert_true(
        rp_nonslice.can_fetch("*", "http://appliance.example.org/ontologies"),
        "Non-slice fixture: generic crawler allowed on /ontologies",
    )
    assert_true(
        not rp_nonslice.can_fetch("*", "http://appliance.example.org/widgets"),
        "Non-slice fixture: generic crawler disallowed on /widgets",
    )
    assert_true(
        not rp_nonslice.can_fetch("MTRobot", "http://appliance.example.org/"),
        "Non-slice fixture: MTRobot disallowed from entire site (/)",
    )
    assert_true(
        not rp_nonslice.can_fetch("MTRobot", "http://appliance.example.org/ontologies"),
        "Non-slice fixture: MTRobot disallowed from /ontologies",
    )

    # 2. Slice response fixture verification (controller-generated disallow-all)
    rp_slice = parse_robots_directives(slice_response)
    assert_true(
        not rp_slice.can_fetch("*", "http://slice.example.org/"),
        "Slice fixture: generic crawler disallowed from /",
    )
    assert_true(
        not rp_slice.can_fetch("*", "http://slice.example.org/ontologies"),
        "Slice fixture: generic crawler disallowed from /ontologies",
    )
    assert_true(
        not rp_slice.can_fetch("MTRobot", "http://slice.example.org/"),
        "Slice fixture: MTRobot disallowed from /",
    )
    assert_true(
        not rp_slice.can_fetch("Googlebot", "http://slice.example.org/ontologies"),
        "Slice fixture: named crawler disallowed from /ontologies",
    )


def test_unaltered_environment_profiles():
    print("\n=== Step 5: Confirm development, staging, and production profiles ===")
    with open(os.path.join(ROBOTS_DIR, "development.txt"), "r", encoding="utf-8") as f:
        dev_content = f.read()
    rp_dev = parse_robots_text(dev_content)
    assert_true(
        not rp_dev.can_fetch("*", "http://dev.example.org/"),
        "development.txt disallows / for all crawlers",
    )

    with open(os.path.join(ROBOTS_DIR, "staging.txt"), "r", encoding="utf-8") as f:
        stage_content = f.read()
    rp_stage = parse_robots_text(stage_content)
    assert_true(
        not rp_stage.can_fetch("*", "http://stage.example.org/"),
        "staging.txt disallows / for all crawlers",
    )

    with open(os.path.join(ROBOTS_DIR, "production.txt"), "r", encoding="utf-8") as f:
        prod_content = f.read()
    rp_prod = parse_robots_text(prod_content)
    assert_true(
        rp_prod.can_fetch("*", "http://prod.example.org/ontologies"),
        "production.txt allows /ontologies for generic crawler",
    )
    assert_true(
        not rp_prod.can_fetch("*", "http://prod.example.org/projects"),
        "production.txt disallows /projects",
    )
    assert_true(
        not rp_prod.can_fetch("SemrushBot", "http://prod.example.org/"),
        "production.txt disallows SemrushBot",
    )


def main():
    test_syntax_and_readability()
    test_fail_before_behavior()
    test_pass_after_appliance()
    test_isolated_rails_response_fixtures()
    test_unaltered_environment_profiles()

    print("\n=== Summary ===")
    if failures:
        print(f"FAILED: {len(failures)} assertion(s) failed:")
        for fail in failures:
            print(f"  - {fail}")
        sys.exit(1)
    else:
        print("All robots parser regression checks passed successfully.")
        sys.exit(0)


if __name__ == "__main__":
    main()
