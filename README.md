# M365-Admin-Exporter
## Description
This powershell script is designed to export all admin roles assignments from Entra

## Prerequisites
- Microsoft.Graph.Authentication Module
- Graph Scopes : Directory.Read.All, RoleManagement.Read.All, UserAuthenticationMethod.Read.All
- Entra tier definition from aztier.com in the same folder of the script : https://github.com/emiliensocchi/azure-tiering/blob/main/Entra%20roles/tiered-entra-roles.json

## Output
- Quick recap in console (number of admin per tier, PIM not enabled, MFA phish resistant not available)
- AdminRoleSummary.csv : Direct members of each Entra role
- AdminRolesDetails.csv : All principals directly or not assigned to Entra role
- AdminEligibleGroups.csv : All Entra groups eligible to role assignment
![image](output.png)
