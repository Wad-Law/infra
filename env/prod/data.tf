data "aws_ami" "ubuntu_2404" {
  owners      = ["099720109477"] # Canonical
  most_recent = true
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default_vpc_subnets" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
