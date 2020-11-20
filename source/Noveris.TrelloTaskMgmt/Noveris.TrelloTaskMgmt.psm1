
################
# Global settings
$InformationPreference = "Continue"
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

#Requires -Modules @{"ModuleName"="Noveris.TrelloApi";"RequiredVersion"="0.2.0"}
#Requires -Modules @{"ModuleName"="Noveris.SvcProc";"RequiredVersion"="0.1.3"}

<#
#>
Function Select-TrelloListMatches
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [DateTime]$Date,

        [Parameter(Mandatory=$true,ValueFromPipeline)]
        [AllowNull()]
        [PSCustomObject]$Template
    )

    process
    {
        # Skip if this entry if null
        if ($Template -eq $null)
        {
            return
        }

        # Ignore if the name is missing or empty
        if (($Template | Get-Member).Name -notcontains "name" -or [string]::IsNullOrEmpty($Template.name))
        {
            Write-Warning "Missing or empty name in template list"
            return
        }
        $name = $Template.name

        # Extract the elements of the list name
        $elements = $null
        try {
            $elements = Format-TrelloListName -ListName $name
        } catch {
            Write-Warning "Parsing list name failed: $_"
            return
        }

        # Ignore if the date pattern doesn't match
        $dateStr = ("{0}_{1}_{2}" -f $Date.ToString("yyyyMMdd"), ([int]($Date.DayOfWeek)), ([int]($Date.DayOfYear)))
        if ($dateStr -notmatch $elements.Pattern)
        {
            return
        }

        $elements | Add-Member -NotePropertyName list -NotePropertyValue $Template
        $elements
    }
}

<#
#>
Function Format-TrelloCardName
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$CardName
    )

    process
    {
        # Default values, if not specified
        $list = "Todo"
        $grace = 0

        # Split name in to components
        $components = $CardName.Split(":")

        # If there are three or more components, extract in to list and grace as well
        if (($components | Measure-Object).Count -eq 2)
        {
            # No target list name supplied
            $grace = [int]::Parse($components[0])
            $name = $components[1]
        } elseif (($components | Measure-Object).Count -ge 3)
        {
            $list = $components[0]
            # Let any parser error flow to caller
            $grace = [int]::Parse($components[1])
            $name = $components[2]
        } else {
            $name = $CardName
        }

        [PSCustomObject]@{
            List = $list
            Grace = $grace
            Name = $name
        }
    }
}

<#
#>
Function Format-TrelloListName
{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ListName
    )

    process
    {
        # Separate based on last index of the separator, allowing the separator to exist in the pattern, if required in the future
        $index = $ListName.LastIndexOf(":")

        # Check if the separator exists in the list name
        if ($index -lt 0)
        {
            Write-Error ("Found list with invalid name: " + $list.name)
        }

        # Extract components from list name
        $pattern = $ListName.Substring(0, $index)
        $name = $ListName.Substring($index+1)

        # Check for missing or empty components
        if ([string]::IsNullOrEmpty($pattern) -or [string]::IsNullOrEmpty($name))
        {
            Write-Error "Missing or empty components in list name"
        }

        # Return custom object with components
        [PSCustomObject]@{
            Pattern = $pattern
            Name = $name
        }
    }
}

<#
#>
Function Test-TrelloValidConfiguration
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Config
    )

    process
    {
        "Name", "TemplateBoardId", "TargetBoardId" | ForEach-Object {
            $prop = $_
            if (($config | Get-Member).Name -notcontains $prop -or [string]::IsNullOrEmpty($config.$prop))
            {
                Write-Error "Missing $prop in configuration"
            }
        }
    }
}

