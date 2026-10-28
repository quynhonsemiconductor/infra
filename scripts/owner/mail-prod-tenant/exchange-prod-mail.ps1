#Requires -Version 7.0
<#
.SYNOPSIS
    Owner script, PROD tenant, Exchange Online side of the rova prod Graph mail setup.

.DESCRIPTION
    Entra-side (Service apps, certificates) lives in `live/identity/mail.tf` and is
    applied by the owner from the README there — this script owns ONLY the Exchange
    Online side, which is not Terraformed here.

    -Step Setup (default), idempotent, ROVA PROD ONLY (the dev service apps' Exchange
    side is live since 2026-10-18; opshub/KB prod are not live — their steps come
    with their own prod PRs):
      1. Shared mailbox noreply-rova@qnsc.vn (created only if missing).
      2. Management scope "noreply-rova" (created only if missing).
      3. Service principal for "Rova Prod Service".
      4. Application Mail.Send role assignment on that service principal, scoped to
         the "noreply-rova" scope (idempotency checked by the SP OBJECT ID, never a
         display name).
      5. Proof table: Test-ServicePrincipalAuthorization for the Rova service
         principal against every dev and prod mailbox, plus an explicit
         -ControlMailbox assertion (must be OUT of scope). A mailbox counts as in
         scope only when an 'Application Mail.Send' row with InScope True exists —
         a bare truthiness test on the cmdlet's array output would pass on any
         2+ element result. Any mismatch throws (first-hour propagation is normal —
         re-run the table before debugging).

    -Step RemoveSignInRole: removes the legacy Application Mail.Send grant on the
    "Rova Prod" SIGN-IN app's service principal (dry run by default). Run only
    after a real prod invitation arrived from noreply-rova@qnsc.vn. The undo
    command is printed before anything is removed.

    Ids are MANDATORY parameters — nothing tenant-specific is hardcoded (public
    repo). Sign in with `Connect-ExchangeOnline` interactively; the script then
    verifies the connected tenant matches -TenantId.

