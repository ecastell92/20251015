"""
Lambda function: backup_configurations

Exporta configuraciones de infraestructura AWS para data lakes:
- S3 buckets (policies, tags, lifecycle, encryption)
- AWS Glue (databases, tables, jobs, crawlers, connections)
- AWS Athena (workgroups, data catalogs, named queries)
- Lambda functions
- IAM roles
- Step Functions
- EventBridge rules
- DynamoDB tables (opcional)
- RDS configurations (opcional)

Guarda todo en formato JSON versionado en el bucket central con estructura Hive.
"""

import boto3
import json
import os
import logging
from datetime import datetime, timezone
from typing import Dict, List, Any
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# Clientes AWS
s3_client = boto3.client("s3")
glue_client = boto3.client("glue")
athena_client = boto3.client("athena")
lambda_client = boto3.client("lambda")
iam_client = boto3.client("iam")
sfn_client = boto3.client("stepfunctions")
events_client = boto3.client("events")
dynamodb_client = boto3.client("dynamodb")
rds_client = boto3.client("rds")
resource_tag_client = boto3.client("resourcegroupstaggingapi")

# Configuración
BACKUP_BUCKET = os.environ["BACKUP_BUCKET"]
INICIATIVA = os.environ.get("INICIATIVA", "backup")
TAG_FILTER_KEY = os.environ.get("TAG_FILTER_KEY", "BackupEnabled")
TAG_FILTER_VALUE = os.environ.get("TAG_FILTER_VALUE", "true")
INCLUDE_GLUE = os.environ.get("INCLUDE_GLUE", "true").lower() == "true"
INCLUDE_ATHENA = os.environ.get("INCLUDE_ATHENA", "true").lower() == "true"
INCLUDE_LAMBDA = os.environ.get("INCLUDE_LAMBDA", "true").lower() == "true"
INCLUDE_IAM = os.environ.get("INCLUDE_IAM", "true").lower() == "true"
INCLUDE_STEPFUNCTIONS = os.environ.get("INCLUDE_STEPFUNCTIONS", "true").lower() == "true"
INCLUDE_EVENTBRIDGE = os.environ.get("INCLUDE_EVENTBRIDGE", "true").lower() == "true"
INCLUDE_DYNAMODB = os.environ.get("INCLUDE_DYNAMODB", "false").lower() == "true"
INCLUDE_RDS = os.environ.get("INCLUDE_RDS", "false").lower() == "true"

# ============================================================================
# S3 CONFIGURATIONS
# ============================================================================

