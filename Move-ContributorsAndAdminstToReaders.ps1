$ErrorActionPreference = "Continue"

# load the required dll
[void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")

function get-tfs
{
    param(
    [string] $serverName = $(throw 'serverName is required')
    )

    $propertiesToAdd = (
        ('VCS', 'Microsoft.TeamFoundation.VersionControl.Client', 'Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer'),
        ('WIT', 'Microsoft.TeamFoundation.WorkItemTracking.Client', 'Microsoft.TeamFoundation.WorkItemTracking.Client.WorkItemStore'),
        ('CSS', 'Microsoft.TeamFoundation', 'Microsoft.TeamFoundation.Server.ICommonStructureService'),
        ('GSS', 'Microsoft.TeamFoundation', 'Microsoft.TeamFoundation.Server.IGroupSecurityService')
    )

    [psobject] $tfs = [Microsoft.TeamFoundation.Client.TeamFoundationServerFactory]::GetServer($serverName)
    foreach ($entry in $propertiesToAdd) {
        $scriptBlock = '
            [System.Reflection.Assembly]::LoadWithPartialName("{0}") > $null
            $this.GetService([{1}])
        ' -f $entry[1],$entry[2]
        $tfs | add-member scriptproperty $entry[0] $ExecutionContext.InvokeCommand.NewScriptBlock($scriptBlock)
    }
    return $tfs
}
#set the TFS server url
[psobject] $tfs = get-tfs -serverName http://tfs.nethouse.eu:8080/tfs/DefaultCollection

$ErrorActionPreference = "Stop"

function Get-Identity($Sid) {
    return $tfs.GSS.ReadIdentity([Microsoft.TeamFoundation.Server.SearchFactor]::Sid, $Sid, [Microsoft.TeamFoundation.Server.QueryMembership]::Direct)
}

function Add-MembersToGroup($FromSid, $ToSid, $ProjName) {
    $members = @(Get-Identity -Sid $FromSid | select -ExpandProperty Members)
    $existingMembers = @(Get-Identity -Sid $ToSid | select -ExpandProperty Members)

    Write-Host "Walking '$((Get-Identity $FromSid).AccountName)' in $ProjName"

    $members | foreach {
        $sid = $_
        if ($existingMembers -notcontains $sid) {
            Write-Host "Added '$((Get-Identity $sid).AccountName)'"
            $tfs.GSS.AddMemberToApplicationGroup($ToSid, $sid)
        }
        $tfs.GSS.RemoveMemberFromApplicationGroup($FromSid, $sid)
    }

}

$items = $tfs.vcs.GetAllTeamProjects( 'True' )
    $items | foreach-object -process { 
    $proj = $_
    $groups = $tfs.GSS.ListApplicationGroups($proj.Name)
    $contributors = $groups | ?{$_.DisplayName -eq 'Contributors' }
    $admins = $groups | ?{$_.DisplayName -eq 'Project Administrators' }
    $readers = $groups | ?{$_.DisplayName -eq 'Readers' }

    Add-MembersToGroup -FromSid $contributors.Sid -ToSid $readers.Sid -ProjName $proj.Name
    Add-MembersToGroup -FromSid $admins.Sid -ToSid $readers.Sid -ProjName $proj.Name
}