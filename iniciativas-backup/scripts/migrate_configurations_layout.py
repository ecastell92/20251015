#!/usr/bin/env python3
"""
Migrate configuration snapshots from the old layout to the new layout.

Old layout:
  backup/criticality=<Critico|MenosCritico|NoCritico>/backup_type=configurations/
    initiative=<initiative>/service=<service>/year=/month=/day=/hour=/...

New layout:
  backup/configurations/
    initiative=<initiative>/service=<service>/year=/month=/day=/hour=/...

This script copies objects within the same bucket, preserving the suffix
path after the legacy prefix. By default it runs in dry-run mode.

Examples:
  # Dry-run: show what would be copied for all criticalities
  python scripts/migrate_configurations_layout.py \
    --bucket <central-bucket> --region eu-west-1 --profile dev

  # Apply, only initiative=mvp and services s3,iam; delete old after verify
  python scripts/migrate_configurations_layout.py \
    --bucket <central-bucket> --initiative mvp --services s3,iam \
    --yes --delete-source --region eu-west-1 --profile dev
"""

import argparse
import concurrent.futures as futures
import sys
from dataclasses import dataclass
from typing import Iterable, List, Optional, Tuple, Dict

import boto3
from botocore.exceptions import ClientError


CRITICALITIES = ["Critico", "MenosCritico", "NoCritico"]


@dataclass
class Options:
    bucket: str
    region: Optional[str]
    profile: Optional[str]
    criticalities: List[str]
    initiative: Optional[str]
    services: Optional[List[str]]
    yes: bool
    delete_source: bool
    on_exists: str  # skip|overwrite
    concurrency: int


def parse_args() -> Options:
    ap = argparse.ArgumentParser(description="Migrate configuration snapshots to new layout")
    ap.add_argument("--bucket", required=True, help="Central backup bucket name")
    ap.add_argument("--region", help="AWS region")
    ap.add_argument("--profile", help="AWS profile")
    ap.add_argument(
        "--criticalities",
        default=",".join(CRITICALITIES),
        help="Comma-separated criticalities to process (default: all)",
    )
    ap.add_argument("--initiative", help="Only migrate this initiative")
    ap.add_argument("--services", help="Comma-separated services to migrate (match stored service folder)")
    ap.add_argument("--yes", action="store_true", help="Execute copy (default: dry-run)")
    ap.add_argument("--delete-source", action="store_true", help="Delete legacy key after successful copy+verify")
    ap.add_argument(
        "--on-exists",
        choices=["skip", "overwrite"],
        default="skip",
        help="When destination already exists (default: skip)",
    )
    ap.add_argument("--concurrency", type=int, default=8, help="Parallel copy workers (default: 8)")
    args = ap.parse_args()

    criticalities = [c.strip() for c in args.criticalities.split(",") if c.strip()]
    if not all(c in CRITICALITIES for c in criticalities):
        ap.error(f"--criticalities must be subset of: {','.join(CRITICALITIES)}")

    services = None
    if args.services:
        services = [s.strip() for s in args.services.split(",") if s.strip()]

    return Options(
        bucket=args.bucket,
        region=args.region,
        profile=args.profile,
        criticalities=criticalities,
        initiative=args.initiative,
        services=services,
        yes=args.yes,
        delete_source=args.delete_source,
        on_exists=args.on_exists,
        concurrency=args.concurrency,
    )


def iter_legacy_objects(s3, bucket: str, criticality: str) -> Iterable[str]:
    prefix = f"backup/criticality={criticality}/backup_type=configurations/"
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            yield obj.get("Key", "")


def parse_suffix(key: str, legacy_prefix: str) -> Tuple[str, Dict[str, str]]:
    if not key.startswith(legacy_prefix):
        raise ValueError("Key does not start with legacy prefix")
    suffix = key[len(legacy_prefix) :]
    parts = suffix.split("/")
    # Expect at least: initiative=.../service=.../year=.../month=.../day=.../hour=.../file.json
    meta: Dict[str, str] = {}
    for i, part in enumerate(parts[:6]):
        if "=" in part:
            k, v = part.split("=", 1)
            meta[k] = v
    return suffix, meta


