#Requires -Modules Microsoft.Graph.Authentication
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

function Get-AssignmentInfo {
    param (
        $assignment,
        $PIM = $false
    )
    
    $UserMFAMethods = ""
    $UserMFAphishresistant = ""
    if ($assignment.principal.'@odata.type' -like "*user*") {
        $userid = $assignment.principal.id
        $UserMFAUri = "https://graph.microsoft.com/beta/users/$userid/authentication/methods"
        $UserMFA = Invoke-MgGraphRequestPaging -uri $UserMFAUri
        $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
        $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
    }
    
    $NbGroupMembers = ""
    if ($assignment.principal.'@odata.type' -like "*group*"){
        $NbGroupMembers = (($AssignableGroups | where DisplayName -eq $assignment.principal.displayName).members).count
    }

    if ($PIM -eq $false){
        $MembershipType = "PERMANENT"
        $PIMDuration    = ""
        $PIMValidation  = ""
        $PIMApproval    = ""
        $PIMAuthContext = ""
    } else {
        $MembershipType = "ELIGIBLE"
        $PIMDuration    = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq "Expiration_EndUser_Assignment").maximumDuration -replace "PT",""
        $PIMValidation  = ((($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "Enablement_EndUser_Assignment").enabledRules | select -Unique) -join "|"
        $PIMApproval    = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "Approval_EndUser_Assignment").setting.isApprovalRequired
        $PIMAuthContext = (($PIMRolePolicies | where roleDefinitionId -eq $role.roleDefinitionId).policy.rules | where id -eq  "AuthenticationContext_EndUser_Assignment").claimvalue
    }

    $AssignmentInfo = [PSCustomObject]@{
        Role                        = ($RoleDefinitions | Where-Object id -eq $assignment.roleDefinitionid).displayName
        Tier                        = ($tierRoles | where id -eq $assignment.roleDefinitionId).tier
        PrincipalType               = $assignment.principal.'@odata.type' -replace "#microsoft.graph.",""
        MembershipType              = $MembershipType
        DisplayName                 = $assignment.principal.DisplayName
        UserPrincipalName           = $assignment.principal.userprincipalname
        Enabled                     = $assignment.principal.accountEnabled
        NumberOfGroupMembers        = $NbGroupMembers
        PIMDuration                 = $PIMDuration
        PIMValidation               = $PIMValidation
        PIMApproval                 = $PIMApproval
        PIMAuthContext              = $PIMAuthContext
        MFAphishresistantAvailable  = $UserMFAphishresistant
        MFAMethods                  = $UserMFAMethods
        id                          = $assignment.principal.Id
    }

    return $AssignmentInfo
}

Import-Module Microsoft.Graph.Authentication

