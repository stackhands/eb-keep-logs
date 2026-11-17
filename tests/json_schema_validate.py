#!/usr/bin/env python3
"""Validate one JSON document against a JSON Schema file."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError:
    sys.stderr.write("json_schema_validate: install the jsonschema package\n")
    raise SystemExit(2) from None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("schema", type=Path)
    parser.add_argument("document", type=Path, nargs="?", default="-")
    args = parser.parse_args()
    schema = json.loads(args.schema.read_text(encoding="utf-8"))
    if str(args.document) == "-":
        payload = json.load(sys.stdin)
    else:
        payload = json.loads(args.document.read_text(encoding="utf-8"))
    jsonschema.validate(payload, schema=schema)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())