#!/usr/bin/env python3
"""Fail on detected secrets or fixable high/critical vulnerabilities."""
import json
from pathlib import Path
import sys

def findings(report):
    for result in report.get("Results") or []:
        for secret in result.get("Secrets") or []:
            yield ("secret", secret.get("RuleID", "unknown"), result.get("Target", ""))
        for vuln in result.get("Vulnerabilities") or []:
            if vuln.get("Severity") in ("HIGH", "CRITICAL") and vuln.get("FixedVersion"):
                yield ("vulnerability", vuln.get("VulnerabilityID", "unknown"), vuln.get("PkgName", ""))

def main(directory):
    reports = sorted(Path(directory).glob("*.json"))
    if {p.name for p in reports} != {"source-secrets.json","image-1.json","image-2.json"}:
        raise ValueError("Incomplete scanner reports")
    count = 0
    for path in reports:
        report = json.loads(path.read_text())
        if not isinstance(report, dict) or report.get("SchemaVersion") != 2:
            raise ValueError("Invalid scanner report")
        for kind, identifier, target in findings(report):
            # Do not echo detected secret material or arbitrary snippets.
            print(f"BLOCK {path.name}: {kind} {identifier} {target}")
            count += 1
    print(f"Security scan: {len(reports)} reports; {count} blocking findings")
    return bool(count)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
