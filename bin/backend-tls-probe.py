#!/usr/bin/env python3
"""Probe a configured HTTPS origin using exactly the route's explicit trust."""
import http.client
import signal
import socket
import ssl
import sys
from urllib.parse import urlsplit

import route_features as features


class VerifiedConnection(http.client.HTTPSConnection):
    def __init__(self, identity, peer, port, context, timeout):
        super().__init__(identity, port, context=context, timeout=timeout)
        self.peer = peer

    def connect(self):
        raw = socket.create_connection((self.peer, self.port), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def probe(record, origin, path, timeout):
    settings = features.from_record(record, record.get("PROVIDER_ROUTE") == "1")
    tls = settings["backend_tls"] or settings["backend_tls_peers"].get(origin)
    targets = [record.get("TARGET", "")] + (record.get("BACKENDS") or "").split(",")
    if not tls or origin not in targets or record.get("HEALTH_ENABLED") != "1":
        raise ValueError("Not a configured TLS health endpoint")
    features.validate_tls_targets(tls, [origin])
    if not features.literal_path(path) or not 1 <= timeout <= 3600:
        raise ValueError("Invalid health path or timeout")
    peer = urlsplit(origin)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.load_verify_locations(cadata=tls["ca_certificate"])
    identity = tls["hostname"]
    conn = VerifiedConnection(identity, peer.hostname, peer.port, context, timeout)
    try:
        # Preserve an explicit backend Host rewrite, otherwise use the
        # certificate identity for the synthetic health request.
        rewrite = settings.get("rewrite") or {}
        conn.request("GET", path, headers={"Host": rewrite.get("hostname") or identity,
                                           "Connection": "close"})
        response = conn.getresponse()
        return response.status
    finally:
        conn.close()


def expired(signum, frame):
    raise TimeoutError("Health probe timed out")


def main():
    try:
        _, route, origin, path, seconds = sys.argv
        timeout = int(seconds)
        if not 1 <= timeout <= 3600:
            raise ValueError("Invalid timeout")
        signal.signal(signal.SIGALRM, expired)
        signal.alarm(timeout)
        try:
            print(probe(features.kv(route), origin, path, timeout))
        finally:
            signal.alarm(0)
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
