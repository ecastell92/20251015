#!/usr/bin/env python3
"""
Summarize latest S3 Batch Operations report CSVs in the central backup bucket.

- Finds the most recent CSV under a given prefix (defaults to incremental reports)
- Prints a compact summary by Result/Status/ErrorCode and shows a few sample rows

Usage:
  python scripts/s3_batch_report_summary.py --bucket <central-bucket> [--prefix reports/] [--profile <aws-profile>] [--region eu-west-1]

Examples:
  python scripts/s3_batch_report_summary.py --bucket 00-dev-central-bcks-mvp-bck-001-aws-notinet --region eu-west-1
  python scripts/s3_batch_report_summary.py --bucket <bucket> --prefix reports/criticality=Critico/backup_type=incremental/ --profile prod
"""

import argparse
import csv
import io
from datetime import datetime, timezone
from typing import Optional

import boto3


def find_latest_csv(s3, bucket: str, prefix: str) -> Optional[str]:
    paginator = s3.get_paginator("list_objects_v2")
    latest = None
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj.get("Key", "")
            if not key.lower().endswith(".csv"):
                continue
            lm = obj.get("LastModified")
            if latest is None or (lm and lm > latest[1]):
                latest = (key, lm)
    return latest[0] if latest else None


def summarize_csv(s3, bucket: str, key: str):
    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read()
    # Handle potential gzip transparently if needed in the future
    text = body.decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text))

    total = 0
    by_result = {}
    by_error = {}
    samples = []

    for row in reader:
        total += 1
        # Robust: try common field names across report formats
        result = row.get("Result") or row.get("Status") or row.get("OperationStatus") or row.get("TaskStatus") or ""
        err_code = row.get("ErrorCode") or row.get("FailureCode") or row.get("Error") or ""

        by_result[result] = by_result.get(result, 0) + 1
        if err_code:
            by_error[err_code] = by_error.get(err_code, 0) + 1

        if len(samples) < 5:
            samples.append({k: row.get(k, "") for k in list(row.keys())[:6]})

    print(f"Report: s3://{bucket}/{key}")
    print(f"Total rows: {total}")
    print("By result/status:")
    for k, v in sorted(by_result.items(), key=lambda x: (-x[1], x[0] or "")):
        print(f"  {k or '(blank)'}: {v}")
    if by_error:
        print("By error code:")
        for k, v in sorted(by_error.items(), key=lambda x: (-x[1], x[0])):
            print(f"  {k}: {v}")
    if samples:
        print("Samples:")
        for s in samples:
            print(f"  {s}")


def main():
    ap = argparse.ArgumentParser(description="Summarize latest S3 Batch report CSV")
    ap.add_argument("--bucket", required=True, help="Central backup bucket name")
    ap.add_argument("--prefix", default="reports/", help="Report prefix to search (default: reports/)")
    ap.add_argument("--profile", help="AWS profile")
    ap.add_argument("--region", help="AWS region")
    args = ap.parse_args()

    session = boto3.session.Session(profile_name=args.profile, region_name=args.region)
    s3 = session.client("s3")

    key = find_latest_csv(s3, args.bucket, args.prefix)
    if not key:
        print(f"No CSV report found under s3://{args.bucket}/{args.prefix}")
        return 1

    summarize_csv(s3, args.bucket, key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

