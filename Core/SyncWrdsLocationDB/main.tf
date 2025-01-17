variable "environment" {
  description = "Hydrovis environment"
  type        = string
}

variable "region" {
  description = "Hydrovis environment"
  type        = string
}

variable "iam_role_arn" {
  description = "Role to use for the lambda functions."
  type        = string
}

variable "email_sns_topics" {
  description = "SnS topics"
  type        = map(any)
}

variable "requests_lambda_layer" {
  description = "Lambda layer that provides the requests library."
  type        = string
}

variable "rds_bastion_id" {
  description = "ID of the RDS Bastion EC2 machine that the DB deploys will be executed from."
  type        = string
}

variable "test_data_services_id" {
  description = "ID of the Test Data Services EC2 machine that the WRDS Location API tests will be run against."
  type        = string
}

variable "lambda_security_groups" {
  description = "Security group for test-wrds-location-api lambda."
  type        = list(any)
}

variable "lambda_subnets" {
  description = "Subnets to use for the test-wrds-location-api lambdas."
  type        = list(any)
}

variable "db_dumps_bucket" {
  description = "The bucket that the WRDS Location DB dumps are being uploaded to"
  type       = string
}

########################################################################################################################################
########################################################################################################################################
data "aws_caller_identity" "current" {}

########################################################################################################################################
########################################################################################################################################

resource "aws_cloudwatch_event_rule" "detect_location_db_dump" {
  name                = "hv-vpp-${var.environment}-detect-wrds-location-db-dump"
  description         = "Detects when a new WRDS location db dump file has been created and triggers the sync_wrds_location_db step function"
  event_pattern       = <<EOF
  {
    "source": ["aws.s3"],
    "detail-type": ["Object Created"],
    "detail": {
      "bucket": {
        "name": ["${var.db_dumps_bucket}"]
      },
      "object": {
        "key": [{
          "prefix": "location/database/wrds_location3_"
        }]
      }
    }
  }
  EOF
}

resource "aws_cloudwatch_event_target" "trigger_sync_location_db_step_function" {
  rule      = aws_cloudwatch_event_rule.detect_location_db_dump.name
  arn       = aws_sfn_state_machine.sync_wrds_location_db_step_function.arn
  role_arn  = var.iam_role_arn
}

###############################
## WRDS API Handler Function ##
###############################
resource "aws_lambda_function" "wrds_location_api_tests" {
  function_name = "hv-vpp-${var.environment}-wrds-location-api-tests"
  description   = "Lambda function to run tests against the WRDS location API deployed at the provided hostname."
  memory_size   = 512
  timeout       = 900
  vpc_config {
    security_group_ids = var.lambda_security_groups
    subnet_ids         = var.lambda_subnets
  }
  filename         = "${path.module}/wrds_location_api_tests.zip"
  source_code_hash = filebase64sha256("${path.module}/wrds_location_api_tests.zip")
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  role             = var.iam_role_arn
  layers = [
    var.requests_lambda_layer
  ]
  tags = {
    "Name" = "hv-vpp-${var.environment}-wrds-location-api-tests"
  }
}

####################################################
##     Ensure EC2 Ready For Use Step Function     ##
####################################################

