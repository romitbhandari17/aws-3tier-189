# IAM module: the two roles ECS Fargate needs (Tier 2 of the demo).
#
#  - task_execution role: used by ECS itself to pull the container image
#    from ECR and ship logs to CloudWatch, before your code even runs.
#  - task role: used by YOUR application code at runtime. Empty for now -
#    permissions (e.g. to read DB credentials) get added in the RDS iteration.

# Trust policy: only the ECS tasks service is allowed to assume these roles.
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"] # the action a service performs to "become" this role

    principals {
      type        = "Service"                   # the trusted entity is an AWS service, not a user/account
      identifiers = ["ecs-tasks.amazonaws.com"] # specifically, the ECS tasks service
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json # who can use this role (above)
}

# AWS-managed policy that covers exactly what every Fargate task needs:
# pull from ECR + write logs to CloudWatch. No custom policy required.
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # AWS-provided, not custom
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  # No policy attachment here on purpose - this role has zero permissions
  # until the RDS iteration adds what the app needs (e.g. Secrets Manager read).
}
