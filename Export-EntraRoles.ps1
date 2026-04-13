
function Invoke-MgGraphRequestPaging {
    param (
        [string]$Uri,
        [string]$Method = "GET"
    )
    
    $results = @()
    $currentUri = $Uri
    while ($null -ne $currentUri) {
        try {
            $req = Invoke-MgGraphRequest -Uri $currentUri -Method $Method -OutputType PSObject -ErrorAction stop
            $results += $req.value
            if ($req.'@odata.nextLink' -ne $null) {
                $currentUri = $req.'@odata.nextLink'
            } else {
                $currentUri = $null
            }
            
        }
        catch {
            Write-error $err
            return "ERROR"
        }
    }
    
    return $results
}

Import-Module Microsoft.Graph.Authentication
if ($null -eq (Get-MgContext)) {
    Connect-MgGraph -Scopes "Directory.Read.All","RoleManagement.Read.All","RoleManagementPolicy.Read.AzureADGroup","UserAuthenticationMethod.Read.All"
}
$WorkingFolder = $PSScriptRoot
if ($WorkingFolder -eq "") {$WorkingFolder = $pwd}

# Graph URIs
$RoleDefinitionsURI     = "https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions?`$top=500"
$RoleAssignmentsURI     = "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?`$expand=principal"
$RoleEligibilityURI     = "https://graph.microsoft.com/beta/roleManagement/directory/roleEligibilitySchedules?`$expand=principal"
$AssignableGroupsURI    = "https://graph.microsoft.com/beta/groups?`$filter=isassignabletorole eq true&`$expand=members"
$PIMRolePoliciesURI     = "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"

# Graph requests
$RoleDefinitions    = Invoke-MgGraphRequestPaging -Uri $RoleDefinitionsURI
$RoleAssignments    = Invoke-MgGraphRequestPaging -Uri $RoleAssignmentsURI
$RoleEligibility    = Invoke-MgGraphRequestPaging -Uri $RoleEligibilityURI
$AssignableGroups   = Invoke-MgGraphRequestPaging -uri $AssignableGroupsURI
$PIMRolePolicies    = Invoke-MgGraphRequestPaging -Uri $PIMRolePoliciesURI

$tierRoles = Get-Content "$WorkingFolder\tiered-entra-roles.json" | ConvertFrom-Json #https://github.com/emiliensocchi/azure-tiering/blob/main/Entra%20roles/tiered-entra-roles.json
if ($null -eq $tierRoles){Write-warning "Failed to get Entra roles tier definition"}

$AssignedRoles = @()
foreach ($role in $RoleAssignments) {
    $UserMFAMethods = ""
    $UserMFAphishresistant = ""
    if ($role.principal.'@odata.type' -like "*user*") {
        $userid = $role.principal.id
        $UserMFAUri = "https://graph.microsoft.com/beta/users/$userid/authentication/methods"
        $UserMFA = Invoke-MgGraphRequestPaging -uri $UserMFAUri
        $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
        $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
    }
    
    $NbGroupMembers = ""
    if ($role.principal.'@odata.type' -like "*group*"){
        $NbGroupMembers = (($AssignableGroups | where DisplayName -eq $role.principal.displayName).members).count
    }

    $current = [PSCustomObject]@{
        Role                        = ($RoleDefinitions | Where-Object id -eq $role.roleDefinitionid).displayName
        Tier                        = ($tierRoles | where id -eq $role.roleDefinitionId).tier
        PrincipalType               = $role.principal.'@odata.type' -replace "#microsoft.graph.",""
        MembershipType              = "DIRECT"
        DisplayName                 = $role.principal.DisplayName
        UserPrincipalName           = $role.principal.userprincipalname
        Enabled                     = $role.principal.accountEnabled
        MFAphishresistantAvailable  = $UserMFAphishresistant
        MFAMethods                  = $UserMFAMethods
        NumberOfGroupMembers        = $NbGroupMembers
        #LastSignIn = $role.principal.signInSessionsValidFromDateTime
        #MFA methods
        #Last IP
    }
    $AssignedRoles += $current
}

