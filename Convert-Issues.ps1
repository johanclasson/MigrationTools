[cmdletbinding()]
param(
    $GitHubIssuesUrl,
    $GithubUsername,
    $GitHubPassword,
    $TfsCollectionUrl,
    $TfsProject,
    $TfsUsername,
    $TfsPersonalAccessToken
)

$ErrorActionPreference = "stop"

$TfsCollectionUrl = $TfsCollectionUrl.TrimEnd('/')

function Get-Headers($Username, $Password) {
    $pair = "$($Username):$($Password)"
    $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $basicAuthValue = "Basic $encodedCreds"
    return @{
        Authorization = $basicAuthValue
    }
}

$gitHubHeaders = Get-Headers -Username $GithubUsername -Password $GitHubPassword
$tfsHeaders = Get-Headers -Username $TfsUsername -Password $TfsPersonalAccessToken

function Get-Iterations {
    $result = Invoke-WebRequest -Uri "$TfsCollectionUrl/$TfsProject/_apis/wit/classificationNodes/iterations?$('$depth')=2&api-version=1.0" -Headers $tfsHeaders
    $iterationsData = ConvertFrom-Json $result.Content
    return @($iterationsData.children.name)
}

$iterations = New-Object "System.Collections.Generic.List[string]"
Get-Iterations | foreach {
    $iterations.Add($_)
}

function Get-TempPath {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "GithubToTfsImport"
    if (-not (Test-Path $temp)) {
        mkdir $temp | Out-Null
    }
    return $temp
}

function Invoke-CachedRequest($Url, $Headers) {
    $cacheFilePath = (Join-Path (Get-TempPath) ($Url -replace "[:/.?=]","_")) + ".json"
    if (-not (Test-Path $cacheFilePath)) {
        $result = Invoke-WebRequest -Uri $Url -Headers $Headers
        Write-Warning "Downloaded $Url. $($result.Headers['X-RateLimit-Remaining']) remaining calls allowed."
        $pageIndex = -1
        if ($result.Headers.Link -ne $null) {
            $pageIndex = $result.Headers.Link.IndexOf('; rel="next"')
        }
        if ($pageIndex -eq -1) {
            [System.IO.File]::WriteAllText($cacheFilePath, $result.Content)
        }
        else {
            $pagedResult = ConvertFrom-Json $result.Content
            while ( $pageIndex -ne -1) {
                $Url = $result.Headers.Link.Substring(1, $pageIndex-2)
                $result = Invoke-WebRequest -Uri $Url -Headers $Headers
                Write-Warning "Downloaded $Url. $($result.Headers['X-RateLimit-Remaining']) remaining calls allowed."
                $pagedResult = $pagedResult + (ConvertFrom-Json $result.Content)
                $pageIndex = $result.Headers.Link.IndexOf('; rel="next"')
            }
            [System.IO.File]::WriteAllText($cacheFilePath, (ConvertTo-Json $pagedResult))
        }
    }
    return ConvertFrom-Json ([System.IO.File]::ReadAllText($cacheFilePath))
}

function CreateOrGet-Iteration($Milestone) {
    if ($Milestone -eq $null) {
        return $TfsProject
    }
    $title = $Milestone.title -replace '[#\\/$?*:"&><#%|+]',''
    $badNames = '.','..','PRN','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','COM10','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9','NUL','CON','AUX'
    if ($badNames -contains $title) {
        $title = "Unsupported title"
        Write-Warning "Encountered the not supported iteration name $title"
    }
    if (-not ($iterations.Contains($title))) {
        $url = "$TfsCollectionUrl/$TfsProject/_apis/wit/classificationNodes/iterations?api-version=1.0"
        $start = $Milestone.created_at
        $end = $Milestone.due_on
        $body = @"
{
  "name": "$title"
}
"@
        if (-not [string]::IsNullOrEmpty($start) -and -not [string]::IsNullOrEmpty($end)) {
            if ($start -gt $end) {
                $start = $end
            }
            $body = @"
{
  "name": "$title",
  "attributes": {
    "startDate": "$start",
    "finishDate": "$end"
  }
}
"@
        }
        $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
        $result = Invoke-WebRequest -Uri $url -Headers $tfsHeaders -Method Post -Body $encBody -ContentType "application/json"
        $iterations.Add($title)
        Write-Host "Created iteration $title"
    }
    return "$TfsProject\$title"
}