if ($null -eq (Get-MgContext)) {
    Write-host "Connecting to MgGraph..."
    Connect-MgGraph -Scopes "Directory.Read.All","RoleManagement.Read.All","UserAuthenticationMethod.Read.All" #"RoleManagementPolicy.Read.AzureADGroup"
} 
else {
    Write-host "Already connected to MgGraph using $((Get-MgContext).AppName)"
    Write-host "Ensure following scopes are available : Directory.Read.All,RoleManagement.Read.All,UserAuthenticationMethod.Read.All"
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
Write-host "Starting Graph Exports"
Write-host "- Exporting role definitions..." -ForegroundColor DarkGray
$RoleDefinitions    = Invoke-MgGraphRequestPaging -Uri $RoleDefinitionsURI
Write-host "- Exporting permanent role assignments..." -ForegroundColor DarkGray
$RoleAssignments    = Invoke-MgGraphRequestPaging -Uri $RoleAssignmentsURI
Write-host "- Exporting eligible role assignments..." -ForegroundColor DarkGray
$RoleEligibility    = Invoke-MgGraphRequestPaging -Uri $RoleEligibilityURI
Write-host "- Exporting role assignable groups..." -ForegroundColor DarkGray
$AssignableGroups   = Invoke-MgGraphRequestPaging -uri $AssignableGroupsURI
Write-host "- Exporting PIM configuration for all roles..." -ForegroundColor DarkGray
$PIMRolePolicies    = Invoke-MgGraphRequestPaging -Uri $PIMRolePoliciesURI
Write-host "--- ✅ Graph exports done ---" -ForegroundColor Green

Write-host "- Importing roles tier definition (aztier.com)... " -ForegroundColor DarkGray
if (!(test-path "$WorkingFolder\tiered-entra-roles.json")){
    Write-host "file not found, trying to download it" -ForegroundColor Yellow
    (Invoke-WebRequest "https://raw.githubusercontent.com/emiliensocchi/azure-tiering/refs/heads/main/Entra%20roles/tiered-entra-roles.json").content | out-file "$WorkingFolder\tiered-entra-roles.json"
}
$tierRoles = Get-Content "$WorkingFolder\tiered-entra-roles.json" | ConvertFrom-Json 
write-host "$($TierRoles.count) role tier definition found"
if ($null -eq $tierRoles){Write-warning "Failed to get Entra roles tier definition"}
else {write-host "--- ✅ done ---" -ForegroundColor Green}

Write-Host "Processing permanent assignments... " -ForegroundColor DarkGray -NoNewline
$AssignedRoles = @()
foreach ($role in $RoleAssignments) {
    $AssignedRoles += Get-AssignmentInfo -assignment $role
}
write-host "$($assignedRoles.count) found"

Write-host "Processing eligible assignments... " -ForegroundColor DarkGray -NoNewline
$EligibleRoles = @()
foreach ($role in $RoleEligibility) {
    $EligibleRoles += Get-AssignmentInfo -assignment $role -PIM $True
}
write-host "$($EligibleRoles.count) found"
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all assignments to $WorkingFolder\AdminRolesSummary.csv..." -ForegroundColor DarkGray
$AllRoleAssignments = ($AssignedRoles + $EligibleRoles) | Sort-Object Tier,Role
$AllRoleAssignments | select -ExcludeProperty id | export-csv $WorkingFolder\AdminRolesSummary.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Expanding role assignable groups... " -ForegroundColor DarkGray -NoNewline
$AdminGroups = @()
foreach ($group in $AssignableGroups){
    $current = [PSCustomObject]@{
        DisplayName         = $group.displayName
        Role                = ($AllRoleAssignments | where DisplayName -eq $group.displayName).Role -join "|"
        RoleAssignmentType  = ($AllRoleAssignments | where DisplayName -eq $group.displayName).MembershipType -join "|"
        MembersUPN          = $group.members.userPrincipalName -join "|"
        MembersID           = $group.members.Id
        #PIMforGrpEnabled    = $PIMEnabled
    }

    $AdminGroups += $current
}
write-host "$($Admingroups.count) groups found"
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all role assignable groups to $WorkingFolder\AdminEligibleGroups.csv..." -ForegroundColor DarkGray
$AdminGroups | select -ExcludeProperty MembersId | export-csv $WorkingFolder\AdminEligibleGroups.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Resolving group members and role assignments to create the complete report..." -ForegroundColor DarkGray
$AdminRolesDetail = @()
foreach ($role in $AllRoleAssignments){
    if ($role.principalType -eq "group") {
        $members = ($AdminGroups | where DisplayName -eq $role.DisplayName).MembersID
        foreach ($member in $members) {
            $mgmember = $AssignableGroups.members | where Id -eq $member | select -Unique
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
        $current | add-member -NotePropertyName AssignedThrough -NotePropertyValue "Direct" -force
        $AdminRolesDetail += $current
    }

}
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all role assignable groups to $WorkingFolder\AdminRolesDetails.csv..." -ForegroundColor DarkGray
$AdminRolesDetail | select Role,Tier,MembershipType,AssignedThrough,PrincipalType,DisplayName,UserPrincipalName,Enabled,PIMDuration,PIMValidation,PIMApproval,PIMAuthContext,MFAphishresistantAvailable,MFAMethods -ExcludeProperty id,NumberOfGroupMembers | sort-object Tier,Role | export-csv $WorkingFolder\AdminRolesDetails.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

#Analysis
Write-host "Export completed : $WorkingFolder" -ForegroundColor Cyan
Write-host "--------------------------------"
$NumberOfRoles = ($AllRoleAssignments | where role -ne $null | select role -Unique).count
$NumberOfAssignments = $AdminRolesDetail.count
Write-Host "Found $NumberOfRoles admin roles with $NumberOfAssignments assignments"
#Tier0
$Tier0Admins        = $AdminRolesDetail | where Tier -eq "0"
$Tier0AdminsCount   = $Tier0Admins.count
$Tier0GAAdmins      = ($AdminRolesDetail | where Role -eq "Global Administrator").count
$Tier0NoPIM         = ($Tier0Admins | where MembershipType -ne "ELIGIBLE").count
$Tier0NoPRMFA       = ($Tier0Admins | where MFAphishresistantAvailable -ne "YES").count
if ($Tier0AdminsCount -ge 20) {$WarningT0 = "⚠️"} else {$WarningT0 = ""}
if ($Tier0NoPIM -ge 1){$WarningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier0NoPRMFA -ge 1){$WarningMFA = "⚠️"} else {$warningMFA = ""}
if ($Tier0GAAdmins -ge 5){$WarningGA = "⚠️"} else {$warningGA = ""}
Write-host "Tier 0 : " -ForegroundColor DarkRed -NoNewline
Write-host "$Tier0AdminsCount admins $warningT0"
Write-host "`t- $Tier0GAAdmins Global Admins $warningGA"
Write-host "`t- $Tier0NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier0NoPRMFA without MFA phish resistant available $warningMFA" 

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
$Tier2Admins       += $AdminRolesDetail | where Tier -eq $null
$Tier2AdminsCount   = $Tier2Admins.count
$Tier2NoPIM         = ($Tier2Admins | where MembershipType -ne "ELIGIBLE").count
$Tier2NoPRMFA       = ($Tier2Admins | where MFAphishresistantAvailable -ne "YES").count
if ($Tier2NoPIM -ge 50)   {$warningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier2NoPRMFA -ge 50) {$warningMFA = "⚠️"} else {$warningMFA = ""}
Write-host "Tier 2 (or untiered) : " -ForegroundColor Magenta -NoNewline
Write-host "$Tier2AdminsCount admins"
Write-host "`t- $Tier2NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier2NoPRMFA without MFA phish resistant available $warningMFA" 

# out enabled/MFA methods/last sign in/Sign ins IPs