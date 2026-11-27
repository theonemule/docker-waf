#!/usr/bin/env python3
"""Bound decompression and extract only explicitly permitted tar members."""
import argparse
import contextlib
import gzip
from pathlib import Path
import shutil
import sys
import tarfile

MIB = 1024 * 1024
MAX_ENTRIES = 30000

class ArchiveError(ValueError):
    pass

class BoundedReader:
    def __init__(self, source, limit):
        self.source, self.remaining = source, limit

    def read(self, size=-1):
        # Limit actual decompressed bytes, including PAX/GNU metadata,
        # padding and headers, rather than only declared file sizes.
        size = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        chunk = self.source.read(size)
        self.remaining -= len(chunk)
        if self.remaining < 0:
            raise ArchiveError("Expanded archive exceeds safety limit")
        return chunk

class SafeTarInfo(tarfile.TarInfo):
    @classmethod
    def frombuf(cls, buf, encoding, errors):
        member = super().frombuf(buf, encoding, errors)
        if member.type in (tarfile.XHDTYPE, tarfile.XGLTYPE,
                           tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
            if member.size > MIB:
                raise ArchiveError("Oversized archive metadata")
        if member.type == tarfile.GNUTYPE_SPARSE or member.size < 0:
            raise ArchiveError("Unsupported sparse or invalid archive entry")
        return member

@contextlib.contextmanager
def bounded_tar(path, expanded_limit):
    with gzip.open(path, "rb") as gz:
        source = BoundedReader(gz, expanded_limit)
        with tarfile.open(fileobj=source, mode="r|", tarinfo=SafeTarInfo) as archive:
            yield archive
        # Consume the remainder to verify the gzip CRC and expanded-size
        # limit, even when the tar end marker occurs early.
        while source.read(64 * 1024):
            pass

def checked_parts(name):
    if not name or len(name) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in name) or "\\" in name:
        raise ArchiveError("Invalid archive path")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ArchiveError("Unsafe archive path")
    return parts

def extract(path, destination, prefix=None, limit=128*MIB, compressed_limit=32*MIB, max_entries=MAX_ENTRIES):
    if path.stat().st_size > compressed_limit:
        raise ArchiveError("Compressed archive exceeds safety limit")
    if not destination.is_dir() or any(destination.iterdir()):
        raise ArchiveError("Extraction requires an empty private directory")
    seen = set()
    with bounded_tar(path, limit) as archive:
        for member in archive:
            parts = checked_parts(member.name)
            if prefix and parts[0] != prefix:
                raise ArchiveError("Archive contains unexpected path")
            if member.name in seen or len(seen) >= max_entries:
                raise ArchiveError("Duplicate archive path or too many entries")
            seen.add(member.name)
            if member.issparse() or any(k.startswith("GNU.sparse") for k in member.pax_headers):
                raise ArchiveError("Sparse archives are unsupported")
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 64 * 1024)
                if target.stat().st_size != member.size:
                    raise ArchiveError("Incomplete archive member")
                target.chmod(0o600 | (member.mode & 0o100))
            else:
                raise ArchiveError("Archive contains unsupported filesystem object")
    if not seen:
        raise ArchiveError("Empty archive")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive",type=Path)
    parser.add_argument("destination",type=Path)
    parser.add_argument("--prefix")
    parser.add_argument("--limit-mib",type=int,default=128)
    parser.add_argument("--compressed-mib",type=int,default=32)
    args = parser.parse_args()
    try:
        extract(args.archive,args.destination,args.prefix,args.limit_mib*MIB,args.compressed_mib*MIB)
    except (ArchiveError, OSError, EOFError, tarfile.TarError, RecursionError) as error:
        print("Archive rejected: "+str(error),file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