.EXAMPLE
    ./exchange-prod-mail.ps1 -TenantId <tenant-guid> -SignInAppId <sign-in-app-guid> `
      -RovaProdServiceAppId <app-id-from-mail_service_client_ids> `
      -RovaProdServiceObjectId <sp-object-id> -ControlMailbox noreply-rova-dev@qnsc.vn
    ./exchange-prod-mail.ps1 -Step RemoveSignInRole -TenantId <tenant-guid> -SignInAppId <sign-in-app-guid> `
      -RovaProdServiceAppId <app-id> -ControlMailbox noreply-rova-dev@qnsc.vn            # dry run
    ./exchange-prod-mail.ps1 -Step RemoveSignInRole ... -ConfirmRemoveSignInAppRole
#>
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'RemoveSignInRole')]
    [string]$Step = 'Setup',

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$SignInAppId,

    [Parameter(Mandatory)]
    [string]$RovaProdServiceAppId,

    [Parameter(Mandatory)]
    [string]$RovaProdServiceObjectId,

    # A mailbox that must stay OUT of scope for the Rova service principal
    # (e.g. noreply-rova-dev@qnsc.vn) — asserted False in addition to the table.
    [Parameter(Mandatory)]
    [string]$ControlMailbox,

    [switch]$ConfirmRemoveSignInAppRole
)

$ErrorActionPreference = 'Stop'

$AllMailboxes = @(
    'noreply-rova@qnsc.vn', 'noreply-opshub@qnsc.vn', 'noreply-kb@qnsc.vn'
    'noreply-rova-dev@qnsc.vn', 'noreply-opshub-dev@qnsc.vn', 'noreply-kb-dev@qnsc.vn'
)
$ServiceName = 'Rova Prod Service'
$MailRole = 'Application Mail.Send'
$ScopeName = 'noreply-rova'
$OwnMailbox = 'noreply-rova@qnsc.vn'

function Assert-RealGuid {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is not set. Take the app id from 'tofu output mail_service_client_ids' (live/identity) and the SP object id from the 'az ad sp show' export."
    }
    if ($Value -match '^<.*>$') {
        throw "$Name is still a placeholder ('$Value'). Replace it with the real GUID."
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name is not a GUID."
    }
}

function Test-MailInScope {
    # TRUE only when an Application Mail.Send row for this principal reports
    # InScope — Test-ServicePrincipalAuthorization returns one row per role, and
    # [bool] on a 2+ element array is always true, so filter explicitly.
    param([string]$AppId, [string]$Mailbox)
    $rows = @(Test-ServicePrincipalAuthorization -Identity $AppId -Resource $Mailbox)
    return @($rows | Where-Object { $_.RoleName -eq $MailRole -and $_.InScope }).Count -gt 0
}

function Connect-ProdExchange {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'The ExchangeOnlineManagement module is not installed (Install-Module ExchangeOnlineManagement).'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -ShowBanner:$false   # interactive sign-in; no -Organization
    $conn = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
    if (-not $conn -or [string]$conn.TenantID -ne $TenantId) {
        throw "Connected tenant '$($conn.TenantID)' is not the expected tenant $TenantId. Disconnect and sign in to the right tenant."
    }
    Write-Host "Connected to tenant $TenantId."
}

function Ensure-SharedMailbox {
    param([string]$Address, [string]$Name, [string]$Alias)
    $existing = Get-Mailbox -Identity $Address -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.RecipientTypeDetails -ne 'SharedMailbox') {
            throw "$Address exists as $($existing.RecipientTypeDetails), not SharedMailbox. Fix it by hand."
        }
        Write-Host "exists   mailbox $Address (SharedMailbox)"
        return
    }
    New-Mailbox -Shared -Name $Name -Alias $Alias -PrimarySmtpAddress $Address | Out-Null
    Write-Host "created  mailbox $Address"
}

function Ensure-ManagementScope {
    param([string]$Name, [string]$Filter)
    $existing = Get-ManagementScope -Identity $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ([string]$existing.RecipientFilter -ne $Filter) {
            throw "Scope '$Name' exists with RecipientFilter '$($existing.RecipientFilter)', expected '$Filter'. Fix it by hand."
        }
        Write-Host "exists   scope $Name (filter as expected)"
        return
    }
    New-ManagementScope -Name $Name -RecipientRestrictionFilter $Filter | Out-Null
    Write-Host "created  scope $Name"
}

function Ensure-ServicePrincipal {
    $sp = Get-ServicePrincipal -ErrorAction SilentlyContinue
    if ($sp) {
        Write-Host "exists   service principal $ServiceName ($RovaProdServiceAppId, object $($sp.ObjectId))"
        return $sp
    }
    $sp = New-ServicePrincipal -AppId $RovaProdServiceAppId -ObjectId $RovaProdServiceObjectId -DisplayName $ServiceName
    Write-Host "created  service principal $ServiceName ($RovaProdServiceAppId)"
    return $sp
}

function Ensure-MailRoleAssignment {
    # Idempotency by the SP OBJECT ID — never a display name.
    param([string]$SpObjectId)
    $existing = Get-ManagementRoleAssignment -Role $MailRole -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.RoleAssignee -eq [string]$SpObjectId -and $_.CustomResourceScope -eq $ScopeName }
    if ($existing) {
        Write-Host "exists   role $MailRole for object $SpObjectId scoped to '$ScopeName'"
        return
    }
    New-ManagementRoleAssignment -App $RovaProdServiceAppId -Role $MailRole -CustomResourceScope $ScopeName | Out-Null
    Write-Host "created  role $MailRole for object $SpObjectId scoped to '$ScopeName'"
}

function Invoke-SetupStep {
    Assert-RealGuid -Name 'RovaProdServiceAppId' -Value $RovaProdServiceAppId
    Assert-RealGuid -Name 'RovaProdServiceObjectId' -Value $RovaProdServiceObjectId
    if ($AllMailboxes -notcontains $ControlMailbox) {
        throw "ControlMailbox '$ControlMailbox' is not one of the known noreply mailboxes — pick one from the proof table (e.g. noreply-rova-dev@qnsc.vn)."
    }
    if ($ControlMailbox -eq $OwnMailbox) {
        throw 'ControlMailbox must be a mailbox that stays OUT of scope, not the own prod mailbox.'
    }

    Write-Host '--- 1. mailbox'
    Ensure-SharedMailbox -Address $OwnMailbox -Name 'Rova No-Reply' -Alias 'noreply-rova'

    Write-Host '--- 2. management scope'
    Ensure-ManagementScope -Name $ScopeName -Filter "PrimarySmtpAddress -eq '$OwnMailbox'"

    Write-Host '--- 3. service principal'
    $sp = Ensure-ServicePrincipal

    Write-Host '--- 4. Exchange RBAC: Application Mail.Send, scoped to own mailbox'
    Ensure-MailRoleAssignment -SpObjectId $sp.ObjectId

    Write-Host '--- 5. proof: Test-ServicePrincipalAuthorization (explicit Application Mail.Send filter)'
    $rows = foreach ($mb in $AllMailboxes) {
        $expected = [bool]($mb -eq $OwnMailbox)
        $actual = Test-MailInScope -AppId $RovaProdServiceAppId -Mailbox $mb
        [pscustomobject]@{
            ServicePrincipal = $ServiceName
            Mailbox          = $mb
            Expected         = $expected
            Actual           = $actual
            Result           = if ($expected -eq $actual) { 'PASS' } else { 'MISMATCH' }
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    if (Test-MailInScope -AppId $RovaProdServiceAppId -Mailbox $ControlMailbox) {
        throw "ControlMailbox proof FAILED: '$ControlMailbox' is IN scope for the Rova service principal — it must stay OUT. Remove the over-broad assignment before continuing."
    }
    Write-Host "ControlMailbox proof PASSED: '$ControlMailbox' is out of scope."

    $mismatches = @($rows | Where-Object { $_.Result -ne 'PASS' })
    if ($mismatches.Count -gt 0) {
        throw "Authorization proof FAILED: $($mismatches.Count) row(s) differ from the expected table. Do not continue to the Graph checks. Propagation can take up to about an hour on a first assignment; re-run the table before debugging."
    }
    Write-Host "Authorization proof PASSED: $($rows.Count) of $($rows.Count) rows match the expected table."
}

function Remove-SignInAppRoleAssignment {
    Assert-RealGuid -Name 'SignInAppId' -Value $SignInAppId
    Assert-RealGuid -Name 'RovaProdServiceAppId' -Value $RovaProdServiceAppId

    $signIn = Get-ServicePrincipal -ErrorAction Stop | Where-Object { [string]$_.AppId -eq $SignInAppId }
    if (-not $signIn) {
        throw "No Exchange service principal for the sign-in app $SignInAppId. Nothing to remove."
    }
    # Every identity form the role assignment may carry for this service principal.
    $signInIds = @($signIn.ObjectId, $signIn.DisplayName, $signIn.Identity) |
        Where-Object { $_ } | ForEach-Object { [string]$_ }

    # The Service app must already be in scope for its own mailbox, or this step removes the only grant.
    if (-not (Test-MailInScope -AppId $RovaProdServiceAppId -Mailbox $OwnMailbox)) {
        throw "The $ServiceName app is NOT in scope for $OwnMailbox. Refusing to remove the sign-in app grant."
    }

    # Find it by role + scope + assignee, not by display name.
    $signInGrants = @(
        Get-ManagementRoleAssignment -Role $MailRole -ErrorAction Stop |
            Where-Object { $_.CustomResourceScope -eq $ScopeName -and ($signInIds -contains [string]$_.RoleAssignee) }
    )
    if ($signInGrants.Count -eq 0) {
        Write-Host "No $MailRole assignment on the sign-in app for scope $ScopeName. Nothing to do."
        return
    }
    if ($signInGrants.Count -gt 1) {
        throw "Found $($signInGrants.Count) matching assignments. Refusing to guess; inspect them by hand."
    }

    $target = $signInGrants[0]
    Write-Host 'Matched assignment (to be removed):'
    $target | Format-List Name, RoleAssignee, Role, CustomResourceScope | Out-String | Write-Host
    Write-Host "UNDO (recreate the assignment if this removal was wrong):"
    Write-Host "  New-ManagementRoleAssignment -App $SignInAppId -Role '$MailRole' -CustomResourceScope $ScopeName"

    if (-not $ConfirmRemoveSignInAppRole) {
        Write-Warning 'DRY RUN: nothing removed. Re-run with -ConfirmRemoveSignInAppRole only after a real prod invitation arrived from noreply-rova@qnsc.vn.'
        return
    }

    Remove-ManagementRoleAssignment -Identity $target.Name -Confirm:$false
    Write-Host "removed  assignment $($target.Name)"
    if (Test-MailInScope -AppId $SignInAppId -Mailbox $OwnMailbox) {
        throw "Removal did not take effect: the sign-in app is still in scope for $OwnMailbox."
    }
    Write-Host "Verified: the sign-in app is out of scope for $OwnMailbox."
}

try {
    Connect-ProdExchange
    switch ($Step) {
        'Setup' {
            Invoke-SetupStep
        }
        'RemoveSignInRole' {
            Remove-SignInAppRoleAssignment
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
