#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
from typing import Dict, Tuple, List

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

def load_exports(fp) -> Dict[str, str]:
    secrets = {}
    for i, line in enumerate(fp, start=1):
        line = line.rstrip('\n')
        if not line or line.lstrip().startswith('#'):
            continue
        try:
            name, value = parse_export_line(line)
        except ValueError:
            continue
        if value in {"", "<secret-content>", "<REPLACE_ME>", "CHANGEME"}:
            sys.stderr.write(f"Skipping {name}: empty/placeholder on line {i}\n")
            continue
        secrets[name] = value
    return secrets

def group_by_region(flat: Dict[str, str]) -> Dict[str, Dict[str, str]]:
    """
    Turn VARS like NORTHCENTRALUS_AZURE_CLIENT_ID into:
    {
      "NORTHCENTRALUS": {"AZURE_CLIENT_ID": "..."},
      ...
    }
    If a name has no underscore, it goes under region 'DEFAULT' with the full name as key.
    """
    grouped: Dict[str, Dict[str, str]] = {}
    for full, val in flat.items():
        if "_" in full:
            region, key = full.split("_", 1)
        else:
            region, key = "DEFAULT", full
        bucket = grouped.setdefault(region, {})
        bucket[key] = val
    return grouped

def ensure_gh_logged_in():
    try:
        subprocess.run(["gh", "auth", "status"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("ERROR: GitHub CLI ('gh') not available or not logged in. Run: gh auth login")

def set_secret(repo: str, name: str, value: str, dry_run: bool = False) -> bool:
    if dry_run:
        print(f"[dry-run] Would set secret {name} in {repo} (size {len(value.encode('utf-8'))} bytes)")
        return True
    try:
        proc = subprocess.run(
            ["gh", "secret", "set", name, "-R", repo, "-b", value],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        return proc.returncode == 0
    except subprocess.CalledProcessError as e:
        msg = e.stderr.strip() or e.stdout.strip() or str(e)
        sys.stderr.write(f"Failed to set {name}: {msg}\n")
        return False

def shard_payloads(grouped: Dict[str, Dict[str, str]],
                   max_bytes: int,
                   bundle_name: str) -> Tuple[List[Tuple[str, str]], Dict]:
    """
    Pack regions into as few JSON secrets as possible under max_bytes.
    Returns: list of (secret_name, json_string), and a manifest dict.
    """
    regions_sorted = sorted(grouped.keys())
    shards: List[Tuple[str, str]] = []
    current: Dict[str, Dict[str, str]] = {}
    shard_index = 1

    def bytes_len(obj) -> int:
        return len(json.dumps(obj, separators=(',', ':'), ensure_ascii=False).encode('utf-8'))

    for r in regions_sorted:
        # try adding region r into current shard
        tentative = dict(current)
        tentative[r] = grouped[r]
        if bytes_len(tentative) <= max_bytes or not current:
            current = tentative
        else:
            # flush current shard
            shards.append((f"{bundle_name}_{shard_index}", json.dumps(current, separators=(',', ':'), ensure_ascii=False)))
            shard_index += 1
            current = {r: grouped[r]}
            # if even a single region is too big (extremely unlikely), fail early
            if bytes_len(current) > max_bytes:
                raise RuntimeError(f"Region '{r}' alone exceeds max_bytes={max_bytes}. Consider increasing --max-bytes or compressing externally.")

    if current:
        # last shard
        name = bundle_name if shard_index == 1 else f"{bundle_name}_{shard_index}"
        shards.append((name, json.dumps(current, separators=(',', ':'), ensure_ascii=False)))

    # Build manifest if multiple shards
    manifest = {
        "type": "region_config_shards",
        "base_name": bundle_name,
        "shards": [n for n, _ in shards],
        "total_regions": len(grouped),
        "version": 1
    }
    return shards, manifest

def main():
    parser = argparse.ArgumentParser(description="Bundle per-region exports into JSON secret(s) and set them via gh.")
    parser.add_argument("input", nargs="?", default="-",
                        help="Path to file with 'export NAME=VALUE' lines (default: stdin)")
    parser.add_argument("--repo", default="merabytes/secrets-lambda",
                        help="Target GitHub repo (OWNER/REPO). Default: merabytes/secrets-lambda")
    parser.add_argument("--bundle-name", default="AZURE_REGION_CONFIGS",
                        help="Base name for the combined secret(s). Default: AZURE_REGION_CONFIGS")
    parser.add_argument("--max-bytes", type=int, default=60000,
                        help="Max bytes per secret payload (safety margin under GitHub ~64KB). Default: 60000")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without creating secrets")
    args = parser.parse_args()

    ensure_gh_logged_in()

    # Read input
    if args.input == "-" or args.input == "/dev/stdin":
        flat = load_exports(sys.stdin)
    else:
        with open(args.input, "r", encoding="utf-8") as f:
            flat = load_exports(f)

    if not flat:
        sys.exit("No valid secrets found (all empty/placeholders or no export lines).")

    grouped = group_by_region(flat)
    shards, manifest = shard_payloads(grouped, args.max_bytes, args.bundle_name)

    total = 0
    for name, payload in shards:
        # If there is only one shard and its name is exactly bundle_name, great.
        # If multiple shards exist, names will be bundle_name_1 .. _N (first one may be just base if only one shard)
        ok = set_secret(args.repo, name, payload, dry_run=args.dry_run)
        if ok:
            print(f"Set combined secret: {name} (regions: {len(json.loads(payload))})")
            total += 1

    if len(shards) > 1:
        # Write a manifest so workflows can discover shards at runtime.
        ok = set_secret(args.repo, f"{args.bundle_name}_MANIFEST",
                        json.dumps(manifest, separators=(',', ':'), ensure_ascii=False),
                        dry_run=args.dry_run)
        if ok:
            print(f"Set manifest: {args.bundle_name}_MANIFEST -> {manifest['shards']}")

    print(f"\nDone. {total}/{len(shards)} combined secret(s) {'would be ' if args.dry_run else ''}set in {args.repo}.")
    if len(shards) > 1:
        print(f"Note: {len(shards)} shards created due to size; see {args.bundle_name}_MANIFEST.")

if __name__ == "__main__":
    main()