def backup_s3_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de buckets S3."""
    logger.info("Exportando configuraciones de S3...")
    
    buckets_config = []
    
    # Obtener buckets filtrados por tag
    try:
        paginator = resource_tag_client.get_paginator("get_resources")
        bucket_arns = []
        
        for page in paginator.paginate(
            TagFilters=[{"Key": TAG_FILTER_KEY, "Values": [TAG_FILTER_VALUE]}],
            ResourceTypeFilters=["s3"]
        ):
            for resource in page.get("ResourceTagMappingList", []):
                bucket_arns.append(resource["ResourceARN"])
        
        logger.info(f"Encontrados {len(bucket_arns)} buckets con tag {TAG_FILTER_KEY}={TAG_FILTER_VALUE}")
        
        for arn in bucket_arns:
            bucket_name = arn.split(":::")[-1]
            bucket_config = {"bucket_name": bucket_name, "arn": arn}
            
            # Tags
            try:
                tags_response = s3_client.get_bucket_tagging(Bucket=bucket_name)
                bucket_config["tags"] = tags_response.get("TagSet", [])
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchTagSet":
                    logger.warning(f"Error obteniendo tags de {bucket_name}: {e}")
                bucket_config["tags"] = []
            
            # Policy
            try:
                policy_response = s3_client.get_bucket_policy(Bucket=bucket_name)
                bucket_config["policy"] = json.loads(policy_response["Policy"])
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchBucketPolicy":
                    logger.warning(f"Error obteniendo policy de {bucket_name}: {e}")
                bucket_config["policy"] = None
            
            # Lifecycle
            try:
                lifecycle_response = s3_client.get_bucket_lifecycle_configuration(Bucket=bucket_name)
                lifecycle_response.pop("ResponseMetadata", None)
                bucket_config["lifecycle"] = lifecycle_response.get("Rules", [])
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchLifecycleConfiguration":
                    logger.warning(f"Error obteniendo lifecycle de {bucket_name}: {e}")
                bucket_config["lifecycle"] = []
            
            # Encryption
            try:
                encryption_response = s3_client.get_bucket_encryption(Bucket=bucket_name)
                bucket_config["encryption"] = encryption_response.get("ServerSideEncryptionConfiguration", {})
            except ClientError as e:
                if e.response["Error"]["Code"] != "ServerSideEncryptionConfigurationNotFoundError":
                    logger.warning(f"Error obteniendo encryption de {bucket_name}: {e}")
                bucket_config["encryption"] = None
            
            # Versioning
            try:
                versioning_response = s3_client.get_bucket_versioning(Bucket=bucket_name)
                versioning_response.pop("ResponseMetadata", None)
                bucket_config["versioning"] = versioning_response
            except ClientError as e:
                logger.warning(f"Error obteniendo versioning de {bucket_name}: {e}")
                bucket_config["versioning"] = {}
            
            # Inventory
            try:
                inventory_response = s3_client.list_bucket_inventory_configurations(Bucket=bucket_name)
                bucket_config["inventory"] = inventory_response.get("InventoryConfigurationList", [])
            except ClientError as e:
                logger.warning(f"Error obteniendo inventory de {bucket_name}: {e}")
                bucket_config["inventory"] = []
            
            # Notifications
            try:
                notification_response = s3_client.get_bucket_notification_configuration(Bucket=bucket_name)
                notification_response.pop("ResponseMetadata", None)
                bucket_config["notifications"] = notification_response
            except ClientError as e:
                logger.warning(f"Error obteniendo notifications de {bucket_name}: {e}")
                bucket_config["notifications"] = {}
            
            # CORS
            try:
                cors_response = s3_client.get_bucket_cors(Bucket=bucket_name)
                bucket_config["cors"] = cors_response.get("CORSRules", [])
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchCORSConfiguration":
                    logger.warning(f"Error obteniendo CORS de {bucket_name}: {e}")
                bucket_config["cors"] = []
            
            # Replication
            try:
                replication_response = s3_client.get_bucket_replication(Bucket=bucket_name)
                replication_response.pop("ResponseMetadata", None)
                bucket_config["replication"] = replication_response.get("ReplicationConfiguration", {})
            except ClientError as e:
                if e.response["Error"]["Code"] != "ReplicationConfigurationNotFoundError":
                    logger.warning(f"Error obteniendo replication de {bucket_name}: {e}")
                bucket_config["replication"] = {}
            
            buckets_config.append(bucket_config)
            logger.info(f"Exportado: {bucket_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de S3: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_buckets": len(buckets_config),
        "buckets": buckets_config
    }


# ============================================================================
# AWS GLUE CONFIGURATIONS
# ============================================================================

def backup_glue_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de AWS Glue."""
    logger.info("Exportando configuraciones de AWS Glue...")
    
    glue_config = {
        "databases": [],
        "tables": [],
        "jobs": [],
        "crawlers": [],
        "connections": [],
        "triggers": [],
        "workflows": []
    }
    
    try:
        # Databases
        paginator = glue_client.get_paginator("get_databases")
        for page in paginator.paginate():
            for db in page["DatabaseList"]:
                glue_config["databases"].append({
                    "name": db["Name"],
                    "description": db.get("Description", ""),
                    "location_uri": db.get("LocationUri", ""),
                    "parameters": db.get("Parameters", {}),
                    "create_time": str(db.get("CreateTime", ""))
                })
        
        logger.info(f"Exportadas {len(glue_config['databases'])} databases")
        
        # Tables (por cada database)
        for db in glue_config["databases"]:
            db_name = db["name"]
            paginator = glue_client.get_paginator("get_tables")
            for page in paginator.paginate(DatabaseName=db_name):
                for table in page["TableList"]:
                    glue_config["tables"].append({
                        "database": db_name,
                        "name": table["Name"],
                        "description": table.get("Description", ""),
                        "owner": table.get("Owner", ""),
                        "create_time": str(table.get("CreateTime", "")),
                        "update_time": str(table.get("UpdateTime", "")),
                        "retention": table.get("Retention", 0),
                        "storage_descriptor": {
                            "columns": table.get("StorageDescriptor", {}).get("Columns", []),
                            "location": table.get("StorageDescriptor", {}).get("Location", ""),
                            "input_format": table.get("StorageDescriptor", {}).get("InputFormat", ""),
                            "output_format": table.get("StorageDescriptor", {}).get("OutputFormat", ""),
                            "serde_info": table.get("StorageDescriptor", {}).get("SerdeInfo", {})
                        },
                        "partition_keys": table.get("PartitionKeys", []),
                        "table_type": table.get("TableType", ""),
                        "parameters": table.get("Parameters", {})
                    })
        
        logger.info(f"Exportadas {len(glue_config['tables'])} tables")
        
        # Jobs
        paginator = glue_client.get_paginator("get_jobs")
        for page in paginator.paginate():
            for job in page["Jobs"]:
                glue_config["jobs"].append({
                    "name": job["Name"],
                    "description": job.get("Description", ""),
                    "role": job["Role"],
                    "created_on": str(job.get("CreatedOn", "")),
                    "last_modified_on": str(job.get("LastModifiedOn", "")),
                    "execution_property": job.get("ExecutionProperty", {}),
                    "command": job.get("Command", {}),
                    "default_arguments": job.get("DefaultArguments", {}),
                    "connections": job.get("Connections", {}),
                    "max_retries": job.get("MaxRetries", 0),
                    "timeout": job.get("Timeout", 0),
                    "max_capacity": job.get("MaxCapacity"),
                    "worker_type": job.get("WorkerType"),
                    "number_of_workers": job.get("NumberOfWorkers"),
                    "glue_version": job.get("GlueVersion", "")
                })
        
        logger.info(f"Exportados {len(glue_config['jobs'])} jobs")
        
        # Crawlers
        paginator = glue_client.get_paginator("get_crawlers")
        for page in paginator.paginate():
            for crawler in page["Crawlers"]:
                glue_config["crawlers"].append({
                    "name": crawler["Name"],
                    "role": crawler["Role"],
                    "database_name": crawler.get("DatabaseName", ""),
                    "description": crawler.get("Description", ""),
                    "targets": crawler.get("Targets", {}),
                    "schedule": crawler.get("Schedule", {}),
                    "classifiers": crawler.get("Classifiers", []),
                    "table_prefix": crawler.get("TablePrefix", ""),
                    "schema_change_policy": crawler.get("SchemaChangePolicy", {}),
                    "recrawl_policy": crawler.get("RecrawlPolicy", {}),
                    "configuration": crawler.get("Configuration", "")
                })
        
        logger.info(f"Exportados {len(glue_config['crawlers'])} crawlers")
        
        # Connections
        paginator = glue_client.get_paginator("get_connections")
        for page in paginator.paginate():
            for conn in page["ConnectionList"]:
                # No guardar contraseñas por seguridad
                conn_properties = conn.get("ConnectionProperties", {}).copy()
                if "PASSWORD" in conn_properties:
                    conn_properties["PASSWORD"] = "***REDACTED***"
                
                glue_config["connections"].append({
                    "name": conn["Name"],
                    "description": conn.get("Description", ""),
                    "connection_type": conn.get("ConnectionType", ""),
                    "connection_properties": conn_properties,
                    "physical_connection_requirements": conn.get("PhysicalConnectionRequirements", {})
                })
        
        logger.info(f"Exportadas {len(glue_config['connections'])} connections")
        
        # Triggers
        paginator = glue_client.get_paginator("get_triggers")
        for page in paginator.paginate():
            for trigger in page["Triggers"]:
                glue_config["triggers"].append({
                    "name": trigger["Name"],
                    "type": trigger["Type"],
                    "state": trigger.get("State", ""),
                    "description": trigger.get("Description", ""),
                    "schedule": trigger.get("Schedule", ""),
                    "actions": trigger.get("Actions", []),
                    "predicate": trigger.get("Predicate", {})
                })
        
        logger.info(f"Exportados {len(glue_config['triggers'])} triggers")
        
        # Workflows
        paginator = glue_client.get_paginator("list_workflows")
        for page in paginator.paginate():
            for workflow_name in page.get("Workflows", []):
                workflow = glue_client.get_workflow(Name=workflow_name)["Workflow"]
                glue_config["workflows"].append({
                    "name": workflow["Name"],
                    "description": workflow.get("Description", ""),
                    "default_run_properties": workflow.get("DefaultRunProperties", {}),
                    "created_on": str(workflow.get("CreatedOn", "")),
                    "last_modified_on": str(workflow.get("LastModifiedOn", "")),
                    "graph": workflow.get("Graph", {})
                })
        
        logger.info(f"Exportados {len(glue_config['workflows'])} workflows")
    
    except Exception as e:
        logger.error(f"Error en backup de Glue: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_databases": len(glue_config["databases"]),
        "total_tables": len(glue_config["tables"]),
        "total_jobs": len(glue_config["jobs"]),
        "total_crawlers": len(glue_config["crawlers"]),
        "total_connections": len(glue_config["connections"]),
        "total_triggers": len(glue_config["triggers"]),
        "total_workflows": len(glue_config["workflows"]),
        "glue": glue_config
    }


