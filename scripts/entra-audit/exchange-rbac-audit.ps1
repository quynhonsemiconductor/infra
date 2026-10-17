<#
.SYNOPSIS
  READ-ONLY audit of Exchange Online RBAC for Applications: which app can send mail as whom.

.DESCRIPTION
  Lists every service principal known to Exchange Online, every management role assignment held by a service
  principal, and every management scope, then writes exchange.json for entra_report.py. Prints each app's
  "Application Mail.*" role with its scope filter and flags an assignment that has NO custom resource scope
  (such an app can send as ANY mailbox in the tenant).

  Only Get-* cmdlets are used (plus Connect/Disconnect). check-readonly.sh enforces that in CI.

.PARAMETER OutDir
  Where exchange.json is written. Default: ~/entra-audit-<date>/ (the same default as entra-audit.sh).
  Keep it outside any git repository: the file names your mailboxes and apps.

.PARAMETER NoConnect
  Skip Connect-ExchangeOnline. For the tests, which define stand-ins for the Get-* cmdlets.

.NOTES
  Needs the ExchangeOnlineManagement module (see the README for the install command) and an account
  that can read Exchange configuration (Global Reader, or the Exchange "View-Only Organization Management" role group).
  No write role is needed or used.

.EXAMPLE
  pwsh ./exchange-rbac-audit.ps1
  pwsh ./exchange-rbac-audit.ps1 ~/entra-audit-2026-10-18
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console report for the person running the audit.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$OutDir = (Join-Path $HOME ('entra-audit-' + (Get-Date -Format 'yyyy-MM-dd'))),
    [switch]$NoConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Text {
    # Exchange returns typed objects (identities, scopes); the report needs plain strings or null.
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = "$Value"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Select-Field {
    param($Item, [string[]]$Names)
    $record = [ordered]@{}
    foreach ($name in $Names) {
        $value = $null
        if ($Item.PSObject.Properties.Name -contains $name) { $value = ConvertTo-Text $Item.$name }
        $record[$name] = $value
    }
    return $record
}

if (-not $NoConnect) {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'The ExchangeOnlineManagement module is not installed; see the README prerequisites.'
    }
    Import-Module ExchangeOnlineManagement
    Connect-ExchangeOnline -ShowBanner:$false
}

try {
    Write-Host 'Reading service principals...'
    $servicePrincipals = @(Get-ServicePrincipal | ForEach-Object { Select-Field $_ @('AppId', 'ObjectId', 'DisplayName', 'Identity', 'Name') })

    Write-Host 'Reading role assignments of service principals...'
    $assignmentFields = @('Name', 'Role', 'RoleAssignee', 'RoleAssigneeName', 'RoleAssigneeType', 'CustomResourceScope',
        'CustomRecipientWriteScope', 'RecipientWriteScope', 'RecipientReadScope', 'ConfigWriteScope', 'Enabled')
    $roleAssignments = @(Get-ManagementRoleAssignment -RoleAssigneeType ServicePrincipal | ForEach-Object { Select-Field $_ $assignmentFields })

    Write-Host 'Reading management scopes...'
    $managementScopes = @(Get-ManagementScope | ForEach-Object { Select-Field $_ @('Name', 'ScopeRestrictionType', 'RecipientRoot', 'RecipientFilter', 'Exclusive') })
}
finally {
    if (-not $NoConnect) { Disconnect-ExchangeOnline -Confirm:$false | Out-Null }
}

$model = [ordered]@{
    collectedAt       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    servicePrincipals = $servicePrincipals
    roleAssignments   = $roleAssignments
    managementScopes  = $managementScopes
}

[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
$path = Join-Path $OutDir 'exchange.json'
$model | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding utf8

# --- console summary ---
$names = @{}
foreach ($sp in $servicePrincipals) {
    foreach ($key in @($sp.ObjectId, $sp.Identity, $sp.AppId, $sp.Name)) {
        if ($key) { $names[$key.ToLowerInvariant()] = $sp.DisplayName }
    }
}
$mail = @($roleAssignments | Where-Object { $_.Role -like 'Application Mail.*' })
Write-Host ''
Write-Host "Application Mail.* role assignments: $($mail.Count)"
$unscoped = 0
foreach ($assignment in $mail) {
    $who = $assignment.RoleAssigneeName
    if ($who -and $names.ContainsKey($who.ToLowerInvariant())) { $who = "$($names[$who.ToLowerInvariant()]) ($who)" }
    $filter = $null
    if ($assignment.CustomResourceScope) {
        $scope = $managementScopes | Where-Object { $_.Name -eq $assignment.CustomResourceScope } | Select-Object -First 1
        if ($scope) { $filter = $scope.RecipientFilter }
    }
    if (-not $assignment.CustomResourceScope) {
        $unscoped++
        Write-Host ("  FAIL  {0}: {1}  has NO custom resource scope (can send as any mailbox)" -f $who, $assignment.Role)
    }
    elseif (-not $filter) {
        $unscoped++
        Write-Host ("  FAIL  {0}: {1}  scope '{2}' has no recipient filter" -f $who, $assignment.Role, $assignment.CustomResourceScope)
    }
    else {
        Write-Host ("  ok    {0}: {1}  scope '{2}' = {3}" -f $who, $assignment.Role, $assignment.CustomResourceScope, $filter)
    }
}
if ($roleAssignments.Count -ge 1000) {
    Write-Warning 'The list has 1000 entries; the cmdlet may have truncated it.'
}
Write-Host ''
Write-Host "Wrote $path"
Write-Host 'Next: run entra-audit.sh --report-only on the same directory.'
if ($unscoped -gt 0) { exit 1 }
