#!/usr/bin/env python3
"""Exercise the ISO web-admin credential prompt through a real pseudo-terminal."""

import os
import pty
import select
import stat
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "scripts" / "iso-admin-setup.sh"
PASSWORD = "test-ISO-password!2026"


def run_installer(destination, username, password, confirmation, env):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("sh", ["sh", str(INSTALLER), str(destination)], env)

    output = bytearray()

    def expect(marker):
        deadline = time.monotonic() + 10
        marker = marker.encode()
        while marker not in output:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"Timed out waiting for {marker!r}: {bytes(output)!r}")
            ready, _, _ = select.select([fd], [], [], remaining)
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    raise AssertionError(f"Installer closed before {marker!r}") from exc
                if not chunk:
                    raise AssertionError("Installer exited too soon")
                output.extend(chunk)

    try:
        expect("Admin username [admin]: ")
        os.write(fd, (username + "\n").encode())
        expect("Admin password (10-128 characters): ")
        os.write(fd, (password + "\n").encode())
        expect("Confirm admin password: ")
        os.write(fd, (confirmation + "\n").encode())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            child, status = os.waitpid(pid, os.WNOHANG)
            if child:
                return os.waitstatus_to_exitcode(status), bytes(output).decode(errors="replace")
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    output.extend(os.read(fd, 4096))
                except OSError:
                    pass
        raise AssertionError("Installer did not exit")
    finally:
        os.close(fd)
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake_id = bin_dir / "id"
        fake_id.write_text('#!/bin/sh\nif [ "${1:-}" = "-u" ]; then echo 0; else exec /usr/bin/id "$@"; fi\n')
        fake_id.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"

        destination = root / ".admin-setup"
        result, output = run_installer(destination, "", PASSWORD, PASSWORD, env)
        assert result == 0, (result, output)
        assert destination.is_file()
        assert stat.S_IMODE(destination.stat().st_mode) == 0o600
        record = destination.read_text().rstrip("\n")
        user, hashed = record.split(":", 1)
        assert user == "admin"
        assert hashed.startswith("$6$")
        assert PASSWORD not in output and PASSWORD not in record
        salt = hashed.split("$")[2]
        verify = subprocess.check_output(
            ["openssl", "passwd", "-6", "-salt", salt, "-stdin"],
            input=(PASSWORD + "\n").encode(),
        ).decode().strip()
        assert verify == hashed, "The configured password must authenticate"

        bad_destination = root / ".admin-setup-bad"
        result, _ = run_installer(
            bad_destination, "admin", PASSWORD, "wrong-password", env
        )
        assert result != 0, "Mismatch must fail"
        assert not bad_destination.exists(), "Mismatch must not persist credentials"

        print("PASS: interactive ISO web-admin setup, masked password, hash and mismatch")


if __name__ == "__main__":
    main()
