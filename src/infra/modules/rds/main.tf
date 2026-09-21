# RDS module (Tier 3 of the 3-tier demo)
#
# What this creates:
#   A small MySQL instance that the ECS Fargate app (Tier 2) connects to.
#   It's reachable only from inside the default VPC, never from the public
#   internet - so it stays private even though the ALB/API Gateway are public.

# Reuse the same default VPC/subnets as the ECS module - no custom networking.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id] # only subnets belonging to the default VPC
  }
}

# RDS requires a "subnet group" spanning at least 2 subnets/AZs, even for a
# single instance with no Multi-AZ failover - this just tells RDS where it's allowed to live.
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

# Security group: only allow MySQL's port (3306) from inside the VPC.
# Combined with publicly_accessible = false below, this is two layers of
# protection against the database being reachable from the internet.
resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MySQL from inside the VPC only (e.g. the ECS tasks)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block] # VPC-internal traffic only, not 0.0.0.0/0
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The database instance itself.
resource "aws_db_instance" "this" {
  identifier        = "${var.name_prefix}-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.instance_class    # smallest/cheapest size, fine for a demo
  allocated_storage = var.allocated_storage # GB of disk space
  storage_type      = "gp2"                 # general-purpose SSD, default/cheapest option

  db_name  = var.db_name # initial schema/database created inside the instance
  username = var.db_username
  password = var.db_password # comes from dev.tfvars, per the plain-variable choice for this demo

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # not reachable from outside the VPC, even with the right credentials

  multi_az            = false # single instance only - cheaper, acceptable for a demo (no failover)
  skip_final_snapshot = true  # so `terraform destroy` isn't blocked waiting for a manual snapshot
  deletion_protection = false # explicit (also the default) - lets `terraform destroy` remove this instance
}
