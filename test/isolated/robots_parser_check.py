#!/usr/bin/env python3
"""
Offline parser regression check for robots.txt policies (ONTO-AT-L03).
Validates urllib.robotparser directive semantics across config/robots profiles.
"""

from pathlib import Path
import urllib.robotparser


def parse(text: str) -> urllib.robotparser.RobotFileParser:
    parser = urllib.robotparser.RobotFileParser()
    parser.parse(text.splitlines())
    return parser


def main() -> None:
    robots_dir = Path(__file__).resolve().parents[2] / "config" / "robots"
    appliance_text = (robots_dir / "appliance.txt").read_text()

    # 1. Prior typo stream demonstrably permits intended blocks (fail-before)
    typo_text = appliance_text.replace(
        "Disallow: /widgets", "Disalow: /widgets"
    ).replace("User-agent: MTRobot", "User agent: MTRobot")
    rp_typo = parse(typo_text)
    assert rp_typo.can_fetch("*", "http://example.org/widgets")
    assert rp_typo.can_fetch("*", "http://example.org/widgets/foo")
    assert rp_typo.can_fetch("MTRobot", "http://example.org/")
    assert rp_typo.can_fetch("MTRobot", "http://example.org/ontologies")

    # 2. Corrected appliance policy
    rp_app = parse(appliance_text)
    assert not rp_app.can_fetch("*", "http://example.org/widgets")
    assert not rp_app.can_fetch("*", "http://example.org/widgets/foo")
    assert rp_app.can_fetch("*", "http://example.org/ontologies")
    assert not rp_app.can_fetch("MTRobot", "http://example.org/")
    assert not rp_app.can_fetch("MTRobot", "http://example.org/ontologies")

    # 3. Development and staging profiles disallow all
    for env in ("development", "staging"):
        rp_env = parse((robots_dir / f"{env}.txt").read_text())
        assert not rp_env.can_fetch("*", "http://example.org/")
        assert not rp_env.can_fetch("*", "http://example.org/ontologies")

    # 4. Representative production policy unchanged
    rp_prod = parse((robots_dir / "production.txt").read_text())
    assert rp_prod.can_fetch("*", "http://example.org/ontologies")
    assert not rp_prod.can_fetch("*", "http://example.org/projects")
    assert not rp_prod.can_fetch("SemrushBot", "http://example.org/")

    print("Robots parser checks passed.")


if __name__ == "__main__":
    main()