$EligibleRoles = @()
foreach ($role in $RoleEligibility) {
    $UserMFAMethods = ""
    $UserMFAphishresistant = ""
    if ($role.principal.'@odata.type' -like "*user*") {
        $userid = $role.principal.id
        $UserMFAUri = "https://graph.microsoft.com/beta/users/$userid/authentication/methods"
        $UserMFA = Invoke-MgGraphRequestPaging -uri $UserMFAUri
        $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
        $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
    }

    $NbGroupMembers = ""
    if ($role.principal.'@odata.type' -like "*group*"){
        $NbGroupMembers = (($AssignableGroups | where DisplayName -eq $role.principal.displayName).members).count
    }
    
    $current = [PSCustomObject]@{
        Role                = ($RoleDefinitions | Where-Object id -eq $role.roleDefinitionid).displayName
        Tier                = ($tierRoles | where id -eq $role.roleDefinitionId).tier
        PrincipalType       = $role.principal.'@odata.type' -replace "#microsoft.graph.",""
        MembershipType      = "ELIGIBLE"
        DisplayName         = $role.principal.DisplayName
        UserPrincipalName   = $role.principal.userprincipalname
        Enabled             = $role.principal.accountEnabled
        MFAphishresistantAvailable  = $UserMFAphishresistant
        MFAMethods                  = $UserMFAMethods
        #LastSignIn = $role.principal.signInSessionsValidFromDateTime
        #MFA methods
        #Last IP
        NumberOfGroupMembers        = $NbGroupMembers
        PIMDuration          = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq "Expiration_EndUser_Assignment").maximumDuration -replace "PT",""
        PIMValidation        = ((($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "Enablement_EndUser_Assignment").enabledRules | select -Unique) -join "|"
        PIMApproval          = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "Approval_EndUser_Assignment").setting.isApprovalRequired
        PIMAuthContext       = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "AuthenticationContext_EndUser_Assignment").claimvalue
    }
    $EligibleRoles += $current
}

$allroles = ($AssignedRoles + $EligibleRoles) | Sort-Object Role

$AdminGroups = @()
foreach ($group in $AssignableGroups){
    $GroupId = $group.id
    $PIMGroupsPoliciesURI   = "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '$groupID' and scopeType eq 'Group'&`$expand=policy(`$expand=rules)"
    $PIMGroupPolicy         = Invoke-MgGraphRequestPaging -uri $PIMGroupsPoliciesURI   
    $PIMEnabled             = switch ((($PIMGroupPolicy | where roleDefinitionId -eq "member").policy).lastModifiedDateTime) {
            $null {"No"}
            Default {"Yes"}
        }

    $current = [PSCustomObject]@{
        DisplayName         = $group.displayName
        Role                = ($allroles | where DisplayName -eq $group.displayName).Role -join "|"
        RoleAssignmentType  = ($allroles | where DisplayName -eq $group.displayName).MembershipType -join "|"
        MembersUPN          = $group.members.userPrincipalName -join "|"
        #PIMforGrpEnabled    = $PIMEnabled
    }

    #if ($PIMEnabled -eq "Yes") {
    #    $current | Add-Member -NotePropertyName PIMRules -NotePropertyValue (($PIMGroupPolicy | where roleDefinitionId -eq "member").policy.rules | where id -eq "Enablement_EndUser_Assignment").enabledRules
    #    $current | Add-Member -NotePropertyName PIMDuration -NotePropertyValue ((($PIMGroupPolicy | where roleDefinitionId -eq "member").policy.rules | where id -eq "Expiration_EndUser_Assignment").maximumDuration).replace "PT",""
    #}

    $AdminGroups += $current
}

$AdminRolesDetail = @()
foreach ($role in $allroles){
    if ($role.principalType -eq "group") {
        $members = (($AdminGroups | where DisplayName -eq $role.DisplayName).MembersUPN).split("|")
        foreach ($member in $members) {
            $mgmember = $AssignableGroups.members | where userPrincipalName -eq $member | select -Unique
            $UserMFAMethods = ""
            $UserMFAphishresistant = ""
            if ($mgmember.'@odata.type' -like "*user*") {
                $userid = $mgmember.id
                $UserMFAUri = "https://graph.microsoft.com/beta/users/$userid/authentication/methods"
                $UserMFA = Invoke-MgGraphRequestPaging -uri $UserMFAUri
                $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
                $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
            }
            $current = [PSCustomObject]@{
                Role                = $role.role
                Tier                = $role.tier
                PrincipalType       = $mgmember.'@odata.type' -replace "#microsoft.graph.",""
                MembershipType      = $Role.MembershipType
                DisplayName         = $mgmember.DisplayName
                UserPrincipalName   = $mgmember.UserPrincipalName
                Enabled             = $mgmember.accountEnabled
                MFAphishresistantAvailable  = $UserMFAphishresistant
                MFAMethods                  = $UserMFAMethods
                #LastSignIn = $role.principal.signInSessionsValidFromDateTime
                #MFA methods
                #Last IP
                AssignedThrough      = $role.DisplayName
                PIMDuration          = $role.PIMDuration
                PIMValidation        = $role.PIMValidation
                PIMApproval          = $role.PIMApproval
                PIMAuthContext       = $Role.PIMAuthContext
            }
            $AdminRolesDetail += $current
        }
    } 
    else {
        $current = $role     
        $AdminRolesDetail += $current
        $AdminRolesDetail | add-member -NotePropertyName AssignedThrough -NotePropertyValue "Direct" -force
    }

}

