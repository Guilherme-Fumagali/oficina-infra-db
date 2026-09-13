output "db_endpoint" {
  description = "Endereco do RDS, consumido pela aplicacao e pela Lambda via SSM."
  value       = aws_db_instance.oficina.endpoint
}

output "db_security_group_id" {
  value = aws_security_group.rds.id
}

output "db_subnet_group" {
  value = aws_db_subnet_group.oficina.name
}
