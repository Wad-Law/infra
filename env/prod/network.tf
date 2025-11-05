resource "aws_security_group" "ec2_sg" {
  name        = "${var.name_prefix}-sg"
  description = "Egress-only; SSM uses outbound"
  vpc_id      = data.aws_vpc.default.id

  # Allow all outbound (internet)
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}
