#==============================================================================#
# (c) 2025 coolOrange s.r.l.                                                   #
#                                                                              #
# THIS SCRIPT/CODE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER    #
# EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES  #
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, OR NON-INFRINGEMENT.   #
#==============================================================================#

# Do not delete the next line. Required for the powerJobs Settings Dialog to determine the entity type for lifecycle state change triggers.
# JobEntityType = CUSTENT

#region Settings
$reportFileLocation = "C:\ProgramData\coolOrange\powerJobs\Jobs\COOLORANGE.Transmittals.rdlc"
#endregion

#region Settings
# The subject of the email
$subject = "Transmittal from coolOrange"
# The email address used to send out the email
$from = ""
# The SMTP user used to authenticate when sending out the email
$user = ""
# The SMTP users password used to authenticate when sending out the email
$password = ""
# The SMTP server name
$smtpServer = ""
# The SMTP server port
$port = 587
# To use SSL when sending out the email $true, otherwise $false
$useSSL = $true
#endregion

#region Debug
if (-not $IAmRunningInJobProcessor) {
    Import-Module powerJobs
    # https://doc.coolorange.com/projects/coolorange-powervaultdocs/en/stable/code_reference/commandlets/open-vaultconnection.html
    Open-VaultConnection

    $workingDirectory = "C:\TEMP\powerJobs Processor\Debug"
    $transmittalName = "Test"

    $propDefs = $vault.PropertyService.GetPropertyDefinitionsByEntityClassId("CUSTENT")
    $propDef = $propDefs | Where-Object { $_.DispName -eq "Name" }
    $srchConds = New-Object System.Collections.Generic.List[Autodesk.Connectivity.WebServices.SrchCond]
    $srchCond = New-Object Autodesk.Connectivity.WebServices.SrchCond
    $srchCond.PropDefId = $propDef.Id
    $srchCond.SrchOper = 3
    $srchCond.SrchTxt = $transmittalName
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

    if ($totalResults.Count -eq 0) { return }
    
    $custEnt = $totalResults[0]
    $global:customObject = New-Object Autodesk.DataManagement.Client.Framework.Vault.Currency.Entities.CustomObject($vaultConnection, $custEnt)

    #$jobs = $vault.JobService.GetJobsByDate([int]::MaxValue, [DateTime]::MinValue)
    #$job = $jobs | Where-Object { $_.Id -eq 69309 }
}
#endregion

if (-not $user) {
    $jobs = $vault.JobService.GetJobsByDate([int]::MaxValue, [DateTime]::MinValue)
    $user = $vault.AdminService.GetUserByUserId(($jobs | Where-Object { $_.Id -eq $job.Id }).CreateUserId)
}

Write-Host "Starting job '$($job.Name)'..."

$message = $job.Message #($job.ParamArray | Where-Object { $_.Name -eq "Message" }).Val
$recepient = $job.Email #($job.ParamArray | Where-Object { $_.Name -eq "Email" }).Val


#region Report Functions
function GetReportColumnType([string]$typeName) {
	switch ($typeName) {
        "String" { return [System.String] }
        "Numeric" { return [System.Double] }
        "Bool" { return [System.Byte] }
        "DateTime" { return [System.DateTime] }
        "Image" { return [System.String] }
        Default { throw ("Type '$typeName' cannot be assigned to a .NET type") }
    }
}

function ReplaceInvalidColumnNameChars([string]$columnName) {
    $pattern = "[^A-Za-z0-9]"
    return [System.Text.RegularExpressions.Regex]::Replace($columnName, $pattern, "_")
}

