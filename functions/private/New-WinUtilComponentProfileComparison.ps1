function New-WinUtilComponentProfileComparison {
    <#
    .SYNOPSIS
        Creates a deterministic visual comparison model for two component profiles.
    #>
    param (
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter(Mandatory)][string]$LeftProfileId,
        [Parameter(Mandatory)][string]$RightProfileId
    )

    $leftProfile = @($Profiles | Where-Object { [string]$_.id -ceq $LeftProfileId })
    $rightProfile = @($Profiles | Where-Object { [string]$_.id -ceq $RightProfileId })
    if ($leftProfile.Count -ne 1) {
        throw "Comparison profile '$LeftProfileId' is unavailable or duplicated."
    }
    if ($rightProfile.Count -ne 1) {
        throw "Comparison profile '$RightProfileId' is unavailable or duplicated."
    }
    if ($LeftProfileId -ceq $RightProfileId) {
        throw 'Choose two different component profiles to compare.'
    }

    $leftActions = Get-WinUtilEffectiveComponentPresetActionMap `
        -Catalog $Catalog -Profiles $Profiles -SelectedProfileId $LeftProfileId
    $rightActions = Get-WinUtilEffectiveComponentPresetActionMap `
        -Catalog $Catalog -Profiles $Profiles -SelectedProfileId $RightProfileId

    $items = foreach ($component in @($Catalog.components)) {
        $componentId = [string]$component.id
        $leftAction = [string]$leftActions[$componentId]
        $rightAction = [string]$rightActions[$componentId]
        if ($leftAction -cne $rightAction) {
            [pscustomobject]@{
                Id          = $componentId
                Name        = [string]$component.name
                Group       = Get-WinUtilComponentPolicyGroupName -Category ([string]$component.category)
                LeftAction  = $leftAction
                RightAction = $rightAction
                Risk        = [string]$component.risk
                Rationale   = [string]$component.reason
                Consequences = [string]$component.consequences
            }
        }
    }

    [pscustomobject]@{
        LeftProfileId = $LeftProfileId
        LeftProfileName = [string]$leftProfile[0].name
        RightProfileId = $RightProfileId
        RightProfileName = [string]$rightProfile[0].name
        ChangedCount = @($items).Count
        Items = @($items)
        Status = if (@($items).Count -eq 0) {
            'The selected profiles have no component action differences.'
        } else {
            "Showing $(@($items).Count) changed component actions."
        }
    }
}
