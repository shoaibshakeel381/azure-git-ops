param
(
    [string] $command = '',
    [string] $commitAuthorEmail = 'gitops@dev.azure.com',
    [string] $commitAuthorName = 'GitOps',
    [string] $commitMessage = 'N/A',
    [string] $diffFilter = 'ARM',
    [string] $diffFileFilter = '+*:*',
    [string] $diffVarName = 'GitDiffFiles',
    [ValidateSet('build', 'pull request')]
    [string] $target = 'pull request'
)


# Git functions

function Get-RepositoryUri
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        [ValidateSet('build', 'pull request')]
        $target
    )
    
    $uri = $null
    if ($target -eq 'build') 
    {
        $uri = $env:BUILD_REPOSITORY_URI
    }
    else 
    {
        $uri = $env:SYSTEM_PULLREQUEST_SOURCEREPOSITORYURI
    }
    
    $repositoryUri = New-Object -TypeName System.UriBuilder -ArgumentList ($uri)
    
    if ($Env:SYSTEM_ACCESSTOKEN -ne $null)
    {
        $repositoryUri.UserName = 'OAuth'
        $repositoryUri.Password = $Env:SYSTEM_ACCESSTOKEN
    }
    
    return $repositoryUri
}


function Get-SourceBranchName 
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        [ValidateSet('build', 'pull request')]
        $target
    )
    
    if ($target -eq 'build') 
    {
        return $env:BUILD_SOURCEBRANCH.Replace('refs/', [string]::Empty)
    }
    else 
    { 
        # TODO: get source branch from Pull Request API response, because merge commit message format can change any time 
        $branchName = git.exe log --format=%s -1
        $separators = @(' from ', ' into ')
        $parts = $branchName.Split(@($separators), [StringSplitOptions]::RemoveEmptyEntries)

        return $parts[1]
    }
}

function Get-ModifiedFiles 
{
    return @() + $(git.exe diff --exit-code --name-only)
}

function Test-CanPush
{
    $status = @() + $(git.exe status --porcelain --branch --no-ahead-behind)
  
    return $status[0].EndsWith('[different]')
}


function Get-CurrentGitCommitId
{
    Invoke-Expression -Command 'git rev-parse --verify HEAD'
}


function Get-PullRequestChanges 
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        $diffFilter
    )
    
    Write-Host 'Getting git diff'
    
    $currentCommit = Get-CurrentGitCommitId
    $targetBranch = $env:SYSTEM_PULLREQUEST_TARGETBRANCH.Replace('refs/heads/', 'origin/')
    $mergeBase = Invoke-GitCommand -command "git merge-base $currentCommit $targetBranch"
    $gitDiff = Invoke-GitCommand -command "git diff --diff-filter=$diffFilter --name-status --exit-code $mergeBase $currentCommit"
    Write-Host $gitDiff -Separator "`n"
    
    [hashtable] $changes = @{}
    $gitDiff | ForEach-Object -Process {
                   $diff = $_.Split("`t")
               
                   $type = $diff[0][0]
                   $file = $diff[1]
                   $changes."$type" = $changes."$type" + @($file)
               }
    
    return $changes
}

function Invoke-GitCommand 
{
    param (
        [Parameter(Mandatory)]
        [string] 
        $command
    )

    Write-Host "##[command] $command"
    return Invoke-Expression -Command $command
}


# Filter functions

function Get-FilterTable
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        $filterString
    )
    
    [char] $separator = ';'
    [char] $quotes = '"'
    
    [hashtable] $filters = @{
        Include = @{}
        Exclude = @{}
    }
    
    $filterString.Trim().Trim($quotes).Split(@($separator), [StringSplitOptions]::RemoveEmptyEntries) | 
        ForEach-Object -Process {
            $filterParts = $_.Split(@(':'), [StringSplitOptions]::RemoveEmptyEntries)
                
            $type = $filterParts[0].Trim().Replace(' ', [string]::Empty)
                
            $table = $null
            if ($type[0] -eq '+') 
            {
                $table = $filters.Include
            }
            else 
            {
                $table = $filters.Exclude
            }
                
            $diffType = $type[1]
            $path = $filterParts[1].Trim()
                
            $table."$diffType" = $table."$diffType" + @($path)
        } > $null

    return $filters
}

function Get-FilterByDiffType
{
    param
    (
        [hashtable]
        [Parameter(Mandatory)]
        $filter,
        
        [string]
        [Parameter(Mandatory)]
        $diffType
    )
  
    $result = @()
    $filter.GetEnumerator() |
        ForEach-Object -Process {
            if ($diffType -like $_.Key) 
            {
                $result = $result + $_.Value
            } 
        }
        
    return $result
}

function Test-FilterMatch 
{
    param (
        [Parameter(Mandatory)]
        [string] 
        $path,
        
        [string[]] 
        $filter = $null
    )
    
    if ($filter -eq $null) 
    {
        return $false
    }
    
    $result = $filter | 
        Where-Object -FilterScript {
            $path -like $_.Trim()
        }

    return $result -ne $null
}

# Utilities

