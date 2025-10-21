#!/usr/bin/env python3
"""
Cleanup script for S3 backup configurations created by this initiative.

What it does per source bucket:
- Removes the S3 Inventory configuration with Id "AutoBackupInventory" (if present)
- Removes the S3→SQS event notification with Id "BckIncrementalTrigger-SQS" (if present)

Selection of buckets:
- By default, scans Resource Groups Tagging API for S3 buckets tagged BackupEnabled=true
- Alternatively, you can pass explicit bucket names with --bucket <name> (repeatable)

Usage examples:
  python scripts/cleanup_s3_backup_configs.py --yes
  python scripts/cleanup_s3_backup_configs.py --tag-key BackupEnabled --tag-value true --yes
  python scripts/cleanup_s3_backup_configs.py --bucket my-source-a --bucket my-source-b --yes

Requires:
- AWS credentials with permissions to read tags and update S3 bucket notification and inventory config
- boto3 installed (pip install boto3)
"""

import argparse
import sys
from typing import List, Tuple

import boto3
from botocore.exceptions import ClientError



DEFAULT_TAG_KEY = "BackupEnabled"
DEFAULT_TAG_VALUE = "true"
INVENTORY_ID = "AutoBackupInventory"
NOTIFICATION_ID = "BckIncrementalTrigger-SQS"


def discover_buckets_by_tag(session: boto3.session.Session, tag_key: str, tag_value: str) -> List[str]:
    client = session.client("resourcegroupstaggingapi")
    buckets: List[str] = []
    paginator = client.get_paginator("get_resources")
    for page in paginator.paginate(
        TagFilters=[{"Key": tag_key, "Values": [tag_value]}],
        ResourceTypeFilters=["s3"],
    ):
        for m in page.get("ResourceTagMappingList", []):
            arn = m.get("ResourceARN", "")
            if arn.startswith("arn:aws:s3:::"):
                buckets.append(arn.split(":::")[-1])
    return buckets


def remove_inventory(session: boto3.session.Session, bucket_name: str) -> Tuple[bool, str]:
    s3 = session.client("s3")
    try:
        # Try to delete known inventory id
        s3.delete_bucket_inventory_configuration(Bucket=bucket_name, Id=INVENTORY_ID)
        return True, f"Deleted inventory '{INVENTORY_ID}'"
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in {"NoSuchConfiguration", "NoSuchBucket"}:
            return False, "No inventory to delete"
        # Some buckets can have different Ids; attempt to list and delete any matching our prefix
        try:
            resp = s3.list_bucket_inventory_configurations(Bucket=bucket_name)
            deleted_any = False
            for cfg in resp.get("InventoryConfigurationList", []):
                inv_id = cfg.get("Id")
                if not inv_id:
                    continue
                try:
                    s3.delete_bucket_inventory_configuration(Bucket=bucket_name, Id=inv_id)
                    deleted_any = True
                except ClientError:
                    pass
            if deleted_any:
                return True, "Deleted one or more inventory configurations"
        except ClientError:
            pass
        return False, f"Inventory delete skipped: {code or str(e)}"


def remove_notification(session: boto3.session.Session, bucket_name: str) -> Tuple[bool, str]:
    s3 = session.client("s3")
    try:
        cfg = s3.get_bucket_notification_configuration(Bucket=bucket_name)
        cfg.pop("ResponseMetadata", None)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in {"NoSuchBucket", "NoSuchConfiguration"}:
            return False, "No notification to remove"
        return False, f"Failed to get notification: {code or str(e)}"

    original = cfg.copy()
    qcfgs = cfg.get("QueueConfigurations", [])
    # Remove our SQS rule by Id
    qcfgs = [q for q in qcfgs if q.get("Id") != NOTIFICATION_ID]
    cfg["QueueConfigurations"] = qcfgs

    # Nothing changed
    if cfg == original:
        return False, "No matching notification found"

    try:
        s3.put_bucket_notification_configuration(Bucket=bucket_name, NotificationConfiguration=cfg)
        return True, f"Removed notification '{NOTIFICATION_ID}'"
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        return False, f"Failed to update notification: {code or str(e)}"


def main() -> int:
    ap = argparse.ArgumentParser(description="Cleanup S3 inventory and S3→SQS notifications for backup")
    ap.add_argument("--tag-key", default=DEFAULT_TAG_KEY, help="Tag key used to discover buckets (default: BackupEnabled)")
    ap.add_argument("--tag-value", default=DEFAULT_TAG_VALUE, help="Tag value used to discover buckets (default: true)")
    ap.add_argument("--bucket", action="append", dest="buckets", help="Bucket name to process (repeatable)")
    ap.add_argument("--yes", action="store_true", help="Do not prompt for confirmation")
    ap.add_argument("--dry-run", action="store_true", help="Only show actions, do not apply changes")
    ap.add_argument("--profile", help="AWS profile to use (overrides env AWS_PROFILE)")
    ap.add_argument("--region", help="AWS region to use (overrides env AWS_REGION)")
    args = ap.parse_args()

    # Build boto3 session (supports --profile/--region)
    try:
        session = boto3.session.Session(profile_name=args.profile, region_name=args.region)
    except Exception as e:
        print(f"Failed to initialize AWS session: {e}")
        return 2

    buckets: List[str]
    if args.buckets:
        buckets = args.buckets
    else:
        print(f"Discovering buckets tagged {args.tag_key}={args.tag_value} ...")
        try:
            buckets = discover_buckets_by_tag(session, args.tag_key, args.tag_value)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code")
            if code in {"UnrecognizedClientException", "InvalidClientTokenId"}:
                print("ERROR: AWS credentials are invalid or expired.")
                print("- If you use SSO: run 'aws sso login' (or 'aws sso login --profile <name>')")
                print("- Else configure credentials: 'aws configure' or set AWS_PROFILE/AWS_ACCESS_KEY_ID...")
                return 2
            raise
        if not buckets:
            print("No buckets found. Nothing to do.")
            return 0

    print(f"Buckets to process: {len(buckets)}")
    for b in buckets:
        print(f" - {b}")

    if not args.yes:
        ans = input("Proceed with cleanup? [y/N]: ").strip().lower()
        if ans not in {"y", "yes"}:
            print("Aborted by user")
            return 1

    any_errors = False

    for bucket in buckets:
        print(f"\n=== Bucket: {bucket} ===")
        if args.dry_run:
            print(f"[DRY-RUN] Would remove inventory '{INVENTORY_ID}' and notification '{NOTIFICATION_ID}'")
            continue

        inv_ok, inv_msg = remove_inventory(session, bucket)
        print(f"Inventory: {inv_msg}")

        notif_ok, notif_msg = remove_notification(session, bucket)
        print(f"Notification: {notif_msg}")

        if not inv_ok and "Failed" in inv_msg:
            any_errors = True
        if not notif_ok and "Failed" in notif_msg:
            any_errors = True

    print("\nCleanup completed.")
    return 1 if any_errors else 0


if __name__ == "__main__":
    sys.exit(main())
