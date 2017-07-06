<#
.SYNOPSIS
Update remote TFS Repository with local source 

.DESCRIPTION
Can be used as part of TFS Build Script to push local source to remote TFS

PAT (Personal access token) can be created at https://d365ops-adtest.visualstudio.com/_details/security/tokens
Required Authorized Scopes: Code (read and write) [vso.code_write]

Alternate credentials can be enabled at https://_account_.visualstudio.com/_details/security/altcreds

#>
[CmdletBinding()]
Param(
    # Url to remote TFS Server (with optional TFS Collection)
    [parameter(Position=0)]
    [uri]$OtherTfsCollectionUrl = $env:OtherTfsCollectionUrl
    
    ,
    # username or 'PAT'
    [string]$OtherTfsUsername = $env:OtherTfsUsername
    
    ,
    # password or *Personal access token*
    [string]$OtherTfsPassword=$env:OtherTfsPassword
    
    ,
    # Remote target server path (must start with '$/')
    # $/project/Trunk/Main
    [string]$OtherTfsServerPath = $env:OtherTfsServerPath
    
    ,
    # Name for temporary local workspace
    [string]$OtherTfsWorkspaceName = $env:OtherTfsWorkspaceName
    
    ,
    # Sources to be synchronized with remote TFS
    [string]$localSource = $env:BUILD_SOURCESDIRECTORY
    
    ,
    # local working folder
    [string]$localWorkPath = (Join-Path $env:AGENT_BUILDDIRECTORY 'remoteTfs')

    ,
    # Verbose output for this scipt only
    [switch]$VerboseScriptOnly = $true
)

function Write-Verbose-Script([string]$Message)
{
    if ($VerboseScriptOnly)
    {
        Write-Verbose -Verbose $Message
    }
    else
    {
        Write-Verbose $Message
    }
}

$tfCmd = Get-Command tf.exe
[System.IO.FileInfo]$tfInfo = $tfCmd.Path
$tfDir = $tfInfo.Directory.FullName

Add-Type -Path (Join-Path $tfDir Microsoft.TeamFoundation.Client.dll)
Add-Type -Path (Join-Path $tfDir Microsoft.TeamFoundation.VersionControl.Client.dll)

function GetWorkspace()
{
    $vssBasicCred = New-Object Microsoft.VisualStudio.Services.Common.VssBasicCredential $OtherTfsUsername, $OtherTfsPassword
    $vssCred = New-Object Microsoft.VisualStudio.Services.Common.VssCredentials $vssBasicCred
    $projColl = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection $OtherTfsCollectionUrl, $vssCred
    #[Microsoft.TeamFoundation.Client.TfsTeamProjectCollection] | select DeclaredConstructors | % {$_.DeclaredConstructors.GetParameters()} | select member -Unique
    #[Microsoft.TeamFoundation.Client.TfsTeamProjectCollection].Assembly.Location

    $projColl.Authenticate()
    $vcs = $projColl.GetService([Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer])
    
    $authUser = $vcs.AuthorizedUser
    $wsArray = $vcs.QueryWorkspaces($OtherTfsWorkspaceName, $authUser, $null)
    if ($wsArray -and $wsArray.Count -gt 0)
    {
        $ws = $wsArray[0]
    }
    else
    {
        $ws = $vcs.CreateWorkspace($OtherTfsWorkspaceName)
    }

    if (!$ws.IsServerPathMapped($OtherTfsServerPath))
    {
        $wf = New-Object Microsoft.TeamFoundation.VersionControl.Client.WorkingFolder $OtherTfsServerPath, $localWorkPath
        $ws.CreateMapping($wf)
    }

    return $ws
}


function Main()
{

    $ws = GetWorkspace
    $itemSpec = @(New-Object Microsoft.TeamFoundation.VersionControl.Client.ItemSpec($OtherTfsServerPath, [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::Full))

    $getStatus = $ws.Get([Microsoft.TeamFoundation.VersionControl.Client.VersionSpec]::Latest, [Microsoft.TeamFoundation.VersionControl.Client.GetOptions]::GetAll)
    ###$getResult = $ws.GetItems($itemSpec,
    ###    [Microsoft.TeamFoundation.VersionControl.Client.DeletedState]::NonDeleted, 
    ###    [Microsoft.TeamFoundation.VersionControl.Client.ItemType]::Any,
    ###    $false,
    ###    [Microsoft.TeamFoundation.VersionControl.Client.GetItemsOptions]::None
    ###)
    #
    # RoboCopy
    #  /mir = /e + /purge 
    #  /sl - symbolic link
    #  /r - retry
    #  /w - wait
    #  /mt - multi thread
    #  logging - /nfl /ndl /ns /nc /np 
    $RoboCopyOutput = & RoboCopy $localSource . /MIR /SL /MT /R:3 /W:10 /NFL /NDL /NS /NC /NP /XD `$tf
    $RoboCopyOutput | Select-Object -Last 8 | Write-Verbose

    [Microsoft.TeamFoundation.VersionControl.Client.PendingChange[]]$pendChangesArg = @()
    $ws.GetPendingChangesWithCandidates($itemSpec, $false, [ref]$pendChangesArg) | Out-Null
    Write-Verbose-Script "Detected changes: $($pendChangesArg.Count)"
    $pendChangesArg | select ChangeTypeName, ToolTipText | Group-Object ChangeTypeName | Out-String | Write-Verbose -Verbose
    #$pendChangesArg|ogv
    $pendChangesArg | % {
        $pendChange = $_
        Write-Verbose $pendChange.ToolTipText
        if ($pendChange.ChangeType -band [Microsoft.TeamFoundation.VersionControl.Client.ChangeType]::Add)
        {
            $ws.PendAdd($pendChange.LocalItem)
        }
        elseif ($pendChange.ChangeType -band [Microsoft.TeamFoundation.VersionControl.Client.ChangeType]::Edit)
        {
            $ws.PendEdit($pendChange.LocalItem)
        }
        elseif ($pendChange.ChangeType -band [Microsoft.TeamFoundation.VersionControl.Client.ChangeType]::Delete)
        {
            $ws.PendDelete($pendChange.LocalItem)
        }
    } | Out-Null
    $pendingChanges = $ws.GetPendingChanges()
    $pendingSummary = $pendingChanges | select ChangeTypeName, ToolTipText | Group-Object ChangeTypeName | Out-String 
    Write-Verbose -Verbose "Pending Changes: $($pendingChanges.Count)"
    Write-Verbose -Verbose "Summary: $pendingSummary"
    if ($pendingChanges)
    {
        $ciResult = $ws.CheckIn($pendingChanges, "Automated CheckIn")
    }
}

try
{
    if (!(Test-Path $localWorkPath))
    {
        mkdir $localWorkPath -Force | Out-Null
    }

    pushd $localWorkPath
    
    Main
}
finally
{
    popd

    if ($ws -and !$ws.IsDeleted)
    {
        if (!$ws.Delete())
        {
            Write-Warning "Workspace delete failed ($($ws.DisambiguatedDisplayName))"
        }
    }

    if (Test-Path $localWorkPath)
    {
        rmdir -Force -Recurse $localWorkPath
    }
}
