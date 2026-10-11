# =============================================================================
# Alerts: production break-glass role (§10b).
#
# WHERE THIS CAME FROM. The rule used to live in `live/cluster-prod/iam.tf` (`qnsc-prod-break-glass`) next to the EKS
# access entry for the same role. The role is account-wide, though (it is the production database tunnel, see
# human-access.tf) and stays when the Kubernetes estate goes, so the alert that makes its use honest belongs with the
# role. They are NEW rules with NEW names, created before the old one is destroyed: no gap, no state surgery.
#
# THE OLD RULE NEVER FIRED, and this one would not have either, for the same reason: `sts:AssumeRole` is a READ-ONLY
# management event (readOnly = true), and an EventBridge rule in the default state `ENABLED` is not delivered
# read-only management events. Delivery needs `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`. (The trail already
# records them: cloudtrail.tf has read_write_type = "All".) Provider 5.100.0 accepts that state.
#
# TWO RULES, because one cannot be relied on alone:
#   1. AssumeRole of the role  (this region's bus). Sees successes AND failures (errorCode is in the message).
#   2. ssm:StartSession by a session issued from the role: the real USE of the role (a write event, so it is
#      delivered whichever STS endpoint minted the credentials).
#
# WHAT THESE RULES CANNOT SEE (stated so nobody reads this as full coverage):
#   * an AssumeRole made through the GLOBAL (or us-east-1) STS endpoint is logged in us-east-1, not on this region's bus;
#   * a console SwitchRole is likewise not an AssumeRole event on this bus.
# Rule 2 still catches the use of such a session once it opens a port-forward through SSM in this region.
#
# Same topic as the root-activity rules in root-activity.tf. NOTE: a topic with no confirmed subscription delivers to
# nobody; see the email subscription in that file.
# =============================================================================

resource "aws_cloudwatch_event_rule" "prod_breakglass_assumed" {
  name        = "qnsc-prod-breakglass-assumed"
  description = "AssumeRole of the production break-glass role was attempted (success or failure) (§10b)."
  # AssumeRole is a read-only management event: this state is what makes EventBridge deliver it.
  state = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName         = ["AssumeRole"]
      requestParameters = { roleArn = [aws_iam_role.prod_breakglass.arn] }
    }
  })

  tags = { Layer = "platform", Purpose = "security-alerts" }
}

resource "aws_cloudwatch_event_target" "prod_breakglass_assumed" {
  rule      = aws_cloudwatch_event_rule.prod_breakglass_assumed.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time    = "$.time"
      region  = "$.region"
      who     = "$.detail.userIdentity.arn"
      ip      = "$.detail.sourceIPAddress"
      session = "$.detail.requestParameters.roleSessionName"
      error   = "$.detail.errorCode"
    }
    # An AssumeRole event is logged for failures too: do not say "assumed".
    input_template = <<-EOT
      "BREAK-GLASS ROLE: AssumeRole call at <time>"
      "by: <who>  session name: <session>  region: <region>"
      "source ip: <ip>"
      "error code: <error>   (empty or null = the call SUCCEEDED; AccessDenied etc. = it was refused)"
      ""
      "qnsc-prod-breakglass opens a network path to the production database. If this was not an"
      "incident you know about, treat it as one: check CloudTrail for the session and revoke it."
    EOT
  }
}

resource "aws_cloudwatch_event_rule" "prod_breakglass_session" {
  name        = "qnsc-prod-breakglass-session"
  description = "A session issued from the production break-glass role started an SSM session (§10b)."

  event_pattern = jsonencode({
    source        = ["aws.ssm"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ssm.amazonaws.com"]
      eventName   = ["StartSession"]
      userIdentity = {
        sessionContext = { sessionIssuer = { arn = [aws_iam_role.prod_breakglass.arn] } }
      }
    }
  })

  tags = { Layer = "platform", Purpose = "security-alerts" }
}

resource "aws_cloudwatch_event_target" "prod_breakglass_session" {
  rule      = aws_cloudwatch_event_rule.prod_breakglass_session.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time   = "$.time"
      region = "$.region"
      who    = "$.detail.userIdentity.arn"
      ip     = "$.detail.sourceIPAddress"
      target = "$.detail.requestParameters.target"
      doc    = "$.detail.requestParameters.documentName"
      error  = "$.detail.errorCode"
    }
    input_template = <<-EOT
      "BREAK-GLASS ROLE IN USE: SSM StartSession at <time>"
      "by: <who>  region: <region>"
      "target: <target>  document: <doc>"
      "source ip: <ip>   error code: <error> (empty or null = the session opened)"
      ""
      "This is the production database tunnel. If this was not an incident you know about, treat it"
      "as one: check CloudTrail and terminate the session."
    EOT
  }
}
