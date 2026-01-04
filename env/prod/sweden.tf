provider "aws" {
  alias  = "sweden"
  region = var.sweden_region
}

# --- VPC & Network ---
resource "aws_vpc" "sweden_vpc" {
  provider             = aws.sweden
  cidr_block           = "10.200.0.0/16" # Distinct from Paris (usually 10.0.0.0/16)
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name_prefix}-sweden-vpc" }
}

resource "aws_internet_gateway" "sweden_igw" {
  provider = aws.sweden
  vpc_id   = aws_vpc.sweden_vpc.id
}

resource "aws_subnet" "sweden_public_subnet" {
  provider                = aws.sweden
  vpc_id                  = aws_vpc.sweden_vpc.id
  cidr_block              = "10.200.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.sweden_region}a"
  tags                    = { Name = "${var.name_prefix}-sweden-subnet" }
}

resource "aws_route_table" "sweden_rt" {
  provider = aws.sweden
  vpc_id   = aws_vpc.sweden_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sweden_igw.id
  }
}

resource "aws_route_table_association" "sweden_rta" {
  provider       = aws.sweden
  subnet_id      = aws_subnet.sweden_public_subnet.id
  route_table_id = aws_route_table.sweden_rt.id
}

resource "aws_security_group" "sweden_sg" {
  provider    = aws.sweden
  name        = "${var.name_prefix}-sweden-sg"
  description = "Allow WireGuard and SSH"
  vpc_id      = aws_vpc.sweden_vpc.id

  ingress {
    description = "WireGuard UDP"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] # Can be restricted to Paris NAT/EIP if static, but Paris is dynamic
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- IAM Role for Sweden Instance (Needs to write to Paris SSM) ---
resource "aws_iam_role" "sweden_role" {
  name = "${var.name_prefix}-sweden-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sweden_ssm_policy" {
  name = "${var.name_prefix}-sweden-ssm-policy"
  role = aws_iam_role.sweden_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters"]
        Resource = "*" # Restrict scope in production
      }
    ]
  })
}

resource "aws_iam_instance_profile" "sweden_profile" {
  name = "${var.name_prefix}-sweden-profile"
  role = aws_iam_role.sweden_role.name
}

# --- AMI Lookup (Amazon Linux 2023 in Sweden) ---
data "aws_ami" "sweden_ami" {
  provider    = aws.sweden
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# --- Exit Node Instance ---
resource "aws_instance" "sweden_exit_node" {
  provider                    = aws.sweden
  ami                         = data.aws_ami.sweden_ami.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.sweden_public_subnet.id
  vpc_security_group_ids      = [aws_security_group.sweden_sg.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.sweden_profile.name
  associate_public_ip_address = true

  tags = { Name = "${var.name_prefix}-sweden-exit" }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y wireguard-tools iptables-services

    # Enable IP Forwarding
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # Helper function to get SSM param from MAIN region (Paris)
    get_ssm() {
        aws ssm get-parameter --region ${var.region} --name "$1" --query "Parameter.Value" --output text
    }
    put_ssm() {
        aws ssm put-parameter --region ${var.region} --name "$1" --value "$2" --type String --overwrite
    }

    # Generate Keys
    cd /etc/wireguard
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey

    PRIVATE_KEY=$(cat privatekey)
    PUBLIC_KEY=$(cat publickey)
    
    # Get Public IP
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

    # Publish details to SSM (Paris region)
    put_ssm "/${var.name_prefix}/sweden/public_key" "$PUBLIC_KEY"
    put_ssm "/${var.name_prefix}/sweden/endpoint" "$PUBLIC_IP"

    # Setup Initial Config (Empty Peer)
    cat > /etc/wireguard/wg0.conf <<WGEOF
    [Interface]
    PrivateKey = $PRIVATE_KEY
    Address = 10.99.0.1/24
    ListenPort = 51820
    PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o enX0 -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o enX0 -j MASQUERADE
WGEOF

    # Fix interface name in config (AL2023 uses predictable names like enX0...)
    # Actually, easiest is to find default route interface
    DEF_IFACE=$(ip route show default | awk '/default/ {print $5}')
    sed -i "s/enX0/$DEF_IFACE/g" /etc/wireguard/wg0.conf

    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    # Watcher Loop: Check for Client Key
    echo "Starting Key Watcher..."
    while true; do
        CLIENT_PUB_KEY=$(get_ssm "/${var.name_prefix}/paris/public_key" || echo "NONE")
        
        if [ "$CLIENT_PUB_KEY" != "NONE" ] && ! grep -q "$CLIENT_PUB_KEY" /etc/wireguard/wg0.conf; then
            echo "Found new client key: $CLIENT_PUB_KEY"
            wg set wg0 peer "$CLIENT_PUB_KEY" allowed-ips 10.99.0.2/32
            # Persist it
            wg-quick save wg0
        fi
        sleep 60
    done &
  EOF
}
