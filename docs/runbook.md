# Lab runbook

This runbook creates billable AWS resources only when you run `terraform apply`. The implementation work itself does not deploy anything.

## 1. Prerequisites

Use an AWS sandbox account. Export credentials through the normal AWS credential chain, or copy `terraform.tfvars.example` to `terraform.tfvars` and set `aws_profile`. If you set a profile only in Terraform variables, also export the matching `AWS_PROFILE` before using the helper scripts because they call the AWS CLI directly.

The deploying principal needs permission to manage the resources in this repository. In particular, direct launch-template parameter references make the caller of Auto Scaling create/update/refresh operations subject to `ssm:GetParameters`, `ec2:RunInstances`, and `iam:PassRole` validation. AWS normally creates the `AWSServiceRoleForImageBuilder` and `AWSServiceRoleForAutoScaling` service-linked roles on first use; an SCP or a principal unable to create service-linked roles can block the first deployment.

Check identity and Region before applying:

```bash
aws sts get-caller-identity
aws configure get region
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan -out lab.tfplan
terraform show lab.tfplan
terraform apply lab.tfplan
```

The apply waits 30 seconds after creating the `aws:ec2:image` parameter because Parameter Store validates that data type asynchronously. The initial `Create` event cannot match the EventBridge rule, which listens only for `Update`.

Wait for both baseline instances before starting a build:

```bash
./scripts/wait-for-baseline.sh
./scripts/inspect.sh
```

## 2. Build and roll out v1

Record the returned image build ARN:

```bash
./scripts/start-build.sh
```

Poll until Image Builder reaches a final state:

```bash
aws imagebuilder get-image \
  --region ap-southeast-2 \
  --image-build-version-arn '<build-arn>' \
  --query 'image.state'
```

Distribution updates the parameter only after the build and test workflows have passed. The write can occur before the overall image resource reports its final `AVAILABLE` state, so preserve timestamps rather than claiming that the parameter write proves final pipeline completion.

Inspect the real event-driven refresh; do not call `start-instance-refresh` manually for this acceptance case:

```bash
./scripts/inspect.sh
./scripts/verify-release.sh v1
./scripts/capture-evidence.sh
```

CloudWatch Logs for `/aws/lambda/ami-ssm-asg-refresh` contain a structured result with the event ID, parameter version, target AMI, old instance IDs, and refresh ID. Check the two SQS queues exposed by Terraform if delivery or execution fails.

## 3. Build and roll out v2

Edit `terraform.tfvars`:

```hcl
recipe_version = "1.0.1"
release_id     = "v2"
```

Then apply the new recipe, start exactly one build, and verify it:

```bash
terraform apply
./scripts/start-build.sh
./scripts/inspect.sh
./scripts/verify-release.sh v2
./scripts/capture-evidence.sh
```

Do not start a second image build while an earlier refresh remains active. The Lambda logs and defers such an update, but this POC intentionally has no durable queue for it.

## 4. Duplicate and reconciliation checks

After a successful rollout, manual reconciliation exercises the same state logic and should return `already-current`:

```bash
./scripts/reconcile.sh
```

To replay a captured EventBridge event, save the full original event JSON and invoke Lambda with it. Replaying while a refresh is active should return `deferred-active-refresh`; replaying after completion should return `already-current`.

Parameter Store service events are delivered on a best-effort basis. Neither failure queue can recover an event that was never emitted. Run `./scripts/reconcile.sh` whenever the parameter and deployed instance AMIs differ without an active refresh.

## 5. Deliberately fail image testing

First record the current parameter value/version and ASG instance IDs. Increment `recipe_version`, leave `release_id = "v2"`, and set:

```hcl
force_test_failure = true
```

Apply and start one build. The test exits with status 42. Confirm that the build fails and that the parameter value/version and ASG instance IDs/AMIs remain unchanged:

```bash
./scripts/inspect.sh
```

Use another new `recipe_version` when returning `force_test_failure` to false; Image Builder component and recipe versions are immutable.

## 6. Recovery

Wait until there is no active refresh. Select a previous account-owned AMI tagged `Project=ami-ssm-asg-refresh`, then run:

```bash
./scripts/recover.sh ami-0123456789abcdef0
./scripts/inspect.sh
```

The script refuses AMIs with the wrong owner/tag and refuses to update the parameter during an active refresh. The parameter `Update` event initiates a fresh rollout. This is the recovery path because Auto Scaling native rollback is unavailable for this direct SSM reference.

## 7. Terraform drift check

After Image Builder has changed the parameter, run:

```bash
terraform plan -detailed-exitcode
```

The parameter resource has `ignore_changes = [value]`, so the plan must not propose restoring the bootstrap AMI. Exit code 0 means no changes; 2 means review unrelated intended configuration changes.

## 8. Cleanup

Capture the Region and project name while outputs exist, disable new events, and inspect for active work:

```bash
export AWS_REGION="$(terraform output -raw aws_region)"
export PROJECT_NAME="$(terraform output -raw project_name)"
./scripts/disable-automation.sh
./scripts/inspect.sh
./scripts/cleanup-generated-images.sh
```

Do not destroy while an Image Builder build or ASG refresh is active. Cancel it deliberately or wait for a final state. Then destroy Terraform-managed resources:

```bash
terraform destroy
```

Only after the ASG and build/test instances are terminated, remove generated images and their snapshots:

```bash
AWS_REGION="${AWS_REGION}" PROJECT_NAME="${PROJECT_NAME}" \
  ./scripts/cleanup-generated-images.sh --execute
```

The cleanup script resolves only account-owned AMIs tagged with the exact project value, prints them, and refuses deletion while a non-terminated instance uses one. Finally verify that no tagged EC2 instances, volumes, AMIs, snapshots, CloudWatch log groups, or SQS queues remain.