function Convert-Markdown($Text) {
    $result = Invoke-WebRequest -Uri "https://api.github.com/markdown/raw" -Headers $gitHubHeaders -Method Post -Body $Text -ContentType "text/plain"
    Write-Warning "Converted markdown. $($result.Headers['X-RateLimit-Remaining']) remaining calls allowed."
    return $result.Content.Replace([char]10," ").Replace('\', '\\').Replace('"', '\"')
}

function Add-WorkItem($Issue, $IterationPath) {
    $url = "$TfsCollectionUrl/$TfsProject/_apis/wit/workitems/$('$Product') Backlog Item?bypassRules=true&api-version=1.0"
    $state = "New"
    if ($Issue.state -eq "Closed") {
        $state = "Done"
    }
    $tags = @($Issue.labels.name) -join "; "
    $description = Convert-Markdown $Issue.body

    $body = @"
[
 {
    "op": "add",
    "path": "/fields/System.Title",
    "value": "$($Issue.title.Replace('"', '\"'))"
  },
  {
    "op": "add",
    "path": "/fields/System.Description",
    "value": "$description"
  },
  {
    "op": "add",
    "path": "/fields/System.State",
    "value": "$state"
  },
  {
    "op": "add",
    "path": "/fields/System.Tags",
    "value": "$($tags.Replace('"', '\"'))"
  },
  {
    "op": "add",
    "path": "/fields/System.IterationPath",
    "value": "$($IterationPath.Replace('\', '\\'))"
  },
  {
    "op": "add",
    "path": "/relations/-",
    "value": {
      "rel": "Hyperlink",
      "url": "$($Issue.html_url)"
    }
  },
  {
    "op": "add",
    "path": "/fields/System.CreatedBy",
    "value": "$($Issue.user.login)"
  },
  {
    "op": "add",
    "path": "/fields/System.CreatedDate",
    "value": "$($Issue.created_at)"
  },
  {
    "op": "add",
    "path": "/fields/System.ChangedBy",
    "value": "$($Issue.user.login)"
  },
  {
    "op": "add",
    "path": "/fields/System.ChangedDate",
    "value": "$($Issue.created_at)"
  },
  {
    "op": "add",
    "path": "/fields/System.AssignedTo",
    "value": "$($Issue.assignee.login)"
  }
]
"@
    $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
    $result = Invoke-WebRequest -Uri $url -Headers $tfsHeaders -Method Patch -Body $encBody -ContentType "application/json-patch+json"
    $id = (ConvertFrom-Json $result.Content).id;
    Write-Host "Created work item $id from issue $($Issue.number)"
    return $id
}

function Add-CommentOnWorkItem($Id, $Comment) {
    $url = "$TfsCollectionUrl/$TfsProject/_apis/wit/workitems/$($id)?bypassRules=true&api-version=1.0"
    $description = Convert-Markdown $comment.body
    $body = @"
[
  {
    "op": "add",
    "path": "/fields/System.History",
    "value": "$description"
  },
  {
    "op": "add",
    "path": "/fields/System.ChangedBy",
    "value": "$($comment.user.login)"
  },
  {
    "op": "add",
    "path": "/fields/System.ChangedDate",
    "value": "$($comment.created_at)"
  }
]
"@
    $encBody = [System.Text.Encoding]::UTF8.GetBytes($body)
    $result = Invoke-WebRequest -Uri $url -Headers $tfsHeaders -Method Patch -Body $encBody -ContentType "application/json-patch+json"
    Write-Host "Added comment on work item $Id"
}

function Import-Issue($Url) {
    $issue = Invoke-CachedRequest -Url $Url -Headers $gitHubHeaders
    $iterationPath = CreateOrGet-Iteration $issue.milestone
    $id = Add-WorkItem -Issue $issue -IterationPath $iterationPath

    if ($issue.comments -gt 0) {
        $comments = Invoke-CachedRequest -Url $issue.comments_url -Headers $gitHubHeaders
        for($i = 0; $i -lt $comments.Length; $i++) {
            Add-CommentOnWorkItem -Id $id -Comment $comments[$i]
        }
    }
}

$issues = Invoke-CachedRequest -Url $GitHubIssuesUrl -Headers $gitHubHeaders
for($i = 0; $i -lt $issues.Length; $i++) {
    Import-Issue $issues[$i].url
}