#!/usr/bin/env python3

import sys
import os
import json
from jinja2 import Environment, FileSystemLoader

def parse_arg(val):
    """
    Try to parse the argument as JSON.
    If parsing fails, return the string as-is.
    """
    try:
        return json.loads(val)
    except json.JSONDecodeError:
        return val

def render_template():
    """
    A Jinja2 template renderer.

    Usage: python render_template.py <template_file> <key1> <value1> <key2> <value2> ...
    """
    if len(sys.argv) < 2 or (len(sys.argv) - 2) % 2 != 0:
        print(f"Usage: {sys.argv[0]} <template_file> <key> <value> [<key> <value> ...]", file=sys.stderr)
        sys.exit(1)

    template_path = sys.argv[1]
    args = sys.argv[2:]

    template_dir = os.path.dirname(template_path) or "."
    template_name = os.path.basename(template_path)

    if not os.path.exists(template_path):
        print(f"Error: Template file not found at '{template_path}'", file=sys.stderr)
        sys.exit(1)

    try:
        env = Environment(loader=FileSystemLoader(template_dir), trim_blocks=True, lstrip_blocks=True)
        template = env.get_template(template_name)

        # Build context dict with JSON parsing
        context = {}
        for i in range(0, len(args), 2):
            key = args[i]
            value = parse_arg(args[i + 1])
            context[key] = value

        rendered_content = template.render(**context)
        print(rendered_content)

    except Exception as e:
        print(f"Error processing template: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    render_template()

