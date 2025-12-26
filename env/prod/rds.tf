resource "aws_db_subnet_group" "default" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = data.aws_subnets.default_vpc_subnets.ids

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow inbound traffic from EC2"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  ingress {
    description = "Postgres Public Access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # WARNING: Insecure, for dev only
  }

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

resource "aws_db_instance" "default" {
  identifier        = "${var.name_prefix}-db"
  engine            = "postgres"
  engine_version    = "16.1"
  instance_class    = "db.t4g.micro" # Free Tier eligible (if available) or cheap
  allocated_storage = 20
  storage_type      = "gp3"

  username = var.db_username
  password = var.db_password

  db_name = "ingestor"

  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true # For dev/proto simplicity
  publicly_accessible = true

  tags = {
    Name = "${var.name_prefix}-db"
  }
}
