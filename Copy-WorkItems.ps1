param(
    $SourceCollectionUrl = "http://localhost:8080/tfs/SSR",
    $SourceProject = "SSR Ritz",
    $Wiql = "Select [System.Id], [System.Title] From WorkItems Where [Work Item Type] = 'Bug' And [State] <> 'Removed' And [State] <> 'Done' And [System.IterationPath] = 'SSR Ritz\Release 1\Buggar'")

$ErrorActionPreference = 'Stop'

function Get-Uri($Path, $ApiVersion = "api-version=1.0", $FromProject){
    if ($Path.Contains('?')) {
        $ApiVersion = "&$ApiVersion" 
    }
    else {
        $ApiVersion = "?$ApiVersion" 
    }
    if ($FromProject) {
        return "$CollectionUrl/$SourceProject/$Path$ApiVersion";
    }
    return "$CollectionUrl/$Path$ApiVersion";
}

function Invoke-TfsMethod($Path, [switch]$FromProject, $Method = "Get", $ContentType, $Body) {
    if ($Method -ne "Get") {
        if (!$ContentType) {
            $ContentType = "application/json"
        }
        if ($Body) {
            $Body = $Body.Replace('\','\\')
        }
    }
    $uri = Get-Uri -Path $Path -FromProject $FromProject
    Write-Host "[$Method] $uri"
    return Invoke-RestMethod -Uri $uri -Method $Method -UseBasicParsing -Credential $c -ContentType $ContentType -Body $Body
}

function Get-WiqlIds() {
    return @(3342,3473,3468)
    return Invoke-TfsMethod -Path "_apis/wit/wiql" -FromProject -Method Post -Body @"
    {
      "query": "$Wiql"
    }
"@ | select -ExpandProperty workItems | select -ExpandProperty id
}

function Copy-WorkItems($Ids) {
    function Get-WorkItems($Ids) {
        if ($Ids.Length -gt 200) {
            throw "Got more than 200 ids" #TODO: Handle more than 200
        }
        return Invoke-TfsMethod -Path "_apis/wit/WorkItems?ids=$([string]::Join(',',$Ids))&$('$expand=all')" | select -ExpandProperty value
    }

    function Copy-WorkItem($Item) {
        $id = $Item.id
        $fields = $Item.fields
        $relations = $Item.relations
        $history = @(Invoke-TfsMethod "_apis/wit/workItems/$id/history" | select -ExpandProperty value)
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