# ============================================================================
# AWS ATHENA CONFIGURATIONS
# ============================================================================

def backup_athena_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de AWS Athena."""
    logger.info("Exportando configuraciones de AWS Athena...")
    
    athena_config = {
        "workgroups": [],
        "data_catalogs": [],
        "named_queries": [],
        "prepared_statements": []
    }
    
    try:
        # Workgroups (no paginator disponible en algunas versiones)
        next_token = None
        while True:
            if next_token:
                resp = athena_client.list_work_groups(NextToken=next_token)
            else:
                resp = athena_client.list_work_groups()
            for wg in resp.get("WorkGroups", []):
                wg_name = wg["Name"]
                
                # Obtener configuración detallada del workgroup
                try:
                    wg_details = athena_client.get_work_group(WorkGroup=wg_name)["WorkGroup"]
                    
                    athena_config["workgroups"].append({
                        "name": wg_name,
                        "state": wg.get("State", ""),
                        "description": wg.get("Description", ""),
                        "creation_time": str(wg.get("CreationTime", "")),
                        "configuration": {
                            "result_configuration": wg_details.get("Configuration", {}).get("ResultConfiguration", {}),
                            "enforce_work_group_configuration": wg_details.get("Configuration", {}).get("EnforceWorkGroupConfiguration", False),
                            "publish_cloud_watch_metrics_enabled": wg_details.get("Configuration", {}).get("PublishCloudWatchMetricsEnabled", False),
                            "bytes_scanned_cutoff_per_query": wg_details.get("Configuration", {}).get("BytesScannedCutoffPerQuery"),
                            "requester_pays_enabled": wg_details.get("Configuration", {}).get("RequesterPaysEnabled", False),
                            "engine_version": wg_details.get("Configuration", {}).get("EngineVersion", {})
                        }
                    })
                except Exception as e:
                    logger.warning(f"Error obteniendo detalles del workgroup {wg_name}: {e}")
            next_token = resp.get("NextToken")
            if not next_token:
                break

        logger.info(f"Exportados {len(athena_config['workgroups'])} workgroups")
        
        # Data Catalogs
        paginator = athena_client.get_paginator("list_data_catalogs")
        for page in paginator.paginate():
            for catalog in page.get("DataCatalogsSummary", []):
                catalog_name = catalog["CatalogName"]
                
                # Obtener detalles del catálogo
                try:
                    catalog_details = athena_client.get_data_catalog(Name=catalog_name)["DataCatalog"]
                    
                    athena_config["data_catalogs"].append({
                        "name": catalog_name,
                        "type": catalog.get("Type", ""),
                        "description": catalog_details.get("Description", ""),
                        "parameters": catalog_details.get("Parameters", {})
                    })
                except Exception as e:
                    logger.warning(f"Error obteniendo detalles del catálogo {catalog_name}: {e}")
        
        logger.info(f"Exportados {len(athena_config['data_catalogs'])} data catalogs")
        
        # Named Queries
        paginator = athena_client.get_paginator("list_named_queries")
        for page in paginator.paginate():
            for query_id in page.get("NamedQueryIds", []):
                try:
                    query = athena_client.get_named_query(NamedQueryId=query_id)["NamedQuery"]
                    
                    athena_config["named_queries"].append({
                        "name": query["Name"],
                        "description": query.get("Description", ""),
                        "database": query["Database"],
                        "query_string": query["QueryString"],
                        "workgroup": query.get("WorkGroup", "")
                    })
                except Exception as e:
                    logger.warning(f"Error obteniendo named query {query_id}: {e}")
        
        logger.info(f"✅ Exportadas {len(athena_config['named_queries'])} named queries")
        
        # Prepared Statements (por workgroup)
        for wg in athena_config["workgroups"]:
            wg_name = wg["name"]
            try:
                paginator = athena_client.get_paginator("list_prepared_statements")
                for page in paginator.paginate(WorkGroup=wg_name):
                    for stmt_summary in page.get("PreparedStatements", []):
                        stmt_name = stmt_summary["StatementName"]
                        
                        try:
                            stmt = athena_client.get_prepared_statement(
                                StatementName=stmt_name,
                                WorkGroup=wg_name
                            )["PreparedStatement"]
                            
                            athena_config["prepared_statements"].append({
                                "name": stmt_name,
                                "workgroup": wg_name,
                                "query_statement": stmt["QueryStatement"],
                                "description": stmt.get("Description", ""),
                                "last_modified_time": str(stmt.get("LastModifiedTime", ""))
                            })
                        except Exception as e:
                            logger.warning(f"Error obteniendo prepared statement {stmt_name}: {e}")
            except Exception as e:
                logger.warning(f"Error listando prepared statements del workgroup {wg_name}: {e}")
        
        logger.info(f"Exportados {len(athena_config['prepared_statements'])} prepared statements")
    
    except Exception as e:
        logger.error(f"Error en backup de Athena: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_workgroups": len(athena_config["workgroups"]),
        "total_data_catalogs": len(athena_config["data_catalogs"]),
        "total_named_queries": len(athena_config["named_queries"]),
        "total_prepared_statements": len(athena_config["prepared_statements"]),
        "athena": athena_config
    }


# ============================================================================
# LAMBDA CONFIGURATIONS
# ============================================================================

def backup_lambda_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de funciones Lambda."""
    logger.info("λ Exportando configuraciones de Lambda...")
    
    functions_config = []
    
    try:
        paginator = lambda_client.get_paginator("list_functions")
        for page in paginator.paginate():
            for func in page["Functions"]:
                func_name = func["FunctionName"]
                
                # Solo backups de funciones relacionadas con backups (opcional: filtrar por tag)
                if not any(keyword in func_name.lower() for keyword in ["backup", "bck", "data"]):
                    continue
                
                # Configuración detallada
                func_config = {
                    "function_name": func_name,
                    "function_arn": func["FunctionArn"],
                    "runtime": func["Runtime"],
                    "role": func["Role"],
                    "handler": func["Handler"],
                    "code_size": func["CodeSize"],
                    "description": func.get("Description", ""),
                    "timeout": func["Timeout"],
                    "memory_size": func["MemorySize"],
                    "last_modified": func["LastModified"],
                    "environment": func.get("Environment", {}).get("Variables", {}),
                    "layers": func.get("Layers", []),
                    "vpc_config": func.get("VpcConfig", {}),
                    "dead_letter_config": func.get("DeadLetterConfig", {}),
                    "tracing_config": func.get("TracingConfig", {})
                }
                
                # Event source mappings
                try:
                    mappings = lambda_client.list_event_source_mappings(FunctionName=func_name)
                    func_config["event_source_mappings"] = mappings.get("EventSourceMappings", [])
                except Exception as e:
                    logger.warning(f"Error obteniendo event sources de {func_name}: {e}")
                    func_config["event_source_mappings"] = []
                
                # Tags
                try:
                    tags = lambda_client.list_tags(Resource=func["FunctionArn"])
                    func_config["tags"] = tags.get("Tags", {})
                except Exception as e:
                    logger.warning(f"Error obteniendo tags de {func_name}: {e}")
                    func_config["tags"] = {}
                
                functions_config.append(func_config)
                logger.info(f"Exportado: {func_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de Lambda: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_functions": len(functions_config),
        "functions": functions_config
    }


