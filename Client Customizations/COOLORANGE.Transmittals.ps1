#==============================================================================#
# (c) 2025 coolOrange s.r.l.                                                   #
#                                                                              #
# THIS SCRIPT/CODE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER    #
# EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES  #
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, OR NON-INFRINGEMENT.   #
#==============================================================================#

if ($processName -notin @('Connectivity.VaultPro')) {
	return
}

$global:custEntName = "Transmittal"
$global:custEntActiveState = "Open"

#region Tab
Add-VaultTab -Name "Assigned Files" -EntityType Transmittal -Action {
	param($selectedCustEnt)
    
    $xamlFile = [xml](Get-Content "C:\ProgramData\coolOrange\Client Customizations\COOLORANGE.Transmittals.Tab.xaml")
	$tab_control = [Windows.Markup.XamlReader]::Load( (New-Object System.Xml.XmlNodeReader $xamlFile) )

    class Link {
        [string] $id
        [string] $fileName
        [string] $fileRevision
        [string] $fileVersion
        [string] $folder     
        [string] $latestRevision
        [string] $latestVersion
        [bool] $isUpToDate
    }

    class DataContext {
        [object] $Transmittal
        [System.Collections.ObjectModel.ObservableCollection[Link]] $Links

        DataContext() {
            $this.Links = New-Object System.Collections.ObjectModel.ObservableCollection[Link]
        }
    }

    $dataContext = [DataContext]::new()
    $dataContext.Transmittal = $selectedCustEnt
    
    $links = $vault.DocumentService.GetLinksByParentIds(@($selectedCustEnt.Id), @("FILE"))
    if ($links) {
        $fileIds = @()
        foreach($link in $links) {
            $fileIds += $link.ToEntId      
        }

        $latestFiles = $vault.DocumentService.GetLatestFilesByIds($fileIds)
        
        for($i=0; $i -lt $fileIds.Count; $i++) {
            try {
                $latestFile = $latestFiles[$i]
                $link = $links | Where-Object { $_.ParEntClsId -eq "CUSTENT" -and $_.ToEntClsId -eq "FILE" -and $_.ToEntId -eq $latestFile.Id }

                $selectedFileId = $latestFile.Id
                $linkedFileId = $vault.DocumentService.GetMetaOnLinks(@($link.Id))
                if ($linkedFileId) {
                    $selectedFileId = [long]::Parse($linkedFileId)
                }

                $selectedFile = $vault.DocumentService.GetFilesByIds($selectedFileId)[0]
                $folder = $vault.DocumentService.GetFolderById($selectedFile.FolderId)

                $l = [Link]::new()
                $l.id = $link.Id
                $l.latestRevision = $latestFile.FileRev.Label
                $l.latestVersion = $latestFile.VerNum
                $l.fileName = $selectedFile.Name
                $l.fileRevision = $selectedFile.FileRev.Label
                $l.fileVersion = $selectedFile.VerNum
                $l.folder = $folder.FullName
                $l.isUpToDate = $selectedFile.Id -eq $latestFile.Id

                $dataContext.Links.Add($l)
            } catch {
                [System.Windows.Forms.MessageBox]::Show($error[0])
            }
        }
        
        $tab_control.FindName('ButtonUpdate').IsEnabled = $true
        $tab_control.FindName('ButtonSubmit').IsEnabled = $true
    } else {
        $tab_control.FindName('ButtonUpdate').IsEnabled = $false
        $tab_control.FindName('ButtonSubmit').IsEnabled = $false
    }

    $tab_control.FindName('Title').Content = "$($selectedCustEnt.Name) ($($dataContext.Links.Count) files attached)"
    $tab_control.DataContext = $dataContext

    $sortDescription = New-Object System.ComponentModel.SortDescription 'fileName', 'Ascending'
    $tab_control.FindName('FilesTable').Items.SortDescriptions.Add($sortDescription)
    
    $tab_control.FindName('ButtonAdd').add_Click({
        AddFilesToSubmittal $selectedCustEnt
    }.GetNewClosure())

    $tab_control.FindName('ButtonUpdate').add_Click({
        $links = $vault.DocumentService.GetLinksByParentIds(@($selectedCustEnt.Id), @("FILE"))
        $fileIds = @()
        $links | Where-Object { $_.ParEntClsId -eq "CUSTENT" -and $_.ToEntClsId -eq "FILE"} | ForEach-Object { $fileIds += $_.ToEntId }
        AddOrUpdateLinks $selectedCustEnt $fileIds
    }.GetNewClosure())

    $tab_control.FindName('ButtonSubmit').add_Click({
        SubmitTransmittal $selectedCustEnt
    }.GetNewClosure())

	return $tab_control
}
#endregion