function Set-Results 
{
    param(
        [Parameter(Mandatory)]
        [string]
        $summaryMessage,
        
        [Parameter(Mandatory)]
        [ValidateSet('Succeeded', 'Failed', 'Cancelled', 'Skipped')]
        [string]
        $buildResult
    )

    $taskCommonTools = 'Microsoft.TeamFoundation.DistributedTask.Task.Common'
    if (Get-Module -ListAvailable -Name $taskCommonTools) 
    {
        Write-Output -InputObject 'Preparing to add summary to build results'
    }
    else 
    {
        Throw [IO.FileNotFoundException] "Module $taskCommonTools is not installed. If using a custom build controller ensure that this library is correctly installed and available for use in PowerShell."
    }
    
    Import-Module -Name $taskCommonTools

    Write-Host ('##vso[task.complete result={0};]{1}' -f $buildResult, $summaryMessage)
}


function Get-PullRequestFileUrl 
{
    param (
        [Parameter(Mandatory)][string] $fileName
    )
    
    $baseUri = "$env:BUILD_REPOSITORY_URI".TrimEnd('/')
    $filePath = [Uri]::EscapeDataString("/$fileName")
 
    return "$($baseUri)/pullrequest/$($env:SYSTEM_PULLREQUEST_PULLREQUESTID)?_a=files&path=$filePath"
}

function Get-CleanedUpFileLinkMarkdown 
{
    param (
        [Parameter(Mandatory)][string] $fileName
    )

    $url = Get-PullRequestFileUrl -fileName $fileName

    return "- [$fileName]($url)"
}


# Build task functions

function Invoke-GitCommit 
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        $authorName,
    
        [String]
        [Parameter(Mandatory)]
        $authorEmail,
        
        [String]
        [Parameter(Mandatory)]
        $message
    )
    
    [string[]] $files = Get-ModifiedFiles
    
    if ($files.Count -gt 0)
    {
        $quotes = '"'
        $authorName = $authorName.Trim($quotes).Trim()
        $authorEmail = $authorEmail.Trim($quotes).Trim()
        $message = $message.Trim($quotes).Trim()

        Invoke-GitCommand -command "git config user.email ""$authorEmail"""
        Invoke-GitCommand -command "git config user.name ""$authorName"""
        Invoke-GitCommand -command "git commit -a -m ""$message"""

        Set-Results -summaryMessage "Git commit '$message': done!" -buildResult Succeeded
    }
    else
    {
        Set-Results -summaryMessage "Git commit '$message': skipped. No changes." -buildResult Skipped
    }
}

function Invoke-GitCheckout
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        $target
    )
    

    $sourceBranch = Get-SourceBranchName -target $target
    $remoteUrl = Get-RepositoryUri -target $target

    Invoke-GitCommand -command "git fetch --quiet $remoteUrl $sourceBranch"
    Invoke-GitCommand -command 'git checkout --quiet FETCH_HEAD'

    Set-Results -summaryMessage "Git checkout $remoteUrl $($sourceBranch): done!" -buildResult Succeeded
}

function Invoke-GitPush 
{
    if (Test-CanPush) 
    {
        $sourceBranch = Get-SourceBranchName -target 'pull request'
        $remoteUrl = Get-RepositoryUri -target 'pull request'

        Write-Host 'Pushing changes to source branch'
        Invoke-GitCommand -command "git push --quiet $remoteUrl HEAD:$sourceBranch"

        $message = "Git push to $remoteUrl $($sourceBranch): done!"
        Set-Results -summaryMessage $message -buildResult Cancelled
    }
    else 
    {
        Set-Results -summaryMessage "Git push to $remoteUrl $($sourceBranch): skipped. No new commits." -buildResult Skipped
    }
}

function Invoke-GitDiff 
{
    param
    (
        [String]
        [Parameter(Mandatory)]
        $diffFilter,
    
        [String]
        [Parameter(Mandatory)]
        $fileFilter,
    
        [String]
        [Parameter(Mandatory)]
        $outVarName
    )
    
    $separator = ';'
    $quotes = '"'
    
    [hashtable] $gitDiff = Get-PullRequestChanges -diffFilter $diffFilter
    [hashtable] $filter = Get-FilterTable -filterString $fileFilter
    
    $result = @()
    $gitDiff.GetEnumerator() | 
        ForEach-Object -Process {
            $type = $_.Key
            $files = $_.Value
                
            $includeFilter = Get-FilterByDiffType -diffType $type -filter $filter.Include
            $excludeFilter = Get-FilterByDiffType -diffType $type -filter $filter.Exclude
                
            $filteredFiles = $files | 
                Where-Object -FilterScript {
                    $(Test-FilterMatch -path $_ -filter $includeFilter) -and -not $(Test-FilterMatch -path $_ -filter $excludeFilter)
                }
                
            $result = $result + $filteredFiles
        }
        
    Write-Host "Filtered git diff:"
    Write-Host $($result| Sort-Object) -Separator "`n"

    $resultString = [string]::Join($separator, $result)
    Write-Host "##vso[task.setvariable variable=$outVarName]$resultString"

    Set-Results -summaryMessage 'Git diff: done!' -buildResult Succeeded
}

cdX -Path $env:BUILD_SOURCESDIRECTORY

if ($command -eq 'checkout') 
{
    Invoke-GitCheckout -target $target
}
elseif ($command -eq 'commit') 
{
    Invoke-GitCommit -authorName $commitAuthorName -authorEmail $commitAuthorEmail -message $commitMessage
}
elseif ($command -eq 'push') 
{
    Invoke-GitPush
}
elseif ($command -eq 'diff') 
{
    Invoke-GitDiff -diffFilter $diffFilter -fileFilter $diffFileFilter -outVarName $diffVarName
}
