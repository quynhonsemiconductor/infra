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
#   1. AssumeRole of the role (this region's bus): successes, AND denied attempts. A DENIED sts:AssumeRole is logged with
#      requestParameters = null and resources = null (checked in a live CloudTrail record, 2026-10-12), so
#      `requestParameters.roleArn` can never match it; the role ARN is only in `errorMessage` ("... is not authorized to
#      perform: sts:AssumeRole on resource: <role arn>"). The pattern therefore matches EITHER the request parameter OR an
#      errorMessage wildcard on the full role ARN (account included). The first version of this rule (#153) had only the
#      first branch and so never matched a denied attempt. The pattern lives in breakglass-assumed.pattern.json.tftpl and
#      is tested against fixtures with test-breakglass-pattern.sh (events:TestEventPattern).
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
  description = "AssumeRole of the production break-glass role: succeeded, or a denied attempt (§10b)."
  # AssumeRole is a read-only management event: this state is what makes EventBridge deliver it.
  state = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = templatefile("${path.module}/breakglass-assumed.pattern.json.tftpl", {
    role_arn = aws_iam_role.prod_breakglass.arn
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
      message = "$.detail.errorMessage"
    }
    # An AssumeRole event is logged for failures too: do not say "assumed". The template cannot default a missing value,
    # so the wording says what null means: a DENIED call has requestParameters = null, hence no session name.
    input_template = <<-EOT
      "BREAK-GLASS ROLE: AssumeRole call at <time>"
      "by: <who>   source ip: <ip>   region: <region>"
      "session name: <session>   (null = a DENIED call: CloudTrail records no request parameters for it)"
      "error code: <error>   (null = the call SUCCEEDED; AccessDenied etc. = it was refused)"
      "error message: <message>"
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
