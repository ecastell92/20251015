from typing import Any, Dict

import boto3

s3control_client = boto3.client("s3control")


def lambda_handler(event: Dict[str, Any], _context) -> Dict[str, Any]:
    job = event.get("job") or {}
    job_id = job.get("jobId") or event.get("jobId")
    if not job_id:
        raise ValueError("jobId es obligatorio para monitorear el restore")

    account_id = event.get("accountId")
    if not account_id:
        account_id = boto3.client("sts").get_caller_identity()["Account"]

    response = s3control_client.describe_job(AccountId=account_id, JobId=job_id)
    status = response["Job"]["Status"]
    failure_reasons = response["Job"].get("FailureReasons", [])

    return {
        "jobId": job_id,
        "status": status,
        "failureReasons": failure_reasons,
    }
