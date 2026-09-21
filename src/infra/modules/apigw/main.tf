# API Gateway module (Tier 1 of the 3-tier demo)
#
# What this creates:
#   REST API -> GET /courses/count -> HTTP_PROXY integration -> ECS/ALB
#
# HTTP_PROXY means API Gateway simply forwards the request to the ALB's
# public DNS name and passes the response straight back - no request/response
# mapping to maintain, which keeps this demo easy to follow.

# 1. The REST API "container" that holds all our resources/methods.
resource "aws_api_gateway_rest_api" "this" {
  name        = var.api_name # shown in the AWS console / Postman-friendly name
  description = "Demo API returning the number of courses offered by everythingAWS"
}

# 2. A URL path segment: /courses
resource "aws_api_gateway_resource" "courses" {
  rest_api_id = aws_api_gateway_rest_api.this.id               # which REST API this path belongs to
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id # attach directly under "/"
  path_part   = "courses"                                      # this segment's literal text
}

# 3. A nested path segment: /courses/count  (final path we call from Postman)
resource "aws_api_gateway_resource" "count" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.courses.id # nested under /courses
  path_part   = "count"
}

# 4. Allow HTTP GET on /courses/count, no auth (demo only, keep it simple)
resource "aws_api_gateway_method" "get_count" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.count.id
  http_method   = "GET"
  authorization = "NONE" # no API key / IAM / Cognito - anyone with the URL can call it
}

# 5. HTTP_PROXY integration: forwards the request as-is to the ALB and
#    passes its response straight back to the caller (no templates needed).
resource "aws_api_gateway_integration" "backend" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.count.id
  http_method             = aws_api_gateway_method.get_count.http_method # must match the method above
  type                    = "HTTP_PROXY"                                 # pass request/response through unchanged
  integration_http_method = "GET"                                        # method used when calling the backend
  uri                     = var.backend_url                              # e.g. http://<alb-dns-name>/courses/count
}

# 6. Deployment: publishes the API so it gets an invoke URL.
#    redeploy_hash forces a new deployment whenever the API config changes.
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    # Terraform doesn't redeploy automatically on every change, so we hash the
    # IDs of everything that matters - any change here forces a fresh deployment.
    redeploy_hash = sha1(jsonencode([
      aws_api_gateway_resource.courses.id,
      aws_api_gateway_resource.count.id,
      aws_api_gateway_method.get_count.id,
      aws_api_gateway_integration.backend.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true # avoid a brief gap with no active deployment
  }
}

# 7. Stage: the named environment (e.g. "dev") that appears in the invoke URL.
resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id # which deployment this stage serves
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.stage_name # e.g. "dev" -> URL ends in .../dev/courses/count
}