#region File Context Menu
Add-VaultMenuItem -Location FileContextMenu -Name "Add Files to Transmittal..." -Action {
    param($entities)

    $propDefs = $vault.PropertyService.GetPropertyDefinitionsByEntityClassId("CUSTENT")
    $propDef = $propDefs | Where-Object { $_.DispName -eq "Custom Object Name" }
    $srchConds = New-Object System.Collections.Generic.List[Autodesk.Connectivity.WebServices.SrchCond]
    $srchCond = New-Object Autodesk.Connectivity.WebServices.SrchCond
    $srchCond.PropDefId = $propDef.Id
    $srchCond.SrchOper = 3
    $srchCond.SrchTxt = $global:custEntName
    $srchCond.PropTyp = [Autodesk.Connectivity.WebServices.PropertySearchType]::SingleProperty
    $srchCond.SrchRule = "Must"
    $srchConds.Add($srchCond)
    $propDef = $propDefs | Where-Object { $_.DispName -eq "State" }
    $srchConds = New-Object System.Collections.Generic.List[Autodesk.Connectivity.WebServices.SrchCond]
    $srchCond = New-Object Autodesk.Connectivity.WebServices.SrchCond
    $srchCond.PropDefId = $propDef.Id
    $srchCond.SrchOper = 3
    $srchCond.SrchTxt = $global:custEntActiveState
    $srchCond.PropTyp = [Autodesk.Connectivity.WebServices.PropertySearchType]::SingleProperty
    $srchCond.SrchRule = "Must"
    $srchConds.Add($srchCond)

    $bookmark = ""
    $status = $null
    $totalResults = @()
    while ($null -eq $status -or $totalResults.Count -lt $status.TotalHits) {
        $results = $vault.CustomEntityService.FindCustomEntitiesBySearchConditions($srchConds, $null, [ref]$bookmark, [ref]$status)
        if ($null -ne $results) {
            $totalResults += $results
        }
        else {
            break
        }
    }

    $custEnts = $totalResults

    if ($custEnts.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No Transmittals found.", "COOLORANGE Transmittal Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $custEnt = Open-DialogSelectTransmittal "Select the Transmittal for this file(s):" $custEnts
    if (-not $custEnt) {
        return
    }

    $fileIds = @()
    $entities | ForEach-Object { $fileIds += $_.Id }

    AddOrUpdateLinks $custEnt $fileIds
}

function Open-DialogSelectTransmittal($label, [array]$objects, $selectedObjectName = $null) {

    $itemsSource = [System.Collections.ObjectModel.ObservableCollection[[System.Object]]]::new($objects)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xamlFile = [xml](Get-Content "C:\ProgramData\coolOrange\Client Customizations\COOLORANGE.Transmittals.Select.xaml")
    $window = [Windows.Markup.XamlReader]::Load( (New-Object System.Xml.XmlNodeReader $xamlFile) )
    $window.WindowStartupLocation = "CenterScreen"
    $window.Owner = $Host.UI.RawUI.WindowHandle
    $window.FindName("Label").Content = $label
    $window.FindName("Object").ItemsSource = $itemsSource
    $window.FindName("Object").SelectedValue = $selectedObjectName
            
    $window.FindName('Ok').add_Click({
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    if ($window.ShowDialog()) {
        return $window.FindName("Object").SelectedItem
    }

    return $null
}
#endregion

#region Add Files
Add-VaultMenuItem -Location 'TransmittalContextMenu' -Name 'Add Files...' -Action {
    param($entities)

    $custEnt = $entities[0]
    AddFilesToSubmittal $custEnt
}

function AddFilesToSubmittal($custEnt) {
    $browsersettings = New-Object Autodesk.DataManagement.Client.Framework.Vault.Forms.Settings.SelectEntitySettings
    $browsersettings.ActionableEntityClassIds.Add("FILE")
    $browsersettings.MultipleSelect = $true
    $browsersettings.DialogCaption = "Select files to be added to the Transmittal '$($custEnt._Name)'"
    $browsersettings.ConfigureActionButtons("Add to Transmittal", $null, $null, $null)

    $result = [Autodesk.DataManagement.Client.Framework.Vault.Forms.Library]::SelectEntity($vaultConnection, $browsersettings)
    if (-not $result.SelectedEntities) { return }

    $fileIds = @()
    $result.SelectedEntities | ForEach-Object { $fileIds += $_.EntityIterationId }

    AddOrUpdateLinks $custEnt $fileIds
}
#endregion

#region Use Latest Versions
Add-VaultMenuItem -Location 'TransmittalContextMenu' -Name 'Use Latest Versions...' -Action {
    param($entities)

    $custEnt = $entities[0]
    $links = $vault.DocumentService.GetLinksByParentIds(@($custEnt.Id), @("FILE"))
    $fileIds = @()
    $links | Where-Object { $_.ParEntClsId -eq "CUSTENT" -and $_.ToEntClsId -eq "FILE"} | ForEach-Object { $fileIds += $_.ToEntId }
    AddOrUpdateLinks $custEnt $fileIds
}
#endregion

#region Submit Transmittal
Add-VaultMenuItem -Location 'TransmittalContextMenu' -Name 'Submit Transmittal...' -Action {
    param($entities)

    $custEnt = $entities[0]
    SubmitTransmittal $custEnt
}

function SubmitTransmittal($custEnt) {
    $dataContext = Open-DialogSubmitTransmittal
    if (-not $dataContext) { return }

    $email = $dataContext.Email
    $message = $dataContext.Message

    Add-VaultJob -Name "COOLORANGE.Transmittals" -Description "Compile and submit Transmittal '$($custEnt._Name)'" -Parameters @{
        "EntityId"= $custEnt.Id
        "EntityClassId"= "CUSTENT"
        "Email" = $email
        "Message" = $message
    }
}

function Open-DialogSubmitTransmittal($email = "", $message = "") {
    class DataContext {
        [string] $Email
        [string] $Message

        DataContext() {
        }
    }

    $dataContext = [DataContext]::new()
    $dataContext.Email = $email
    $dataContext.Message = $message
    
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xamlFile = [xml](Get-Content "C:\ProgramData\coolOrange\Client Customizations\COOLORANGE.Transmittals.Submit.xaml")
    $window = [Windows.Markup.XamlReader]::Load( (New-Object System.Xml.XmlNodeReader $xamlFile) )
    $window.WindowStartupLocation = "CenterScreen"
    $window.Owner = $Host.UI.RawUI.WindowHandle
    $window.DataContext = $dataContext
    $window.FindName('Ok').add_Click({
        $window.DialogResult = $true
        $window.Close()
    }.GetNewClosure())

    if ($window.ShowDialog()) {
        return $dataContext
    }
    
    return $null
}
#endregion

function AddOrUpdateLinks($custEnt, $fileIds) {
    $linkFailed = @()
    $linkReplaced = @()
    $linkCount = 0

    $links = $vault.DocumentService.GetLinksByParentIds(@($custEnt.Id), @("FILE"))
    $latestFiles = $vault.DocumentService.GetLatestFilesByIds($fileIds)
    $selectedFiles = $vault.DocumentService.GetFilesByIds($fileIds)

    for($i=0; $i -lt $fileIds.Count; $i++) {
        try {
            $latestFile = $latestFiles[$i]
            $selectedFile = $selectedFiles[$i]
            $link = $links | Where-Object { $_.ParEntClsId -eq "CUSTENT" -and $_.ToEntClsId -eq "FILE" -and $_.ToEntId -eq $latestFile.Id }

            if ($link) {
                $linkedFileId = $vault.DocumentService.GetMetaOnLinks(@($link.Id))
                if ($linkedFileId -ne [string]$selectedFile.Id) {
                    $vault.DocumentService.DeleteLinks(@($link.Id))
                    $linkReplaced += $selectedFile
                } else {
                    continue
                }
            }

            $link = $vault.DocumentService.AddLink($custEnt.Id, "FILE", $latestFile.Id, $selectedFile.Id)
            $linkCount++
        } catch {
            $linkFailed += $selectedFile
        }
    }

    $message = "$linkCount file(s) attached to the Transmittal '$($custEnt.Name)'."
    if ($linkReplaced.Count -gt 0)
    {
        $message += [System.Environment]::NewLine
        $message += "The links to the following files have been updated:"
        $message += [System.Environment]::NewLine
        foreach($file in $linkReplaced)
        {
            $message += [System.Environment]::NewLine
            $message += "`t$($file.Name)"
        }
    }
    if ($linkFailed.Count -gt 0)
    {
        $message += [System.Environment]::NewLine
        $message += "Linking the following files failed:"
        $message += [System.Environment]::NewLine
        foreach($file in $linkFailed)
        {
            $message += [System.Environment]::NewLine
            $message += "`t$($file.Name)"
        }
    }

    [System.Windows.Forms.SendKeys]::SendWait('{F5}')
    #[System.Windows.Forms.MessageBox]::Show($message, "Transmittal Information", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}
