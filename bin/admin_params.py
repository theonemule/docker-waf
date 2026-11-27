#!/usr/bin/env python3
"""Strict bounded URL-form decoder; emit NUL-separated key/value pairs."""
import re
import sys
from urllib.parse import unquote_to_bytes

MAX_BYTES = 4 * 1024 * 1024
MAX_FIELDS = 256
BAD_ESCAPE = re.compile(rb"%(?![a-fA-F0-9]{2})")
KEY = re.compile(rb"[A-Za-z_][A-Za-z0-9_-]{0,63}\Z")

def parse(raw):
    if len(raw) > MAX_BYTES:
        raise ValueError("Form too large")
    if raw.count(b"&") >= MAX_FIELDS or BAD_ESCAPE.search(raw) or b"\0" in raw:
        raise ValueError("Malformed form encoding")
    fields = {}
    for pair in raw.split(b"&"):
        if not pair:
            continue
        key, _, value = pair.partition(b"=")
        key = unquote_to_bytes(key.replace(b"+", b" "))
        value = unquote_to_bytes(value.replace(b"+", b" "))
        if not KEY.fullmatch(key) or b"\0" in value or key in fields or len(fields) >= MAX_FIELDS:
            raise ValueError("Invalid or duplicate parameter")
        fields[key] = value
    return fields

def main():
    try:
        fields = parse(sys.stdin.buffer.read(MAX_BYTES + 1))
    except ValueError:
        return 1
    for key, value in fields.items():
        sys.stdout.buffer.write(key + b"\0" + value + b"\0")
    sys.stdout.buffer.write(b"OK\0")
    return 0

if __name__ == "__main__":
    sys.exit(main())
