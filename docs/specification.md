# Lab specification

This file records the implementation baseline supplied in the project handoff. It is the spec source for reviewing changes from the repository's initial commit.

## Objective

Create a reproducible, single-account AWS lab demonstrating this path:

1. EC2 Image Builder builds and tests an Amazon Linux 2023 AMI.
2. Successful distribution writes the output AMI ID to a standard Parameter Store `String` parameter with data type `aws:ec2:image`.
3. A real `Parameter Store Change` event with operation `Update` reaches Lambda through EventBridge.
4. Lambda validates the event and AMI, then starts an Auto Scaling group instance refresh.
5. The ASG's launch template resolves the AMI directly from the same parameter.

Terraform must provision the network, IAM, bootstrap parameter, ASG, Image Builder pipeline, Lambda, EventBridge rule, logging, and failure destinations. Terraform owns the parameter resource but must ignore post-bootstrap value changes made by Image Builder. It must not configure Terraform's automatic `instance_refresh` block.

## Infrastructure requirements

- Default Region `ap-southeast-2`, configurable for one account and Region.
- Dedicated VPC with one public subnet, internet gateway, outbound access, public instance addresses, and no inbound security-group rules.
- Small x86 instances; encrypted root volumes; IMDSv2 required; Systems Manager access for inspection.
- ASG desired/minimum capacity 2 and enough maximum capacity for one-at-a-time launch-before-terminate replacement.
- Standard Parameter Store parameter under `/imagebuilder/`, initially containing a valid regional Amazon Linux 2023 AMI.
- Image Builder components must write `/etc/asg-refresh-lab-release` with a release identifier and UTC build timestamp, verify the marker and operating system, and expose a deliberate test failure mode.
- The pipeline is manually triggered, has image tests enabled, and uses native `ssm_parameter_configuration` distribution.
- IAM roles for Image Builder workflow execution, Image Builder instances, ASG instances, and Lambda are separate.
- Delivery failures and Lambda execution failures have separate destinations.

## Lambda requirements

For EventBridge invocations, validate the account, Region, source, detail type, exact parameter name, and `Update` operation. For explicit manual reconciliation, apply the same state checks without requiring an EventBridge envelope.

Read and record the current parameter value and version. Accept only an available, x86_64 AMI owned by the lab account with the expected lab tag. Inspect the ASG's current instance IDs and AMIs and its recent refreshes.

- If every current instance already uses the target AMI, return without starting a refresh.
- If a refresh is active, record a deferred result rather than starting another.
- Otherwise start a rolling refresh with minimum healthy 100%, maximum healthy 150%, warmup 120 seconds, skip matching disabled, auto rollback disabled, and no desired configuration.
- Defend against duplicate delivery and the race in which another invocation starts a refresh after inspection.

The core lab intentionally assumes serial image builds. Active-refresh deferral is observable but is not a durable production queue.

## Direct-reference restrictions

Because the launch template contains `resolve:ssm:...`, refresh requests must not use desired configuration or skip matching. Native rollback is disabled, and the lab must not add a warm pool. Recovery is a new parameter update to a previous valid lab AMI after active work has ended.

The mutable parameter does not pin a rollout. A later production design can resolve each AMI into a numbered launch-template version.

## Acceptance scenarios

- Static Terraform and source checks pass.
- Bootstrap produces two healthy instances whose launch-template parameter resolves to the seed AMI.
- A successful v1 build updates the parameter and causes an event-driven refresh; both instances use the new AMI and contain marker `v1`.
- A changed v2 recipe repeats that flow with marker `v2`.
- Replayed update events do not create concurrent or unnecessary refreshes.
- A deliberately failed image test does not change the parameter or deployed instances.
- Restoring a previous successful lab AMI triggers recovery.
- A later Terraform plan does not restore the seed parameter value.

## Cleanup

Disable the event rule, wait for or stop outstanding builds and refreshes, inventory only account-owned images tagged for this lab, destroy Terraform-managed resources, and then deregister generated AMIs and delete their snapshots after confirming no instances use them.
