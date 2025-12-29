
locals {
  compose_content     = file("${path.module}/files/docker-compose.yml")
  deploy_content      = file("${path.module}/files/deploy.sh")
  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    region              = var.region
    account_id          = var.account_id
    compose_content     = local.compose_content
    deploy_content      = local.deploy_content
    db_endpoint         = aws_db_instance.default.endpoint
    db_username         = var.db_username
    db_password         = var.db_password
    llm_api_key         = var.llm_api_key
    s3_bucket_id        = aws_s3_bucket.config_bucket.id
  })
}

# --- S3 Configuration Bucket ---
resource "aws_s3_bucket" "config_bucket" {
  bucket = "${var.name_prefix}-config-${var.account_id}"
}

resource "aws_s3_object" "obs_compose" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "docker-compose.observability.yml"
  source = "${path.module}/files/docker-compose.observability.yml"
  etag   = filemd5("${path.module}/files/docker-compose.observability.yml")
}

resource "aws_s3_object" "prometheus" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "prometheus.yml"
  source = "${path.module}/files/prometheus.yml"
  etag   = filemd5("${path.module}/files/prometheus.yml")
}

resource "aws_s3_object" "filebeat" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "filebeat.yml"
  source = "${path.module}/files/filebeat.yml"
  etag   = filemd5("${path.module}/files/filebeat.yml")
}

resource "aws_s3_object" "grafana_ds" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "datasource.yml"
  source = "${path.module}/files/grafana/datasources/datasource.yml"
  etag   = filemd5("${path.module}/files/grafana/datasources/datasource.yml")
}

resource "aws_s3_object" "grafana_dash_prov" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "dashboard.yml"
  source = "${path.module}/files/grafana/dashboards/dashboard.yml"
  etag   = filemd5("${path.module}/files/grafana/dashboards/dashboard.yml")
}

resource "aws_s3_object" "grafana_dash_json" {
  bucket = aws_s3_bucket.config_bucket.id
  key    = "polymind_main.json"
  source = "${path.module}/files/grafana/dashboards/polymind_main.json"
  etag   = filemd5("${path.module}/files/grafana/dashboards/polymind_main.json")
}

# Defines what each EC2 instance looks like:
resource "aws_launch_template" "lt" {
  name_prefix            = "${var.name_prefix}-lt-"
  image_id               = data.aws_ssm_parameter.al2023_x86_64.value
  instance_type          = "t3.small"
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.key_name
  user_data              = base64encode(local.user_data)

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-ec2" }
  }
}

# Creates 1 instance that can restart itself if it dies.
resource "aws_autoscaling_group" "asg" {
  name                = "${var.name_prefix}-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [element(data.aws_subnets.default_vpc_subnets.ids, 0)]

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 60

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0 # Allow replacing the single instance
    }
  }

  lifecycle { create_before_destroy = true }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-ec2"
    propagate_at_launch = true
  }
}