#Export
$allroles | export-csv $WorkingFolder\AdminRolesSummary.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
$AdminGroups | export-csv $WorkingFolder\AdminEligibleGroups.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
$AdminRolesDetail | select -ExcludeProperty NumberOfGroupMembers | export-csv $WorkingFolder\AdminRolesDetails.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8

#Analysis
Write-host "Export completed : $WorkingFolder" -ForegroundColor Cyan
Write-host "--------------------------------"
$NumberOfRoles = ($allroles | where role -ne $null | select role -Unique).count
$NumberOfAssignments = $AdminRolesDetail.count
Write-Host "Found $NumberOfRoles admin roles with $NumberOfAssignments assignments"
#Tier0
$Tier0Admins        = $AdminRolesDetail | where Tier -eq "0"
$Tier0AdminsCount   = $Tier0Admins.count
$Tier0GAAdmins      = ($AdminRolesDetail | where Role -eq "Global Administrator").count
$Tier0NoPIM         = ($Tier0Admins | where MembershipType -ne "ELIGIBLE").count
$Tier0NoPRMFA       = ($Tier0Admins | where MFAphishresistantAvailable -ne "YES").count
if ($Tier0AdminsCount -ge 20) {$WarningT0 = "⚠️"} else {$WarningT0 = ""}
if ($Tier0NoPIM -ge 1 -or $Tier0NoPRMFA -ge 1){$Warning = "⚠️"} else {$warning = ""}
if ($Tier0GAAdmins -ge 5){$WarningGA = "⚠️"} else {$warningGA = ""}
Write-host "Tier 0 : " -ForegroundColor DarkRed -NoNewline
Write-host "$Tier0AdminsCount admins $warningT0"
Write-host "`t- $Tier0GAAdmins Global Admins $warningGA"
Write-host "`t- $Tier0NoPIM without PIM (permanent admin) $warning" 
Write-host "`t- $Tier0NoPRMFA without MFA phish resistant available $warning" 

#Tier1
$Tier1Admins        = $AdminRolesDetail | where Tier -eq "1"
$Tier1AdminsCount   = $Tier1Admins.count
$Tier1NoPIM         = ($Tier1Admins | where MembershipType -ne "ELIGIBLE").count
$Tier1NoPRMFA       = ($Tier1Admins | where MFAphishresistantAvailable -ne "YES").count
if ($Tier1NoPIM -ge 5)   {$warningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier1NoPRMFA -ge 1) {$warningMFA = "⚠️"} else {$warningMFA = ""}
Write-host "Tier 1 : " -ForegroundColor Darkyellow -NoNewline
Write-host "$Tier1AdminsCount admins"
Write-host "`t- $Tier1NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier1NoPRMFA without MFA phish resistant available $warningMFA" 

#Tier2 or untiered
$Tier2Admins        = $AdminRolesDetail | where Tier -eq "2"
$Tier2Admins       += $AdminRolesDetail | where Tier -eq ""
$Tier2AdminsCount   = $Tier2Admins.count
$Tier2NoPIM         = ($Tier2Admins | where MembershipType -ne "ELIGIBLE").count
$Tier2NoPRMFA       = ($Tier2Admins | where MFAphishresistantAvailable -ne "YES").count
if ($Tier2NoPIM -ge 10)   {$warningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier2NoPRMFA -ge 10) {$warningMFA = "⚠️"} else {$warningMFA = ""}
Write-host "Tier 2 (or untiered) : " -ForegroundColor Magenta -NoNewline
Write-host "$Tier2AdminsCount admins"
Write-host "`t- $Tier2NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier2NoPRMFA without MFA phish resistant available $warningMFA" 

# out enabled/MFA methods/last sign in/Sign ins IPs