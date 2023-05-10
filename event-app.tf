provider "aws" {
  region = "eu-west-1"
}


resource "aws_s3_bucket" "event_app" {
  bucket = "mransbro-event-app"
}

resource "aws_s3_bucket_ownership_controls" "event_app" {
  bucket = aws_s3_bucket.event_app.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "event_app" {
  depends_on = [aws_s3_bucket_ownership_controls.event_app]

  bucket = aws_s3_bucket.event_app.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "event-app" {
  bucket = aws_s3_bucket.event_app.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "queue" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:SendMessage"]
    resources = ["arn:aws:sqs:*:*:s3-event-notification-queue"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.event_app.arn]
    }
  }
}

# Create the SQS topic to receive notifications from the S3 bucket
resource "aws_sqs_queue" "event_app" {
  name = "event_app"
  policy = data.aws_iam_policy_document.queue.json
}

# Set up the bucket notification to send messages to the SQS topic
resource "aws_s3_bucket_notification" "event_app" {
  bucket = aws_s3_bucket.event_app.id
  queue {
    queue_arn = aws_sqs_queue.event_app.arn
    events    = ["s3:ObjectCreated:*"]
  }
}
data "archive_file" "event_app" {
  output_path = "${path.module}/src/event_app.zip"
  type        = "zip"
  source_file = "${path.module}/event_app.py"
}

# Create the Lambda function to process the uploaded files
resource "aws_lambda_function" "event_app" {
  filename         = "${path.module}/src/event_app.zip"
  function_name    = "event_app"     # Change this to your desired function name
  role             = aws_iam_role.event_app_lambda_role.arn
  handler          = "lambda_handler"
  #source_code_hash = filebase64sha256("${path.module}/src/event_app.zip")
  runtime          = "python3.9"
  depends_on        = [data.archive_file.event_app]
}

# Create the IAM role for the Lambda function
resource "aws_iam_role" "event_app_lambda_role" {
  name = "event_app_lambda_role" # Change this to your desired role name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the necessary policies to the Lambda function role
resource "aws_iam_role_policy_attachment" "event_app_lambda_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.event_app_lambda_role.name
}

# Create the DynamoDB table to store the processed data
resource "aws_dynamodb_table" "event_app" {
  name         = "event_app_table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Set up the Lambda function trigger to be the SQS queue
resource "aws_lambda_event_source_mapping" "event_app" {
  event_source_arn  = aws_sqs_queue.event_app.arn
  function_name     = aws_lambda_function.event_app.function_name
}
