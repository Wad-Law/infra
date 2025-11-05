# x86_64
data "aws_ssm_parameter" "al2023_x86_64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# Uses default AWS VPC and subnets
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default_vpc_subnets" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
