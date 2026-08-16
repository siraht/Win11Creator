function Update-WinUtilComponentProfileComparisonUI {
    $leftProfileId = [string]$sync.WPFWin11ISOCompareLeftProfile.SelectedValue
    $rightProfileId = [string]$sync.WPFWin11ISOCompareRightProfile.SelectedValue

    try {
        $comparison = New-WinUtilComponentProfileComparison `
            -Catalog $sync.configs.componentPolicy.catalog `
            -Profiles @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value) `
            -LeftProfileId $leftProfileId `
            -RightProfileId $rightProfileId
        $sync['Win11ISOComponentProfileComparison'] = $comparison
        Invoke-WPFUIThread {
            $sync.WPFWin11ISOProfileDiffStatus.Text = $comparison.Status
            $sync.WPFWin11ISOProfileDiffStatus.Foreground = $sync.WPFWin11ISOProfileComboBox.Foreground
            $sync.WPFWin11ISOProfileDiffLeftHeader.Text = $comparison.LeftProfileName
            $sync.WPFWin11ISOProfileDiffRightHeader.Text = $comparison.RightProfileName
            $sync.WPFWin11ISOProfileDiffItems.ItemsSource = @($comparison.Items)
        }
    } catch {
        $errorMessage = [string]$_.Exception.Message
        $sync['Win11ISOComponentProfileComparison'] = $null
        Invoke-WPFUIThread {
            $sync.WPFWin11ISOProfileDiffStatus.Text = $errorMessage
            $sync.WPFWin11ISOProfileDiffStatus.Foreground = 'OrangeRed'
            $sync.WPFWin11ISOProfileDiffLeftHeader.Text = 'First action'
            $sync.WPFWin11ISOProfileDiffRightHeader.Text = 'Second action'
            $sync.WPFWin11ISOProfileDiffItems.ItemsSource = @()
        }
    }
}

function Initialize-WinUtilComponentProfileComparisonUI {
    $profileOptions = @(
        $sync.configs.componentPolicy.profiles.PSObject.Properties.Value |
            Sort-Object { [string]$_.name } |
            ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } }
    )

    Invoke-WPFUIThread {
        foreach ($selector in @($sync.WPFWin11ISOCompareLeftProfile, $sync.WPFWin11ISOCompareRightProfile)) {
            $selector.ItemsSource = $profileOptions
            $selector.DisplayMemberPath = 'Name'
            $selector.SelectedValuePath = 'Id'
        }
        if ($profileOptions.Count -ge 1) { $sync.WPFWin11ISOCompareLeftProfile.SelectedValue = $profileOptions[0].Id }
        if ($profileOptions.Count -ge 2) { $sync.WPFWin11ISOCompareRightProfile.SelectedValue = $profileOptions[1].Id }
    }
    Update-WinUtilComponentProfileComparisonUI
}
