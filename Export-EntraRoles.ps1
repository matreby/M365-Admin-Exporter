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
            if ($null -ne $req.'@odata.nextLink') {
                $currentUri = $req.'@odata.nextLink'
            } else {
                $currentUri = $null
            }
            
        }
        catch {
            Write-error $_
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
        $CurrentUserMFAURI = $UserMFAUri -replace "<userid>",$assignment.principal.id
        $UserMFA = Invoke-MgGraphRequestPaging -uri $CurrentUserMFAURI
        $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
        $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
    }
    
    $NbGroupMembers = ""
    #if ($assignment.principal.'@odata.type' -like "*group*"){
        #$NbGroupMembers = ($AssignableGroupsMembers |  Where-Object ParentGroupID -eq $assignment.principal.id).count
    #}

    if ($PIM -eq $false){
        $MembershipType = "PERMANENT"
        $PIMDuration    = ""
        $PIMValidation  = ""
        $PIMApproval    = ""
        $PIMAuthContext = ""
    } else {
        $PIMRules = ($PIMRolePolicies |  Where-Object roleDefinitionId -eq $assignment.roleDefinitionId).policy.rules
        $MembershipType = "ELIGIBLE"
        $PIMDuration    = ($PIMRules  |  Where-Object id -eq "Expiration_EndUser_Assignment").maximumDuration -replace "PT",""
        $PIMValidation  = (($PIMRules |  Where-Object id -eq "Enablement_EndUser_Assignment").enabledRules | Select-Object -Unique) -join "|"
        $PIMApproval    = ($PIMRules  |  Where-Object id -eq "Approval_EndUser_Assignment").setting.isApprovalRequired
        $PIMAuthContext = ($PIMRules  |  Where-Object id -eq "AuthenticationContext_EndUser_Assignment").claimvalue
    }

    $AssignmentInfo = [PSCustomObject]@{
        Role                        = ($RoleDefinitions | Where-Object id -eq $assignment.roleDefinitionid).displayName
        Tier                        = ($tierRolesDefinition  |  Where-Object id -eq $assignment.roleDefinitionId).tier
        PrincipalType               = $assignment.principal.'@odata.type' -replace "#microsoft.graph.",""
        MembershipType              = $MembershipType
        DisplayName                 = $assignment.principal.DisplayName
        UserPrincipalName           = $assignment.principal.userprincipalname
        Enabled                     = $assignment.principal.accountEnabled
        #NumberOfGroupMembers        = $NbGroupMembers
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
$ProgressPreference = "Continue" #Replace by SilentlyContinue to mask progress bar and gain performances

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
$AssignableGroupsURI    = "https://graph.microsoft.com/beta/groups?`$filter=isassignabletorole eq true&`$expand=owners"
$PIMRolePoliciesURI     = "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"
$PIMRolesActivatedURI   = "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignmentSchedules?`$filter=assignmentType eq 'Activated'"
$GroupMembersURI        = "https://graph.microsoft.com/beta/groups/<groupid>/members"
$UserMFAUri             = "https://graph.microsoft.com/beta/users/<userid>/authentication/methods"

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
Write-host "- Exporting currently activated PIM roles..." -ForegroundColor DarkGray
$PIMRolesActivated  = Invoke-MgGraphRequestPaging -Uri $PIMRolesActivatedURI
Write-host "--- ✅ Graph exports done ---" -ForegroundColor Green

Write-host "- Importing roles tier definition (aztier.com)... " -ForegroundColor DarkGray
if (!(test-path "$WorkingFolder\tiered-entra-roles.json")){
    Write-host "file not found, trying to download it" -ForegroundColor Yellow
    (Invoke-WebRequest "https://raw.githubusercontent.com/emiliensocchi/azure-tiering/refs/heads/main/Entra%20roles/tiered-entra-roles.json").content | out-file "$WorkingFolder\tiered-entra-roles.json"
}
$tierRolesDefinition = Get-Content "$WorkingFolder\tiered-entra-roles.json" | ConvertFrom-Json 
write-host "$($tierRolesDefinition.count) role tier definition found"
if ($null -eq $tierRolesDefinition ){Write-warning "Failed to get Entra roles tier definition"}
else {write-host "--- ✅ done ---" -ForegroundColor Green}

Write-Host "Processing permanent assignments... " -ForegroundColor DarkGray -NoNewline
$AssignedRoles = @()
$i=0;$j=$RoleAssignments.count
foreach ($PermanentAssignment in $RoleAssignments) {
    $i++;Write-Progress -Activity "In Progress..." -PercentComplete ($i/$j*100) -Status "$i/$j"
    #Exclude PIM activated roles from permanent assignemnts
    if ($null -eq ($PIMRolesActivated |  Where-Object {$_.principalId -eq $role.principalId -and $_.roleDefinitionId -eq $role.roleDefinitionId})){
        $AssignedRoles += Get-AssignmentInfo -assignment $PermanentAssignment
    }
}
Write-Progress -Activity "In progress..." -Completed
write-host "$($assignedRoles.count) found"

Write-host "Processing eligible assignments... " -ForegroundColor DarkGray -NoNewline
$EligibleRoles = @()
$i=0;$j=$RoleEligibility.count
foreach ($EligibleAssignment in $RoleEligibility) {
    $i++;Write-Progress -Activity "In Progress..." -PercentComplete ($i/$j*100) -Status "$i/$j"
    $EligibleRoles += Get-AssignmentInfo -assignment $EligibleAssignment -PIM $True
}
Write-Progress -Activity "In progress..." -Completed
write-host "$($EligibleRoles.count) found"
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all assignments to $WorkingFolder\AdminRolesSummary.csv..." -ForegroundColor DarkGray
$AllRoleAssignments = ($AssignedRoles + $EligibleRoles) | Sort-Object Tier,Role
$AllRoleAssignments | select-object -ExcludeProperty id | export-csv $WorkingFolder\AdminRolesSummary.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Expanding role assignable groups... " -ForegroundColor DarkGray -NoNewline
$AdminGroups = @()
$AssignableGroupsMembers = @()
$i=0;$j=$AssignableGroups.count
foreach ($group in $AssignableGroups){
    $i++;Write-Progress -Activity "In Progress..." -PercentComplete ($i/$j*100) -Status "$i/$j"
    #Getting Members of the group
    $GroupMembers = @()
    $groupMembers = Invoke-MgGraphRequestPaging -uri $($GroupMembersURI -replace "<groupid>",$group.id)
    $groupMembers | Add-Member -NotePropertyName "ParentGroupID" -NotePropertyValue $group.id
    $groupMembers | Add-Member -NotePropertyName "ParentGroupDisplayName" -NotePropertyValue $group.displayName
    $AssignableGroupsMembers += $GroupMembers

    $current = [PSCustomObject]@{
        DisplayName         = $group.displayName
        Owner               = $group.owners.userPrincipalName -join "|"
        Role                = ($AllRoleAssignments |  Where-Object DisplayName -eq $group.displayName).Role -join "|"
        RoleAssignmentType  = ($AllRoleAssignments |  Where-Object DisplayName -eq $group.displayName).MembershipType -join "|"
        MembersUPN          = $GroupMembers.userPrincipalName -join "|" #$group.members.userPrincipalName -join "|"
        MembersID           = $GroupMembers.Id -join "|"  #$group.members.Id
        #PIMforGrpEnabled    = $PIMEnabled
    }

    $AdminGroups += $current
}
Write-Progress -Activity "In progress..." -Completed
write-host "$($Admingroups.count) groups found"
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all role assignable groups to $WorkingFolder\AdminEligibleGroups.csv..." -ForegroundColor DarkGray
$AdminGroups | Select-Object -ExcludeProperty MembersId | export-csv $WorkingFolder\AdminEligibleGroups.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Resolving group members and role assignments to create the complete report..." -ForegroundColor DarkGray
$AdminRolesDetails = @()
$i=0;$j=$AllRoleAssignments.count
foreach ($roleAsssignment in $AllRoleAssignments){
    $i++;Write-Progress -Activity "In Progress..." -PercentComplete ($i/$j*100) -Status "$i/$j"
    if ($roleAsssignment.principalType -eq "group") {
        $members = $AssignableGroupsMembers |  Where-Object ParentGroupID -eq $roleAsssignment.id
        foreach ($member in $members) {
            $UserMFAMethods = ""
            $UserMFAphishresistant = ""
            if ($member.'@odata.type' -like "*user*") {
                $CurrentUserMFAURI = $UserMFAUri -replace "<userid>",$member.id
                $UserMFA = Invoke-MgGraphRequestPaging -uri $CurrentUserMFAURI
                $UserMFAMethods = $UserMFA.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","" -join "|"
                $UserMFAphishresistant = if ($UserMFAMethods -like "*fido2*" -or $UserMFAMethods -like "*windowsHelloForBusiness*"){"Yes"} else {"No"}
            }
            $current = [PSCustomObject]@{
                Role                         = $roleAsssignment.role
                Tier                         = $roleAsssignment.tier
                PrincipalType                = $member.'@odata.type' -replace "#microsoft.graph.",""
                MembershipType               = $roleAsssignment.MembershipType
                DisplayName                  = $member.DisplayName
                UserPrincipalName            = $member.UserPrincipalName
                Enabled                      = $member.accountEnabled
                MFAphishresistantAvailable   = $UserMFAphishresistant
                MFAMethods                   = $UserMFAMethods
                AssignedThrough              = $roleAsssignment.DisplayName
                PIMDuration                  = $roleAsssignment.PIMDuration
                PIMValidation                = $roleAsssignment.PIMValidation
                PIMApproval                  = $roleAsssignment.PIMApproval
                PIMAuthContext               = $roleAsssignment.PIMAuthContext
                id                           = $roleAsssignment.id
            }
            $AdminRolesDetails += $current
        }
    } 
    else {
        $current = $roleAsssignment     
        $current | add-member -NotePropertyName AssignedThrough -NotePropertyValue "Direct" -force
        $AdminRolesDetails += $current
    }

}
Write-Progress -Activity "In progress..." -Completed
write-host "--- ✅ done ---" -ForegroundColor Green

Write-host "Exporting all role assignable groups to $WorkingFolder\AdminRolesDetails.csv..." -ForegroundColor DarkGray
$AdminRolesDetails | Select-Object Role,Tier,MembershipType,AssignedThrough,PrincipalType,DisplayName,UserPrincipalName,Enabled,PIMDuration,PIMValidation,PIMApproval,PIMAuthContext,MFAphishresistantAvailable,MFAMethods -ExcludeProperty id,NumberOfGroupMembers | sort-object Tier,Role | export-csv $WorkingFolder\AdminRolesDetails.csv -NoTypeInformation -Delimiter ";" -Force -Encoding utf8
write-host "--- ✅ done ---" -ForegroundColor Green

#Analysis
Write-host "Export completed : $WorkingFolder" -ForegroundColor Cyan
Write-host "----------------------------------------"
$NumberOfRoles = ($AllRoleAssignments |  Where-Object role -ne $null | Select-Object role -Unique).count
$NumberOfAssignments = $AdminRolesDetails.count
Write-Host "Found $NumberOfRoles admin roles with $NumberOfAssignments assignments" -ForegroundColor Cyan
Write-host "-------"
#Tier0
$Tier0Admins              = $AdminRolesDetails |  Where-Object Tier -eq "0"
$Tier0AdminsCount         = $Tier0Admins.count
$Tier0UniqueAdminsCount   = ($Tier0Admins | Select-Object id -unique).count
$Tier0GAAdmins            = ($AdminRolesDetails |  Where-Object Role -eq "Global Administrator").count
$Tier0NoPIM               = ($Tier0Admins |  Where-Object MembershipType -ne "ELIGIBLE").count
$Tier0NoPRMFA             = ($Tier0Admins |  Where-Object MFAphishresistantAvailable -ne "YES").count
if ($Tier0AdminsCount -ge 20) {$WarningT0 = "⚠️"} else {$WarningT0 = ""}
if ($Tier0NoPIM -ge 1){$WarningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier0NoPRMFA -ge 1){$WarningMFA = "⚠️"} else {$warningMFA = ""}
if ($Tier0GAAdmins -ge 5){$WarningGA = "⚠️"} else {$warningGA = ""}
Write-host "Tier 0 : " -ForegroundColor DarkRed -NoNewline
Write-host "$Tier0AdminsCount assignments ($Tier0UniqueAdminsCount admins) $warningT0"
Write-host "`t- $Tier0GAAdmins Global Admins $warningGA"
Write-host "`t- $Tier0NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier0NoPRMFA without MFA phish resistant available $warningMFA" 
Write-host "-------"

#Tier1
$Tier1Admins              = $AdminRolesDetails |  Where-Object Tier -eq "1"
$Tier1AdminsCount         = $Tier1Admins.count
$Tier1UniqueAdminsCount   = ($Tier1Admins | Select-Object id -unique).count
$Tier1NoPIM               = ($Tier1Admins |  Where-Object MembershipType -ne "ELIGIBLE").count
$Tier1NoPRMFA             = ($Tier1Admins |  Where-Object MFAphishresistantAvailable -ne "YES").count
if ($Tier1NoPIM -ge 5)   {$warningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier1NoPRMFA -ge 1) {$warningMFA = "⚠️"} else {$warningMFA = ""}
Write-host "Tier 1 : " -ForegroundColor Darkyellow -NoNewline
Write-host "$Tier1AdminsCount assignments ($Tier1UniqueAdminsCount admins)"
Write-host "`t- $Tier1NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier1NoPRMFA without MFA phish resistant available $warningMFA" 
Write-host "-------"

#Tier2 or untiered
$Tier2Admins            = $AdminRolesDetails |  Where-Object Tier -eq "2"
$Tier2Admins           += $AdminRolesDetails |  Where-Object Tier -eq $null
$Tier2AdminsCount       = $Tier2Admins.count
$Tier2UniqueAdminsCount = ($Tier2Admins | Select-Object id -unique).count
$Tier2NoPIM             = ($Tier2Admins |  Where-Object MembershipType -ne "ELIGIBLE").count
$Tier2NoPRMFA           = ($Tier2Admins |  Where-Object MFAphishresistantAvailable -ne "YES").count
if ($Tier2NoPIM -ge 50)   {$warningPIM = "⚠️"} else {$warningPIM = ""}
if ($Tier2NoPRMFA -ge 50) {$warningMFA = "⚠️"} else {$warningMFA = ""}
Write-host "Tier 2 (or untiered) : " -ForegroundColor Magenta -NoNewline
Write-host "$Tier2AdminsCount assignments ($Tier2UniqueAdminsCount admins)"
Write-host "`t- $Tier2NoPIM without PIM (permanent admin) $warningPIM" 
Write-host "`t- $Tier2NoPRMFA without MFA phish resistant available $warningMFA" 
Write-host "-------"