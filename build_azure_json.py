#!/usr/bin/env python3
import json
import re
import sys
from collections import defaultdict

# Regex to match export lines like:
# export NORTHCENTRALUS_AZURE_TENANT_ID="secret"
LINE_RE = re.compile(r'^\s*export\s+([A-Z0-9_]+)\s*=\s*(.*)\s*$')

def parse_export_line(line):
    """Parse an export line into (name, value). Strip quotes if present."""
    m = LINE_RE.match(line)
    if not m:
        return None, None
    name, value = m.group(1), m.group(2).strip()
    if not value or value in ('""', "''"):
        return name, ""
    # Strip wrapping quotes
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        value = value[1:-1]
    return name, value

def group_by_region(env_lines):
    """
    Turn lines like NORTHCENTRALUS_AZURE_CLIENT_ID into:
    {
      "NORTHCENTRALUS": {
         "AZURE_CLIENT_ID": "xxxx",
         ...
      },
      ...
    }
    """
    regions = defaultdict(dict)
    for line in env_lines:
        name, value = parse_export_line(line)
        if not name or not value:
            continue
        # Split the variable name into REGION and remainder
        # e.g. NORTHCENTRALUS_AZURE_CLIENT_ID → REGION=NORTHCENTRALUS, VAR=AZURE_CLIENT_ID
        parts = name.split("_", 1)
        if len(parts) < 2:
            continue
        region, var = parts
        regions[region][var] = value
    return regions

def main():
    if len(sys.argv) < 2:
        print("Usage: python build_azure_json.py <input_file> [output_file]")
        sys.exit(1)

    infile = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else "azure_secrets.json"

    with open(infile, encoding="utf-8") as f:
        lines = f.readlines()

    regions = group_by_region(lines)

    if not regions:
        print("No valid exports found in file.")
        sys.exit(1)

    with open(outfile, "w", encoding="utf-8") as f:
        json.dump(regions, f, indent=2, sort_keys=True)

    print(f"✅ Wrote {len(regions)} regions to {outfile}")

if __name__ == "__main__":
    main()