# ============================================================================
# IAM CONFIGURATIONS
# ============================================================================

def backup_iam_configurations() -> Dict[str, Any]:
    """Exporta roles y policies de IAM relacionados con backups y data lakes."""
    logger.info("Exportando configuraciones de IAM...")
    
    roles_config = []
    
    try:
        # Filtrar roles relacionados con backups/data
        paginator = iam_client.get_paginator("list_roles")
        for page in paginator.paginate():
            for role in page["Roles"]:
                role_name = role["RoleName"]
                
                # Filtrar solo roles relevantes
                if not any(keyword in role_name.lower() for keyword in ["backup", "bck", "glue", "lambda", "data", "lake", "athena"]):
                    continue
                
                # Policies adjuntas
                attached_policies = []
                policy_paginator = iam_client.get_paginator("list_attached_role_policies")
                for policy_page in policy_paginator.paginate(RoleName=role_name):
                    attached_policies.extend(policy_page["AttachedPolicies"])
                
                # Inline policies
                inline_policies = []
                inline_paginator = iam_client.get_paginator("list_role_policies")
                for inline_page in inline_paginator.paginate(RoleName=role_name):
                    for policy_name in inline_page["PolicyNames"]:
                        policy_doc = iam_client.get_role_policy(RoleName=role_name, PolicyName=policy_name)
                        inline_policies.append({
                            "policy_name": policy_name,
                            "policy_document": policy_doc["PolicyDocument"]
                        })
                
                roles_config.append({
                    "role_name": role_name,
                    "role_arn": role["Arn"],
                    "path": role["Path"],
                    "description": role.get("Description", ""),
                    "create_date": str(role["CreateDate"]),
                    "assume_role_policy": role["AssumeRolePolicyDocument"],
                    "attached_policies": attached_policies,
                    "inline_policies": inline_policies,
                    "max_session_duration": role.get("MaxSessionDuration", 3600)
                })
                
                logger.info(f"Exportado: {role_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de IAM: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_roles": len(roles_config),
        "roles": roles_config
    }


