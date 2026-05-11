# =============================================================================
# Qdrant on EC2 — vector database (analog to GCP Qdrant VM)
# =============================================================================

# Use the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  count       = var.enable_qdrant_vm ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "qdrant" {
  count = var.enable_qdrant_vm ? 1 : 0

  ami                    = data.aws_ami.amazon_linux[0].id
  instance_type          = var.qdrant_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.qdrant.id]
  iam_instance_profile   = aws_iam_instance_profile.qdrant[0].name

  # No SSH key — access via SSM Session Manager (set up by the SSM IAM policy)
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.qdrant_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y docker
    systemctl start docker
    systemctl enable docker

    mkdir -p /data/qdrant

    docker run -d \
      --name qdrant \
      --restart unless-stopped \
      -p 6333:6333 \
      -p 6334:6334 \
      -v /data/qdrant:/qdrant/storage \
      qdrant/qdrant:v1.9.0

    echo "Qdrant started" > /var/log/qdrant-bootstrap.log
  USERDATA

  user_data_replace_on_change = false

  tags = {
    Name = "${local.name_prefix}-qdrant"
    Role = "vector-db"
  }
}
