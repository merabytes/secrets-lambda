#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from typing import Dict, Tuple, Set, List
from fnmatch import fnmatch

EXPORT_RE = re.compile(r'^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')

def parse_export_line(line: str) -> Tuple[str, str]:
    m = EXPORT_RE.match(line)
    if not m:
        raise ValueError("Not an export line")
    name, raw = m.group(1), m.group(2).strip()
    if raw == "":
        return name, ""
    if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
        raw = raw[1:-1]
    return name, raw

def load_names(fp) -> List[str]:
    names = []
    for i, line in enumerate(fp, start=1):
        line = line.rstrip('\n')
        if not line or line.lstrip().startswith('#'):
            continue
        try:
            name, _ = parse_export_line(line)
        except ValueError:
            continue
        # Record the name even if the value was placeholder/empty — we’re removing by name
        names.append(name)
    return names

def ensure_gh_logged_in():
    try:
        subprocess.run(["gh", "auth", "status"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("ERROR: GitHub CLI ('gh') not available or not logged in. Run: gh auth login")

def list_existing_secret_names(repo: str) -> Set[str]:
    """
    Uses `gh secret list` and returns a set of existing secret NAMES in the repo.
    """
    try:
        proc = subprocess.run(
            ["gh", "secret", "list", "-R", repo],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
    except subprocess.CalledProcessError as e:
        sys.exit(f"ERROR listing secrets: {e.stderr.strip() or e.stdout.strip() or e}")
    names = set()
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Expected format is a table like: NAME  updated ...
        # We take the first whitespace-separated token as the name.
        tok = line.split()[0]
        # Skip header separators if any
        if tok.upper() in {"NAME", "SECRET"} or set(tok) == {"-"}:
            continue
        names.add(tok)
    return names

def should_protect(name: str, protect_patterns: List[str]) -> bool:
    return any(fnmatch(name, pat) for pat in protect_patterns)

def remove_secret(repo: str, name: str, dry_run: bool) -> bool:
    if dry_run:
        print(f"[dry-run] Would remove secret {name} from {repo}")
        return True
    try:
        subprocess.run(["gh", "secret", "remove", name, "-R", repo],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return True
    except subprocess.CalledProcessError as e:
        # If it's already gone, we treat that as a non-fatal miss.
        msg = e.stderr.strip() or e.stdout.strip()
        sys.stderr.write(f"Skip {name}: {msg}\n")
        return False

def main():
    parser = argparse.ArgumentParser(description="Remove per-item GitHub repo secrets listed in an exports file.")
    parser.add_argument("input", nargs="?", default="-",
                        help="Path to file with 'export NAME=VALUE' lines (default: stdin)")
    parser.add_argument("--repo", default="merabytes/secrets-lambda",
                        help="Target GitHub repo (OWNER/REPO). Default: merabytes/secrets-lambda")
    parser.add_argument("--protect", default="AZURE_REGION_CONFIGS*",
                        help="Comma-separated glob patterns to keep (e.g. 'AZURE_REGION_CONFIGS*,FOO_MANIFEST'). "
                             "Default protects combined bundle & shards: 'AZURE_REGION_CONFIGS*'")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without removing secrets")
    args = parser.parse_args()

    ensure_gh_logged_in()

    # Determine names to remove from input file
    if args.input == "-" or args.input == "/dev/stdin":
        names = load_names(sys.stdin)
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            names = load_names(f)

    if not names:
        sys.exit("No names found in input (no 'export NAME=...' lines).")

    # Build protection list
    protect_patterns = [p.strip() for p in args.protect.split(",") if p.strip()]

    # Only try to remove secrets that currently exist
    existing = list_existing_secret_names(args.repo)

    to_remove: List[str] = []
    skipped_protected: List[str] = []
    skipped_missing: List[str] = []

    for n in names:
        if should_protect(n, protect_patterns):
            skipped_protected.append(n)
            continue
        if n not in existing:
            skipped_missing.append(n)
            continue
        to_remove.append(n)

    print(f"Found {len(existing)} existing secrets in {args.repo}.")
    if skipped_protected:
        print(f"Protected (skipped): {len(skipped_protected)}")
    if skipped_missing:
        print(f"Not present (skipped): {len(skipped_missing)}")

    removed = 0
    for n in sorted(set(to_remove)):
        if remove_secret(args.repo, n, args.dry_run):
            print(f"Removed: {n}")
            removed += 1

    print(f"\nDone. {removed}/{len(set(to_remove))} secrets {'would be ' if args.dry_run else ''}removed from {args.repo}.")
    if protect_patterns:
        print("Protection patterns:", ", ".join(protect_patterns))

if __name__ == "__main__":
    main()