# ============================================================================
# STEP FUNCTIONS CONFIGURATIONS
# ============================================================================

def backup_stepfunctions_configurations() -> Dict[str, Any]:
    """Exporta definiciones de Step Functions."""
    logger.info("Exportando configuraciones de Step Functions...")
    
    state_machines_config = []
    
    try:
        paginator = sfn_client.get_paginator("list_state_machines")
        for page in paginator.paginate():
            for sm in page["stateMachines"]:
                sm_arn = sm["stateMachineArn"]
                sm_name = sm["name"]
                
                # Filtrar solo state machines relevantes
                if not any(keyword in sm_name.lower() for keyword in ["backup", "bck", "data"]):
                    continue
                
                # Obtener definición completa
                sm_details = sfn_client.describe_state_machine(stateMachineArn=sm_arn)
                
                state_machines_config.append({
                    "name": sm_name,
                    "arn": sm_arn,
                    "type": sm["type"],
                    "status": sm.get("status", ""),
                    "creation_date": str(sm["creationDate"]),
                    "role_arn": sm_details["roleArn"],
                    "definition": json.loads(sm_details["definition"]),
                    "logging_configuration": sm_details.get("loggingConfiguration", {}),
                    "tracing_configuration": sm_details.get("tracingConfiguration", {})
                })
                
                logger.info(f"✅ Exportado: {sm_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de Step Functions: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_state_machines": len(state_machines_config),
        "state_machines": state_machines_config
    }