function GetReportDataSet([Autodesk.Connectivity.WebServices.File[]]$files, [System.String]$reportFileLocation, [System.String]$reportDataSet) {
    $sysNames = @()
    [xml]$reportFileXmlDocument = Get-Content -Path $reportFileLocation
    $dataSets = $reportFileXmlDocument.Report.DataSets.ChildNodes | Where-Object {$_.Name -eq $reportDataSet} 
    $dataSets.Fields.ChildNodes | ForEach-Object {
        $sysNames += $_.DataField
    }
    
    $table = New-Object System.Data.DataTable -ArgumentList @($reportDataSet)
    $table.BeginInit()

    $propDefIds = @()
    $propDefs = $vault.PropertyService.GetPropertyDefinitionsByEntityClassId("FILE")
    $propDefs | ForEach-Object {
		if ($sysNames -icontains $_.SysName) { 
			$propDefIds += $_.Id
	        $type = GetReportColumnType $_.Typ

	        $column = New-Object System.Data.DataColumn -ArgumentList @(($_.SysName), $type)
	        $column.Caption = (ReplaceInvalidColumnNameChars $_.DispName)
	        $column.AllowDBNull = $true
	        $table.Columns.Add($column)
		}
    }

    $colEntityType = New-Object System.Data.DataColumn -ArgumentList @("EntityType", [System.String])
    $colEntityType.Caption = "Entity_Type"
    $colEntityType.DefaultValue = "File"
    $table.Columns.Add($colEntityType)
    
	$colEntityTypeId = New-Object System.Data.DataColumn -ArgumentList @("EntityTypeID", [System.String])
    $colEntityTypeId.Caption = "Entity_Type_ID"
    $colEntityTypeId.DefaultValue = "FILE"
	$table.Columns.Add($colEntityTypeId)

    $fileIds = @($files | Select-Object -ExpandProperty Id)
    $propInsts = $vault.PropertyService.GetProperties("FILE", $fileIds, $propDefIds)
    
    $table.EndInit()	
	$table.BeginLoadData()
    $files | ForEach-Object {
        $file = $_
        $row = $table.NewRow()
        
        $propInsts | Where-Object { $_.EntityId -eq $file.Id } | ForEach-Object {
            if ($_.Val) {
                $propDefId = $_.PropDefId
                $propDef = $propDefs | Where-Object { $_.Id -eq $propDefId }
                if ($propDef) {
                    if ($propDef.Typ -eq "Image") {
                        $val = [System.Convert]::ToBase64String($_.Val)
                    } else {
                        $val = $_.Val
                    }
                    $row."$($propDef.SysName)" = $val
                }
            }
        }
        $table.Rows.Add($row)
    }
	$table.EndLoadData()
	$table.AcceptChanges()
	
    return ,$table
}

