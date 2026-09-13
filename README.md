# AMI → Parameter Store → ASG refresh lab

This repository is a reproducible AWS proof of concept for an event-driven AMI rollout:

```text
EC2 Image Builder build + test
            │
            ▼
native distribution updates /imagebuilder/ami-ssm-asg-refresh/ami
            │
            ▼
EventBridge matches Parameter Store Change / Update
            │
            ▼
Lambda validates the AMI and starts an ASG instance refresh
            │
            ▼
new instances resolve the same SSM parameter from their launch template
```

Terraform provisions an isolated VPC, two-instance Auto Scaling group, Image Builder pipeline, standard AMI parameter, Lambda function, EventBridge automation, IAM roles, CloudWatch logs, and separate SQS destinations for event-delivery and Lambda-execution failures. It does not deploy until you run `terraform apply`.

Start with [the runbook](docs/runbook.md). The original implementation requirements are preserved in [the specification](docs/specification.md).

## Design choices

- The launch template intentionally contains `resolve:ssm:/imagebuilder/.../ami`. Lambda never creates launch-template versions.
- Terraform seeds and owns the parameter resource but ignores later changes to its value. Image Builder owns runtime publication.
- The EventBridge rule matches `Update`, not `Create`, so bootstrap cannot trigger a rollout.
- Image Builder has no schedule. Builds are manual and serial for deterministic evidence.
- The ASG has EC2 health checks only. This POC demonstrates replacement mechanics, not application-level availability.
- Instances have public egress and no inbound rules. Systems Manager supplies shell-free inspection.
- Lambda concurrency is one. It validates event provenance, parameter identity, AMI owner/state/architecture/tag, deployed AMIs, and active refresh state before acting.

## Important limitations

AWS does not allow desired configuration, skip matching, warm pools, or native rollback when an ASG launch template references an SSM parameter for its AMI. This lab therefore sends no desired configuration, explicitly disables skip matching and auto rollback, and recovers by restoring a previous lab AMI to the parameter.

The reference is mutable: an update during an active refresh can change which AMI later replacements resolve. Lambda records and defers when it observes active work, but there is no durable update queue. Keep builds serial. Parameter Store service events are also best effort, so `scripts/reconcile.sh` is the manual safety net.

## Local checks

No unit or integration test suite is included for this POC. Run non-deploying checks with:

```bash
make check
```

This checks Terraform formatting/provider schemas, Python syntax, and Bash syntax. It does not contact or mutate AWS after providers have been initialized.

## Cost and cleanup

An applied lab incurs charges for EC2 instances, EBS volumes/snapshots, generated AMIs, Image Builder build/test compute, Lambda/logging beyond free tiers, and possibly Parameter Store/API usage under account-specific pricing. There is no NAT gateway or load balancer. Check current regional pricing before deployment and follow the runbook's cleanup sequence; Image Builder output AMIs and snapshots are not Terraform resources.

## Primary references

- [EC2 Image Builder native SSM output parameter prerequisites](https://docs.aws.amazon.com/imagebuilder/latest/userguide/cr-upd-ami-distribution-settings.html)
- [Parameter Store EventBridge event formats and best-effort delivery](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-cwe.html)
- [Using SSM AMI parameters in Auto Scaling launch templates](https://docs.aws.amazon.com/autoscaling/ec2/userguide/using-systems-manager-parameters.html)
- [Starting and monitoring an instance refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/start-instance-refresh.html)
- [Instance refresh rollback restrictions](https://docs.aws.amazon.com/autoscaling/ec2/userguide/instance-refresh-rollback.html)
- [Terraform AWS provider Image Builder distribution configuration](https://registry.terraform.io/providers/hashicorp/aws/6.59.0/docs/resources/imagebuilder_distribution_configuration)
