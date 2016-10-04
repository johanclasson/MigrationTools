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
    Write-Verbose "[$Method] $uri"

    if ($Source) {
        return Invoke-RestMethod -Uri $uri -Method $Method -UseBasicParsing -Credential $credential -ContentType $ContentType -Body $Body
    }
    return Invoke-RestMethod -Uri $uri -Method $Method -UseBasicParsing -Headers $destHeaders -ContentType $ContentType -Body $Body
}

function Get-WiqlIds() {
    #return @(3342,3473,3468)
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

    <#
    function Create-Iterations($workItems) {
        function Get-DestIterations {
            $iterationsData = Invoke-TfsMethod "_apis/wit/classificationNodes/iterations?$('$')depth=2&api-version=1.0" -FromProject -Destination
            return @($iterationsData.children.name)
        }
        function Get-SourceIterations {
            $iterationsData = Invoke-TfsMethod "_apis/wit/classificationNodes/iterations?$('$')depth=2&api-version=1.0" -FromProject -Source
            return @($iterationsData.children)
        }

        $expectedPaths = $workItems.fields."System.IterationPath" | sort -Unique
        $existingDestPaths = Get-DestIterations
        $existingSourcePaths = Get-SourceIterations
        $expectedPaths | %{
            if (!$existingPahts.Contains($_)) {

            }
        }
    }
    #>

    function Copy-WorkItem($Item) {
        function Get-FieldsOfInterest($Item) {
            function Get-Field($Item, $fieldName, $fromOtherFieldName) {
                
                if ($fromOtherFieldName) {
                    $value = $Item.fields.$fromOtherFieldName
                }
                else {
                    $value = $Item.fields.$fieldName
                }
                if ($value.length -gt 1000000) {
                    Write-Warning "Field $fieldName of work item $($Item.id) was to large! Cropping content..."
                    $value = $value.Substring(0, 1000000)
                }
                return [PSCustomObject]@{"name"=$fieldName; "value"=$value}
            }
            $fields = @()
            #$fields += Get-Field $Item 'System.Id'
            #$fields += Get-Field $Item 'System.AreaPath'
            #$fields += Get-Field $Item 'System.IterationPath'
            #$fields += Get-Field $Item 'System.WorkItemType'
            $fields += Get-Field $Item 'System.State'
            $fields += Get-Field $Item 'System.AssignedTo'
            $fields += Get-Field $Item 'System.ChangedDate' 'System.CreatedDate'
            $fields += Get-Field $Item 'System.ChangedBy' 'System.CreatedBy'
            #$fields += Get-Field $Item 'System.ChangedDate'
            #$fields += Get-Field $Item 'System.ChangedBy'
            $fields += Get-Field $Item 'System.Title'
            #$fields += Get-Field $Item 'System.BoardColumn'
            $fields += Get-Field $Item 'Microsoft.VSTS.Common.BacklogPriority'
            $fields += Get-Field $Item 'System.Description' 'Microsoft.VSTS.TCM.ReproSteps'
            $fields += Get-Field $Item 'System.Tags'
            $fields = $fields | ?{ $_.value -ne $null }
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

        function Add-History($Item, $Id) {
            if (!$Item.history) {
                return
            }
            
            $Item.history | %{
                $date = $_.revisedDate
                if ($date -eq "9999-01-01T00:00:00Z") {
                    Write-Warning "Got an unexpected date $date for work item $Id"
                    if (!$lastDate) {
                        $lastDate = "2016-01-01T00:00:00Z"
                    }
                    $date = [datetime]::Parse($lastDate).Add([timespan]::Parse("00:00:01")).ToString("yyyy-MM-ddTHH:mm:ss")
                }
                $lastDate = $date
                $body = @"
    [
      {
        "op": "add",
        "path": "/fields/System.History",
        "value": "$($_.value.Replace('\', '\\').Replace('"', '\"'))"
      },
      {
        "op": "add",
        "path": "/fields/System.ChangedBy",
        "value": "$($_.revisedBy.name.Replace('\', '\\').Replace('"', '\"'))"
      },
      {
        "op": "add",
        "path": "/fields/System.ChangedDate",
        "value": "$date"
      }
    ]
"@
                $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
                $result = Invoke-TfsMethod "_apis/wit/workitems/$($Id)?bypassRules=true&api-version=1.0" -Method Patch -Body $encBody -ContentType "application/json-patch+json" -Destination
                Write-Host "Added comment on work item $Id"
            }
        }


        $relations = $Item.relations

        $body = @"
[

"@

        $body += [string]::Join(",`r`n", (Get-FieldsOfInterest $Item | %{ Render-Field $_ }))
        $body += "`r`n]"

        $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
        #$type = "Product Backlog Item"
        $type = $Item.fields.'System.WorkItemType'
        $path = "_apis/wit/workitems/$('$')$($type)?bypassRules=true"
        $result = Invoke-TfsMethod -Path $path -FromProject -Method Patch -Body $encBody -ContentType "application/json-patch+json" -Destination
        Write-Host "Created work item $($result.id) from work item $($Item.fields.'System.Id')"
        Add-History $Item $result.id
    }

    $workItems = Get-WorkItems $Ids
    #Create-Iterations $workItems
    $workItems | %{
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