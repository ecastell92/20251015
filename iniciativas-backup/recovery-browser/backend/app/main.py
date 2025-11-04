import os
import json
from typing import List, Dict

from fastapi import FastAPI, Depends, HTTPException, Header
import boto3
from botocore.config import Config


REGION = os.getenv("AWS_REGION", "eu-west-1")
ASSUME_ROLE_NAME = os.getenv("ASSUME_ROLE_NAME", "CrossAccountBackupReadRole")
CENTRAL_BUCKET_PATTERN = os.getenv("CENTRAL_BUCKET_PATTERN", "central-bck")
API_TOKEN = os.getenv("API_TOKEN")

app = FastAPI(title="Recovery Points Browser")


def auth(x_api_token: str = Header(None)):
    if not API_TOKEN or x_api_token != API_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")


def assume(account_id: str):
    # Fallback: si no se define ASSUME_ROLE_NAME, usar sesión actual
    if not ASSUME_ROLE_NAME:
        return boto3.session.Session(region_name=REGION)

    sts = boto3.client("sts", region_name=REGION, config=Config(retries={"max_attempts": 5}))

    # Si la cuenta solicitada es la misma que la de las credenciales actuales, no asumir
    try:
        current = sts.get_caller_identity().get("Account")
        if current and current == account_id:
            return boto3.session.Session(region_name=REGION)
    except Exception:
        pass

    role_arn = f"arn:aws:iam::{account_id}:role/{ASSUME_ROLE_NAME}"
    creds = sts.assume_role(RoleArn=role_arn, RoleSessionName="recovery-browser")["Credentials"]
    return boto3.session.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=REGION,
    )


def find_central_buckets(sess) -> List[str]:
    s3 = sess.client("s3", config=Config(retries={"max_attempts": 5}))
    resp = s3.list_buckets()
    names = [b.get("Name") for b in resp.get("Buckets", [])]
    return [n for n in names if n and CENTRAL_BUCKET_PATTERN in n]


def list_s3_recovery_points(sess, bucket: str) -> List[Dict]:
    s3 = sess.client("s3", config=Config(retries={"max_attempts": 5}))
    prefixes = [
        "manifests/criticality=Critico/",
        "manifests/criticality=MenosCritico/",
        "manifests/criticality=NoCritico/",
    ]
    items: List[Dict] = []
    for pfx in prefixes:
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=pfx):
            for o in page.get("Contents", []):
                key = o.get("Key") or ""
                if not key.endswith(".csv"):
                    continue
                parts = {p.split("=")[0]: p.split("=")[1] for p in key.split("/") if "=" in p}
                items.append(
                    {
                        "type": "S3",
                        "bucket": bucket,
                        "key": key,
                        "criticality": parts.get("criticality"),
                        "backup_type": parts.get("backup_type"),
                        "initiative": parts.get("initiative"),
                        "source_bucket": parts.get("bucket"),
                        "window": parts.get("window"),
                        "last_modified": o.get("LastModified").isoformat()
                        if o.get("LastModified")
                        else None,
                    }
                )
    return items


def list_backup_recovery_points(sess) -> List[Dict]:
    backup = sess.client("backup", config=Config(retries={"max_attempts": 5}))
    points: List[Dict] = []
    vaults = backup.list_backup_vaults().get("BackupVaultList", [])
    for v in vaults:
        vault_name = v.get("BackupVaultName")
        paginator = backup.get_paginator("list_recovery_points_by_backup_vault")
        for page in paginator.paginate(BackupVaultName=vault_name):
            for rp in page.get("RecoveryPoints", []):
                points.append(
                    {
                        "type": "AWS_BACKUP",
                        "backup_vault": vault_name,
                        "arn": rp.get("RecoveryPointArn"),
                        "resource_type": rp.get("ResourceType"),
                        "creation_date": rp.get("CreationDate").isoformat()
                        if rp.get("CreationDate")
                        else None,
                        "completion_date": rp.get("CompletionDate").isoformat()
                        if rp.get("CompletionDate")
                        else None,
                        "backup_size_in_bytes": rp.get("BackupSizeInBytes"),
                        "backup_plan_id": rp.get("BackupPlanId"),
                    }
                )
    return points


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/accounts", dependencies=[Depends(auth)])
def accounts():
    with open(os.path.join(os.path.dirname(__file__), "../config/accounts.json"), "r", encoding="utf-8") as f:
        return json.load(f)


@app.get("/recovery-points/{account_id}", dependencies=[Depends(auth)])
def recovery_points(account_id: str):
    sess = assume(account_id)
    s3_points: List[Dict] = []
    for b in find_central_buckets(sess):
        s3_points.extend(list_s3_recovery_points(sess, b))
    backup_points = list_backup_recovery_points(sess)
    return {"account_id": account_id, "s3": s3_points, "aws_backup": backup_points}


