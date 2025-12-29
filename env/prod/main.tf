locals {
  compose_content     = file("${path.module}/files/docker-compose.yml")
  deploy_content      = file("${path.module}/files/deploy.sh")
  obs_compose_content = file("${path.module}/files/docker-compose.observability.yml")
  prom_content        = file("${path.module}/files/prometheus.yml")
  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    region              = var.region
    account_id          = var.account_id
    compose_content     = local.compose_content
    deploy_content      = local.deploy_content
    obs_compose_content = local.obs_compose_content
    prom_content        = local.prom_content
    grafana_ds          = file("${path.module}/files/grafana/datasources/datasource.yml")
    grafana_dash_prov   = file("${path.module}/files/grafana/dashboards/dashboard.yml")
    grafana_dash_json   = file("${path.module}/files/grafana/dashboards/polymind_main.json")
    filebeat_content    = file("${path.module}/files/filebeat.yml")
    db_endpoint         = aws_db_instance.default.endpoint
    db_username         = var.db_username
    db_password         = var.db_password
    llm_api_key         = var.llm_api_key
  })
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
