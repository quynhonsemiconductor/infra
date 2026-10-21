#Requires -Version 7.0
<#
.SYNOPSIS
    Owner script, PROD tenant, Exchange Online side of the Graph mail setup.

.DESCRIPTION
    -Step Setup (default), idempotent:
      1. Shared mailboxes noreply-rova@, noreply-opshub@, noreply-kb@qnsc.vn (created only if missing).
      2. Management scopes "noreply-rova", "noreply-opshub", "noreply-kb" (created only if missing).
      3. Service principals for "Rova Prod Service", "OpsHub Prod Service", "KB Prod Service".
      4. Application Mail.Send role assignment on each Service principal, scoped to its own mailbox.
      5. Proof table: Test-ServicePrincipalAuthorization for every product against every
         dev and prod mailbox. Expected: own prod mailbox True, everything else False.
         Any mismatch throws.

    -Step RemoveSignInRole (run ONLY after a real prod invitation arrived from noreply-rova@qnsc.vn):
      Removes the old Application Mail.Send assignment on the SIGN-IN app "Rova Prod"
      (503133fe-58c0-4158-86ca-0cecb2f6f376). Dry run unless -ConfirmRemoveSignInAppRole is passed.

    Placeholders: the Entra app IDs and enterprise-app object IDs are parameters with no default.
    The owner creates the three app registrations by hand and passes the real GUIDs. Placeholder
    values such as <ROVA_PROD_SERVICE_APP_ID> are refused.

    Run as the owner, signed in to the PROD tenant. Nothing in this file has been executed against a tenant.

.EXAMPLE
    ./exchange-prod-mail.ps1 -RovaProdServiceAppId <guid> -RovaProdServiceObjectId <guid> `
        -OpshubProdServiceAppId <guid> -OpshubProdServiceObjectId <guid> `
        -KbProdServiceAppId <guid> -KbProdServiceObjectId <guid>

.EXAMPLE
    ./exchange-prod-mail.ps1 -Step RemoveSignInRole -RovaProdServiceAppId <guid>            # dry run
    ./exchange-prod-mail.ps1 -Step RemoveSignInRole -RovaProdServiceAppId <guid> -ConfirmRemoveSignInAppRole
#>
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'RemoveSignInRole')]
    [string]$Step = 'Setup',

    [string]$RovaProdServiceAppId,
    [string]$RovaProdServiceObjectId,
    [string]$OpshubProdServiceAppId,
    [string]$OpshubProdServiceObjectId,
    [string]$KbProdServiceAppId,
    [string]$KbProdServiceObjectId,

    [string]$TenantId = 'dc0f2078-ac28-4ff2-b21a-d4b28df32361',
    [string]$SignInAppId = '503133fe-58c0-4158-86ca-0cecb2f6f376',

    [switch]$ConfirmRemoveSignInAppRole
)

$ErrorActionPreference = 'Stop'

$AllMailboxes = @(
    'noreply-rova@qnsc.vn', 'noreply-opshub@qnsc.vn', 'noreply-kb@qnsc.vn'
    'noreply-rova-dev@qnsc.vn', 'noreply-opshub-dev@qnsc.vn', 'noreply-kb-dev@qnsc.vn'
)

function Assert-RealGuid {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is not set. Pass the GUID from the Entra app registration (owner step)."
    }
    if ($Value -match '^<.*>$') {
        throw "$Name is still a placeholder ('$Value'). Replace it with the real GUID."
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name is not a GUID."
    }
}

function Connect-ProdExchange {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'The ExchangeOnlineManagement module is not installed (Install-Module ExchangeOnlineManagement).'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -Organization $TenantId -ShowBanner:$false
    $conn = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
    if (-not $conn -or [string]$conn.TenantID -ne $TenantId) {
        throw "Connected tenant '$($conn.TenantID)' is not the PROD tenant $TenantId. Disconnect and sign in to the right tenant."
    }
    Write-Host "Connected to the PROD tenant $TenantId."
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
    param([string]$AppId, [string]$ObjectId, [string]$DisplayName)
    $existing = Get-ServicePrincipal -ErrorAction Stop | Where-Object { [string]$_.AppId -eq $AppId }
    if ($existing) {
        Write-Host "exists   service principal $DisplayName ($AppId)"
        return
    }
    New-ServicePrincipal -AppId $AppId -ObjectId $ObjectId -DisplayName $DisplayName | Out-Null
    Write-Host "created  service principal $DisplayName ($AppId)"
}