resource "aws_sfn_state_machine" "ensure_ec2_ready_for_use_step_function" {
  name     = "hv-vpp-${var.environment}-ensure-ec2-ready-for-use"
  role_arn = var.iam_role_arn

  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "StartAt": "Which arg provided?",
  "States": {
    "Which arg provided?": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.InstanceId",
          "IsPresent": true,
          "Next": "Get Machine Status"
        },
        {
          "Variable": "$.InstanceName",
          "IsPresent": true,
          "Next": "Get InstanceId"
        }
      ],
      "Default": "Fail"
    },
    "Get InstanceId": {
      "Type": "Task",
      "Parameters": {
        "Filters": [
          {
            "Name": "tag:Name",
            "Values.$": "States.Array(States.Format($.InstanceName))"
          }
        ]
      },
      "Resource": "arn:aws:states:::aws-sdk:ec2:describeInstances",
      "Next": "Get Machine Status",
      "ResultSelector": {
        "InstanceId.$": "$.Reservations[0].Instances[0].InstanceId"
      }
    },
    "Get Machine Status": {
      "Type": "Task",
      "Parameters": {
        "InstanceIds.$": "States.Array(States.Format($.InstanceId))"
      },
      "Resource": "arn:aws:states:::aws-sdk:ec2:describeInstanceStatus",
      "Next": "Machine Running?",
      "ResultPath": "$.result"
    },
    "Machine Running?": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.result.InstanceStatuses[0]",
          "IsPresent": true,
          "Next": "Machine Accessible?"
        }
      ],
      "Default": "StartInstances"
    },
    "Machine Accessible?": {
      "Type": "Choice",
      "Choices": [
        {
          "And": [
            {
              "Variable": "$.result.InstanceStatuses[0].InstanceStatus.Status",
              "StringEquals": "ok"
            },
            {
              "Variable": "$.result.InstanceStatuses[0].SystemStatus.Status",
              "StringEquals": "ok"
            }
          ],
          "Next": "DescribeInstances"
        }
      ],
      "Default": "Wait"
    },
    "DescribeInstances": {
      "Type": "Task",
      "Next": "Success",
      "Parameters": {
        "InstanceIds.$": "States.Array(States.Format($.InstanceId))"
      },
      "Resource": "arn:aws:states:::aws-sdk:ec2:describeInstances",
      "OutputPath": "$.Reservations[0].Instances[0]"
    },
    "StartInstances": {
      "Type": "Task",
      "Next": "Wait",
      "Parameters": {
        "InstanceIds.$": "States.Array(States.Format($.InstanceId))"
      },
      "Resource": "arn:aws:states:::aws-sdk:ec2:startInstances",
      "ResultPath": null
    },
    "Success": {
      "Type": "Succeed"
    },
    "Wait": {
      "Type": "Wait",
      "Seconds": 60,
      "Next": "Get Machine Status"
    },
    "Fail": {
      "Type": "Fail"
    }
  }
}
  EOF
}

###################################################
##     Restore DB From S3 Dump Step Function     ##
###################################################

resource "aws_sfn_state_machine" "restore_db_from_s3_step_function" {
  name     = "hv-vpp-${var.environment}-restore-db-from-s3"
  role_arn = var.iam_role_arn

  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "StartAt": "Ensure RDS Bastion Running",
  "States": {
    "Ensure RDS Bastion Running": {
      "Type": "Task",
      "Resource": "arn:aws:states:::states:startExecution.sync:2",
      "Parameters": {
        "StateMachineArn": "${aws_sfn_state_machine.ensure_ec2_ready_for_use_step_function.arn}",
        "Input": {
          "InstanceId": "${var.rds_bastion_id}"
        }
      },
      "Next": "Execute Restore DB on RDS Bastion",
      "ResultPath": null
    },
    "Execute Restore DB on RDS Bastion": {
      "Type": "Task",
      "End": true,
      "Parameters": {
        "DocumentName": "AWS-RunShellScript",
        "InstanceIds": [
          "${var.rds_bastion_id}"
        ],
        "Parameters": {
          "commands.$": "States.Array(States.Format('. /deploy_files/restore_db_from_s3.sh {} {} {} {} ${var.region}', $.db_instance_tag, $.s3_uri, $.db_name, $$.Task.Token))"
        },
        "CloudWatchOutputConfig": {
          "CloudWatchLogGroupName": "/aws/systemsmanager/sendcommand",
          "CloudWatchOutputEnabled": true
        }
      },
      "Resource": "arn:aws:states:::aws-sdk:ssm:sendCommand.waitForTaskToken"
    }
  }
}
  EOF
}

#################################################
##     Sync WRDS Location DB Step Function     ##
#################################################

