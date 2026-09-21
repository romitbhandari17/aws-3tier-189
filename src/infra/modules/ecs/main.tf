# ECS Fargate module (Tier 2 of the 3-tier demo)
#
# What this creates, in order:
#   ECR repo (holds our image) -> ECS cluster -> Fargate service running the
#   Flask app -> fronted by a public Application Load Balancer (ALB).
#
# API Gateway talks to the ALB's public DNS name over plain HTTP - no VPC
# Link needed, which keeps this demo simple.

# 1. Where our container image lives. After `terraform apply`, build & push:
#      docker build -t <ecr_repository_url>:latest src/ecs
#      docker push <ecr_repository_url>:latest
#    (the ECS service won't have a healthy task until an image is pushed)
resource "aws_ecr_repository" "app" {
  name                 = "${var.name_prefix}-app" # repo name shown in ECR console
  image_tag_mutability = "MUTABLE"                # allow re-pushing the same tag (e.g. "latest"), simpler for a demo
  force_delete         = true                     # demo only: lets `terraform destroy` remove images too
}

# 2. Reuse the account's default VPC/subnets - no custom networking to build.
data "aws_vpc" "default" {
  default = true # look up the pre-existing default VPC instead of creating one
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id] # only subnets that belong to the default VPC
  }
}

data "aws_region" "current" {} # used below so the log group knows which region it's in

# 3. Security groups (act like mini firewalls attached to resources)
#    ALB: accept plain HTTP from the internet (demo only - no HTTPS/auth).
resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-" # AWS appends a random suffix to keep the name unique
  vpc_id      = data.aws_vpc.default.id   # attach this SG to the default VPC

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80 # inbound port range start
    to_port     = 80 # inbound port range end (same as start = single port)
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # allow any IP address (public demo, no restriction)
  }

  egress {
    from_port   = 0 # 0-0 with protocol "-1" means "all ports"
    to_port     = 0
    protocol    = "-1"          # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"] # allow the ALB to reach anywhere outbound
  }
}

#    ECS task: only accept traffic from the ALB, on the app's port.
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "${var.name_prefix}-ecs-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App traffic from the ALB only"
    from_port       = var.container_port # the Flask app's port (5000 by default)
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # source = ALB's security group, not a raw IP range
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # lets the task reach the internet (e.g. to pull the image from ECR)
  }
}

# 4. Public Application Load Balancer - this is what API Gateway calls.
resource "aws_lb" "app" {
  name               = "${var.name_prefix}-alb"
  internal           = false                        # false = gets a public DNS name/IP
  load_balancer_type = "application"                # Layer-7 (HTTP) load balancer
  security_groups    = [aws_security_group.alb.id]  # firewall rules defined above
  subnets            = data.aws_subnets.default.ids # spread across the default VPC's public subnets
}

# Where the ALB sends traffic - it forwards to whichever ECS tasks register here.
resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port # port on the target (the container), not the ALB
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip" # required for Fargate (tasks aren't EC2 instances, so they're targeted by IP)

  health_check {
    path = "/courses/count" # ALB polls this path; unhealthy tasks get removed automatically
  }
}

# Listener: tells the ALB "when a request arrives on port 80, send it to this target group".
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward" # forward = pass the request on unchanged
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 5. ECS cluster - just a logical grouping; Fargate needs no EC2 instances to manage.
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
}

# CloudWatch log group so container output (stdout/stderr) is visible without SSH-ing anywhere.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}" # convention: /ecs/<name> makes logs easy to find
  retention_in_days = 7                         # short retention - demo only, avoids cost buildup
}

# 6. Task definition - describes the single container we run (like a docker-compose.yml for ECS).
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-task"   # groups revisions of this task definition together
  requires_compatibilities = ["FARGATE"]                 # run on Fargate, not EC2
  network_mode             = "awsvpc"                    # required by Fargate; gives the task its own ENI/IP
  cpu                      = var.cpu                     # total CPU for the task (shared across containers)
  memory                   = var.memory                  # total memory for the task
  execution_role_arn       = var.task_execution_role_arn # role ECS uses to start the task (pull image, logs)
  task_role_arn            = var.task_role_arn           # role the app code uses once running

  # container_definitions is a JSON blob (ECS's native format) describing each container.
  # We only run one container here, named "app".
  container_definitions = jsonencode([
    {
      name         = "app"
      image        = "${aws_ecr_repository.app.repository_url}:${var.image_tag}" # image built/pushed by the developer
      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]  # port the container listens on
      # DB connection details, passed as plain env vars (per the demo's plain-variable choice).
      # The Flask app (src/ecs/app.py) reads these with os.environ[...].
      environment = [
        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USER", value = var.db_username },
        { name = "DB_PASSWORD", value = var.db_password },
      ]
      logConfiguration = {
        logDriver = "awslogs" # ship container logs straight to CloudWatch
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name # which log group to write to
          "awslogs-region"        = data.aws_region.current.name      # which region that log group lives in
          "awslogs-stream-prefix" = "app"                             # prefix for the log stream name
        }
      }
    }
  ])
}

# 7. Service - keeps 1 task running and registered with the ALB target group.
resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1 # always keep exactly 1 task running (minimum for a demo)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids      # which subnets the task's network interface lives in
    security_groups  = [aws_security_group.ecs_tasks.id] # firewall rules for the task
    assign_public_ip = true                              # default VPC subnets are public; needed to pull the image from ECR
  }

  # Tells ECS: "register/deregister each task's IP with this target group automatically".
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"              # must match the container "name" above
    container_port   = var.container_port # must match the container's listening port
  }

  depends_on = [aws_lb_listener.http] # ensure the ALB can actually route before the service starts
}
