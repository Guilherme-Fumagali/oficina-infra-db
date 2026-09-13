data "aws_ssm_parameter" "vpc_id" {
  name = "/oficina/${var.ambiente}/vpc-id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/oficina/${var.ambiente}/private-subnet-ids"
}

data "aws_ssm_parameter" "eks_node_security_group_id" {
  name = "/oficina/${var.ambiente}/eks-node-security-group-id"
}

data "aws_ssm_parameter" "lambda_security_group_id" {
  name = "/oficina/${var.ambiente}/lambda-security-group-id"
}

locals {
  vpc_id             = data.aws_ssm_parameter.vpc_id.value
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  identificador      = "oficina-api-db-${var.ambiente}"
}

resource "aws_db_subnet_group" "oficina" {
  name       = "${local.identificador}-subnet-group"
  subnet_ids = local.private_subnet_ids

  tags = { Name = "${local.identificador}-subnet-group" }
}

resource "aws_security_group" "rds" {
  name        = "${local.identificador}-sg"
  description = "Postgres acessivel apenas pelos nos do EKS e pela Lambda de autenticacao"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.identificador}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "postgres_do_eks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres a partir dos nos do EKS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = data.aws_ssm_parameter.eks_node_security_group_id.value
}

resource "aws_vpc_security_group_ingress_rule" "postgres_da_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres a partir da Lambda de autenticacao por CPF"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = data.aws_ssm_parameter.lambda_security_group_id.value
}

resource "aws_vpc_security_group_egress_rule" "todo_trafego" {
  security_group_id = aws_security_group.rds.id
  description       = "Saida liberada"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_db_parameter_group" "oficina" {
  name        = "${local.identificador}-pg16"
  family      = "postgres16"
  description = "Ajustes de observabilidade do PostgreSQL da oficina"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "oficina" {
  identifier     = local.identificador
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.oficina.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.oficina.name

  publicly_accessible = false

  multi_az                = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1

  auto_minor_version_upgrade = true
  apply_immediately          = true
}

resource "aws_ssm_parameter" "db_endpoint" {
  name        = "/oficina/${var.ambiente}/db-endpoint"
  description = "Endereco host:porta do RDS"
  type        = "String"
  value       = aws_db_instance.oficina.endpoint
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/oficina/${var.ambiente}/db-name"
  type  = "String"
  value = var.db_name
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/oficina/${var.ambiente}/db-username"
  type  = "String"
  value = var.db_username
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/oficina/${var.ambiente}/db-password"
  type  = "SecureString"
  value = var.db_password
}
