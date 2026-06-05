resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}-${var.environment}-db-password"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = { Environment = var.environment }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    password = random_password.db.result
    username = "admin"
  })
}

resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = aws_secretsmanager_secret.db.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn
  rotation_rules {
    automatically_after_days = 30
  }
}

resource "aws_iam_role" "rotation_lambda" {
  name = "${var.name}-${var.environment}-rotation-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rotation_lambda" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.rotation_lambda.name
}

resource "aws_iam_role_policy" "rotation_secrets" {
  role = aws_iam_role.rotation_lambda.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:*"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

data "archive_file" "rotation_lambda" {
  type        = "zip"
  output_path = "${path.module}/rotation_lambda.zip"
  source {
    content  = <<-PYTHON
import boto3, json
def lambda_handler(event, context):
    return {"status": "rotation placeholder"}
    PYTHON
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "rotation" {
  filename         = data.archive_file.rotation_lambda.output_path
  function_name    = "${var.name}-${var.environment}-secret-rotation"
  role             = aws_iam_role.rotation_lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.rotation_lambda.output_base64sha256
}

resource "aws_lambda_permission" "secrets_manager" {
  statement_id  = "AllowSecretsManager"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
}