# ============================================================================
# EVENTBRIDGE CONFIGURATIONS
# ============================================================================

def backup_eventbridge_configurations() -> Dict[str, Any]:
    """Exporta reglas de EventBridge."""
    logger.info("Exportando configuraciones de EventBridge...")
    
    rules_config = []
    
    try:
        paginator = events_client.get_paginator("list_rules")
        for page in paginator.paginate():
            for rule in page["Rules"]:
                rule_name = rule["Name"]
                
                # Filtrar solo reglas relevantes
                if not any(keyword in rule_name.lower() for keyword in ["backup", "bck", "data", "sweep"]):
                    continue
                
                # Targets
                targets = events_client.list_targets_by_rule(Rule=rule_name)
                
                rules_config.append({
                    "name": rule_name,
                    "arn": rule["Arn"],
                    "state": rule["State"],
                    "description": rule.get("Description", ""),
                    "schedule_expression": rule.get("ScheduleExpression", ""),
                    "event_pattern": rule.get("EventPattern", ""),
                    "role_arn": rule.get("RoleArn", ""),
                    "targets": targets.get("Targets", [])
                })
                
                logger.info(f"Exportado: {rule_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de EventBridge: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_rules": len(rules_config),
        "rules": rules_config
    }


# ============================================================================
# DYNAMODB CONFIGURATIONS (Opcional)
# ============================================================================

