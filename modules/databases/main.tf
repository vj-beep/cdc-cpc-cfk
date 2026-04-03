# SQL Server Security Group
resource "aws_security_group" "sqlserver" {
  name_prefix = "${var.project_name}-sqlserver-"
  description = "Allow EKS nodes + Mac to reach SQL Server"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.project_name}-sqlserver" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "sqlserver_from_eks" {
  type                     = "ingress"
  from_port                = 1433
  to_port                  = 1433
  protocol                 = "tcp"
  description              = "SQL Server from EKS nodes"
  security_group_id        = aws_security_group.sqlserver.id
  source_security_group_id = var.eks_node_security_group_id
}

resource "aws_security_group_rule" "sqlserver_from_mac" {
  type              = "ingress"
  from_port         = 1433
  to_port           = 1433
  protocol          = "tcp"
  description       = "SQL Server from Mac"
  security_group_id = aws_security_group.sqlserver.id
  cidr_blocks       = [var.my_ip]
}

resource "aws_security_group_rule" "sqlserver_from_cloud9" {
  type              = "ingress"
  from_port         = 1433
  to_port           = 1433
  protocol          = "tcp"
  description       = "SQL Server from Cloud9"
  security_group_id = aws_security_group.sqlserver.id
  cidr_blocks       = ["100.30.53.57/32"]
}

resource "aws_security_group_rule" "sqlserver_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.sqlserver.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Aurora PostgreSQL Security Group
resource "aws_security_group" "aurora_pg" {
  name_prefix = "${var.project_name}-aurora-pg-"
  description = "Allow EKS nodes + Mac to reach Aurora PostgreSQL"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.project_name}-aurora-pg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "aurora_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "PostgreSQL from EKS nodes"
  security_group_id        = aws_security_group.aurora_pg.id
  source_security_group_id = var.eks_node_security_group_id
}

resource "aws_security_group_rule" "aurora_from_mac" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  description       = "PostgreSQL from Mac"
  security_group_id = aws_security_group.aurora_pg.id
  cidr_blocks       = [var.my_ip]
}

resource "aws_security_group_rule" "aurora_from_cloud9" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  description       = "PostgreSQL from Cloud9"
  security_group_id = aws_security_group.aurora_pg.id
  cidr_blocks       = ["100.30.53.57/32"]
}

resource "aws_security_group_rule" "aurora_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.aurora_pg.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# RDS SQL Server
resource "aws_db_option_group" "sqlserver" {
  name                     = "${var.project_name}-sqlserver-og"
  engine_name              = "sqlserver-se"
  major_engine_version     = "15.00"
  option_group_description = "Option group for CDC SQL Server"
  tags                     = { Name = "${var.project_name}-sqlserver-og" }
  lifecycle { create_before_destroy = true }
}

resource "aws_db_parameter_group" "sqlserver" {
  name   = "${var.project_name}-sqlserver-pg"
  family = "sqlserver-se-15.0"
  tags   = { Name = "${var.project_name}-sqlserver-pg" }
  lifecycle { create_before_destroy = true }
}

resource "aws_db_instance" "sqlserver" {
  identifier              = "${var.project_name}-sqlserver"
  engine                  = "sqlserver-se"
  engine_version          = var.sqlserver_engine_version
  instance_class          = var.sqlserver_instance_class
  license_model           = "license-included"
  allocated_storage       = var.sqlserver_allocated_storage
  max_allocated_storage   = var.sqlserver_max_allocated_storage
  storage_type            = "gp3"
  iops                    = var.sqlserver_iops
  storage_throughput      = var.sqlserver_storage_throughput
  storage_encrypted       = true
  username                = var.sqlserver_username
  password                = var.sqlserver_password
  parameter_group_name    = aws_db_parameter_group.sqlserver.name
  option_group_name       = aws_db_option_group.sqlserver.name
  db_subnet_group_name    = var.database_subnet_group_name
  vpc_security_group_ids  = [aws_security_group.sqlserver.id]
  publicly_accessible     = true
  multi_az                = false
  apply_immediately       = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"
  tags                    = { Name = "${var.project_name}-sqlserver" }
}

# Aurora PostgreSQL
resource "aws_rds_cluster_parameter_group" "aurora_pg" {
  name   = "${var.project_name}-aurora-pg-cpg"
  family = "aurora-postgresql16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = { Name = "${var.project_name}-aurora-pg-cpg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_db_parameter_group" "aurora_pg" {
  name   = "${var.project_name}-aurora-pg-dpg"
  family = "aurora-postgresql16"

  tags = { Name = "${var.project_name}-aurora-pg-dpg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_rds_cluster" "aurora_pg" {
  cluster_identifier = "${var.project_name}-aurora-pg"

  engine         = "aurora-postgresql"
  engine_version = var.aurora_pg_engine_version
  engine_mode    = "provisioned"

  database_name   = var.aurora_db_name
  master_username = var.aurora_username
  master_password = var.aurora_password

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora_pg.name
  db_subnet_group_name            = var.database_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.aurora_pg.id]

  apply_immediately   = true
  storage_encrypted   = true
  skip_final_snapshot = true
  deletion_protection = false

  backup_retention_period      = 7
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  tags = { Name = "${var.project_name}-aurora-pg" }
}

resource "aws_rds_cluster_instance" "aurora_pg_writer" {
  identifier         = "${var.project_name}-aurora-pg-writer"
  cluster_identifier = aws_rds_cluster.aurora_pg.id

  engine         = aws_rds_cluster.aurora_pg.engine
  engine_version = aws_rds_cluster.aurora_pg.engine_version
  instance_class = var.aurora_pg_instance_class

  apply_immediately       = true
  db_parameter_group_name = aws_db_parameter_group.aurora_pg.name
  publicly_accessible     = true

  tags = { Name = "${var.project_name}-aurora-pg-writer" }
}

resource "aws_rds_cluster_instance" "aurora_pg_reader" {
  identifier         = "${var.project_name}-aurora-pg-reader"
  cluster_identifier = aws_rds_cluster.aurora_pg.id

  engine         = aws_rds_cluster.aurora_pg.engine
  engine_version = aws_rds_cluster.aurora_pg.engine_version
  instance_class = var.aurora_pg_instance_class

  apply_immediately       = true
  db_parameter_group_name = aws_db_parameter_group.aurora_pg.name
  publicly_accessible     = true

  tags = { Name = "${var.project_name}-aurora-pg-reader" }
}