function Ensure-MailRoleAssignment {
    param([string]$AppId, [string]$DisplayName, [string]$Scope)
    $existing = Get-ManagementRoleAssignment -Role 'Application Mail.Send' -RoleAssignee $DisplayName -ErrorAction SilentlyContinue |
        Where-Object { $_.CustomResourceScope -eq $Scope }
    if ($existing) {
        Write-Host "exists   role Application Mail.Send for '$DisplayName' scoped to '$Scope'"
        return
    }
    New-ManagementRoleAssignment -App $AppId -Role 'Application Mail.Send' -CustomResourceScope $Scope | Out-Null
    Write-Host "created  role Application Mail.Send for '$DisplayName' scoped to '$Scope'"
}

function Invoke-SetupStep {
    Assert-RealGuid -Name 'RovaProdServiceAppId' -Value $RovaProdServiceAppId
    Assert-RealGuid -Name 'RovaProdServiceObjectId' -Value $RovaProdServiceObjectId
    Assert-RealGuid -Name 'OpshubProdServiceAppId' -Value $OpshubProdServiceAppId
    Assert-RealGuid -Name 'OpshubProdServiceObjectId' -Value $OpshubProdServiceObjectId
    Assert-RealGuid -Name 'KbProdServiceAppId' -Value $KbProdServiceAppId
    Assert-RealGuid -Name 'KbProdServiceObjectId' -Value $KbProdServiceObjectId

    $products = @(
        [pscustomobject]@{
            Product = 'rova'; Mailbox = 'noreply-rova@qnsc.vn'; Alias = 'noreply-rova'
            MailboxName = 'Rova No-Reply'; Scope = 'noreply-rova'
            AppId = $RovaProdServiceAppId; ObjectId = $RovaProdServiceObjectId; ServiceName = 'Rova Prod Service'
        },
        [pscustomobject]@{
            Product = 'opshub'; Mailbox = 'noreply-opshub@qnsc.vn'; Alias = 'noreply-opshub'
            MailboxName = 'OpsHub No-Reply'; Scope = 'noreply-opshub'
            AppId = $OpshubProdServiceAppId; ObjectId = $OpshubProdServiceObjectId; ServiceName = 'OpsHub Prod Service'
        },
        [pscustomobject]@{
            Product = 'kb'; Mailbox = 'noreply-kb@qnsc.vn'; Alias = 'noreply-kb'
            MailboxName = 'QNSC KB No-Reply'; Scope = 'noreply-kb'
            AppId = $KbProdServiceAppId; ObjectId = $KbProdServiceObjectId; ServiceName = 'KB Prod Service'
        }
    )

    Write-Host '--- 1. mailboxes'
    foreach ($p in $products) {
        Ensure-SharedMailbox -Address $p.Mailbox -Name $p.MailboxName -Alias $p.Alias
    }

    Write-Host '--- 2. management scopes'
    foreach ($p in $products) {
        Ensure-ManagementScope -Name $p.Scope -Filter "PrimarySmtpAddress -eq '$($p.Mailbox)'"
    }

    Write-Host '--- 3. service principals'
    foreach ($p in $products) {
        Ensure-ServicePrincipal -AppId $p.AppId -ObjectId $p.ObjectId -DisplayName $p.ServiceName
    }

    Write-Host '--- 4. Exchange RBAC: Application Mail.Send, scoped to own mailbox'
    foreach ($p in $products) {
        Ensure-MailRoleAssignment -AppId $p.AppId -DisplayName $p.ServiceName -Scope $p.Scope
    }

    Write-Host '--- 5. proof: Test-ServicePrincipalAuthorization'
    $rows = foreach ($p in $products) {
        foreach ($mb in $AllMailboxes) {
            $expected = [bool]($mb -eq $p.Mailbox)
            $result = Test-ServicePrincipalAuthorization -Identity $p.AppId -Resource $mb
            $actual = [bool]$result.InScope
            [pscustomobject]@{
                ServicePrincipal = $p.ServiceName
                Mailbox          = $mb
                Expected         = $expected
                Actual           = $actual
                Result           = if ($expected -eq $actual) { 'PASS' } else { 'MISMATCH' }
            }
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $mismatches = @($rows | Where-Object { $_.Result -ne 'PASS' })
    if ($mismatches.Count -gt 0) {
        throw "Authorization proof FAILED: $($mismatches.Count) row(s) differ from the expected table. Do not continue to the Graph checks. Propagation can take up to about an hour on a first assignment; re-run the table before debugging."
    }
    Write-Host "Authorization proof PASSED: $($rows.Count) of $($rows.Count) rows match the expected table."
}

function Remove-SignInAppRoleAssignment {
    [CmdletBinding()]
    param(
        [string]$SignInAppId,
        [string]$ServiceAppId,
        [switch]$ConfirmRemoveSignInAppRole
    )
    Assert-RealGuid -Name 'RovaProdServiceAppId' -Value $ServiceAppId

    $signIn = Get-ServicePrincipal -ErrorAction Stop | Where-Object { [string]$_.AppId -eq $SignInAppId }
    if (-not $signIn) {
        throw "No Exchange service principal for the sign-in app $SignInAppId. Nothing to remove."
    }
    # Every identity form the role assignment may carry for this service principal.
    $signInIds = @($signIn.ObjectId, $signIn.DisplayName, $signIn.Identity) |
        Where-Object { $_ } | ForEach-Object { [string]$_ }

    # The Service app must already be in scope for its own mailbox, or this step removes the only grant.
    $serviceCheck = Test-ServicePrincipalAuthorization -Identity $ServiceAppId -Resource 'noreply-rova@qnsc.vn'
    if (-not [bool]$serviceCheck.InScope) {
        throw 'The Rova PROD Service app is NOT in scope for noreply-rova@qnsc.vn. Refusing to remove the sign-in app grant.'
    }

    # Find it by role + scope + assignee, not by display name.
    $matches = @(
        Get-ManagementRoleAssignment -Role 'Application Mail.Send' -ErrorAction Stop |
            Where-Object { $_.CustomResourceScope -eq 'noreply-rova' -and ($signInIds -contains [string]$_.RoleAssignee) }
    )
    if ($matches.Count -eq 0) {
        Write-Host 'No Application Mail.Send assignment on the sign-in app for scope noreply-rova. Nothing to do.'
        return
    }
    if ($matches.Count -gt 1) {
        throw "Found $($matches.Count) matching assignments. Refusing to guess; inspect them by hand."
    }

    $target = $matches[0]
    Write-Host 'Matched assignment (to be removed):'
    $target | Format-List Name, RoleAssignee, Role, CustomResourceScope | Out-String | Write-Host

    if (-not $ConfirmRemoveSignInAppRole) {
        Write-Warning 'DRY RUN: nothing removed. Re-run with -ConfirmRemoveSignInAppRole only after a real prod invitation arrived from noreply-rova@qnsc.vn.'
        return
    }

    Remove-ManagementRoleAssignment -Identity $target.Name -Confirm:$false
    Write-Host "removed  assignment $($target.Name)"
    Test-ServicePrincipalAuthorization -Identity $SignInAppId -Resource 'noreply-rova@qnsc.vn' |
        Format-List Identity, InScope | Out-String | Write-Host
    Write-Host 'Expected: InScope False (or Not Run) for the sign-in app.'
}

try {
    Connect-ProdExchange
    switch ($Step) {
        'Setup' {
            Invoke-SetupStep
        }
        'RemoveSignInRole' {
            Remove-SignInAppRoleAssignment -SignInAppId $SignInAppId -ServiceAppId $RovaProdServiceAppId `
                -ConfirmRemoveSignInAppRole:$ConfirmRemoveSignInAppRole
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
