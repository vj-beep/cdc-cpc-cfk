output "sqlserver_address" {
  value = aws_db_instance.sqlserver.address
}

output "sqlserver_port" {
  value = aws_db_instance.sqlserver.port
}

output "aurora_endpoint" {
  value = aws_rds_cluster.aurora_pg.endpoint
}

output "aurora_port" {
  value = aws_rds_cluster.aurora_pg.port
}

output "aurora_reader_endpoint" {
  value = aws_rds_cluster.aurora_pg.reader_endpoint
}
