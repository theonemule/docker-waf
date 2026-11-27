#!/usr/bin/env python3
"""Check release gates, job isolation and non-publishing scheduled qualification."""
from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[1]
path = root / ".github/workflows/build-and-publish.yml"
raw = path.read_text()
workflow = yaml.load(raw, Loader=yaml.BaseLoader)
jobs = workflow["jobs"]
assert "schedule" in workflow["on"]
assert "workflow_call" in workflow["on"]
repeat = yaml.load((root / ".github/workflows/repeatability.yml").read_text(), Loader=yaml.BaseLoader)["jobs"]
assert repeat["first"]["if"] == "github.run_attempt == 1"
assert repeat["second"]["needs"] == "first"
assert repeat["third"]["needs"] == "second"
assert repeat["acceptance"]["needs"] == ["first", "second", "third"]
assert [repeat[k]["with"]["repeat_pass"] for k in ("first", "second", "third")] == ["1", "2", "3"]
assert 'repeat.$REPEAT_PASS' in raw
assert 'if [[ -n "$REPEAT_PASS" ]]; then' in raw
assert not (root / ".github/workflows/monthly-regression.yml").exists()
assert jobs["build-appliance"]["if"] == "needs.validate.outputs.enabled == 'true'"
assert jobs["build-iso"]["strategy"]["fail-fast"] == "false"
assert {entry["variant"] for entry in jobs["build-iso"]["strategy"]["matrix"]["include"]} == {"vm", "baremetal"}
assert jobs["qualify-containers"]["strategy"]["fail-fast"] == "false"
assert set(jobs["qualify-containers"]["strategy"]["matrix"]["suite"]) == {"runtime", "kind", "qemu", "conformance"}
assert set(jobs["qualify-containers"]["needs"]) == {"build-appliance", "build-container"}
assert set(jobs["verify-artifacts"]["needs"]) == {"build-appliance", "build-container", "build-iso", "qualify-containers"}
for name in ("publish-images", "publish-release"):
    assert "verify-artifacts" in jobs[name]["needs"]
    assert jobs[name]["if"] == "needs.build-appliance.outputs.publish == 'true'"
assert "publish-images" in jobs["publish-release"]["needs"]
steps = jobs["qualify-containers"]["steps"]
cleanup = next(s for s in steps if s.get("name") == "Destroy and verify disposable QEMU resources")
assert cleanup["if"] == "always() && matrix.suite == 'qemu'"
assert steps.index(cleanup) < next(i for i,s in enumerate(steps) if s.get("name") == "Preserve QEMU regression evidence")
assert 'bash tests/qemu/cleanup-ci.sh "$QEMU_CI_SCOPE"' in cleanup["run"]
assert "sha256sum -c SHA256SUMS" in raw
assert "github.run_attempt" in raw
assert "scripts/security-scan.sh" in raw and "govulncheck ./..." in raw
assert "test-security-inputs.py" in raw
assert "-fuzz FuzzDecode" in raw
assert "test-provider-dns-pinning.sh" in raw
assert "!feature/security-hardening" in workflow["on"]["push"]["branches"]
assert "feature/security-hardening" in yaml.load((root / ".github/workflows/repeatability.yml").read_text(), Loader=yaml.BaseLoader)["on"]["push"]["branches"]
assert raw.count("Build standalone appliance payload from source") == 1
assert raw.count("Rebuild Kubernetes controller from source") == 1
assert "GITHUB_EVENT_NAME" in raw and '== push' in raw
for job in jobs.values():
    for step in job.get("steps", []):
        if "uses" in step:
            ref = step["uses"].rsplit("@", 1)[1]
            assert len(ref) == 40 and all(ch in "0123456789abcdef" for ch in ref), step["uses"]
versions = dict(line.split("=", 1) for line in (root / "build/versions.env").read_text().splitlines() if "=" in line)
dockerfile = (root / "Dockerfile").read_text()
for key in ("ALPINE_VERSION", "ALPINE_DIGEST"):
    assert f"ARG {key}={versions[key]}" in dockerfile, f"{key} differs between native and container build"
print("PASS isolated ISO and qualification matrices; immutable image handoff, pinned actions, monthly schedule and release gates")
