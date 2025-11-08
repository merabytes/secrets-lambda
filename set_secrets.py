#!/usr/bin/env python3
import argparse
import os
import re
import shlex
import subprocess
import sys
from typing import Dict, Tuple

EXPORT_RE = re.compile(r'^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')

def parse_export_line(line: str) -> Tuple[str, str]:
    """
    Parse a bash-style 'export NAME=VALUE' line.
    Returns (name, value) with quotes around VALUE removed if present.
    Raises ValueError if the line isn't an export assignment.
    """
    m = EXPORT_RE.match(line)
    if not m:
        raise ValueError("Not an export line")
    name, raw = m.group(1), m.group(2)

    # Handle empty assignment (e.g., NAME= or NAME="")
    raw = raw.strip()
    if raw == "":
        return name, ""

    # If VALUE contains inline comments, do not strip (secrets may include '#')
    # Remove surrounding single/double quotes if they wrap the entire value.
    if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
        value = raw[1:-1]
    else:
        value = raw

    return name, value

def load_exports(fp) -> Dict[str, str]:
    secrets = {}
    for i, line in enumerate(fp, start=1):
        line = line.rstrip('\n')
        if not line or line.lstrip().startswith('#'):
            continue
        try:
            name, value = parse_export_line(line)
        except ValueError:
            # Ignore non-export lines
            continue
        # Skip placeholder markers commonly used in examples
        if value in {"", "<secret-content>", "<REPLACE_ME>", "CHANGEME"}:
            sys.stderr.write(f"Skipping {name}: empty or placeholder on line {i}\n")
            continue
        secrets[name] = value
    return secrets

def ensure_gh_logged_in():
    try:
        # 'gh auth status' returns 0 when authenticated
        subprocess.run(["gh", "auth", "status"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("ERROR: GitHub CLI ('gh') not available or not logged in. Run: gh auth login")

def set_secret(repo: str, name: str, value: str, dry_run: bool = False) -> bool:
    """
    Create/update a single repository secret using gh.
    Returns True on success.
    """
    if dry_run:
        print(f"[dry-run] Would set secret {name} in {repo}")
        return True

    # Use -R for repo, -b to pass the value from stdin buffer
    # Note: Avoid passing secret via command args or environment where possible.
    try:
        proc = subprocess.run(
            ["gh", "secret", "set", name, "-R", repo, "-b", value],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        # gh prints something like: ✓ Set secret NAME for merabytes/secrets-lambda
        return proc.returncode == 0
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"Failed to set {name}: {e.stderr.strip() or e.stdout.strip()}\n")
        return False

def main():
    parser = argparse.ArgumentParser(description="Create GitHub repo secrets from export lines using gh.")
    parser.add_argument("input", nargs="?", default="-",
                        help="Path to file with 'export NAME=VALUE' lines (default: stdin)")
    parser.add_argument("--repo", default="merabytes/secrets-lambda",
                        help="Target GitHub repo in OWNER/REPO form (default: merabytes/secrets-lambda)")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without creating secrets")
    args = parser.parse_args()

    ensure_gh_logged_in()

    # Read input
    if args.input == "-" or args.input == "/dev/stdin":
        secrets = load_exports(sys.stdin)
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            secrets = load_exports(f)

    if not secrets:
        sys.exit("No valid secrets found to set (all empty/placeholders or no 'export' lines).")

    ok = 0
    for name, value in secrets.items():
        success = set_secret(args.repo, name, value, dry_run=args.dry_run)
        if success:
            print(f"Set secret: {name}")
            ok += 1

    print(f"\nDone. {ok}/{len(secrets)} secrets {'would be ' if args.dry_run else ''}set in {args.repo}.")

if __name__ == "__main__":
    main()

