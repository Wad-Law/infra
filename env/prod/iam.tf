# Allow EC2 to assume the role aws_iam_role
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions   = ["sts:AssumeRole"]
    principals {
        type = "Service"
        identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Managed policies: SSM + ECR (pull images)

# Allow EC2 to use SSM
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# Allow pulling Docker images from ECR
resource "aws_iam_role_policy_attachment" "ecr_ro" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# inline policy: DescribeAvailabilityZones (for region detection via CLI) - small permissions
resource "aws_iam_policy" "allow_describe_azs" {
  name   = "${var.name_prefix}-allow-describe-azs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid      = "AllowDescribeAZs",
      Effect   = "Allow",
      Action   = "ec2:DescribeAvailabilityZones",
      Resource = "*"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "attach_allow_describe_azs" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.allow_describe_azs.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.name_prefix}-profile"
  role = aws_iam_role.ec2_role.name
}