resource "aws_sfn_state_machine" "sync_wrds_location_db_step_function" {
  name     = "hv-vpp-${var.environment}-sync-wrds-location-db"
  role_arn = var.iam_role_arn

  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "StartAt": "Parallel",
  "States": {
    "Parallel": {
      "Type": "Parallel",
      "Next": "Run API Tests",
      "Branches": [
        {
          "StartAt": "Deploy wrds_location3_ondeck DB",
          "States": {
            "Deploy wrds_location3_ondeck DB": {
              "Type": "Task",
              "Resource": "arn:aws:states:::states:startExecution.sync:2",
              "Parameters": {
                "StateMachineArn": "${aws_sfn_state_machine.restore_db_from_s3_step_function.arn}",
                "Input": {
                  "db_instance_tag": "ingest",
                  "s3_uri.$": "States.Format('s3://{}/{}', $.detail.bucket.name, $.detail.object.key)",
                  "db_name": "wrds_location3_ondeck"
                }
              },
              "End": true
            }
          }
        },
        {
          "StartAt": "Start Test WRDS API Machine",
          "States": {
            "Start Test WRDS API Machine": {
              "Type": "Task",
              "Resource": "arn:aws:states:::states:startExecution.sync:2",
              "Parameters": {
                "StateMachineArn": "${aws_sfn_state_machine.ensure_ec2_ready_for_use_step_function.arn}",
                "Input": {
                  "InstanceId": "${var.test_data_services_id}"
                }
              },
              "OutputPath": "$.Output",
              "End": true
            }
          }
        }
      ],
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "Shutdown Deploy and Test Machines",
          "ResultPath": "$.error"
        }
      ]
    },
    "Run API Tests": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "OutputPath": "$.Payload",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.wrds_location_api_tests.arn}",
        "Payload": {
          "PrivateIpAddress.$": "$[1].PrivateIpAddress"
        }
      },
      "Retry": [
        {
          "ErrorEquals": [
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException",
            "Lambda.TooManyRequestsException"
          ],
          "IntervalSeconds": 2,
          "MaxAttempts": 6,
          "BackoffRate": 2
        }
      ],
      "Next": "Swap DBs and Cleanup"
    },
    "Swap DBs and Cleanup": {
      "Type": "Task",
      "Parameters": {
        "DocumentName": "AWS-RunShellScript",
        "InstanceIds": [
          "${var.rds_bastion_id}"
        ],
        "Parameters": {
          "commands.$": "States.Array(States.Format('. /deploy_files/swap_dbs.sh ingest wrds_location3 {} ${var.region}', $$.Task.Token))"
        },
        "CloudWatchOutputConfig": {
          "CloudWatchLogGroupName": "/aws/sendcommand",
          "CloudWatchOutputEnabled": true
        }
      },
      "Resource": "arn:aws:states:::aws-sdk:ssm:sendCommand.waitForTaskToken",
      "Next": "Shutdown Deploy and Test Machines"
    },
    "Shutdown Deploy and Test Machines": {
      "Type": "Task",
      "Parameters": {
        "InstanceIds": [
          "${var.rds_bastion_id}",
          "${var.test_data_services_id}"
        ]
      },
      "Resource": "arn:aws:states:::aws-sdk:ec2:stopInstances",
      "ResultPath": "$.result",
      "Next": "Choice"
    },
    "Choice": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.error",
          "IsPresent": true,
          "Next": "Fail"
        }
      ],
      "Default": "Success"
    },
    "Fail": {
      "Type": "Fail"
    },
    "Success": {
      "Type": "Succeed"
    }
  }
}
  EOF
}

####### Step Function Failure / Time Out SNS #######
resource "aws_cloudwatch_event_rule" "sync_wrds_location_db_step_function_failure" {
  name        = "hv-vpp-${var.environment}-sync-wrds-location-db-step-function-failure"
  description = "Alert when the sync wrds location db step function times out or fails."

  event_pattern = <<EOF
  {
    "source": ["aws.states"],
    "detail-type": ["Step Functions Execution Status Change"],
    "detail": {
      "status": ["FAILED", "TIMED_OUT"],
      "stateMachineArn": ["${aws_sfn_state_machine.sync_wrds_location_db_step_function.arn}"]
    }
  }
  EOF
}

resource "aws_cloudwatch_event_target" "step_function_failure_sns" {
  rule        = aws_cloudwatch_event_rule.sync_wrds_location_db_step_function_failure.name
  target_id   = "SendToSNS"
  arn         = var.email_sns_topics["viz_lambda_errors"].arn
  input_path  = "$.detail.name"
}

resource "aws_s3_bucket_notification" "nwm_bucket_notification" {
  bucket = var.db_dumps_bucket
  eventbridge = true
}