def head_key(s3, bucket: str, key: str) -> Optional[Dict]:
    try:
        return s3.head_object(Bucket=bucket, Key=key)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in ("404", "NotFound", "NoSuchKey"):
            return None
        raise


def copy_one(s3, opts: Options, src_key: str) -> Tuple[str, Optional[str]]:
    legacy_prefix = "backup/criticality="
    # Find the actual legacy prefix segment to trim (up to backup_type=configurations/)
    idx = src_key.find("/backup_type=configurations/")
    if idx == -1:
        return (src_key, "skip: not a configurations key")
    head = src_key[: idx + len("/backup_type=configurations/")]
    suffix, meta = parse_suffix(src_key, head)

    ini = meta.get("initiative")
    svc = meta.get("service")
    if opts.initiative and ini != opts.initiative:
        return (src_key, "skip: initiative filter")
    if opts.services and svc not in opts.services:
        return (src_key, "skip: service filter")

    dst_key = f"backup/configurations/{suffix}"

    # Existence check
    dst_head = head_key(s3, opts.bucket, dst_key)
    if dst_head and opts.on_exists == "skip":
        return (src_key, f"exists, skipped -> {dst_key}")

    # Plan message
    action = "COPY" if not dst_head else "OVERWRITE"
    print(f"{action}: s3://{opts.bucket}/{src_key} -> s3://{opts.bucket}/{dst_key}")
    if not opts.yes:
        return (src_key, f"dry-run -> {dst_key}")

    # Copy
    try:
        s3.copy_object(
            Bucket=opts.bucket,
            Key=dst_key,
            CopySource={"Bucket": opts.bucket, "Key": src_key},
            MetadataDirective="COPY",
            ServerSideEncryption="AES256",
        )
    except ClientError as e:
        return (src_key, f"error copying: {e}")

    # Verify by size match
    src_head = head_key(s3, opts.bucket, src_key)
    dst_head = head_key(s3, opts.bucket, dst_key)
    if not (src_head and dst_head and src_head.get("ContentLength") == dst_head.get("ContentLength")):
        return (src_key, "verify failed: size mismatch or head missing")

    # Delete source if requested
    if opts.delete_source:
        try:
            s3.delete_object(Bucket=opts.bucket, Key=src_key)
        except ClientError as e:
            return (src_key, f"copied but delete failed: {e}")
        return (src_key, f"migrated and deleted -> {dst_key}")

    return (src_key, f"migrated -> {dst_key}")


def main() -> int:
    opts = parse_args()
    session = boto3.session.Session(profile_name=opts.profile, region_name=opts.region)
    s3 = session.client("s3")

    # Gather tasks
    to_process: List[str] = []
    for crit in opts.criticalities:
        legacy_prefix = f"backup/criticality={crit}/backup_type=configurations/"
        print(f"Listing {crit}: s3://{opts.bucket}/{legacy_prefix}")
        for key in iter_legacy_objects(s3, opts.bucket, crit):
            # basic sanity: ensure it's under configurations
            if "/backup_type=configurations/" not in key:
                continue
            to_process.append(key)

    if not to_process:
        print("No legacy objects found.")
        return 0

    print(f"Total keys to consider: {len(to_process)}")

    # Process in parallel
    results: List[Tuple[str, Optional[str]]] = []
    with futures.ThreadPoolExecutor(max_workers=max(1, opts.concurrency)) as ex:
        for res in ex.map(lambda k: copy_one(s3, opts, k), to_process):
            results.append(res)

    # Summarize
    moved = sum(1 for _, msg in results if msg and msg.startswith("migrated"))
    skipped = sum(1 for _, msg in results if msg and msg.startswith("skip"))
    exists = sum(1 for _, msg in results if msg and "exists" in msg)
    errors = [(k, m) for k, m in results if m and m.startswith("error")]
    verify_fail = [(k, m) for k, m in results if m and m.startswith("verify failed")]

    print("\nSummary:")
    print(f"  migrated  : {moved}")
    print(f"  skipped   : {skipped}")
    print(f"  existed   : {exists}")
    print(f"  errors    : {len(errors)}")
    print(f"  verify err: {len(verify_fail)}")

    if errors:
        print("\nErrors:")
        for k, m in errors[:20]:
            print(f"  {k}: {m}")
        if len(errors) > 20:
            print(f"  ... and {len(errors)-20} more")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

