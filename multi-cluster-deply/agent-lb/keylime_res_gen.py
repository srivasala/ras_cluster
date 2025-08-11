#!/usr/bin/env python3

import argparse
import os
import sys

def main():
    parser = argparse.ArgumentParser(
        description="Generate Kubernetes manifests with namespace substitution."
    )
    parser.add_argument(
        "--namespace", type=str, required=True, help="Namespace for deployment."
    )
    parser.add_argument(
        "--file",
        type=str,
        required=True,
        help="Input manifest template file.",
    )
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"Error: File not found at {args.file}", file=sys.stderr)
        sys.exit(1)

    with open(args.file, "r") as f:
        content = f.read()

    # Substitute placeholders
    content = content.replace("{{ namespace }}", args.namespace)

    print(content)

if __name__ == "__main__":
    main()
