# =============================================================================
# Root-account activity detection.
#
# WHY THIS EXISTS. On 2026-09-09 the ROOT user created an untagged
# db.m8i.4xlarge SQL Server Enterprise instance (`database-1`) in the DEFAULT VPC. It ran
# three days at roughly $110/day with zero connections, and nothing anywhere told anyone:
# the account budget had no notifications, the cost-anomaly monitor had no subscriber, and
# every product alarm topic had no subscriptions. This stack detects the *cause* — root
# being used at all — rather than only the symptom.
#
# Root should never perform day-to-day operations. This account is a MEMBER of the
# organisation whose management account is 033086823579, so Identity Center is not
# available here (see the CKV_AWS_273 justification in main.tf) and human access runs
# through IAM users + MFA in human-access.tf. That makes root usage both rare and
# significant: any hit here is either a deliberate break-glass action or an incident.
#
# ── WHY EVENTBRIDGE AND NOT A CLOUDWATCH LOGS METRIC FILTER ──────────────────
# CIS recommends a metric filter on `{ $.userIdentity.type = "Root" }`. That route needs
# the trail delivering to CloudWatch Logs, which `aws_cloudtrail.org` in cloudtrail.tf
# deliberately does NOT do — it writes to S3 only. Adding the log-group destination would
# bill CloudWatch Logs ingestion for every management event in the account, forever, to
# detect an event that should occur roughly never.
#
# EventBridge costs nothing for AWS-service events and needs no trail change. The
# trade-off, stated plainly: the ConsoleLogin rule is exact, while `AWS API Call via
# CloudTrail` delivery is best-effort across services rather than guaranteed for every
# API. Since root activity almost always begins with a console sign-in, the first rule is
# the one that would have caught `database-1`. If a guaranteed audit trail of every root
# API call is ever required for compliance, add the CloudWatch Logs destination and a
# metric filter then, and accept the ingestion cost as the price of that guarantee.
# =============================================================================

# ── Alert topic ──────────────────────────────────────────────────────────────
# Separate from the per-product `<name>-alarms` topics created by the observability
# module: those are per-environment operational alarms owned by a product, this is
# account-wide security signal owned by the platform.
#
# Encryption: see the inline checkov:skip on the resource below for why this topic is
# deliberately unencrypted.
resource "aws_sns_topic" "security_alerts" {
  #checkov:skip=CKV_AWS_26:EventBridge cannot publish to a topic encrypted with the AWS-managed alias/aws/sns key — that key's policy does not grant kms:GenerateDataKey to events.amazonaws.com — so making this work needs a customer-managed key ($1/mo) whose policy names the EventBridge principal. The payload here is alarm metadata (event name, principal type, account id, region) and carries no credential or customer data. A silently broken alert path is strictly worse than an unencrypted notification, and a silently broken alert path is the exact failure this file exists to end.
  name = "qnsc-security-alerts"
  tags = { Layer = "platform", Purpose = "security-alerts" }
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# EventBridge cannot publish to a topic that does not name it as a principal. The
# SourceAccount condition keeps another account's bus from publishing here.
resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "AllowAccountOwnerFullControl"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["sns:Subscribe", "sns:SetTopicAttributes", "sns:GetTopicAttributes", "sns:Publish"]
        Resource  = aws_sns_topic.security_alerts.arn
      },
    ]
  })
}

# ── Rule 1: root console sign-in (exact) ─────────────────────────────────────
# `aws.signin` events are global and surface in us-east-1 for the console. This trail is
# multi-region with global service events included, and the EventBridge default bus in
# this region receives sign-in events for the account.
resource "aws_cloudwatch_event_rule" "root_console_login" {
  name        = "qnsc-root-console-login"
  description = "Root user signed in to the AWS console — expected to be rare and deliberate."

  event_pattern = jsonencode({
    source        = ["aws.signin"]
    "detail-type" = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = { type = ["Root"] }
    }
  })

  tags = { Layer = "platform", Purpose = "security-alerts" }
}

resource "aws_cloudwatch_event_target" "root_console_login" {
  rule      = aws_cloudwatch_event_rule.root_console_login.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn

  # Without a transformer the email is the raw event JSON, which nobody reads at 2am.
  input_transformer {
    input_paths = {
      time   = "$.time"
      region = "$.region"
      event  = "$.detail.eventName"
      ip     = "$.detail.sourceIPAddress"
      agent  = "$.detail.userAgent"
      result = "$.detail.responseElements.ConsoleLogin"
    }
    input_template = <<-EOT
      "ROOT CONSOLE SIGN-IN (<result>) at <time>"
      "region: <region>  event: <event>"
      "source ip: <ip>"
      "user agent: <agent>"
      ""
      "Root should not be used for day-to-day operations. If this was not you, treat it as"
      "an incident: rotate the root password, check root MFA, and review CloudTrail for"
      "what the session did."
    EOT
  }
}

# ── Rule 2: root API activity (best-effort breadth) ──────────────────────────
# Catches root doing things without a console sign-in in the same window — an access key
# on the root user, or a session that outlives the sign-in event. Delivery of
# `AWS API Call via CloudTrail` to EventBridge is not guaranteed for every service, so
# this rule widens coverage without being the thing relied upon; rule 1 is the reliable
# signal. ReadOnly calls are excluded so an idle root console session browsing pages does
# not generate a stream of alerts.
resource "aws_cloudwatch_event_rule" "root_api_activity" {
  name        = "qnsc-root-api-activity"
  description = "A mutating API call made by the root user (best-effort; see file header)."

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      userIdentity = { type = ["Root"] }
      readOnly     = [false]
    }
  })

  tags = { Layer = "platform", Purpose = "security-alerts" }
}

resource "aws_cloudwatch_event_target" "root_api_activity" {
  rule      = aws_cloudwatch_event_rule.root_api_activity.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time    = "$.time"
      region  = "$.region"
      service = "$.detail.eventSource"
      event   = "$.detail.eventName"
      ip      = "$.detail.sourceIPAddress"
    }
    input_template = <<-EOT
      "ROOT API CALL at <time>"
      "<service> / <event>  region: <region>"
      "source ip: <ip>"
      ""
      "Root made a mutating API call. Anything root creates is outside OpenTofu and"
      "outside the tagging conventions, so it will not appear in cost attribution or in"
      "any product's state. Verify it was intentional, then move it into IaC or remove it."
    EOT
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "security_alerts_topic_arn" {
  description = "Account-wide security alert topic. Subscriptions require email confirmation before anything is delivered."
  value       = aws_sns_topic.security_alerts.arn
}