<#
#>
Function Update-TrelloTasksFromTemplate
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Session,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateBoardId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetBoardId,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$StatusListName = "Status"
    )

    process
    {
        # Make sure we have a valid session
        Test-TrelloValidSession -Session $Session

        $now = [DateTime]::Now
        $today = [DateTime]::new($now.Year, $now.Month, $now.Day, 0, 0, 0, [System.DateTimeKind]::Local)

        # Retrieve the 'Status' list from the board. Create if it doesn't exist
        Write-Verbose "Retrieving status list."
        $statusList = Get-TrelloLists -Session $session -BoardId $TargetBoardId -FilterFirstNameMatch $StatusListName
        if (($statusList | Measure-Object).Count -lt 1)
        {
            Write-Verbose "Status list not found. Creating."
            $statusList = Add-TrelloList -Session $session -BoardId $TargetBoardId -Name $StatusListName
        }

        # Display status list information
        Write-Verbose ("'Status' list has id: " + $statusList.id)

        # Retrieve the 'Last Processed' status card from the list
        $lastProcessed = Get-TrelloListCards -Session $session -ListId $statusList.id -FilterFirstNameRegex "^Last Processed"

        # Check if we have a last processed card
        if (($lastProcessed | Measure-Object).Count -ne 1)
        {
            Write-Verbose "Failed to find 'Last Processed' card. Creating."
            $name = "Last Processed: {0}" -f ($now.ToString("yyyy/MM/dd HH:mm"))
            $desc = "Next Process: {0}" -f ($today.ToString("o"))
            $lastProcessed = Add-TrelloListCard -Session $session -ListId $statusList.id -Name $name -Description $desc
        }

        Write-Verbose ("Last Procedded Card: {0}" -f $lastProcessed.name)

        # Determine the next processing date
        $nextProcess = $today
        try {
            $str = $lastProcessed.desc.Split([Environment]::Newline) |
                Where-Object {$_.StartsWith("Next Process: ")} |
                Select-Object -First 1
            $str = $str.Substring("Next Process: ".Length)
            $nextProcess = [DateTime]::Parse($str)
        } catch {
            Write-Warning "Failed to parse Next Process time from Last Processed card: $_"
        }

        Write-Verbose ("Next Processing Date: {0}" -f $nextProcess)

        # Read all of the lists in the source board
        Write-Verbose "Reading all template lists"
        $templateLists = Get-TrelloLists -Session $session -BoardId $TemplateBoardId

        # Read all of the cards in the source board
        Write-Verbose "Reading all template cards"
        $templateCards = Get-TrelloBoardCards -Session $session -BoardId $TemplateBoardId

        # For each day since the 'Next Process' day, run the copy from source to target for that day
        # Use AddDays(1) and -lt to ensure we cover any unexpected variance in the hours, minutes and seconds for the Next Process date
        while ($nextProcess -lt $today.AddDays(1))
        {
            Write-Verbose ("Processing for date: {0}" -f $nextProcess.ToString("yyyy/MM/dd HH:mm"))

            # For any source list that has a pattern match for the processing date, copy the relevant cards to the relevant target lists in the target board
            $templateLists |
                Select-TrelloListMatches -Date $nextProcess |
                ForEach-Object {
                    $list = $_.list
                    $listDesc = $_.Name
                    Write-Verbose ("Processing for template list: {0}" -f $list.name)

                    $templateCards |
                      Where-Object { $_.idList -eq $list.id } |
                      ForEach-Object {
                          $card = $_
                          Write-Verbose ("Processing for card name: {0}" -f $card.name)

                          # Extract the card name components
                          try {
                              $components = Format-TrelloCardName -CardName $card.name
                          } catch {
                              Write-Warning "Failed to parse card name: $_"
                              return
                          }

                          # Ensure the target list exists
                          Write-Verbose ("Card target list: {0}" -f $components.list)
                          $targetList = Get-TrelloLists -Session $session -BoardId $TargetBoardId -FilterFirstNameMatch $components.List
                          if (($targetList | Measure-Object).Count -lt 1)
                          {
                              Write-Verbose "Target list does not exist. Creating."
                              $targetList = Add-TrelloList -Session $session -BoardId $TargetBoardId -Name $components.List
                          }
                          
                          # Copy the card to the target list
                          Write-Verbose "Copying card to target list"
                          $dueDate = $nextProcess.AddDays($components.Grace)
                          $body = [PSCustomObject]@{
                              name = [string]::Format("{0}/{1}: {2}", $nextProcess.ToString("yyyyMMdd"), $listDesc, $components.Name)
                              keepFromSource = "all"
                              idCardSource = $card.id
                              idList = $targetList.id
                              due = [DateTime]::new($dueDate.Year, $dueDate.Month, $dueDate.Day, 15, 0, 0, [System.DateTimeKind]::Local)
                          } | ConvertTo-Json
                          Write-Verbose "Posting card with body: $body"
                          Invoke-TrelloApi -Session $session -Endpoint "/cards" -Method Post -Body $body | Write-Verbose
                      }
                  }

            # Increment the processing date
            Write-Verbose "Incrementing processing date"
            $nextProcess = $nextProcess.AddDays(1)

            # Update the 'Last Processed' card
            Write-Verbose "Updating last processed card"
            $body = [PSCustomObject]@{
                name = "Last Processed: {0}" -f ($now.ToString("yyyy/MM/dd HH:mm"))
                desc = "Next Process: {0}" -f ($nextProcess.ToString("o"))
            } | ConvertTo-Json
            Invoke-TrelloApi -Session $session -Endpoint ("/cards/{0}" -f $lastProcessed.id) -Method Put -Body $body | Write-Verbose
        }
    }
}

