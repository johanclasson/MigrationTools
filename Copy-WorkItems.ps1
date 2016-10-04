[cmdletbinding()]
param(
    $SourceCollectionUrl = "http://localhost:8080/tfs/SSR",
    $SourceProject = "SSR Ritz",
    $Wiql = "Select [System.Id] From WorkItems Where [Work Item Type] = 'Bug' And [State] in ('Committed','New','Reopened') And [System.IterationPath] = 'SSR Ritz\Release 1\Buggar'",
    $DestCollectionUrl = "https://nethouse-solutions.visualstudio.com",
    $DestProject = "JohansDev"
)

if (!$SourceCredential) {
    throw 'You must specify $SourceCredential outside of this script'
}
if (!$DestUsername) {
    throw 'You must specify $DestUsername outside of this script'
}
if (!$DestPassword) {
    throw 'You must specify $DestPassword outside of this script'
}

$ErrorActionPreference = 'Stop'

function Get-Headers($Username, $Password) {
    $pair = "$($Username):$($Password)"
    $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $basicAuthValue = "Basic $encodedCreds"
    return @{
        Authorization = $basicAuthValue
    }
}

$destHeaders = Get-Headers -Username $DestUsername -Password $DestPassword

function Get-Uri($Path, $ApiVersion = "api-version=1.0", $FromProject, $Source, $Destination, $Collection, $Project){
    if ($Path.Contains('?')) {
        $ApiVersion = "&$ApiVersion" 
    }
    else {
        $ApiVersion = "?$ApiVersion" 
    }
    if ($FromProject) {
        return "$Collection/$Project/$Path$ApiVersion";
    }
    return "$Collection/$Path$ApiVersion";
}

function Invoke-TfsMethod($Path, [switch]$FromProject, $Method = "Get", $ContentType, $Body, [switch]$Source, [switch]$Destination) {
    if ($Method -ne "Get") {
        if (!$ContentType) {
            $ContentType = "application/json"
        }
    }
    if ($Source) {
        $collection = $SourceCollectionUrl
        $project = $SourceProject
        $credential = $SourceCredential
    }
    elseif ($Destination) {
        $collection = $DestCollectionUrl
        $project = $DestProject
    }
    else {
        throw "You must specify either source or destination"
    }


    $uri = Get-Uri -Path $Path -FromProject $FromProject -Source $Source -Destination $Destination -Collection $collection -Project $project
    Write-Host "[$Method] $uri"

    if ($Source) {
        return Invoke-RestMethod -Uri $uri -Method $Method -UseBasicParsing -Credential $credential -ContentType $ContentType -Body $Body
    }
    return Invoke-RestMethod -Uri $uri -Method $Method -UseBasicParsing -Headers $destHeaders -ContentType $ContentType -Body $Body
}

function Get-WiqlIds() {
    return @(3342,3473,3468)
    $body = @"
    {
      "query": "$($Wiql.Replace('\','\\'))"
    }
"@
    return @(Invoke-TfsMethod -Path "_apis/wit/wiql" -FromProject -Method Post -Body $body -Source | select -ExpandProperty workItems | select -ExpandProperty id)
}

function Copy-WorkItems($Ids) {
    function Get-WorkItems($Ids) {
        function Get-WorkItemHistory($Item) {
            if ([string]::IsNullOrEmpty($Item.fields."System.History")) {
                return @()
            }
            return @(Invoke-TfsMethod "_apis/wit/workItems/$($Item.id)/history" -Source | select -ExpandProperty value)
        }

        if (!$Ids) {
            throw "Found no work items"
        }
        if ($Ids.Length -gt 200) {
            throw "Got more than 200 ids" #TODO: Handle more than 200
        }
        $workItems = @(Invoke-TfsMethod -Path "_apis/wit/WorkItems?ids=$([string]::Join(',',$Ids))&$('$expand=all')" -Source | select -ExpandProperty value)
        $workItems | %{
            $_ | Add-Member history (Get-WorkItemHistory $_)
        }
        return $workItems
    }

    function Copy-WorkItem($Item) {
        function Get-FieldsOfInterest($Item) {
            function Get-Field($Item, $fieldName) {
                return [PSCustomObject]@{"name"=$fieldName; "value"=$Item.fields.$fieldName}
            }
            $fields = @()
            #$fields += Get-Field $Item 'System.Id'
            $fields += Get-Field $Item 'System.AreaPath'
            #$fields += Get-Field $Item 'System.IterationPath'
            #$fields += Get-Field $Item 'System.WorkItemType'
            $fields += Get-Field $Item 'System.State'
            $fields += Get-Field $Item 'System.AssignedTo'
            $fields += Get-Field $Item 'System.CreatedDate'
            $fields += Get-Field $Item 'System.CreatedBy'
            $fields += Get-Field $Item 'System.ChangedDate'
            $fields += Get-Field $Item 'System.ChangedBy'
            $fields += Get-Field $Item 'System.Title'
            #$fields += Get-Field $Item 'System.BoardColumn'
            $fields += Get-Field $Item 'Microsoft.VSTS.Common.BacklogPriority'
            $fields += Get-Field $Item 'Microsoft.VSTS.TCM.ReproSteps'
            $fields += Get-Field $Item 'System.Tags'
            return $fields
        }

        function Render-Field($Field) {
            return @"
  {
    "op": "add",
    "path": "/fields/$($Field.name)",
    "value": "$($Field.value.ToString().Replace('\', '\\').Replace('"', '\"'))"
  }
"@ 
        }

        $relations = $Item.relations
        $history = $Item.history

        $body = @"
[

"@

        $body += [string]::Join(",`r`n", (Get-FieldsOfInterest $Item | %{ Render-Field $_ }))
        $body += "`r`n]"

        $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
        $path = "_apis/wit/workitems/$('$')$($Item.fields.'System.WorkItemType')?bypassRules=true"
        $result = Invoke-TfsMethod -Path $path -FromProject -Method Patch -Body $encBody -ContentType "application/json-patch+json" -Destination

    }

    Get-WorkItems $Ids | %{
        Copy-WorkItem $_
    }
}

$ids = Get-WiqlIds
Copy-WorkItems $ids



#2769 (Done)
#3342 (Tags, attatch, history)
#3473 (attatch utan bild)
#3468 Märklig referens till attach som inte finns
#Invoke-TfsMethod -Path '_apis/wit/WorkItems?ids=3473&$expand=all' | select -ExpandProperty value | select -ExpandProperty _links