"""Reconcile an Auto Scaling group with an AMI published to Parameter Store."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any, Mapping


LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.INFO)

ACTIVE_REFRESH_STATUSES = {
    "Pending",
    "InProgress",
    "Baking",
    "RollbackInProgress",
    "Cancelling",
}


@dataclass(frozen=True)
class Settings:
    parameter_name: str
    asg_name: str
    account_id: str
    region: str
    ami_owner_id: str
    required_tag_key: str
    required_tag_value: str
    min_healthy_percentage: int = 100
    max_healthy_percentage: int = 150
    instance_warmup: int = 120

    @classmethod
    def from_environment(cls) -> Settings:
        """Load the deployment contract from Lambda environment variables."""
        required = {
            name: os.environ[name]
            for name in (
                "PARAMETER_NAME",
                "ASG_NAME",
                "EXPECTED_ACCOUNT_ID",
                "EXPECTED_REGION",
                "AMI_OWNER_ID",
                "REQUIRED_AMI_TAG_KEY",
                "REQUIRED_AMI_TAG_VALUE",
            )
        }
        return cls(
            parameter_name=required["PARAMETER_NAME"],
            asg_name=required["ASG_NAME"],
            account_id=required["EXPECTED_ACCOUNT_ID"],
            region=required["EXPECTED_REGION"],
            ami_owner_id=required["AMI_OWNER_ID"],
            required_tag_key=required["REQUIRED_AMI_TAG_KEY"],
            required_tag_value=required["REQUIRED_AMI_TAG_VALUE"],
            min_healthy_percentage=int(
                os.environ.get("MIN_HEALTHY_PERCENTAGE", "100")
            ),
            max_healthy_percentage=int(
                os.environ.get("MAX_HEALTHY_PERCENTAGE", "150")
            ),
            instance_warmup=int(os.environ.get("INSTANCE_WARMUP", "120")),
        )


@dataclass(frozen=True)
class AwsClients:
    ssm: Any
    ec2: Any
    autoscaling: Any


def _event_id(event: Mapping[str, Any]) -> str:
    return str(event.get("id", "manual-reconcile"))


def _validate_event(event: Mapping[str, Any], settings: Settings) -> None:
    """Accept either the exact EventBridge event or an explicit reconcile request."""
    if event.get("mode") == "reconcile":
        return

    detail = event.get("detail")
    expected_fields = {
        "account": settings.account_id,
        "region": settings.region,
        "source": "aws.ssm",
        "detail-type": "Parameter Store Change",
    }
    mismatches = [
        name for name, expected in expected_fields.items() if event.get(name) != expected
    ]
    if not isinstance(detail, Mapping):
        mismatches.append("detail")
    elif (
        detail.get("name") != settings.parameter_name
        or detail.get("operation") != "Update"
    ):
        mismatches.append("detail")
    if mismatches:
        raise ValueError(f"event failed validation: {', '.join(sorted(set(mismatches)))}")


def _validate_image(target_ami: str, settings: Settings, ec2: Any) -> None:
    response = ec2.describe_images(ImageIds=[target_ami])
    images = response.get("Images", [])
    if len(images) != 1:
        raise ValueError(f"AMI {target_ami} was not found")

    image = images[0]
    tags = {item["Key"]: item["Value"] for item in image.get("Tags", [])}
    problems = []
    if image.get("State") != "available":
        problems.append("not available")
    if image.get("OwnerId") != settings.ami_owner_id:
        problems.append("unexpected owner")
    if image.get("Architecture") != "x86_64":
        problems.append("unexpected architecture")
    if tags.get(settings.required_tag_key) != settings.required_tag_value:
        problems.append("missing required lab tag")
    if problems:
        raise ValueError(f"AMI {target_ami} failed validation: {', '.join(problems)}")


def _current_instances(asg_name: str, clients: AwsClients) -> list[dict[str, str]]:
    response = clients.autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )
    groups = response.get("AutoScalingGroups", [])
    if len(groups) != 1:
        raise ValueError(f"Auto Scaling group {asg_name} was not found")

    instance_ids = [item["InstanceId"] for item in groups[0].get("Instances", [])]
    if not instance_ids:
        return []

    reservations = clients.ec2.describe_instances(InstanceIds=instance_ids).get(
        "Reservations", []
    )
    instances = [
        {"InstanceId": item["InstanceId"], "ImageId": item["ImageId"]}
        for reservation in reservations
        for item in reservation.get("Instances", [])
    ]
    if len(instances) != len(instance_ids):
        raise RuntimeError("EC2 did not return every instance in the Auto Scaling group")
    return sorted(instances, key=lambda item: item["InstanceId"])


def _active_refresh(asg_name: str, autoscaling: Any) -> dict[str, Any] | None:
    refreshes = autoscaling.describe_instance_refreshes(
        AutoScalingGroupName=asg_name,
        MaxRecords=20,
    ).get("InstanceRefreshes", [])
    return next(
        (
            refresh
            for refresh in refreshes
            if refresh.get("Status") in ACTIVE_REFRESH_STATUSES
        ),
        None,
    )


def process_event(
    event: dict[str, Any], settings: Settings, clients: AwsClients
) -> dict[str, Any]:
    """Validate a parameter update and reconcile the ASG with the current AMI."""
    _validate_event(event, settings)

    parameter = clients.ssm.get_parameter(Name=settings.parameter_name)["Parameter"]
    target_ami = parameter["Value"]
    _validate_image(target_ami, settings, clients.ec2)

    instances = _current_instances(settings.asg_name, clients)
    instance_ids = [item["InstanceId"] for item in instances]
    instance_amis = {item["InstanceId"]: item["ImageId"] for item in instances}
    if instances and all(item["ImageId"] == target_ami for item in instances):
        return {
            "action": "already-current",
            "event_id": _event_id(event),
            "instance_amis": instance_amis,
            "instance_ids": instance_ids,
            "parameter_version": parameter["Version"],
            "target_ami": target_ami,
        }

    active = _active_refresh(settings.asg_name, clients.autoscaling)
    if active:
        return {
            "action": "deferred-active-refresh",
            "active_instance_refresh_id": active["InstanceRefreshId"],
            "active_status": active["Status"],
            "event_id": _event_id(event),
            "instance_amis": instance_amis,
            "instance_ids": instance_ids,
            "parameter_version": parameter["Version"],
            "target_ami": target_ami,
        }

    try:
        response = clients.autoscaling.start_instance_refresh(
            AutoScalingGroupName=settings.asg_name,
            Strategy="Rolling",
            Preferences={
                "MinHealthyPercentage": settings.min_healthy_percentage,
                "MaxHealthyPercentage": settings.max_healthy_percentage,
                "InstanceWarmup": settings.instance_warmup,
                "SkipMatching": False,
                "AutoRollback": False,
            },
        )
    except Exception as error:
        error_code = getattr(error, "response", {}).get("Error", {}).get("Code")
        if error_code == "InstanceRefreshInProgress":
            return {
                "action": "deferred-race",
                "event_id": _event_id(event),
                "instance_amis": instance_amis,
                "instance_ids": instance_ids,
                "parameter_version": parameter["Version"],
                "target_ami": target_ami,
            }
        raise

    return {
        "action": "started",
        "event_id": _event_id(event),
        "instance_refresh_id": response["InstanceRefreshId"],
        "parameter_version": parameter["Version"],
        "previous_instance_amis": instance_amis,
        "previous_instance_ids": instance_ids,
        "target_ami": target_ami,
    }


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """AWS Lambda entry point."""
    import boto3

    settings = Settings.from_environment()
    clients = AwsClients(
        ssm=boto3.client("ssm", region_name=settings.region),
        ec2=boto3.client("ec2", region_name=settings.region),
        autoscaling=boto3.client("autoscaling", region_name=settings.region),
    )
    result = process_event(event, settings, clients)
    LOGGER.info(json.dumps(result, sort_keys=True))
    return result