<#
#>
Function Update-TrelloTasksFromConfig
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SessionPath
    )

    # Read configuration from file
    $entries = $null
    try {
        $entries = Get-Content -Encoding UTF8 $ConfigPath | ConvertFrom-Json -Depth 3
        $entries | ForEach-Object { Test-TrelloValidConfiguration -Config $_ }
    } catch {
        Write-Information "Failed to import configuration: $_"
        throw $_
    }

    # Import Trello session configuration
    $session = $null
    try {
        $session = Import-TrelloSession -Path $SessionPath
    } catch {
        Write-Information "Failed to import session: $_"
        throw $_
    }

    # Iterate through each configuration entry
    $errors = 0
    $entries | ForEach-Object {
        try {
              Write-Information ("Running Configuration: " + $_.Name)
              Write-Information ("Target Board: " + $_.TargetBoardId)
              Write-Information ("Template Board: " + $_.TemplateBoardId)

              Update-TrelloTasksFromTemplate -Session $session -Name $_.Name -TemplateBoardId $_.TemplateBoardId -TargetBoardId $_.TargetBoardId
        } catch {
            Write-Warning "Failed to process board: $_"
            $errors++
        }
    }

    # Exit with error if any of the runs failed
    Write-Information "Completed processing. Errors: $errors"
    if ($errors -gt 0)
    {
        Write-Error "Errors during processing. May have partially processed."
    }
}

<#
#>
Function Invoke-TrelloTaskUpdateService
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SessionPath,

        [Parameter(Mandatory=$false)]
        [ValidateNotNull()]
        [int]$Iterations = 1,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Start", "Finish")]
        [string]$WaitFrom = "Start",

        [Parameter(Mandatory=$false)]
        [ValidateNotNull()]
        [int]$WaitSeconds = 0,

        [Parameter(Mandatory=$false)]
        [ValidateNotNull()]
        [string]$LogPath = "",

        [Parameter(Mandatory=$false)]
        [int]$RotateSizeKB = 128,

        [Parameter(Mandatory=$false)]
        [int]$PreserveCount = 5
    )

    process
    {
        # Service command block
        $block = {
            Update-TrelloTasksFromConfig -ConfigPath $ConfigPath -SessionPath $SessionPath
        }

        # Build service parameters
        $serviceParams = @{
            ScriptBlock = $block
            Iterations = $Iterations
            WaitFrom = $WaitFrom
            WaitSeconds = $WaitSeconds
            LogPath = $LogPath
            RotateSizeKB = $RotateSizeKB
            PreserveCount = $PreserveCount
        }

        # Actual service invocation
        Invoke-ServiceRun @serviceParams
    }
}