def backup_dynamodb_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de tablas DynamoDB."""
    logger.info("Exportando configuraciones de DynamoDB...")
    
    tables_config = []
    
    try:
        paginator = dynamodb_client.get_paginator("list_tables")
        for page in paginator.paginate():
            for table_name in page["TableNames"]:
                # Describir tabla
                table_desc = dynamodb_client.describe_table(TableName=table_name)["Table"]
                
                tables_config.append({
                    "table_name": table_name,
                    "table_arn": table_desc["TableArn"],
                    "table_status": table_desc["TableStatus"],
                    "creation_date_time": str(table_desc["CreationDateTime"]),
                    "key_schema": table_desc["KeySchema"],
                    "attribute_definitions": table_desc["AttributeDefinitions"],
                    "table_size_bytes": table_desc.get("TableSizeBytes", 0),
                    "item_count": table_desc.get("ItemCount", 0),
                    "billing_mode": table_desc.get("BillingModeSummary", {}).get("BillingMode", ""),
                    "global_secondary_indexes": table_desc.get("GlobalSecondaryIndexes", []),
                    "local_secondary_indexes": table_desc.get("LocalSecondaryIndexes", []),
                    "stream_specification": table_desc.get("StreamSpecification", {}),
                    "sse_description": table_desc.get("SSEDescription", {})
                })
                
                logger.info(f"Exportado: {table_name}")
    
    except Exception as e:
        logger.error(f"Error en backup de DynamoDB: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_tables": len(tables_config),
        "tables": tables_config
    }


# ============================================================================
# RDS CONFIGURATIONS (Opcional)
# ============================================================================

def backup_rds_configurations() -> Dict[str, Any]:
    """Exporta configuraciones de RDS."""
    logger.info("Exportando configuraciones de RDS...")
    
    rds_config = {
        "instances": [],
        "clusters": [],
        "parameter_groups": [],
        "subnet_groups": []
    }
    
    try:
        # DB Instances
        paginator = rds_client.get_paginator("describe_db_instances")
        for page in paginator.paginate():
            for instance in page["DBInstances"]:
                rds_config["instances"].append({
                    "db_instance_identifier": instance["DBInstanceIdentifier"],
                    "db_instance_arn": instance["DBInstanceArn"],
                    "engine": instance["Engine"],
                    "engine_version": instance["EngineVersion"],
                    "db_instance_class": instance["DBInstanceClass"],
                    "storage_type": instance.get("StorageType", ""),
                    "allocated_storage": instance.get("AllocatedStorage", 0),
                    "master_username": instance.get("MasterUsername", ""),
                    "endpoint": instance.get("Endpoint", {}),
                    "vpc_security_groups": instance.get("VpcSecurityGroups", []),
                    "db_parameter_groups": instance.get("DBParameterGroups", []),
                    "db_subnet_group": instance.get("DBSubnetGroup", {}),
                    "backup_retention_period": instance.get("BackupRetentionPeriod", 0),
                    "preferred_backup_window": instance.get("PreferredBackupWindow", ""),
                    "multi_az": instance.get("MultiAZ", False),
                    "storage_encrypted": instance.get("StorageEncrypted", False),
                    "kms_key_id": instance.get("KmsKeyId", "")
                })
        
        logger.info(f"Exportadas {len(rds_config['instances'])} instancias RDS")
        
        # Parameter Groups
        param_paginator = rds_client.get_paginator("describe_db_parameter_groups")
        for page in param_paginator.paginate():
            for pg in page["DBParameterGroups"]:
                rds_config["parameter_groups"].append({
                    "name": pg["DBParameterGroupName"],
                    "family": pg["DBParameterGroupFamily"],
                    "description": pg.get("Description", ""),
                    "arn": pg["DBParameterGroupArn"]
                })
        
        logger.info(f"Exportados {len(rds_config['parameter_groups'])} parameter groups")
        
        # Subnet Groups
        subnet_paginator = rds_client.get_paginator("describe_db_subnet_groups")
        for page in subnet_paginator.paginate():
            for sg in page["DBSubnetGroups"]:
                rds_config["subnet_groups"].append({
                    "name": sg["DBSubnetGroupName"],
                    "description": sg.get("DBSubnetGroupDescription", ""),
                    "vpc_id": sg.get("VpcId", ""),
                    "subnets": sg.get("Subnets", []),
                    "arn": sg["DBSubnetGroupArn"]
                })
        
        logger.info(f"Exportados {len(rds_config['subnet_groups'])} subnet groups")
    
    except Exception as e:
        logger.error(f"Error en backup de RDS: {e}", exc_info=True)
        raise
    
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_instances": len(rds_config["instances"]),
        "total_parameter_groups": len(rds_config["parameter_groups"]),
        "total_subnet_groups": len(rds_config["subnet_groups"]),
        "rds": rds_config
    }


# ============================================================================
# SAVE TO S3 - Estructura Hive Consistente
# ============================================================================

def save_to_s3(data: Dict[str, Any], service: str, timestamp: str) -> str:
    """
    Guarda las configuraciones en S3 usando estructura Hive consistente.
    
    Ruta: backup/criticality=Critico/backup_type=configurations/
          initiative={INICIATIVA}/service={service}/
          year=YYYY/month=MM/day=DD/hour=HH/{service}_YYYYMMDD_HHMMSS.json
    """
    dt = datetime.fromisoformat(timestamp)
    
    # Estructura consistente estilo Hive
    key = (
        f"backup/criticality=Critico/backup_type=configurations/"
        f"initiative={INICIATIVA}/service={service}/"
        f"year={dt.strftime('%Y')}/month={dt.strftime('%m')}/"
        f"day={dt.strftime('%d')}/hour={dt.strftime('%H')}/"
        f"{service}_{dt.strftime('%Y%m%d_%H%M%S')}.json"
    )
    
    try:
        s3_client.put_object(
            Bucket=BACKUP_BUCKET,
            Key=key,
            Body=json.dumps(data, indent=2, default=str),
            ContentType="application/json",
            ServerSideEncryption="AES256"
        )
        logger.info(f"Guardado: s3://{BACKUP_BUCKET}/{key}")
        return key
    except Exception as e:
        logger.error(f"Error guardando {service} en S3: {e}", exc_info=True)
        raise


# ============================================================================
# LAMBDA HANDLER
# ============================================================================

def lambda_handler(event, context):
    """Handler principal."""
    timestamp = datetime.now(timezone.utc).isoformat()
    logger.info(f"Iniciando backup de configuraciones - {timestamp}")
    
    summary = {
        "timestamp": timestamp,
        "services_backed_up": [],
        "total_resources": 0,
        "s3_keys": []
    }
    
    try:
        # S3 (siempre)
        logger.info("=" * 80)
        s3_config = backup_s3_configurations()
        key = save_to_s3(s3_config, "s3_buckets", timestamp)
        summary["services_backed_up"].append("S3")
        summary["total_resources"] += s3_config["total_buckets"]
        summary["s3_keys"].append(key)
        
        # Glue
        if INCLUDE_GLUE:
            logger.info("=" * 80)
            glue_config = backup_glue_configurations()
            key = save_to_s3(glue_config, "glue", timestamp)
            summary["services_backed_up"].append("Glue")
            summary["total_resources"] += (
                glue_config["total_databases"] +
                glue_config["total_tables"] +
                glue_config["total_jobs"] +
                glue_config["total_crawlers"]
            )
            summary["s3_keys"].append(key)
        
        # Athena
        if INCLUDE_ATHENA:
            logger.info("=" * 80)
            athena_config = backup_athena_configurations()
            key = save_to_s3(athena_config, "athena", timestamp)
            summary["services_backed_up"].append("Athena")
            summary["total_resources"] += (
                athena_config["total_workgroups"] +
                athena_config["total_data_catalogs"] +
                athena_config["total_named_queries"] +
                athena_config["total_prepared_statements"]
            )
            summary["s3_keys"].append(key)
        
        # Lambda
        if INCLUDE_LAMBDA:
            logger.info("=" * 80)
            lambda_config = backup_lambda_configurations()
            key = save_to_s3(lambda_config, "lambda_functions", timestamp)
            summary["services_backed_up"].append("Lambda")
            summary["total_resources"] += lambda_config["total_functions"]
            summary["s3_keys"].append(key)
        
        # IAM
        if INCLUDE_IAM:
            logger.info("=" * 80)
            iam_config = backup_iam_configurations()
            key = save_to_s3(iam_config, "iam_roles", timestamp)
            summary["services_backed_up"].append("IAM")
            summary["total_resources"] += iam_config["total_roles"]
            summary["s3_keys"].append(key)
        
        # Step Functions
        if INCLUDE_STEPFUNCTIONS:
            logger.info("=" * 80)
            sfn_config = backup_stepfunctions_configurations()
            key = save_to_s3(sfn_config, "step_functions", timestamp)
            summary["services_backed_up"].append("StepFunctions")
            summary["total_resources"] += sfn_config["total_state_machines"]
            summary["s3_keys"].append(key)
        
        # EventBridge
        if INCLUDE_EVENTBRIDGE:
            logger.info("=" * 80)
            events_config = backup_eventbridge_configurations()
            key = save_to_s3(events_config, "eventbridge_rules", timestamp)
            summary["services_backed_up"].append("EventBridge")
            summary["total_resources"] += events_config["total_rules"]
            summary["s3_keys"].append(key)
        
        # DynamoDB (opcional)
        if INCLUDE_DYNAMODB:
            logger.info("=" * 80)
            dynamodb_config = backup_dynamodb_configurations()
            key = save_to_s3(dynamodb_config, "dynamodb_tables", timestamp)
            summary["services_backed_up"].append("DynamoDB")
            summary["total_resources"] += dynamodb_config["total_tables"]
            summary["s3_keys"].append(key)
        
        # RDS (opcional)
        if INCLUDE_RDS:
            logger.info("=" * 80)
            rds_config = backup_rds_configurations()
            key = save_to_s3(rds_config, "rds", timestamp)
            summary["services_backed_up"].append("RDS")
            summary["total_resources"] += rds_config["total_instances"]
            summary["s3_keys"].append(key)
        
        # Guardar summary
        logger.info("=" * 80)
        summary_key = save_to_s3(summary, "summary", timestamp)
        
        logger.info("=" * 80)
        logger.info(f"Backup de configuraciones completado")
        logger.info(f"Servicios: {', '.join(summary['services_backed_up'])}")
        logger.info(f"Total recursos: {summary['total_resources']}")
        logger.info(f"Archivos generados: {len(summary['s3_keys']) + 1}")
        
        return {
            "statusCode": 200,
            "body": json.dumps(summary, default=str)
        }
    
    except Exception as e:
        logger.error(f"Error fatal en backup de configuraciones: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
