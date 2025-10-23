#!/usr/bin/env python3
"""
Restore AWS configuration snapshots produced by backup_configurations.

Reads JSON artifacts stored under:
  backup/criticality=<Critico|MenosCritico|NoCritico>/backup_type=configurations/
    initiative=<initiative>/service=<service>/year=/month=/day=/hour=/...

Supports restoring a subset of services with dry-run by default.

Examples:
  python scripts/restore_configurations.py \
    --bucket <central-bucket> --initiative mvp --criticality Critico \
    --services s3,eventbridge --latest --region eu-west-1 --profile prod --yes

  python scripts/restore_configurations.py \
    --bucket <central-bucket> --initiative mvp --criticality Critico \
    --service s3 --timestamp 2025-10-21T19:30:00Z --dry-run
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional, Tuple

import boto3
from botocore.exceptions import ClientError


SERVICES = [
    "s3", "eventbridge", "stepfunctions", "glue", "athena", "lambda", "iam", "dynamodb", "rds"
]

# Some services are stored under different service folder names in the snapshot
# paths. This map translates the CLI service name -> stored folder name.
SERVICE_ALIAS = {
    "s3": "s3_buckets",
    "lambda": "lambda_functions",
}


def build_prefix(initiative: str, criticality: str, service: str) -> str:
    stored = SERVICE_ALIAS.get(service, service)
    return (
        f"backup/criticality={criticality}/backup_type=configurations/"
        f"initiative={initiative}/service={stored}/"
    )


def find_latest_key(s3, bucket: str, prefix: str) -> Optional[str]:
    paginator = s3.get_paginator("list_objects_v2")
    latest: Optional[Tuple[str, datetime]] = None
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj.get("Key", "")
            if not key.lower().endswith(".json"):
                continue
            lm = obj.get("LastModified")
            if latest is None or (lm and lm > latest[1]):
                latest = (key, lm)
    return latest[0] if latest else None


def load_json(s3, bucket: str, key: str) -> Dict[str, Any]:
    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read().decode("utf-8")
    return json.loads(body)


# ------------------------------ Restorers ----------------------------------

def restore_s3(cfg: Dict[str, Any], s3, *, yes: bool, apply_inventory_and_notifications: bool = False) -> None:
    buckets: List[Dict[str, Any]] = cfg.get("buckets", [])
    for b in buckets:
        name = b.get("bucket_name")
        if not name:
            continue

        # Policy
        policy = b.get("policy")
        if policy:
            print(f"S3: put-bucket-policy {name}")
            if yes:
                s3.put_bucket_policy(Bucket=name, Policy=json.dumps(policy))

        # Lifecycle
        rules = b.get("lifecycle", [])
        if rules:
            print(f"S3: put-bucket-lifecycle-configuration {name}")
            if yes:
                s3.put_bucket_lifecycle_configuration(
                    Bucket=name,
                    LifecycleConfiguration={"Rules": rules},
                )

        # Encryption
        enc = b.get("encryption")
        if enc:
            print(f"S3: put-bucket-encryption {name}")
            if yes:
                s3.put_bucket_encryption(
                    Bucket=name,
                    ServerSideEncryptionConfiguration=enc,
                )

        # CORS
        cors = b.get("cors", [])
        if cors:
            print(f"S3: put-bucket-cors {name}")
            if yes:
                s3.put_bucket_cors(Bucket=name, CORSConfiguration={"CORSRules": cors})

        # Replication
        repl = b.get("replication")
        if repl:
            print(f"S3: put-bucket-replication {name}")
            if yes:
                s3.put_bucket_replication(
                    Bucket=name,
                    ReplicationConfiguration=repl,
                )

        if apply_inventory_and_notifications:
            inv = b.get("inventory", [])
            if inv:
                print(f"S3: restore inventory entries for {name}")
                if yes:
                    # Overwrite existing inventory configurations
                    # Note: API requires one-by-one PutBucketInventoryConfiguration
                    for entry in inv:
                        inv_id = entry.get("Id") or entry.get("id")
                        if not inv_id:
                            continue
                        s3.put_bucket_inventory_configuration(
                            Bucket=name, Id=inv_id, InventoryConfiguration=entry
                        )
            notif = b.get("notifications", {})
            if notif:
                print(f"S3: put-bucket-notification-configuration {name}")
                if yes:
                    s3.put_bucket_notification_configuration(
                        Bucket=name, NotificationConfiguration=notif
                    )


def restore_eventbridge(cfg: Dict[str, Any], events, *, yes: bool) -> None:
    for r in cfg.get("rules", []):
        name = r.get("name")
        if not name:
            continue
        kwargs: Dict[str, Any] = {
            "Name": name,
            "State": r.get("state", "ENABLED"),
            "Description": r.get("description", ""),
        }
        sched = r.get("schedule_expression")
        patt = r.get("event_pattern")
        role_arn = r.get("role_arn") or None
        if role_arn:
            kwargs["RoleArn"] = role_arn
        if sched:
            kwargs["ScheduleExpression"] = sched
        if patt:
            kwargs["EventPattern"] = patt
        print(f"Events: put-rule {name}")
        if yes:
            events.put_rule(**kwargs)
        targets = r.get("targets", [])
        if targets:
            print(f"Events: put-targets {name} ({len(targets)})")
            if yes:
                events.put_targets(Rule=name, Targets=targets)


def restore_stepfunctions(cfg: Dict[str, Any], sfn, *, yes: bool) -> None:
    for sm in cfg.get("state_machines", []):
        name = sm.get("name")
        if not name:
            continue
        definition = json.dumps(sm.get("definition", {}))
        role_arn = sm.get("role_arn")
        print(f"SFN: create/update state machine {name}")
        if not yes:
            continue
        # Try update, else create
        try:
            # Need ARN to update; attempt by listing and matching name
            found_arn = None
            paginator = sfn.get_paginator("list_state_machines")
            for page in paginator.paginate():
                for item in page.get("stateMachines", []):
                    if item.get("name") == name:
                        found_arn = item.get("stateMachineArn")
                        break
                if found_arn:
                    break
            if found_arn:
                sfn.update_state_machine(stateMachineArn=found_arn, definition=definition, roleArn=role_arn)
            else:
                sfn.create_state_machine(name=name, definition=definition, roleArn=role_arn, type=sm.get("type", "STANDARD"))
        except ClientError as e:
            print(f"  ERROR: {e}")


def restore_glue(cfg: Dict[str, Any], glue, *, yes: bool) -> None:
    g = cfg
    # Databases
    for db in g.get("databases", []):
        name = db.get("name") or db.get("Name")
        if not name:
            continue
        db_input = {
            "Name": name,
            **({"Description": db.get("description")} if db.get("description") else {}),
            **({"LocationUri": db.get("location_uri")} if db.get("location_uri") else {}),
            **({"Parameters": db.get("parameters")} if db.get("parameters") else {}),
        }
        print(f"Glue: create/update database {name}")
        if yes:
            try:
                glue.create_database(DatabaseInput=db_input)
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "AlreadyExistsException":
                    glue.update_database(Name=name, DatabaseInput=db_input)
                else:
                    print(f"  ERROR: {e}")

    # Tables (best-effort: requires DatabaseName + minimal TableInput)
    for t in g.get("tables", []):
        dbname = t.get("database_name") or t.get("DatabaseName")
        table_input = t.get("table_input") or t.get("Table") or {}
        name = table_input.get("Name") or t.get("name")
        if not (dbname and name):
            continue
        print(f"Glue: create/update table {dbname}.{name}")
        if yes:
            try:
                glue.create_table(DatabaseName=dbname, TableInput=table_input)
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "AlreadyExistsException":
                    glue.update_table(DatabaseName=dbname, TableInput=table_input)
                else:
                    print(f"  ERROR: {e}")

    # Jobs
    for job in g.get("jobs", []):
        name = job.get("name") or job.get("Name")
        if not name:
            continue
        print(f"Glue: create/update job {name}")
        if yes:
            try:
                glue.create_job(**{k[0].upper()+k[1:]: v for k, v in job.items() if v is not None})
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "AlreadyExistsException":
                    glue.update_job(JobName=name, JobUpdate={k[0].upper()+k[1:]: v for k, v in job.items() if v is not None})
                else:
                    print(f"  ERROR: {e}")

    # Crawlers
    for cr in g.get("crawlers", []):
        name = cr.get("name") or cr.get("Name")
        if not name:
            continue
        print(f"Glue: create/update crawler {name}")
        if yes:
            try:
                glue.create_crawler(**{k[0].upper()+k[1:]: v for k, v in cr.items() if v is not None})
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "AlreadyExistsException":
                    glue.update_crawler(Name=name, **{k[0].upper()+k[1:]: v for k, v in cr.items() if v is not None})
                else:
                    print(f"  ERROR: {e}")


def restore_athena(cfg: Dict[str, Any], athena, *, yes: bool) -> None:
    a = cfg
    # Workgroups
    for wg in a.get("workgroups", []):
        name = wg.get("name") or wg.get("Name")
        if not name:
            continue
        conf = wg.get("configuration") or wg.get("Configuration") or {}
        print(f"Athena: create/update workgroup {name}")
        if yes:
            try:
                athena.create_work_group(Name=name, Configuration=conf, Description=wg.get("description", ""))
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "InvalidRequestException":
                    athena.update_work_group(WorkGroup=name, ConfigurationUpdates={"EnforceWorkGroupConfiguration": conf.get("EnforceWorkGroupConfiguration", False), "ResultConfigurationUpdates": conf.get("ResultConfiguration", {})}, Description=wg.get("description", ""))
                else:
                    print(f"  ERROR: {e}")

    # Data catalogs
    for dc in a.get("data_catalogs", []):
        name = dc.get("name") or dc.get("Name")
        if not name:
            continue
        typ = dc.get("type") or dc.get("Type") or "GLUE"
        params = dc.get("parameters") or dc.get("Parameters") or {}
        print(f"Athena: create/update data catalog {name}")
        if yes:
            try:
                athena.create_data_catalog(Name=name, Type=typ, Description=dc.get("description", ""), Parameters=params)
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") == "InvalidRequestException":
                    athena.update_data_catalog(Name=name, Type=typ, Description=dc.get("description", ""), Parameters=params)
                else:
                    print(f"  ERROR: {e}")

    # Named queries
    for nq in a.get("named_queries", []):
        name = nq.get("name") or nq.get("Name")
        q = nq.get("query_string") or nq.get("QueryString")
        wg = nq.get("work_group") or nq.get("WorkGroup") or "primary"
        if not (name and q):
            continue
        print(f"Athena: create named query {name}")
        if yes:
            try:
                athena.create_named_query(Name=name, Database=nq.get("database", ""), QueryString=q, WorkGroup=wg, Description=nq.get("description", ""))
            except ClientError as e:
                print(f"  WARN: {e}")


def restore_lambda_cfg(cfg: Dict[str, Any], lam, *, yes: bool) -> None:
    # Configuration-only (no code)
    for fn in cfg.get("functions", []):
        name = fn.get("function_name") or fn.get("FunctionName") or fn.get("name")
        if not name:
            continue
        print(f"Lambda: update configuration {name}")
        if yes:
            kwargs: Dict[str, Any] = {}
            for k_src, k_dst in [
                ("role", "Role"), ("handler", "Handler"), ("runtime", "Runtime"),
                ("memory_size", "MemorySize"), ("timeout", "Timeout"),
                ("dead_letter_config", "DeadLetterConfig"),
                ("tracing_config", "TracingConfig"), ("vpc_config", "VpcConfig"),
                ("environment", "Environment"), ("layers", "Layers"),
            ]:
                v = fn.get(k_src) or fn.get(k_dst)
                if v is not None:
                    kwargs[k_dst] = v
            if kwargs:
                try:
                    lam.update_function_configuration(FunctionName=name, **kwargs)
                except ClientError as e:
                    print(f"  ERROR: {e}")


def restore_iam(cfg: Dict[str, Any], iam, *, yes: bool) -> None:
    for role in cfg.get("roles", []):
        name = role.get("role_name") or role.get("RoleName") or role.get("name")
        if not name:
            continue
        trust = role.get("assume_role_policy_document") or role.get("AssumeRolePolicyDocument")
        print(f"IAM: create/ensure role {name}")
        if yes and trust:
            try:
                iam.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust))
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") != "EntityAlreadyExists":
                    print(f"  ERROR: {e}")
        # Attach managed policies
        for p in role.get("attached_policies", []):
            arn = p.get("PolicyArn") or p.get("policy_arn") or p.get("arn")
            if not arn:
                continue
            print(f"IAM: attach policy {arn} to {name}")
            if yes:
                try:
                    iam.attach_role_policy(RoleName=name, PolicyArn=arn)
                except ClientError as e:
                    print(f"  WARN: {e}")
        # Inline policies
        for ip in role.get("inline_policies", []):
            pol_name = ip.get("PolicyName") or ip.get("policy_name") or ip.get("name")
            doc = ip.get("PolicyDocument") or ip.get("policy_document")
            if not (pol_name and doc):
                continue
            print(f"IAM: put inline policy {pol_name} on {name}")
            if yes:
                iam.put_role_policy(RoleName=name, PolicyName=pol_name, PolicyDocument=json.dumps(doc))


def restore_dynamodb(cfg: Dict[str, Any], ddb, *, yes: bool) -> None:
    for t in cfg.get("tables", []):
        name = t.get("table_name") or t.get("TableName")
        if not name:
            continue
        print(f"DynamoDB: create table {name}")
        if yes:
            try:
                params: Dict[str, Any] = {
                    "TableName": name,
                    "AttributeDefinitions": t.get("attribute_definitions") or t.get("AttributeDefinitions") or [],
                    "KeySchema": t.get("key_schema") or t.get("KeySchema") or [],
                }
                billing = t.get("billing_mode") or (t.get("BillingModeSummary") or {}).get("BillingMode")
                if billing == "PAY_PER_REQUEST":
                    params["BillingMode"] = billing
                else:
                    pt = t.get("provisioned_throughput") or t.get("ProvisionedThroughput")
                    if pt:
                        params["ProvisionedThroughput"] = {"ReadCapacityUnits": pt.get("ReadCapacityUnits", 5), "WriteCapacityUnits": pt.get("WriteCapacityUnits", 5)}
                for key in ["LocalSecondaryIndexes", "GlobalSecondaryIndexes", "StreamSpecification", "SSESpecification"]:
                    v = t.get(key) or t.get(key.lower())
                    if v:
                        params[key] = v
                ddb.create_table(**params)
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") != "ResourceInUseException":
                    print(f"  ERROR: {e}")


def restore_rds(cfg: Dict[str, Any], rds, *, yes: bool) -> None:
    # Parameter groups
    for pg in cfg.get("parameter_groups", []):
        name = pg.get("name") or pg.get("DBParameterGroupName")
        fam = pg.get("db_parameter_group_family") or pg.get("DBParameterGroupFamily")
        desc = pg.get("description") or pg.get("Description", "restored")
        if not (name and fam):
            continue
        print(f"RDS: create/ensure parameter group {name}")
        if yes:
            try:
                rds.create_db_parameter_group(DBParameterGroupName=name, DBParameterGroupFamily=fam, Description=desc)
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") != "DBParameterGroupAlreadyExists":
                    print(f"  WARN: {e}")
        # Apply parameters if present
        params = pg.get("parameters") or []
        if yes and params:
            try:
                rds.modify_db_parameter_group(DBParameterGroupName=name, Parameters=params)
            except ClientError as e:
                print(f"  WARN: {e}")
    # Subnet groups
    for sg in cfg.get("subnet_groups", []):
        name = sg.get("name") or sg.get("DBSubnetGroupName")
        if not name:
            continue
        print(f"RDS: create/ensure subnet group {name}")
        if yes:
            try:
                rds.create_db_subnet_group(DBSubnetGroupName=name, DBSubnetGroupDescription=sg.get("description", ""), SubnetIds=[s.get("SubnetIdentifier") or s.get("SubnetId") for s in sg.get("subnets", []) if (s.get("SubnetIdentifier") or s.get("SubnetId"))], Tags=[])
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") != "DBSubnetGroupAlreadyExists":
                    print(f"  WARN: {e}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Restore configuration snapshots from central bucket")
    ap.add_argument("--bucket", required=True, help="Central backup bucket name")
    ap.add_argument("--initiative", required=True, help="Initiative name used in the path")
    ap.add_argument("--criticality", default="Critico", choices=["Critico", "MenosCritico", "NoCritico"], help="Criticality path segment")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--latest", action="store_true", help="Use latest snapshot per service")
    group.add_argument("--timestamp", help="ISO timestamp to pick specific snapshot (prefix match)")
    ap.add_argument("--service", dest="services", action="append", help=f"Service to restore ({','.join(SERVICES)})")
    ap.add_argument("--services", help="Comma-separated services to restore")
    ap.add_argument("--all", action="store_true", help="Restore all supported services in dependency order")
    ap.add_argument("--profile", help="AWS profile")
    ap.add_argument("--region", help="AWS region")
    ap.add_argument("--yes", action="store_true", help="Apply changes (default: dry-run)")
    ap.add_argument("--apply-s3-inventory-notifications", action="store_true", help="Also restore S3 Inventory and Notifications")
    args = ap.parse_args()

    # Resolve services
    dependency_order = ["iam", "s3", "eventbridge", "stepfunctions", "glue", "athena", "lambda", "dynamodb", "rds"]
    services: List[str] = []
    if args.all:
        services = dependency_order.copy()
    else:
        if args.services:
            services.extend([s.strip() for s in args.services.split(",") if s.strip()])
        if args.service:
            services.extend(args.service)
        if not services:
            services = ["s3", "eventbridge", "stepfunctions"]
    for s in services:
        if s not in SERVICES:
            print(f"Unsupported service: {s}")
            return 2

    session = boto3.session.Session(profile_name=args.profile, region_name=args.region)
    s3 = session.client("s3")
    events = session.client("events")
    sfn = session.client("stepfunctions")
    glue = session.client("glue")
    athena = session.client("athena")
    lam = session.client("lambda")
    iam = session.client("iam")
    ddb = session.client("dynamodb")
    rds = session.client("rds")

    for svc in services:
        prefix = build_prefix(args.initiative, args.criticality, svc)
        if args.latest:
            key = find_latest_key(s3, args.bucket, prefix)
            if not key:
                print(f"No snapshot found for {svc} under s3://{args.bucket}/{prefix}")
                continue
        else:
            # pick by timestamp substring in key
            key = None
            paginator = s3.get_paginator("list_objects_v2")
            for page in paginator.paginate(Bucket=args.bucket, Prefix=prefix):
                for obj in page.get("Contents", []):
                    k = obj.get("Key", "")
                    if args.timestamp in k:
                        key = k
                        break
                if key:
                    break
            if not key:
                print(f"No snapshot with timestamp '{args.timestamp}' for {svc} under {prefix}")
                continue

        print(f"Loading snapshot: s3://{args.bucket}/{key}")
        cfg = load_json(s3, args.bucket, key)

        if svc == "s3":
            restore_s3(cfg, s3, yes=args.yes, apply_inventory_and_notifications=args.apply_s3_inventory_notifications)
        elif svc == "eventbridge":
            restore_eventbridge(cfg, events, yes=args.yes)
        elif svc == "stepfunctions":
            restore_stepfunctions(cfg, sfn, yes=args.yes)
        elif svc == "glue":
            restore_glue(cfg, glue, yes=args.yes)
        elif svc == "athena":
            restore_athena(cfg, athena, yes=args.yes)
        elif svc == "lambda":
            restore_lambda_cfg(cfg, lam, yes=args.yes)
        elif svc == "iam":
            restore_iam(cfg, iam, yes=args.yes)
        elif svc == "dynamodb":
            restore_dynamodb(cfg, ddb, yes=args.yes)
        elif svc == "rds":
            restore_rds(cfg, rds, yes=args.yes)

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