function CreateReport($reportFileLocation, $reportDataSet, $files, $reportFileName) {
    Write-Host "Creating RDLC report '$($reportFileLocation | Split-Path -Leaf)'..."
    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.ReportViewer`.WinForms") | Out-Null
        
    $table = GetReportDataSet $files $reportFileLocation $reportDataSet
    
    $xmlDocument = New-Object System.Xml.XmlDocument
    $xmlDocument.Load($reportFileLocation)
    
    $localReport = New-Object Microsoft.Reporting.WinForms.LocalReport
    $stringReader = New-Object System.IO.StringReader -ArgumentList @($xmlDocument.OuterXml)
    
    $localReport.LoadReportDefinition($stringReader)
    $stringReader.Close()
    $stringReader.Dispose()
    
    $paramNames = $localReport.GetParameters() | Select-Object { $_.Name } -ExpandProperty Name    
    $parameterList = New-Object System.Collections.Generic.List[Microsoft.Reporting.WinForms.ReportParameter]
    foreach($parameter in $parameters.GetEnumerator()) {
		if ($paramNames -contains $parameter.Key) {
	        $param = New-Object Microsoft.Reporting.WinForms.ReportParameter -ArgumentList @($parameter.Key, $parameter.Value)
	        $parameterList.Add($param)
		}
    }
    $localReport.SetParameters($parameterList)
    
    $reportDataSource = New-Object -TypeName Microsoft.Reporting.WinForms.ReportDataSource -ArgumentList @($table.TableName, [System.Data.DataTable]$table)
    $localReport.DataSources.Add($reportDataSource)
    $bytes = $localReport.Render("PDF");
    
    $localPdfFolder = $reportFileName | Split-Path -Parent
    if (-not [System.IO.Directory]::Exists($localPdfFolder)) {
        [System.IO.Directory]::CreateDirectory($localPdfFolder) | Out-Null
    }
    
    if ([System.IO.File]::Exists($reportFileName)) {
        [System.IO.File]::Delete($reportFileName)
    }
    
    [System.IO.File]::WriteAllBytes($reportFileName, $bytes)
    Write-Host "Report saved as PDF to '$reportFileName'"
}
#endregion

Write-Host "Collecting files..."
$files = @()
$links = @($vault.DocumentService.GetLinksByParentIds(@($customObject.EntityIterationId), @("FILE")))
foreach($link in $links) {
    $linkedFileId = $vault.DocumentService.GetMetaOnLinks(@($link.Id))
    if (-not $linkedFileId) {
        $linkedFileId = $link.ToEntId
    } else {
        $linkedFileId = [long]::Parse($linkedFileId)
    }

    $file = Get-VaultFile -FileId $linkedFileId -DownloadPath $workingDirectory
    $files += $vault.DocumentService.GetFileById($linkedFileId)
}

Write-Host "Compressing files..."
$zipFileName = [System.IO.Path]::Combine($workingDirectory, "$($customObject.EntityName).zip")
Compress-Archive -Force -Path $workingDirectory -DestinationPath $zipFileName

Write-Host "Generating report..."
$reportFileName = [System.IO.Path]::Combine($workingDirectory, "$($customObject.EntityName).pdf")
$reportDataSet = "AutodeskVault_ReportDataSource"

$parameters = @{
    Report_UserName = $vaultConnection.UserName
    Report_Source = $customObject.EntityName
    Report_Action = "Transmittal"
    Report_Destination = $recepient
    Report_Date = Get-Date
    Report_FilesCountAndSize = $files.Count
}

CreateReport $reportFileLocation $reportDataSet $files $reportFileName

Write-Host "Sending email to $($recepient)..."
$emails = @($recepient)
if ($emails.Length -gt 0) {
    $credential = New-Object Management.Automation.PSCredential @($user, (ConvertTo-SecureString -AsPlainText $password -Force))
    foreach($email in $emails) {
        if ($useSSL) {
            Send-MailMessage -From $from -To $email -Subject $subject -Body $message -SmtpServer $smtpServer -Port $port -Credential $credential -UseSsl -Attachments @($reportFileName, $zipFileName)
        } else {
            Send-MailMessage -From $from -To $email -Subject $subject -Body $message -SmtpServer $smtpServer -Port $port -Credential $credential -Attachments @($reportFileName, $zipFileName)
        }
    }    
} else {
    Write-Host "No email recipients specified."
}

Write-Host "Completed job '$($job.Name)'"

<# 
TODO: Future improvements

- check inputs (email, message) - should be done in the Vault Client Extension
- allow multiple recepients
- add an instance of the transmittal to a history to keep track of what has been sent (code below)

	$custEntDefs = $vault.CustomEntityService.GetAllCustomEntityDefinitions()
	$custEntDef = $custEntDefs | Where-Object { $_.DispName -eq "Transmittal History" }

	$custEntCats = $vault.CategoryService.GetCategoriesByEntityClassId("CUSTENT", $true)
	$custEntCat = $custEntCats | Where-Object { $_.Name -eq "Transmittal History" }

	$numSchms = $vault.DocumentService.GetNumberingSchemesByType([Autodesk.Connectivity.WebServices.NumSchmType]::Activated)
	$numSchm = $numSchms | Where-Object { $_.Name -eq $numSchmName }
	$number = $vault.DocumentService.GenerateFileNumber($numSchm.SchmID, $null)
	$custEnt = $vault.CustomEntityService.AddCustomEntity($custEntDef.Id, $number)


	$propInstParamArray = New-Object Autodesk.Connectivity.WebServices.PropInstParamArray
	$propDefs = $vault.PropertyService.GetPropertyDefinitionsByEntityClassId("CUSTENT")

	$propDef = $propDefs | Where-Object { $_.DispName -eq "Change Description" }
	$propInstParam0 = New-Object Autodesk.Connectivity.WebServices.PropInstParam
	$propInstParam0.PropDefId = $propDef.Id
	$propInstParam0.Val = $changeRequestInfo.Description

	$propDef = $propDefs | Where-Object { $_.DispName -eq "Change Validity" }
	$propInstParam1 = New-Object Autodesk.Connectivity.WebServices.PropInstParam
	$propInstParam1.PropDefId = $propDef.Id
	$propInstParam1.Val = $valid

	$propDef = $propDefs | Where-Object { $_.DispName -eq "Change Type" }
	$propInstParam2 = New-Object Autodesk.Connectivity.WebServices.PropInstParam
	$propInstParam2.PropDefId = $propDef.Id
	$propInstParam2.Val = $numSchmName

	$propInstParamArray.Items = @($propInstParam0,$propInstParam1,$propInstParam2)
	$vault.CustomEntityService.UpdateCustomEntityProperties(@($custEnt.Id), @($propInstParamArray))
#>
