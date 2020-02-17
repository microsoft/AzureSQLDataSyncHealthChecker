#Copyright (c) Microsoft Corporation.
#Licensed under the MIT license.

#Azure SQL Data Sync Health Checker

#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Databases and credentials
# Sync metadata database credentials (Only SQL Authentication is supported)
$SyncDbServer = '.database.windows.net'
$SyncDbDatabase = ''
$SyncDbUser = ''
$SyncDbPassword = ''

# Hub credentials (Only SQL Authentication is supported)
$HubServer = '.database.windows.net'
$HubDatabase = ''
$HubUser = ''
$HubPassword = ''

# Member credentials (Azure SQL DB or SQL Server)
$MemberServer = ''
$MemberDatabase = ''
$MemberUser = ''
$MemberPassword = ''
# set MemberUseWindowsAuthentication to $true in case you wish to use integrated Windows authentication (MemberUser and MemberPassword will be ignored)
$MemberUseWindowsAuthentication = $false

## Optional parameters (default values will be used if ommited)

## Health checks
$HealthChecksEnabled = $true  #Set as $true (default) or $false

## Monitoring
$MonitoringMode = 'AUTO'  #Set as AUTO (default), ENABLED or DISABLED
$MonitoringIntervalInSeconds = 20
$MonitoringDurationInMinutes = 1

## Tracking Record Validations
$ExtendedValidationsTableFilter = @('All')  #Set as "All" or the tables you need using '[dbo].[TableName1]','[dbo].[TableName2]'
$ExtendedValidationsEnabledForHub = $false  #Set as $true or $false (default)
$ExtendedValidationsEnabledForMember = $false  #Set as $true or $false (default)
$ExtendedValidationsCommandTimeout = 900 #seconds (default)

## Other
$SendAnonymousUsageData = $true  #Set as $true (default) or $false
$DumpMetadataSchemasForSyncGroup = '' #leave empty for automatic detection
$DumpMetadataObjectsForTable = '' #needs to be formatted like [SchemaName].[TableName]

#####################################################################################################
# Parameter region when Invoke-Command -ScriptBlock is used
$parameters = $args[0]
if ($null -ne $parameters) {
    ## Databases and credentials
    # Sync metadata database credentials (Only SQL Authentication is supported)
    $SyncDbServer = $parameters['SyncDbServer']
    $SyncDbDatabase = $parameters['SyncDbDatabase']
    $SyncDbUser = $parameters['SyncDbUser']
    $SyncDbPassword = $parameters['SyncDbPassword']

    # Hub credentials (Only SQL Authentication is supported)
    $HubServer = $parameters['HubServer']
    $HubDatabase = $parameters['HubDatabase']
    $HubUser = $parameters['HubUser']
    $HubPassword = $parameters['HubPassword']

    # Member credentials (Azure SQL DB or SQL Server)
    $MemberServer = $parameters['MemberServer']
    $MemberDatabase = $parameters['MemberDatabase']
    $MemberUser = $parameters['MemberUser']
    $MemberPassword = $parameters['MemberPassword']
    # set MemberUseWindowsAuthentication to $true in case you wish to use integrated Windows authentication (MemberUser and MemberPassword will be ignored)
    $MemberUseWindowsAuthentication = $false
    if ($parameters['MemberUseWindowsAuthentication']) {
        $MemberUseWindowsAuthentication = $parameters['MemberUseWindowsAuthentication']
    }

    ## Health checks
    $HealthChecksEnabled = $true  #Set as $true or $false
    if ($null -ne $parameters['HealthChecksEnabled']) {
        $HealthChecksEnabled = $parameters['HealthChecksEnabled']
    }

    ## Monitoring
    $MonitoringMode = 'AUTO'  #Set as AUTO, ENABLED or DISABLED
    if ($null -ne $parameters['MonitoringMode']) {
        $MonitoringMode = $parameters['MonitoringMode']
    }
    $MonitoringIntervalInSeconds = 20
    if ($null -ne $parameters['MonitoringIntervalInSeconds']) {
        $MonitoringIntervalInSeconds = $parameters['MonitoringIntervalInSeconds']
    }
    $MonitoringDurationInMinutes = 2
    if ($null -ne $parameters['MonitoringDurationInMinutes']) {
        $MonitoringDurationInMinutes = $parameters['MonitoringDurationInMinutes']
    }

    ## Tracking Record Validations
    # Set as "All" to validate all tables
    # or pick the tables you need using '[dbo].[TableName1]','[dbo].[TableName2]'
    $ExtendedValidationsTableFilter = @('All')
    if ($null -ne $parameters['ExtendedValidationsTableFilter']) {
        $ExtendedValidationsTableFilter = $parameters['ExtendedValidationsTableFilter']
    }
    $ExtendedValidationsEnabledForHub = $false  #Attention, this may cause high I/O impact
    if ($null -ne $parameters['ExtendedValidationsEnabledForHub']) {
        $ExtendedValidationsEnabledForHub = $parameters['ExtendedValidationsEnabledForHub']
    }
    $ExtendedValidationsEnabledForMember = $false  #Attention, this may cause high I/O impact
    if ($null -ne $parameters['ExtendedValidationsEnabledForMember']) {
        $ExtendedValidationsEnabledForMember = $parameters['ExtendedValidationsEnabledForMember']
    }
    $ExtendedValidationsCommandTimeout = 900 #seconds
    if ($null -ne $parameters['ExtendedValidationsCommandTimeout']) {
        $ExtendedValidationsCommandTimeout = $parameters['ExtendedValidationsCommandTimeout']
    }

    ## Other
    $SendAnonymousUsageData = $true
    if ($null -ne $parameters['SendAnonymousUsageData']) {
        $SendAnonymousUsageData = $parameters['SendAnonymousUsageData']
    }
    $DumpMetadataSchemasForSyncGroup = '' #leave empty for automatic detection
    if ($null -ne $parameters['DumpMetadataSchemasForSyncGroup']) {
        $DumpMetadataSchemasForSyncGroup = $parameters['DumpMetadataSchemasForSyncGroup']
    }
    $DumpMetadataObjectsForTable = '' #needs to be formatted like [SchemaName].[TableName]
    if ($null -ne $parameters['DumpMetadataObjectsForTable']) {
        $DumpMetadataObjectsForTable = $parameters['DumpMetadataObjectsForTable']
    }
}
#####################################################################################################

function ValidateTablesVSLocalSchema([Array] $userTables) {
    Try {
        if ($userTables.Count -eq 0) {
            $msg = "WARNING: member schema with 0 tables was detected, maybe related to provisioning issues."
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)
        }
        else {
            Write-Host Schema has $userTables.Count tables
        }

        foreach ($userTable in $userTables) {
            $TablePKList = New-Object System.Collections.ArrayList

            $query = "SELECT
            c.name 'ColumnName',
            t.Name 'Datatype',
            c.max_length 'MaxLength',
            c.is_nullable 'IsNullable',
            c.is_computed 'IsComputed',
            c.default_object_id 'DefaultObjectId'
            FROM sys.columns c
            INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
            WHERE c.object_id = OBJECT_ID('" + $userTable + "')"

            $MemberCommand.CommandText = $query
            $result = $MemberCommand.ExecuteReader()
            $datatable = new-object 'System.Data.DataTable'
            $datatable.Load($result)

            foreach ($userColumn in $datatable) {
                $sbCol = New-Object -TypeName "System.Text.StringBuilder"
                $schemaObj = $global:scope_config_data.SqlSyncProviderScopeConfiguration.Adapter | Where-Object GlobalName -eq $userTable
                $schemaColumn = $schemaObj.Col | Where-Object Name -eq $userColumn.ColumnName
                if (!$schemaColumn) {
                    if (($userColumn.IsNullable -eq $false) -and ($userColumn.IsComputed -eq $false) -and ($userColumn.DefaultObjectId -eq 0) ) {
                        $msg = "WARNING: " + $userTable + ".[" + $userColumn.ColumnName + "] is not included in the sync group but is NOT NULLABLE, not a computed column or has a default value!"
                        Write-Host $msg -Foreground Red
                        [void]$errorSummary.AppendLine($msg)
                    }
                    continue
                }

                [void]$sbCol.Append($userTable + ".[" + $userColumn.ColumnName + "] " + $schemaColumn.param)

                if ($schemaColumn.pk) {
                    [void]$sbCol.Append(" PrimaryKey ")
                    [void]$TablePKList.Add($schemaColumn.name)
                }

                if ($schemaColumn.type -ne $userColumn.Datatype) {
                    [void]$sbCol.Append('  Type(' + $schemaColumn.type + '):NOK ')
                    $msg = "WARNING: " + $userTable + ".[" + $userColumn.ColumnName + "] has a different datatype! (table:" + $userColumn.Datatype + " VS scope:" + $schemaColumn.type + ")"
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }
                else {
                    [void]$sbCol.Append('  Type(' + $schemaColumn.type + '):OK ')
                }

                $colMaxLen = $userColumn.MaxLength

                if ($schemaColumn.type -eq 'nvarchar' -or $schemaColumn.type -eq 'nchar') { $colMaxLen = $colMaxLen / 2 }

                if ($userColumn.MaxLength -eq -1 -and ($schemaColumn.type -eq 'nvarchar' -or $schemaColumn.type -eq 'nchar' -or $schemaColumn.type -eq 'varbinary' -or $schemaColumn.type -eq 'varchar' -or $schemaColumn.type -eq 'nvarchar')) { $colMaxLen = 'max' }

                if ($schemaColumn.size -ne $colMaxLen) {
                    [void]$sbCol.Append('  Size(' + $schemaColumn.size + '):NOK ')
                    $msg = "WARNING: " + $userTable + ".[" + $userColumn.ColumnName + "] has a different data size!(table:" + $colMaxLen + " VS scope:" + $schemaColumn.size + ")"
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }
                else {
                    [void]$sbCol.Append('  Size(' + $schemaColumn.size + '):OK ')
                }

                if ($schemaColumn.null) {
                    if ($schemaColumn.null -ne $userColumn.IsNullable) {
                        [void]$sbCol.Append('  Nullable(' + $schemaColumn.null + '):NOK ')
                        $msg = "WARNING: " + $userTable + ".[" + $userColumn.ColumnName + "] has a different IsNullable! (table:" + $userColumn.IsNullable + " VS scope:" + $schemaColumn.null + ")"
                        Write-Host $msg -Foreground Red
                        [void]$errorSummary.AppendLine($msg)
                    }
                    else {
                        [void]$sbCol.Append('  Nullable(' + $schemaColumn.null + '):OK ')
                    }
                }

                $sbColString = $sbCol.ToString()
                if ($sbColString -match 'NOK') { Write-Host $sbColString -ForegroundColor Red } else { Write-Host $sbColString -ForegroundColor Green }

            }

            if ($ExtendedValidationsEnabled -and (($ExtendedValidationsTableFilter -contains 'All') -or ($ExtendedValidationsTableFilter -contains $userTable))) {
                ValidateTrackingRecords $userTable $TablePKList
            }
        }
    }
    Catch {
        Write-Host ValidateTablesVSLocalSchema exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ShowRowCountAndFragmentation([Array] $userTables) {
    Try {
        $previousMemberCommandTimeout = $MemberCommand.CommandTimeout
        $tablesList = New-Object System.Collections.ArrayList

        foreach ($item in $userTables) {
            $tablesList.Add($item) > $null
            $tablesList.Add('[DataSync].[' + ($item.Replace("[", "").Replace("]", "").Split('.')[1]) + '_dss_tracking]') > $null
        }

        $tablesListStr = "'$($tablesList -join "','")'"

        Write-Host "Row Counts:"
        $query = "SELECT
        '['+s.name+'].['+ t.name+']' as TableName,
        p.rows AS RowCounts,
        CAST(ROUND(((SUM(a.total_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS TotalSpaceMB,
        CAST(ROUND(((SUM(a.used_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS UsedSpaceMB,
        CAST(ROUND(((SUM(a.total_pages) - SUM(a.used_pages)) * 8) / 1024.00, 2) AS NUMERIC(36, 2)) AS UnusedSpaceMB
        FROM sys.tables t
        INNER JOIN sys.indexes i ON t.OBJECT_ID = i.object_id
        INNER JOIN sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
        INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
        LEFT OUTER JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE '['+s.name+'].['+ t.name+']' IN (" + $tablesListStr + ")
        GROUP BY t.Name, s.Name, p.Rows
        ORDER BY '['+s.name+'].['+ t.name+']'"

        $MemberCommand.CommandTimeout = 180
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        }

        Write-Host "Fragmentation:"
        $query = "SELECT '['+s.[name]+'].['+ t.[name]+']' as TableName, i.[name] as [IndexName],
        CONVERT(DECIMAL(10,2),idxstats.avg_fragmentation_in_percent) as FragmentationPercent,
        idxstats.page_count AS [PageCount]
        FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) AS idxstats
        INNER JOIN sys.tables t on t.[object_id] = idxstats.[object_id]
        INNER JOIN sys.schemas s on t.[schema_id] = s.[schema_id]
        INNER JOIN sys.indexes AS i ON i.[object_id] = idxstats.[object_id] AND idxstats.index_id = i.index_id
        WHERE '['+s.name+'].['+ t.name+']' IN (" + $tablesListStr + ")
        AND idxstats.database_id = DB_ID() AND idxstats.avg_fragmentation_in_percent >= 5
        ORDER BY idxstats.avg_fragmentation_in_percent desc"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        }
        else {
            Write-Host "- No relevant fragmentation (>5%) detected" -ForegroundColor Green
            Write-Host
        }
    }
    Catch {
        Write-Host ShowRowCountAndFragmentation exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    Finally {
        $MemberCommand.CommandTimeout = $previousMemberCommandTimeout
    }
}

function ValidateTablesVSSyncDbSchema($SyncDbScopes) {
    Try {
        foreach ($SyncDbScope in $SyncDbScopes) {
            Write-Host 'Validating Table(s) VS SyncDB for' $SyncDbScope.SyncGroupName':' -Foreground White
            $ValidateTablesVSSyncDbSchemaIssuesFound = $false
            $syncdbscopeobj = ([xml]$SyncDbScope.SchemaDescription).DssSyncScopeDescription.TableDescriptionCollection.DssTableDescription
            $syncGroupSchemaTables = $syncdbscopeobj | Select-Object -ExpandProperty QuotedTableName

            foreach ($syncGroupSchemaTable in $syncGroupSchemaTables) {
                $syncGroupSchemaColumns = $syncdbscopeobj | Where-Object { $_.QuotedTableName -eq $syncGroupSchemaTable } | Select-Object -ExpandProperty ColumnsToSync

                $query = "SELECT
                c.name 'ColumnName',
                t.Name 'Datatype',
                c.max_length 'MaxLength',
                c.is_nullable 'IsNullable'
                FROM sys.columns c
                INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
                WHERE c.object_id = OBJECT_ID('" + $syncGroupSchemaTable + "')"

                $MemberCommand.CommandText = $query
                $result = $MemberCommand.ExecuteReader()
                $datatable = new-object 'System.Data.DataTable'
                $datatable.Load($result)

                if ($datatable.Rows.Count -eq 0) {
                    $ValidateTablesVSSyncDbSchemaIssuesFound = $true
                    $msg = "WARNING: " + $syncGroupSchemaTable + " does not exist in the database but exist in the sync group schema."
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }
                else {
                    foreach ($syncGroupSchemaColumn in $syncGroupSchemaColumns.DssColumnDescription) {
                        $scopeCol = $datatable | Where-Object ColumnName -eq $syncGroupSchemaColumn.Name
                        if (!$scopeCol) {
                            $ValidateTablesVSSyncDbSchemaIssuesFound = $true
                            $msg = "WARNING: " + $syncGroupSchemaTable + ".[" + $syncGroupSchemaColumn.Name + "] is missing in this database but exist in sync group schema, maybe preventing provisioning/re-provisioning!"
                            Write-Host $msg -Foreground Red
                            [void]$errorSummary.AppendLine($msg)
                        }
                        else {
                            if ($syncGroupSchemaColumn.DataType -ne $scopeCol.Datatype) {
                                $ValidateTablesVSSyncDbSchemaIssuesFound = $true
                                $msg = "WARNING: " + $syncGroupSchemaTable + ".[" + $syncGroupSchemaColumn.Name + "] has a different datatype! (" + $syncGroupSchemaColumn.DataType + " VS " + $scopeCol.Datatype + ")"
                                Write-Host $msg -Foreground Red
                                [void]$errorSummary.AppendLine($msg)
                            }
                            else {
                                $colMaxLen = $scopeCol.MaxLength
                                if ($syncGroupSchemaColumn.DataType -eq 'nvarchar' -or $syncGroupSchemaColumn.DataType -eq 'nchar') { $colMaxLen = $colMaxLen / 2 }
                                if ($scopeCol.MaxLength -eq -1 -and ($syncGroupSchemaColumn.DataType -eq 'nvarchar' -or $syncGroupSchemaColumn.DataType -eq 'nchar' -or $syncGroupSchemaColumn.DataType -eq 'varbinary' -or $syncGroupSchemaColumn.DataType -eq 'varchar' -or $syncGroupSchemaColumn.DataType -eq 'nvarchar')) { $colMaxLen = 'max' }

                                if ($syncGroupSchemaColumn.DataSize -ne $colMaxLen) {
                                    $ValidateTablesVSSyncDbSchemaIssuesFound = $true
                                    $msg = "WARNING: " + $syncGroupSchemaTable + ".[" + $syncGroupSchemaColumn.Name + "] has a different data size! (" + $syncGroupSchemaColumn.DataSize + " VS " + $scopeCol.MaxLength + ")"
                                    Write-Host $msg -Foreground Red
                                    [void]$errorSummary.AppendLine($msg)
                                }
                            }
                        }
                    }
                }
            }
            if (!$ValidateTablesVSSyncDbSchemaIssuesFound) {
                Write-Host '- No issues detected for' $SyncDbScope.SyncGroupName -Foreground Green
            }
        }
    }
    Catch {
        Write-Host ValidateTablesVSSyncDbSchema exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateTrackingRecords([String] $table, [Array] $tablePKList) {
    Try {
        Write-Host "Running ValidateTrackingRecords for" $table "..." -Foreground Green
        $tableNameWithoutSchema = ($table.Replace("[", "").Replace("]", "").Split('.'))[1]

        $sbQuery = New-Object -TypeName "System.Text.StringBuilder"
        $sbDeleteQuery = New-Object -TypeName "System.Text.StringBuilder"

        [void]$sbQuery.Append("SELECT COUNT(*) AS C FROM DataSync.[")
        [void]$sbQuery.Append($tableNameWithoutSchema)
        [void]$sbQuery.Append("_dss_tracking] t WITH (NOLOCK) WHERE sync_row_is_tombstone=0 AND NOT EXISTS (SELECT * FROM ")
        [void]$sbQuery.Append($table)
        [void]$sbQuery.Append(" s WITH (NOLOCK) WHERE ")

        [void]$sbDeleteQuery.Append("DELETE DataSync.[")
        [void]$sbDeleteQuery.Append($tableNameWithoutSchema)
        [void]$sbDeleteQuery.Append("_dss_tracking] FROM DataSync.[")
        [void]$sbDeleteQuery.Append($tableNameWithoutSchema)
        [void]$sbDeleteQuery.Append("_dss_tracking] t WHERE sync_row_is_tombstone=0 AND NOT EXISTS (SELECT * FROM ")
        [void]$sbDeleteQuery.Append($table)
        [void]$sbDeleteQuery.Append(" s WHERE ")

        for ($i = 0; $i -lt $tablePKList.Length; $i++) {
            if ($i -gt 0) {
                [void]$sbQuery.Append(" AND ")
                [void]$sbDeleteQuery.Append(" AND ")
            }
            [void]$sbQuery.Append("t." + $tablePKList[$i] + " = s." + $tablePKList[$i] )
            [void]$sbDeleteQuery.Append("t." + $tablePKList[$i] + " = s." + $tablePKList[$i] )
        }
        [void]$sbQuery.Append(")")
        [void]$sbDeleteQuery.Append(")")

        $previousMemberCommandTimeout = $MemberCommand.CommandTimeout
        $MemberCommand.CommandTimeout = $ExtendedValidationsCommandTimeout
        $MemberCommand.CommandText = $sbQuery.ToString()
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        $count = $datatable | Select-Object C -ExpandProperty C
        $MemberCommand.CommandTimeout = $previousMemberCommandTimeout

        if ($count -ne 0) {
            $msg = "WARNING: Tracking Records for Table " + $table + " may have " + $count + " invalid records!"
            Write-Host $msg -Foreground Red
            Write-Host $sbDeleteQuery.ToString() -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)
            [void]$errorSummary.AppendLine($sbDeleteQuery.ToString())
        }
        else {
            $msg = "No issues detected in Tracking Records for Table " + $table
            Write-Host $msg -Foreground Green
        }

    }
    Catch {
        Write-Host "Error at ValidateTrackingRecords" $table -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateTrackingTable($table) {
    Try {
        if (![string]::IsNullOrEmpty($table)) {
            [void]$allTrackingTableList.Add($table)
        }

        $query = "SELECT COUNT(*) AS C FROM INFORMATION_SCHEMA.TABLES WHERE '['+TABLE_SCHEMA+'].['+ TABLE_NAME + ']' = '" + $table + "'"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        $count = $datatable | Select-Object C -ExpandProperty C

        if ($count -eq 1) {
            Write-Host "Tracking Table " $table "exists" -Foreground Green
        }

        if ($count -eq 0) {
            $msg = "WARNING: Tracking Table " + $table + " IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine($msg)
        }
    }
    Catch {
        Write-Host "Error at ValidateTrackingTable" $table -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateTrigger([String] $trigger) {
    Try {
        if (![string]::IsNullOrEmpty($trigger)) {
            [void]$allTriggersList.Add($trigger)
        }

        $query = "SELECT tr.name, tr.is_disabled AS 'Disabled'
        FROM sys.triggers tr
        INNER JOIN sys.tables t ON tr.parent_id = t.object_id
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE '['+s.name+'].['+ tr.name+']' = '" + $trigger + "'"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $table = new-object 'System.Data.DataTable'
        $table.Load($result)
        $count = $table.Rows.Count

        if ($count -eq 1) {
            if ($table.Rows[0].Disabled -eq 1) {
                $msg = "WARNING (DSS035): Trigger " + $trigger + " exists but is DISABLED!"
                Write-Host $msg -Foreground Red
                [void]$errorSummary.AppendLine($msg)
            }
            else {
                Write-Host "Trigger" $trigger "exists and is enabled." -Foreground Green
            }
        }

        if ($count -eq 0) {
            $msg = "WARNING (DSS035): Trigger " + $trigger + " IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine($msg)
        }
    }
    Catch {
        Write-Host "Error at ValidateTrigger" $trigger -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateSP([String] $SP) {
    Try {
        if (![string]::IsNullOrEmpty($SP)) {
            [void]$allSPsList.Add($SP)
        }

        $query = "SELECT COUNT(*) AS C FROM sys.procedures p INNER JOIN sys.schemas s ON p.schema_id = s.schema_id WHERE '['+s.name+'].['+ p.name+']' = N'" + $SP + "'"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $table = new-object 'System.Data.DataTable'
        $table.Load($result)
        $count = $table | Select-Object C -ExpandProperty C

        if ($count -eq 1) {
            Write-Host "Procedure" $SP "exists" -Foreground Green

            $query = "sp_helptext '" + $SP + "'"
            $MemberCommand.CommandText = $query
            $result = $MemberCommand.ExecuteReader()
            $sphelptextDataTable = new-object 'System.Data.DataTable'
            $sphelptextDataTable.Load($result)

            #DumpObject
            $tableNameWithoutSchema = ($DumpMetadataObjectsForTable.Replace("[", "").Replace("]", "").Split('.'))[1] + '_dss'
            if ($DumpMetadataObjectsForTable -and ($SP.IndexOf($tableNameWithoutSchema) -ne -1)) {
                $xmlResult = $sphelptextDataTable.Text
                if ($xmlResult -and $canWriteFiles) {
                    $xmlResult | Out-File -filepath ('.\' + (SanitizeString $Server) + '_' + (SanitizeString $Database) + '_' + (SanitizeString $SP) + '.txt')
                }
            }

            #provision marker validations
            $objectId = ([string[]] $sphelptextDataTable.Text) | Where-Object { $_ -match 'object_id' } | Select-Object -First 1

            if ($objectId) {
                $objectId = $objectId.Replace('WHERE [object_id] =', '').Trim()

                $query = "select COUNT(object_id) as C from sys.tables where object_id = " + $objectId
                $MemberCommand.CommandText = $query
                $result = $MemberCommand.ExecuteReader()
                $datatable = new-object 'System.Data.DataTable'
                $datatable.Load($result)
                if ($datatable.Rows[0].C -eq 0) {
                    $msg = "WARNING: Table with object_id " + $objectId + " was not found, " + $SP.Replace('[', '').Replace(']', '') + " was provisoned using this object_id!"
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }
                else {
                    $msg = " - Found table with object_id " + $objectId
                    Write-Host $msg -Foreground Green
                }

                $query = "SELECT [owner_scope_local_id] FROM [DataSync].[provision_marker_dss] WHERE object_id = " + $objectId
                $MemberCommand.CommandText = $query
                $result = $MemberCommand.ExecuteReader()
                $datatable = new-object 'System.Data.DataTable'
                $datatable.Load($result)

                if ($datatable.Rows | Where-Object { $_.owner_scope_local_id -eq 0 }) {
                    $msg = " - Found owner_scope_local_id 0 for object_id " + $objectId
                    Write-Host $msg -Foreground Green
                }
                else {
                    $msg = "WARNING: owner_scope_local_id 0 was not found for object_id " + $objectId
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }

                $owner_scope_local_id = ([string[]] $sphelptextDataTable.Text) | Where-Object { $_ -match 'owner_scope_local_id' -and $_ -notmatch '0' }
                if ($owner_scope_local_id) {
                    $owner_scope_local_id = $owner_scope_local_id.Replace('AND [owner_scope_local_id] =', '').Trim()

                    if ($datatable.Rows | Where-Object { $_.owner_scope_local_id -eq $owner_scope_local_id }) {
                        $msg = " - Found owner_scope_local_id " + $owner_scope_local_id + " for object_id " + $objectId
                        Write-Host $msg -Foreground Green
                    }
                    else {
                        $msg = "WARNING: owner_scope_local_id " + $owner_scope_local_id + " was not found for object_id " + $objectId
                        Write-Host $msg -Foreground Red
                        [void]$errorSummary.AppendLine($msg)
                    }
                }
            }
        }
        if ($count -eq 0) {
            $msg = "WARNING: Procedure " + $SP + " IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine($msg)
        }
    }
    Catch {
        Write-Host "Error at ValidateSP" $SP -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateBulkType([String] $bulkType, $columns) {
    Try {
        if (![string]::IsNullOrEmpty($bulkType)) {
            [void]$allBulkTypeList.Add($bulkType)
        }

        $query = "select tt.name 'Type',
        c.name 'ColumnName',
        t.Name 'Datatype',
        c.max_length 'MaxLength',
        c.is_nullable 'IsNullable',
        c.column_id 'ColumnId'
        from sys.table_types tt
        inner join sys.columns c on c.object_id = tt.type_table_object_id
        inner join sys.types t ON c.user_type_id = t.user_type_id
        where '['+ SCHEMA_NAME(tt.schema_id) +'].['+ tt.name+']' ='" + $bulkType + "'"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $table = new-object 'System.Data.DataTable'
        $table.Load($result)
        $count = $table.Rows.Count

        if ($count -gt 0) {
            Write-Host "Type" $bulkType "exists" -Foreground Green
            foreach ($column in $columns) {
                $sbCol = New-Object -TypeName "System.Text.StringBuilder"
                $typeColumn = $table.Rows | Where-Object ColumnName -eq $column.name

                if (!$typeColumn) {
                    $msg = "WARNING: " + $bulkType + ".[" + $column.name + "] does not exit!"
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                    continue
                }

                [void]$sbCol.Append("- [" + $column.name + "] " + $column.param)

                if ($column.type -ne $typeColumn.Datatype) {
                    if ($column.type -eq 'geography' -or $column.type -eq 'geometry') {
                        [void]$sbCol.Append('  Type(' + $column.type + '):Expected diff ')
                    }
                    else {
                        [void]$sbCol.Append('  Type(' + $column.type + '):NOK ')
                        $msg = "WARNING: " + $bulkType + ".[" + $column.name + "] has a different datatype! (type:" + $typeColumn.Datatype + " VS scope:" + $column.type + ")"
                        Write-Host $msg -Foreground Red
                        [void]$errorSummary.AppendLine($msg)
                    }
                }
                else {
                    [void]$sbCol.Append('  Type(' + $column.type + '):OK ')
                }

                $colMaxLen = $typeColumn.MaxLength

                if ($column.type -eq 'nvarchar' -or $column.type -eq 'nchar') { $colMaxLen = $colMaxLen / 2 }

                if ($typeColumn.MaxLength -eq -1 -and ($column.type -eq 'nvarchar' -or $column.type -eq 'nchar' -or $column.type -eq 'varbinary' -or $column.type -eq 'varchar' -or $column.type -eq 'nvarchar')) { $colMaxLen = 'max' }

                if ($column.size -ne $colMaxLen) {
                    [void]$sbCol.Append('  Size(' + $column.size + '):NOK ')
                    $msg = "WARNING: " + $bulkType + ".[" + $column.name + "] has a different data size!(type:" + $colMaxLen + " VS scope:" + $column.size + ")"
                    Write-Host $msg -Foreground Red
                    [void]$errorSummary.AppendLine($msg)
                }
                else {
                    [void]$sbCol.Append('  Size(' + $column.size + '):OK ')
                }

                if ($column.null) {
                    if ($column.null -ne $typeColumn.IsNullable) {
                        [void]$sbCol.Append('  Nullable(' + $column.null + '):NOK ')
                        $msg = "WARNING: " + $bulkType + ".[" + $column.name + "] has a different IsNullable! (type:" + $typeColumn.IsNullable + " VS scope:" + $column.null + ")"
                        Write-Host $msg -Foreground Red
                        [void]$errorSummary.AppendLine($msg)
                    }
                    else {
                        [void]$sbCol.Append('  Nullable(' + $column.null + '):OK ')
                    }
                }

                $sbColString = $sbCol.ToString()

                if ($sbColString -match 'NOK') {
                    Write-Host $sbColString -ForegroundColor Red
                }
                else {
                    Write-Host $sbColString -ForegroundColor Green
                }
            }
        }
        if ($count -eq 0) {
            $msg = "WARNING: Type " + $bulkType + " IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine($msg)
        }

        #DumpObject
        $tableNameWithoutSchema = ($DumpMetadataObjectsForTable.Replace("[", "").Replace("]", "").Split('.'))[1] + '_dss_BulkType_'
        if ($DumpMetadataObjectsForTable -and $bulkType -match $tableNameWithoutSchema -and $canWriteFiles) {
            $table | Out-File -filepath ('.\' + (SanitizeString $Server) + '_' + (SanitizeString $Database) + '_' + (SanitizeString $bulkType) + '.txt')
        }
    }
    Catch {
        Write-Host "Error at ValidateBulkType" $bulkType -Foreground Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectTrackingTableLeftovers() {
    Try {
        $allTrackingTableString = "'$($allTrackingTableList -join "','")'"
        $query = "SELECT '['+TABLE_SCHEMA+'].['+ TABLE_NAME + ']' as FullTableName, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME LIKE '%_dss_tracking' AND '['+TABLE_SCHEMA+'].['+ TABLE_NAME + ']' NOT IN (" + $allTrackingTableString + ")"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.FullTableName).Count -eq 0) {
            Write-Host "There are no Tracking Table leftovers" -Foreground Green
        }
        else {
            foreach ($leftover in $datatable) {
                Write-Host "WARNING: Tracking Table" $leftover.FullTableName "should be a leftover." -Foreground Yellow
                $deleteStatement = "Drop Table " + $leftover.FullTableName + ";"
                [void]$runnableScript.AppendLine($deleteStatement)
                [void]$runnableScript.AppendLine("GO")

                $leftover.TABLE_NAME = ($leftover.TABLE_NAME -replace "_dss_tracking", "")
                $query = "SELECT [object_id] FROM [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = 0 and object_name([object_id]) = '" + $leftover.TABLE_NAME + "'"
                $MemberCommand.CommandText = $query
                $provision_marker_result2 = $MemberCommand.ExecuteReader()
                $provision_marker_leftovers2 = new-object 'System.Data.DataTable'
                $provision_marker_leftovers2.Load($provision_marker_result2)

                foreach ($provision_marker_leftover2 in $provision_marker_leftovers2) {
                    $deleteStatement = "DELETE FROM [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = 0 and [object_id] = " + $provision_marker_leftover2.object_id + " --" + $leftover.TABLE_NAME
                    Write-Host "WARNING: [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = 0 and [object_id] = " $provision_marker_leftover2.object_id "("  $leftover.TABLE_NAME ") should be a leftover." -Foreground Yellow
                    [void]$runnableScript.AppendLine($deleteStatement)
                    [void]$runnableScript.AppendLine("GO")
                }
            }
        }
    }
    Catch {
        Write-Host DetectTrackingTableLeftovers exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectTriggerLeftovers() {
    Try {
        $allTriggersString = "'$($allTriggersList -join "','")'"
        $query = "SELECT '['+s.name+'].['+ trig.name+']'
        FROM sys.triggers trig
        INNER JOIN sys.tables t ON trig.parent_id = t.object_id
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE trig.name like '&_dss_&' AND '['+s.name+'].['+ trig.name+']' NOT IN (" + $allTriggersString + ")"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.Column1).Count -eq 0) {
            Write-Host "There are no Trigger leftovers" -Foreground Green
        }
        else {
            foreach ($leftover in $datatable.Column1) {
                Write-Host "WARNING: Trigger" $leftover "should be a leftover." -Foreground Yellow
                $deleteStatement = "Drop Trigger " + $leftover + ";"
                [void]$runnableScript.AppendLine($deleteStatement)
                [void]$runnableScript.AppendLine("GO")
            }
        }
    }
    Catch {
        Write-Host DetectTriggerLeftovers exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectProcedureLeftovers() {
    Try {
        $allSPsString = "'$($allSPsList -join "','")'"
        $query = "SELECT '['+s.name+'].['+ p.name+']'
        FROM sys.procedures p
        INNER JOIN sys.schemas s ON p.schema_id = s.schema_id
        WHERE p.name like '%_dss_%' AND '['+s.name+'].['+ p.name+']' NOT IN (" + $allSPsString + ")"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.Column1).Count -eq 0) {
            Write-Host "There are no Procedure leftovers" -Foreground Green
        }
        else {
            foreach ($leftover in $datatable.Column1) {
                Write-Host "WARNING: Procedure" $leftover "should be a leftover." -Foreground Yellow
                $deleteStatement = "Drop Procedure " + $leftover + ";"
                [void]$runnableScript.AppendLine($deleteStatement)
                [void]$runnableScript.AppendLine("GO")
            }
        }
    }
    Catch {
        Write-Host DetectProcedureLeftovers exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectBulkTypeLeftovers() {
    Try {
        $allBulkTypeString = "'$($allBulkTypeList -join "','")'"
        $query = "select distinct '['+ SCHEMA_NAME(tt.schema_id) +'].['+ tt.name+']' 'Type'
        from sys.table_types tt
        inner join sys.columns c on c.object_id = tt.type_table_object_id
        inner join sys.types t ON c.user_type_id = t.user_type_id
        where SCHEMA_NAME(tt.schema_id) = 'DataSync' and '['+ SCHEMA_NAME(tt.schema_id) +'].['+ tt.name+']' NOT IN (" + $allBulkTypeString + ")"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.Type).Count -eq 0) {
            Write-Host "There are no Bulk Type leftovers" -Foreground Green
        }
        else {
            foreach ($leftover in $datatable.Type) {
                Write-Host "WARNING: Bulk Type" $leftover "should be a leftover." -Foreground Yellow
                $deleteStatement = "Drop Type " + $leftover + ";"
                [void]$runnableScript.AppendLine($deleteStatement)
                [void]$runnableScript.AppendLine("GO")
            }
        }
    }
    Catch {
        Write-Host DetectBulkTypeLeftovers exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateFKDependencies([Array] $userTables) {
    Try {
        $allTablesFKString = "'$($userTables -join "','")'"

        $query = "SELECT
        OBJECT_NAME(fk.parent_object_id) TableName
        ,OBJECT_NAME(fk.constraint_object_id) FKName
        ,OBJECT_NAME(fk.referenced_object_id) ParentTableName
        ,t.name TrackingTableName
        FROM sys.foreign_key_columns fk
        INNER JOIN sys.tables t2 ON t2.name = OBJECT_NAME(fk.parent_object_id)
        INNER JOIN sys.schemas s ON s.schema_id = t2.schema_id
        LEFT OUTER JOIN sys.tables t ON t.name like OBJECT_NAME(fk.referenced_object_id)+'_dss_tracking'
        WHERE t.name IS NULL AND '['+s.name +'].['+OBJECT_NAME(fk.parent_object_id)+']' IN (" + $allTablesFKString + ")"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            $msg = "WARNING: Missing tables in the sync group due to FK references:"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            foreach ($fkrow in $datatable) {
                $msg = "- The " + $fkrow.FKName + " in " + $fkrow.TableName + " needs " + $fkrow.ParentTableName
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
        }
        else {
            Write-Host "No FKs referencing tables not used in sync group detected" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateFKDependencies exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateProvisionMarker {
    Try {
        $query = "SELECT COUNT(*) AS C FROM sys.tables WHERE schema_name(schema_id) = 'DataSync' and [name] = 'provision_marker_dss'"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        $provisionMarkerDSSExists = ($datatable.Rows[0].C -eq 1);

        if (!$provisionMarkerDSSExists) {
            $query = "WITH TrackingTablesObjId_CTE (object_id) AS (
            SELECT OBJECT_ID(REPLACE([name], '_dss_tracking', ''))
            FROM sys.tables WHERE schema_name(schema_id) = 'DataSync' and [name] like ('%_dss_tracking'))
            SELECT '['+OBJECT_SCHEMA_NAME(cte.object_id)+'].['+ OBJECT_NAME(cte.object_id) +']' AS TableName, cte.object_id
            FROM TrackingTablesObjId_CTE AS cte WHERE cte.object_id IS NOT NULL"
        }
        else {
            $query = "WITH TrackingTablesObjId_CTE (object_id) AS (
            SELECT OBJECT_ID(REPLACE([name], '_dss_tracking', ''))
            FROM sys.tables WHERE schema_name(schema_id) = 'DataSync' and [name] like ('%_dss_tracking'))
            SELECT '['+OBJECT_SCHEMA_NAME(cte.object_id)+'].['+ OBJECT_NAME(cte.object_id) +']' AS TableName, cte.object_id
            FROM TrackingTablesObjId_CTE AS cte
            LEFT OUTER JOIN [DataSync].[provision_marker_dss] marker on marker.owner_scope_local_id = 0 and marker.object_id = cte.object_id
            WHERE marker.object_id IS NULL AND cte.object_id IS NOT NULL"
        }

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {

            $msg = "WARNING (DSS034): ValidateProvisionMarker found some possible issues"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            $msg = "This can cause the error: Cannot insert the value NULL into column 'provision_timestamp', table '(...).DataSync.provision_marker_dss';"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine($msg)

            foreach ($row in $datatable) {
                if (!$provisionMarkerDSSExists) {
                    $msg = "- Tracking table for " + $row.TableName + " exists but provision_marker_dss table does not exist"
                }
                else {
                    $msg = "- Tracking table for " + $row.TableName + " exists but there is no provision_marker record with object_id " + $row.object_id
                }
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
        }
        else {
            Write-Host "ValidateProvisionMarker did not detect any issue" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateProvisionMarker exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateCircularReferences {
    Try {
        $query = "SELECT OBJECT_SCHEMA_NAME(fk1.parent_object_id) + '.' + OBJECT_NAME(fk1.parent_object_id) Table1, OBJECT_SCHEMA_NAME(fk2.parent_object_id) + '.' + OBJECT_NAME(fk2.parent_object_id) Table2,fk1.name FK1Name, fk2.name FK2Name
        FROM sys.foreign_keys AS fk1
        INNER JOIN sys.foreign_keys AS fk2 ON fk1.parent_object_id = fk2.referenced_object_id AND fk2.parent_object_id = fk1.referenced_object_id
        WHERE fk1.parent_object_id <> fk2.parent_object_id;"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            $msg = "WARNING: ValidateCircularReferences found some circular references in this database:"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            foreach ($row in $datatable) {
                $msg = "- " + $row.Table1 + " | " + $row.Table2 + " | " + $row.FK1Name + " | " + $row.FK2Name
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
            [void]$errorSummary.AppendLine()
        }
        else {
            Write-Host "ValidateCircularReferences did not detect any issue" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateCircularReferences exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateTableNames {
    Try {
        $query = "SELECT DISTINCT t1.name AS TableName FROM sys.tables t1 LEFT JOIN sys.tables t2 ON t1.name = t2.name AND t1.object_id <> t2.object_id WHERE (t2.schema_id) IS NOT NULL AND SCHEMA_NAME(t1.schema_id) NOT IN ('dss','TaskHosting')"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            $msg = "INFO: ValidateTableNames found some tables names in multiple schemas in this database:"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            foreach ($row in $datatable) {
                $msg = "- " + $row.TableName + " seems to exist in multiple schemas!"
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
        }
        else {
            Write-Host "ValidateTableNames did not detect any issue" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateTableNames exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateObjectNames {
    Try {
        $query = "SELECT table_schema, table_name, column_name
        FROM information_schema.columns
        WHERE table_name LIKE '%.%' OR table_name LIKE '%[[]%' OR table_name LIKE '%]%'
        OR column_name LIKE '%.%' OR column_name LIKE '%[[]%' OR column_name LIKE '%]%'"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            $msg = "WARNING: ValidateObjectNames found some issues:"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            foreach ($row in $datatable) {
                $msg = "- [" + $row.table_schema + "].[" + $row.table_name + "].[" + $row.column_name + "]"
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
        }
        else {
            Write-Host "ValidateObjectNames did not detect any issue" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateObjectNames exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectProvisioningIssues {
    Try {
        $query = "with TrackingTables as (
        select REPLACE(name,'_dss_tracking','') as TrackingTableOrigin, name TrackingTable
        from sys.tables
        where SCHEMA_NAME(schema_id) = 'DataSync' AND [name] not in ('schema_info_dss','scope_info_dss','scope_config_dss','provision_marker_dss')
        )
        select TrackingTable from TrackingTables c
        left outer join sys.tables t on c.TrackingTableOrigin = t.[name]
        where t.[name] is null"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        foreach ($extraTrackingTable in $datatable) {
            $msg = "WARNING: " + $extraTrackingTable.TrackingTable + " exists but the corresponding user table does not exist! this maybe preventing provisioning/re-provisioning!"
            Write-Host $msg -Foreground Red
            [void]$errorSummary.AppendLine($msg)
        }
    }
    Catch {
        Write-Host DetectProvisioningIssues exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function DetectComputedColumns {
    Try {
        $query = "SELECT SCHEMA_NAME(T.schema_id) AS SchemaName, T.name AS TableName, C.name AS ColumnName FROM sys.objects AS T JOIN sys.columns AS C ON T.object_id = C.object_id WHERE  T.type = 'U' AND C.is_computed = 1;"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            $msg = "INFO: Computed columns detected (only an issue if part of sync schema):"
            Write-Host $msg -Foreground Yellow
            [void]$errorSummary.AppendLine()
            [void]$errorSummary.AppendLine($msg)

            foreach ($row in $datatable) {
                $msg = "- [" + $row.SchemaName + "].[" + $row.TableName + "].[" + $row.ColumnName + "]"
                Write-Host $msg -Foreground Yellow
                [void]$errorSummary.AppendLine($msg)
            }
        }
        else {
            Write-Host "DetectComputedColumns did not detect any computed column" -ForegroundColor Green
        }
    }
    Catch {
        Write-Host ValidateObjectNames exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function GetUIHistory {
    Try {
        $query = "WITH UIHistory_CTE ([completionTime], SyncGroupName,DatabaseName,OperationResult,Seconds,Upload,UploadFailed,Download,DownloadFailed, Error)
        AS
        (
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Seconds
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[2]', 'nvarchar(max)') as Upload
        ,'' as UploadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[3]', 'nvarchar(max)') as Download
        ,'' as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] = 'SyncSuccess' AND ud.[server] = '" + $Server + "' AND ud.[database] = '" + $Database + "'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Seconds
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[2]', 'nvarchar(max)') as Upload
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[3]', 'nvarchar(max)') as UploadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[4]', 'nvarchar(max)') as Download
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[5]', 'nvarchar(max)') as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] = 'SyncSuccessWithWarning' AND ud.[server] = '" + $Server + "' AND ud.[database] = '" + $Database + "'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,'' as Seconds
        ,'' as Upload
        ,'' as UploadFailed
        ,'' as Download
        ,'' as DownloadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] like '%Failure' AND ud.[server] = '" + $Server + "' AND ud.[database] = '" + $Database + "'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,'' as Seconds
        ,'' as Upload
        ,'' as UploadFailed
        ,'' as Download
        ,'' as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] != 'SyncSuccess' AND ui.[detailEnumId] != 'SyncSuccessWithWarning' AND ui.[detailEnumId] NOT LIKE '%Failure'
        AND ud.[server] = '" + $Server + "' AND ud.[database] = '" + $Database + "')
        SELECT TOP(30) [completionTime],SyncGroupName,OperationResult,Seconds,Upload,UploadFailed AS UpFailed,Download,DownloadFailed AS DFailed,Error
        FROM UIHistory_CTE ORDER BY [completionTime] DESC"

        $SyncDbCommand.CommandTimeout = 120
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            Write-Host "UI History:" -Foreground White
            $datatable | Format-Table -AutoSize -Wrap | Out-String -Width 4096
            $top = $datatable | Group-Object -Property SyncGroupName | ForEach-Object { $_ | Select-Object -ExpandProperty Group | Select-Object -First 1 }
            $shouldDump = $top | Where-Object { $_.OperationResult -like '*Failure*' }
            if ($null -ne $shouldDump -and $DumpMetadataSchemasForSyncGroup -eq '') {
                foreach ($error in $shouldDump) {
                    DumpMetadataSchemasForSyncGroup $error.SyncGroupName
                }
            }
        }
    }
    Catch {
        Write-Host GetUIHistory exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function GetUIHistoryForSyncDBValidator {
    Try {
        $query = "WITH UIHistory_CTE ([completionTime], SyncGroupName,DatabaseName,OperationResult,Seconds,Upload,UploadFailed,Download,DownloadFailed, Error)
        AS
        (
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Seconds
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[2]', 'nvarchar(max)') as Upload
        ,'' as UploadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[3]', 'nvarchar(max)') as Download
        ,'' as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] = 'SyncSuccess'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Seconds
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[2]', 'nvarchar(max)') as Upload
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[3]', 'nvarchar(max)') as UploadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[4]', 'nvarchar(max)') as Download
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[5]', 'nvarchar(max)') as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] = 'SyncSuccessWithWarning'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,'' as Seconds
        ,'' as Upload
        ,'' as UploadFailed
        ,'' as Download
        ,'' as DownloadFailed
        ,CAST (ui.detailStringParameters as XML).value('(/ArrayOfString//string/node())[1]', 'nvarchar(max)') as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] like '%Failure'
        UNION ALL
        SELECT ui.[completionTime], sg.[name] SyncGroupName, ud.[database] DatabaseName, ui.[detailEnumId] OperationResult
        ,'' as Seconds
        ,'' as Upload
        ,'' as UploadFailed
        ,'' as Download
        ,'' as DownloadFailed
        ,'' as Error
        FROM [dss].[UIHistory] AS ui WITH (NOLOCK)
        INNER JOIN [dss].[syncgroup] AS sg WITH (NOLOCK) on ui.syncgroupId = sg.id
        INNER JOIN [dss].[userdatabase] AS ud WITH (NOLOCK) on ui.databaseid = ud.id
        WHERE ui.[detailEnumId] != 'SyncSuccess' AND ui.[detailEnumId] != 'SyncSuccessWithWarning' AND ui.[detailEnumId] NOT LIKE '%Failure')
        SELECT TOP(50) [completionTime],SyncGroupName,OperationResult,Seconds,Upload,UploadFailed AS UpFailed,Download,DownloadFailed AS DFailed,Error
        FROM UIHistory_CTE ORDER BY [completionTime] DESC"

        $SyncDbCommand.CommandTimeout = 120
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if ($datatable.Rows.Count -gt 0) {
            Write-Host "UI History:" -Foreground White
            $datatable | Format-Table -AutoSize -Wrap | Out-String -Width 4096
        }
    }
    Catch {
        Write-Host GetUIHistoryForSyncDBValidator exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function SendAnonymousUsageData {
    Try {
        #Despite computername and username will be used to calculate a hash string, this will keep you anonymous but allow us to identify multiple runs from the same user
        $StringBuilderHash = New-Object System.Text.StringBuilder
        [System.Security.Cryptography.HashAlgorithm]::Create("MD5").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($env:computername + $env:username)) | ForEach-Object {
            [Void]$StringBuilderHash.Append($_.ToString("x2"))
        }

        $body = New-Object PSObject `
        | Add-Member -PassThru NoteProperty name 'Microsoft.ApplicationInsights.Event' `
        | Add-Member -PassThru NoteProperty time $([System.dateTime]::UtcNow.ToString('o')) `
        | Add-Member -PassThru NoteProperty iKey "c8aa884b-5a60-4bec-b49e-702d69657409" `
        | Add-Member -PassThru NoteProperty tags (New-Object PSObject | Add-Member -PassThru NoteProperty 'ai.user.id' $StringBuilderHash.ToString()) `
        | Add-Member -PassThru NoteProperty data (New-Object PSObject `
            | Add-Member -PassThru NoteProperty baseType 'EventData' `
            | Add-Member -PassThru NoteProperty baseData (New-Object PSObject `
                | Add-Member -PassThru NoteProperty ver 2 `
                | Add-Member -PassThru NoteProperty name '6.16' `
                | Add-Member -PassThru NoteProperty properties (New-Object PSObject `
                    | Add-Member -PassThru NoteProperty 'Source:' "Microsoft/AzureSQLDataSyncHealthChecker"`
                    | Add-Member -PassThru NoteProperty 'HealthChecksEnabled' $HealthChecksEnabled.ToString()`
                    | Add-Member -PassThru NoteProperty 'MonitoringMode' $MonitoringMode.ToString()`
                    | Add-Member -PassThru NoteProperty 'MonitoringIntervalInSeconds' $MonitoringIntervalInSeconds.ToString()`
                    | Add-Member -PassThru NoteProperty 'MonitoringDurationInMinutes' $MonitoringDurationInMinutes.ToString()`
                    | Add-Member -PassThru NoteProperty 'ExtendedValidationsCommandTimeout' $ExtendedValidationsCommandTimeout.ToString()`
                    | Add-Member -PassThru NoteProperty 'ExtendedValidationsEnabledForHub' $ExtendedValidationsEnabledForHub.ToString() `
                    | Add-Member -PassThru NoteProperty 'ExtendedValidationsEnabledForMember' $ExtendedValidationsEnabledForMember.ToString() )));
        $body = $body | ConvertTo-JSON -depth 5;
        Invoke-WebRequest -Uri 'https://dc.services.visualstudio.com/v2/track' -Method 'POST' -UseBasicParsing -body $body > $null
    }
    Catch {
        Write-Host SendAnonymousUsageData exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function ValidateSyncDB {
    Try {
        $SyncDbConnection = New-Object System.Data.SqlClient.SQLConnection
        $SyncDbConnection.ConnectionString = [string]::Format("Server=tcp:{0},1433;Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;", $SyncDbServer, $SyncDbDatabase, $SyncDbUser, $SyncDbPassword)

        Write-Host Connecting to SyncDB $SyncDbServer"/"$SyncDbDatabase
        Try {
            $SyncDbConnection.Open()
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Test-NetConnection $SyncDbServer -Port 1433
            Break
        }

        $SyncDbCommand = New-Object System.Data.SQLClient.SQLCommand
        $SyncDbCommand.Connection = $SyncDbConnection

        $query = "select [name] from sys.schemas where name in ('dss','TaskHosting')"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.Rows | Where-Object { $_.name -eq "dss" } | Measure-Object).Count -gt 0) {
            Write-Host "dss schema exists" -Foreground White
        }
        else {
            $msg = "WARNING: dss schema IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        if (($datatable.Rows | Where-Object { $_.name -eq "TaskHosting" } | Measure-Object).Count -gt 0) {
            Write-Host "TaskHosting schema exists" -Foreground White
        }
        else {
            $msg = "WARNING: TaskHosting schema IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select schema_name(schema_id) as [name], count(*) as 'Count' from sys.tables
        where schema_name(schema_id) = 'dss' or schema_name(schema_id) = 'TaskHosting'
        group by schema_name(schema_id)"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "dss" }
        if ($spCount.Count -gt 0) {
            Write-Host "dss" $spCount.Count "tables found" -Foreground White
        }
        else {
            $msg = "WARNING: dss tables are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "TaskHosting" }
        if ($spCount.Count -gt 0) {
            Write-Host "TaskHosting" $spCount.Count "tables found" -Foreground White
        }
        else {
            $msg = "WARNING: TaskHosting tables are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select schema_name(schema_id) as [name], count(*) as 'Count' from sys.procedures
        where schema_name(schema_id) = 'dss' or schema_name(schema_id) = 'TaskHosting'
        group by schema_name(schema_id)"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "dss" }
        if ($spCount.Count -gt 0) {
            Write-Host "dss" $spCount.Count "stored procedures found" -Foreground White
        }
        else {
            $msg = "WARNING: dss stored procedures are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "TaskHosting" }
        if ($spCount.Count -gt 0) {
            Write-Host "TaskHosting" $spCount.Count "stored procedures found" -Foreground White
        }
        else {
            $msg = "WARNING: TaskHosting stored procedures are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select schema_name(schema_id) as [name], count(*) as 'Count'
        from sys.types where is_user_defined = 1 and schema_name(schema_id) = 'dss' or schema_name(schema_id) = 'TaskHosting'
        group by schema_name(schema_id)"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "dss" }
        if ($spCount.Count -gt 0) {
            Write-Host "dss" $spCount.Count "types found" -Foreground White
        }
        else {
            $msg = "WARNING: dss types are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "TaskHosting" }
        if ($spCount.Count -gt 0) {
            Write-Host "TaskHosting" $spCount.Count "types found" -Foreground White
        }
        else {
            $msg = "WARNING: TaskHosting types are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select schema_name(schema_id) as [name], count(*) as 'Count'
        from sys.objects where type in ( 'FN', 'IF', 'TF' )
        and schema_name(schema_id) = 'dss' or schema_name(schema_id) = 'TaskHosting'
        group by schema_name(schema_id)"

        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "dss" }
        if ($spCount.Count -gt 0) {
            Write-Host "dss" $spCount.Count "functions found" -Foreground White
        }
        else {
            $msg = "WARNING: dss functions are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $spCount = $datatable.Rows | Where-Object { $_.name -eq "TaskHosting" }
        if ($spCount.Count -gt 0) {
            Write-Host "TaskHosting" $spCount.Count "functions found" -Foreground White
        }
        else {
            $msg = "WARNING: TaskHosting functions are MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select name from sys.sysusers where name in ('##MS_SyncAccount##','DataSync_reader','DataSync_executor','DataSync_admin')"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        if (($datatable.Rows | Where-Object { $_.name -eq "##MS_SyncAccount##" } | Measure-Object).Count -gt 0) { Write-Host "##MS_SyncAccount## exists" -Foreground White }
        else {
            $msg = "WARNING: ##MS_SyncAccount## IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        if (($datatable.Rows | Where-Object { $_.name -eq "DataSync_reader" } | Measure-Object).Count -gt 0) { Write-Host "DataSync_reader exists" -Foreground White }
        else {
            $msg = "WARNING: DataSync_reader IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        if (($datatable.Rows | Where-Object { $_.name -eq "DataSync_executor" } | Measure-Object).Count -gt 0) { Write-Host "DataSync_executor exists" -Foreground White }
        else {
            $msg = "WARNING: DataSync_executor IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        if (($datatable.Rows | Where-Object { $_.name -eq "DataSync_admin" } | Measure-Object).Count -gt 0) { Write-Host "DataSync_admin exists" -Foreground White }
        else {
            $msg = "WARNING: DataSync_admin IS MISSING!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select [name] AS DataSyncEncryptionKeys from sys.symmetric_keys where name like 'DataSyncEncryptionKey%'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $keyCount = $datatable.Rows
        if ($keyCount.Count -gt 0) {
            Write-Host
            Write-Host $datatable.rows.Count DataSyncEncryptionKeys
            $datatable.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        }
        else {
            $msg = "WARNING: no DataSyncEncryptionKeys were found!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $query = "select [name] as 'DataSyncEncryptionCertificates' from sys.certificates where name like 'DataSyncEncryptionCertificate%'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)

        $keyCount = $datatable.Rows
        if ($keyCount.Count -gt 0) {
            Write-Host
            Write-Host $datatable.rows.Count DataSyncEncryptionCertificates
            $datatable.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        }
        else {
            $msg = "WARNING: no DataSyncEncryptionCertificates were found!"
            Write-Host $msg -Foreground Red
            [void]$errorSummaryForSyncDB.AppendLine($msg)
        }

        $SyncDbCommand.CommandText = "SELECT sg.id, sg.[name] AS SyncGroup,  ud.[database]  + ' at ' + ud.[server] AS [Database]
FROM [dss].[syncgroup] as sg
INNER JOIN [dss].[userdatabase] as ud on sg.hub_memberid = ud.id
ORDER BY sg.[name]"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTableGroups = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTableGroups.Load($SyncDbMembersResult)
        Write-Host $SyncDbMembersDataTableGroups.rows.Count Sync Groups
        $SyncDbMembersDataTableGroups.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096

        $SyncDbCommand.CommandText = "SELECT sg.[name] AS SyncGroup, sgm.[name] AS Member,  ud.[database]  + ' at ' + ud.[server] AS [Database]
FROM [dss].[syncgroupmember] sgm
INNER JOIN [dss].[syncgroup] sg ON sg.id = sgm.syncgroupid
INNER JOIN [dss].[userdatabase] as ud on sgm.databaseid = ud.id
ORDER BY sg.[name]"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTableMembers = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTableMembers.Load($SyncDbMembersResult)
        Write-Host $SyncDbMembersDataTableMembers.rows.Count Sync Group Members
        $SyncDbMembersDataTableMembers.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096

        $SyncDbCommand.CommandText = "SELECT [id], [name], [lastalivetime], [version] FROM [dss].[agent]"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTableAgents = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTableAgents.Load($SyncDbMembersResult)
        Write-Host $SyncDbMembersDataTableAgents.rows.Count Sync Agents
        $SyncDbMembersDataTableAgents.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        Write-Host

        $SyncDbCommand.CommandText = "SELECT pr.name, pr.type_desc, pe.state_desc, pe.permission_name, class_desc
        ,s.name as SchemaName, c.name as CertificateName, k.name as SymmetricKeyName
        FROM sys.database_principals AS pr
        JOIN sys.database_permissions AS pe ON pe.grantee_principal_id = pr.principal_id
        LEFT OUTER JOIN sys.schemas AS s ON (pe.class = 3 and pe.major_id = s.schema_id)
        LEFT OUTER JOIN sys.certificates AS c ON (pe.class = 25 and pe.major_id = c.certificate_id)
        LEFT OUTER JOIN sys.symmetric_keys AS k ON (pe.class = 24 and pe.major_id = k.symmetric_key_id)
        WHERE pr.[name] = '##MS_SyncAccount##' OR pr.[name] = 'DataSync_admin'
        OR pr.[name] = 'DataSync_executor' OR pr.[name] = 'DataSync_reader'
        ORDER by pe.class, pr.name"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTablePermissions = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTablePermissions.Load($SyncDbMembersResult)
        Write-Host $SyncDbMembersDataTablePermissions.rows.Count Permissions
        $SyncDbMembersDataTablePermissions.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        Write-Host

        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CONTROL" "dss"
        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CONTROL" "TaskHosting"

        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_executor" "EXECUTE" "dss"
        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_executor" "EXECUTE" "TaskHosting"
        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_executor" "SELECT" "dss"
        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_executor" "SELECT" "TaskHosting"

        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_reader" "SELECT" "dss"
        CheckSchemaPermission $SyncDbMembersDataTablePermissions "DataSync_reader" "SELECT" "TaskHosting"

        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CREATE FUNCTION"
        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CREATE PROCEDURE"
        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CREATE TABLE"
        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CREATE TYPE"
        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "CREATE VIEW"
        CheckDatabasePermission $SyncDbMembersDataTablePermissions "DataSync_admin" "VIEW DATABASE STATE"

        CheckDatabasePermission $SyncDbMembersDataTablePermissions "##MS_SyncAccount##" "CONNECT"

        Write-Host
        GetUIHistoryForSyncDBValidator
    }
    Catch {
        Write-Host ValidateSyncDB exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    Finally {
        if ($SyncDbConnection) {
            Write-Host Closing connection to SyncDb...
            $SyncDbConnection.Close()
        }
    }
}

function CheckSchemaPermission($permissionsTable, [String] $permissionUserName, [String] $permissionName, [String] $schemaName) {
    if (($permissionsTable.Rows | Where-Object { $_.name -eq $permissionUserName -and $_.permission_name -eq $permissionName -and $_.class_desc -eq "SCHEMA" -and $_.SchemaName -eq $schemaName } | Measure-Object).Count -eq 0) {
        $msg = "WARNING: $permissionUserName $permissionName on SCHEMA $schemaName IS MISSING!"
        Write-Host $msg -Foreground Red
        [void]$errorSummaryForSyncDB.AppendLine($msg)
    }
    else {
        Write-Host $permissionUserName $permissionName on SCHEMA $schemaName "exists" -ForegroundColor Green
    }
}

function CheckDatabasePermission($permissionsTable, [String] $permissionUserName, [String] $permissionName, [String] $schemaName) {
    if (($permissionsTable.Rows | Where-Object { $_.name -eq $permissionUserName -and $_.permission_name -eq $permissionName -and $_.class_desc -eq "DATABASE" } | Measure-Object).Count -eq 0) {
        $msg = "WARNING: $permissionUserName $permissionName on DATABASE IS MISSING!"
        Write-Host $msg -Foreground Red
        [void]$errorSummaryForSyncDB.AppendLine($msg)
    }
    else {
        Write-Host $permissionUserName $permissionName on DATABASE "exists" -ForegroundColor Green
    }
}

function DumpMetadataSchemasForSyncGroup([String] $syncGoupName) {
    Try {
        Write-Host Running DumpMetadataSchemasForSyncGroup
        $SyncDbConnection = New-Object System.Data.SqlClient.SQLConnection
        $SyncDbConnection.ConnectionString = [string]::Format("Server=tcp:{0},1433;Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;", $SyncDbServer, $SyncDbDatabase, $SyncDbUser, $SyncDbPassword)
        Write-Host Connecting to SyncDB $SyncDbServer"/"$SyncDbDatabase
        Try {
            $SyncDbConnection.Open()
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Test-NetConnection $SyncDbServer -Port 1433
            Break
        }

        $SyncDbCommand = New-Object System.Data.SQLClient.SQLCommand
        $SyncDbCommand.Connection = $SyncDbConnection

        $query = "SELECT [schema_description] FROM [dss].[syncgroup] WHERE [schema_description] IS NOT NULL AND [name] = '" + $syncGoupName + "'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            $xmlResult = $datatable.Rows[0].schema_description
            if ($xmlResult -and $canWriteFiles) {
                $xmlResult | Out-File -filepath ('.\' + (SanitizeString $syncGoupName) + '_schema_description.xml')
            }
        }

        $query = "SELECT [ocsschemadefinition] FROM [dss].[syncgroup] WHERE [ocsschemadefinition] IS NOT NULL AND [name] = '" + $syncGoupName + "'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            $xmlResult = $datatable.Rows[0].ocsschemadefinition
            if ($xmlResult -and $canWriteFiles) {
                $xmlResult | Out-File -filepath ('.\' + (SanitizeString $syncGoupName) + '_ocsschemadefinition.xml')
            }
        }

        $query = "SELECT ud.server as HubServer, ud.[database] as HubDatabase, [db_schema]
        FROM [dss].[syncgroup] as sg
        INNER JOIN [dss].[userdatabase] as ud on sg.hub_memberid = ud.id
        LEFT JOIN [dss].[syncgroupmember] as m on sg.id = m.syncgroupid
        WHERE [db_schema] IS NOT NULL AND sg.name = '" + $syncGoupName + "'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            $xmlResult = $datatable.Rows[0].db_schema
            if ($xmlResult -and $canWriteFiles) {
                $xmlResult | Out-File -filepath ('.\' + (SanitizeString $datatable.Rows[0].HubServer) + '_' + (SanitizeString $datatable.Rows[0].HubDatabase) + '_db_schema.xml')
            }
        }

        $query = "SELECT ud2.[server] as MemberServer ,ud2.[database] as MemberDatabase, [db_schema]
        FROM [dss].[syncgroup] as sg
        LEFT JOIN [dss].[syncgroupmember] as m on sg.id = m.syncgroupid
        LEFT JOIN [dss].[userdatabase] as ud2 on m.databaseid = ud2.id
        WHERE [db_schema] IS NOT NULL AND sg.name = '" + $syncGoupName + "'"
        $SyncDbCommand.CommandText = $query
        $result = $SyncDbCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            foreach ($databse in $datatable.Rows) {
                $xmlResult = $databse.db_schema
                if ($xmlResult -and $canWriteFiles) {
                    $xmlResult | Out-File -filepath ('.\' + (SanitizeString $databse.MemberServer) + '_' + (SanitizeString $databse.MemberDatabase) + '_db_schema.xml')
                }
            }
        }
    }
    Catch {
        Write-Host DumpMetadataSchemasForSyncGroup exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    Finally {
        if ($SyncDbConnection) {
            Write-Host Closing connection to SyncDb...
            $SyncDbConnection.Close()
        }
    }
}

function GetIndexes($table) {
    Try {
        $query = "sp_helpindex '" + $table + "'"
        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            Write-Host
            $msg = "Indexes for " + $table + ":"
            Write-Host $msg -Foreground Green
            $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            Write-Host
        }
    }
    Catch {
        Write-Host GetIndexes exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function GetConstraints($table) {
    Try {
        $query = "select case when [syskc].[type] = 'PK' then 'PK' when [syskc].[type] = 'UQ' then 'UNIQUE'
        when [sysidx].[type] = 1 then 'UQ CI' when [sysidx].[type] = 2 then 'UQ INDEX' end as [type],
        ISNULL([syskc].[name], [sysidx].[name]) as [name], SUBSTRING([columns], 1, LEN([columns])-1) as [definition]
        from sys.objects [sysobj]
        left outer join sys.indexes [sysidx] on [sysobj].[object_id] = [sysidx].[object_id]
        left outer join sys.key_constraints [syskc] on [sysidx].[object_id] = [syskc].parent_object_id and [sysidx].index_id = [syskc].unique_index_id
        cross apply
        (select [syscol].[name] + ', ' from sys.index_columns [sysic]
        inner join sys.columns [syscol] on [sysic].[object_id] = [syscol].[object_id] and [sysic].column_id = [syscol].column_id
        where [sysic].[object_id] = [sysobj].[object_id] and [sysic].index_id = [sysidx].index_id FOR XML PATH ('')
        ) COLS ([columns])
        where is_unique = 1 and [sysobj].is_ms_shipped <> 1 and ('['+ SCHEMA_NAME([sysobj].[schema_id]) + '].[' + [sysobj].[name] + ']') = '" + $table + "'
        union all select 'FOREIGN KEY', [sysfk].[name], SCHEMA_NAME([systabpk].[schema_id]) + '.' + [systabpk].[name]
        from sys.foreign_keys [sysfk]
        inner join sys.tables [systabfk] on [systabfk].[object_id] = [sysfk].[parent_object_id]
        inner join sys.tables [systabpk] on [systabpk].[object_id] = [sysfk].[referenced_object_id]
        inner join sys.foreign_key_columns [sysfkcols] on [sysfkcols].[constraint_object_id] = [sysfk].[object_id]
        where ('['+ SCHEMA_NAME([systabfk].[schema_id]) + '].[' + [systabfk].[name] + ']') = '" + $table + "'
        union all select 'CHECK', [syscc].[name] + ']', [syscc].[definition]
        from sys.check_constraints [syscc]
        left outer join sys.objects [sysobj] on [syscc].parent_object_id = [sysobj].[object_id]
        left outer join sys.all_columns [syscol] on [syscc].parent_column_id = [syscol].column_id and [syscc].parent_object_id = [syscol].[object_id]
        where ('['+ SCHEMA_NAME([sysobj].[schema_id]) + '].[' + [sysobj].[name]+ ']') = '" + $table + "'
        union all select 'DEFAULT', [sysdc].[name], [syscol].[name] + ' = ' + [sysdc].[definition]
        from sys.default_constraints [sysdc]
        left outer join sys.objects [sysobj] on [sysdc].[parent_object_id] = [sysobj].[object_id]
        left outer join sys.all_columns [syscol] on [sysdc].[parent_column_id] = [syscol].[column_id] and [sysdc].[parent_object_id] = [syscol].[object_id]
        where ('['+ SCHEMA_NAME([sysobj].[schema_id]) + '].[' + [sysobj].[name] + ']') = '" + $table + "'"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            Write-Host
            $msg = "Constraints for " + $table + ":"
            Write-Host $msg -Foreground Green
            $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            Write-Host
        }
    }
    Catch {
        Write-Host GetConstraints exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function GetCustomerTriggers($table) {
    Try {
        $query = "SELECT tr.name AS TriggerName, tr.is_disabled AS 'Disabled'
        FROM sys.triggers tr
        INNER JOIN sys.tables t ON tr.parent_id = t.object_id
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
		where '['+ SCHEMA_NAME(t.schema_id) +'].['+ t.name+']'  = '" + $table + "'
		AND tr.[name] not like '%_dss_%'"

        $MemberCommand.CommandText = $query
        $result = $MemberCommand.ExecuteReader()
        $datatable = new-object 'System.Data.DataTable'
        $datatable.Load($result)
        if ($datatable.Rows.Count -gt 0) {
            Write-Host
            $msg = "Customer triggers for " + $table + ":"
            Write-Host $msg -Foreground Green
            $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            Write-Host
        }
    }
    Catch {
        Write-Host GetCustomerTriggers exception:
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function SanitizeString([String] $param) {
    return ($param.Replace('\', '_').Replace('/', '_').Replace("[", "").Replace("]", "").Replace('.', '_').Replace(':', '_').Replace(',', '_'))
}

function ValidateDSSMember() {
    Try {
        if (-not($HealthChecksEnabled)) { return }
        $runnableScript = New-Object -TypeName "System.Text.StringBuilder"
        $errorSummary = New-Object -TypeName "System.Text.StringBuilder"
        $allTrackingTableList = New-Object System.Collections.ArrayList
        $allTriggersList = New-Object System.Collections.ArrayList
        $allSPsList = New-Object System.Collections.ArrayList
        $allBulkTypeList = New-Object System.Collections.ArrayList

        $SyncDbConnection = New-Object System.Data.SqlClient.SQLConnection
        $SyncDbConnection.ConnectionString = [string]::Format("Server=tcp:{0},1433;Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;", $SyncDbServer, $SyncDbDatabase, $SyncDbUser, $SyncDbPassword)

        Write-Host Connecting to SyncDB $SyncDbServer"/"$SyncDbDatabase
        Try {
            $SyncDbConnection.Open()
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Test-NetConnection $SyncDbServer -Port 1433
            Break
        }

        $SyncDbCommand = New-Object System.Data.SQLClient.SQLCommand
        $SyncDbCommand.Connection = $SyncDbConnection

        Write-Host Validating if $Server/$Database exist in SyncDB:

        $SyncDbCommand.CommandText = "SELECT count(*) as C FROM [dss].[userdatabase] WHERE server = '" + $Server + "' and [database] = '" + $Database + "'"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTable = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTable.Load($SyncDbMembersResult)

        if ($SyncDbMembersDataTable.Rows[0].C -eq 0) {
            Write-Host ERROR: $Server/$Database was not found in [dss].[userdatabase] -ForegroundColor Red
            return;
        }
        else {
            Write-Host $Server/$Database was found in SyncDB -ForegroundColor Green
        }

        Write-Host Getting scopes in SyncDB for this member database:

        $SyncDbCommand.CommandText = "SELECT m.[scopename]
        ,sg.name as SyncGroupName
        ,CAST(sg.schema_description as nvarchar(max)) as SchemaDescription
        ,m.[name] as MemberName
        ,m.[jobid] as JobId
        ,COUNT(mq.[MessageId]) as Messages
        ,enum1.Name as State
		,enum2.Name as HubState
        ,enum3.Name as SyncDirection
        FROM [dss].[syncgroup] as sg
        INNER JOIN [dss].[userdatabase] as ud on sg.hub_memberid = ud.id
        LEFT JOIN [dss].[syncgroupmember] as m on sg.id = m.syncgroupid
        LEFT JOIN [dss].[EnumType] as enum1 on (enum1.Type='SyncGroupMemberState' and enum1.EnumId = m.memberstate)
		LEFT JOIN [dss].[EnumType] as enum2 on (enum2.Type='SyncGroupMemberState' and enum2.EnumId = m.hubstate)
        LEFT JOIN [dss].[EnumType] as enum3 on (enum3.Type='DssSyncDirection' and enum3.EnumId = m.syncdirection)
        LEFT JOIN [dss].[userdatabase] as ud2 on m.databaseid = ud2.id
        left outer join [TaskHosting].[Job] job on m.JobId = job.JobId
        left outer join [TaskHosting].[MessageQueue] mq on job.JobId = mq.JobId
        WHERE (ud.server = '" + $Server + "' and ud.[database] = '" + $Database + "')
        or (ud2.[server] = '" + $Server + "' and ud2.[database] = '" + $Database + "')
        GROUP BY m.[scopename],sg.name,CAST(sg.schema_description as nvarchar(max)),m.[name],m.[memberstate],m.[hubstate],m.[jobid],enum1.Name,enum2.Name,enum3.Name"
        $SyncDbMembersResult = $SyncDbCommand.ExecuteReader()
        $SyncDbMembersDataTable = new-object 'System.Data.DataTable'
        $SyncDbMembersDataTable.Load($SyncDbMembersResult)

        Write-Host $SyncDbMembersDataTable.Rows.Count members found in this sync metadata database -ForegroundColor Green
        $SyncDbMembersDataTable.Rows | Sort-Object -Property scopename | Select-Object scopename, SyncGroupName, MemberName, SyncDirection, State, HubState, JobId, Messages | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        $scopesList = $SyncDbMembersDataTable.Rows | Select-Object -ExpandProperty scopename

        $shouldMonitor = $SyncDbMembersDataTable.Rows | Where-Object { `
                $_.State.Equals('Provisioning') `
                -or $_.State.Equals('SyncInProgress') `
                -or $_.State.Equals('DeProvisioning') `
                -or $_.State.Equals('DeProvisioned') `
                -or $_.State.Equals('Reprovisioning') `
                -or $_.State.Equals('SyncCancelling') `
                -or $_.HubState.Equals('Provisioning') `
                -or $_.HubState.Equals('DeProvisioning') `
                -or $_.HubState.Equals('DeProvisioned') `
                -or $_.HubState.Equals('Reprovisioning')
        }
        if ($shouldMonitor -and $MonitoringMode -eq 'AUTO') {
            $MonitoringMode = 'ENABLED'
        }

        if (($SyncDbMembersDataTable.Rows | Measure-Object Messages -Sum).Sum -gt 0) {
            $allJobIds = "'$(($SyncDbMembersDataTable.Rows | Select-Object -ExpandProperty JobId | Where-Object { $_.ToString() -ne '' }) -join "','")'"
            $SyncDbCommand.CommandText = "select job.[JobId]
            ,job.[IsCancelled]
            ,job.[JobType]
            ,job.[TaskCount]
            ,job.[CompletedTaskCount]
            ,m.[MessageId]
            ,m.[MessageType]
            ,m.[ExecTimes]
            ,m.[ResetTimes]
            from [TaskHosting].[Job] job
            left outer join [TaskHosting].[MessageQueue] m on job.JobId = m.JobId
            where job.JobId IN (" + $allJobIds + ")"
            $SyncJobsResult = $SyncDbCommand.ExecuteReader()
            $SyncJobsDataTable = new-object 'System.Data.DataTable'
            $SyncJobsDataTable.Load($SyncJobsResult)
            $SyncJobsDataTable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
        }

        Write-Host
        GetUIHistory
        Write-Host

        $MemberConnection = New-Object System.Data.SqlClient.SQLConnection
        if ($MbrUseWindowsAuthentication) {
            $MemberConnection.ConnectionString = [string]::Format("Server={0};Initial Catalog={1};Persist Security Info=False;Integrated Security=true;MultipleActiveResultSets=False;Connection Timeout=30;", $Server, $Database)
        }
        else {
            $MemberConnection.ConnectionString = [string]::Format("Server={0};Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Connection Timeout=30;", $Server, $Database, $MbrUser, $MbrPassword)
        }

        Write-Host
        Write-Host Connecting to $Server"/"$Database
        Try {
            $MemberConnection.Open()
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Test-NetConnection $Server -Port 1433
            Break
        }

        $MemberCommand = New-Object System.Data.SQLClient.SQLCommand
        $MemberCommand.Connection = $MemberConnection

        Try {
            Write-Host
            Write-Host Database version and configuration:
            $MemberCommand.CommandText = "SELECT compatibility_level AS [CompatLevel], collation_name AS [Collation], snapshot_isolation_state_desc AS [Snapshot], @@VERSION AS [Version] FROM sys.databases WHERE name = DB_NAME();"
            $MemberResult = $MemberCommand.ExecuteReader()
            $MemberVersion = new-object 'System.Data.DataTable'
            $MemberVersion.Load($MemberResult)
            $MemberVersion.Rows | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            Write-Host
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        ### Database Validations ###
        ValidateCircularReferences
        ValidateTableNames
        ValidateObjectNames
        DetectComputedColumns
        DetectProvisioningIssues

        ValidateTablesVSSyncDbSchema $SyncDbMembersDataTable
        Write-Host
        Write-Host Getting scopes in this $Server"/"$Database database...

        Try {
            $MemberCommand.CommandText = "SELECT [sync_scope_name], [scope_local_id], [scope_config_id],[config_data],[scope_status], CAST([schema_major_version] AS varchar) + '.' + CAST([schema_minor_version] AS varchar) as [Version] FROM [DataSync].[scope_config_dss] AS sc LEFT OUTER JOIN [DataSync].[scope_info_dss] AS si ON si.scope_config_id = sc.config_id LEFT JOIN [DataSync].[schema_info_dss] ON 1=1"
            $MemberResult = $MemberCommand.ExecuteReader()
            $MemberScopes = new-object 'System.Data.DataTable'
            $MemberScopes.Load($MemberResult)

            Write-Host $MemberScopes.Rows.Count scopes found in Hub/Member
            $MemberScopes.Rows | Select-Object sync_scope_name, scope_config_id, scope_status, scope_local_id, Version | Sort-Object -Property sync_scope_name | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            Write-Host

            $global:Connection = $MemberConnection

            foreach ($scope in $MemberScopes) {
                Write-Host
                $SyncGroupName = $SyncDbMembersDataTable.Rows | Where-Object { $_.scopename -eq $scope.sync_scope_name } | Select-Object -ExpandProperty SyncGroupName
                Write-Host "Validating sync group" $SyncGroupName "(ScopeName:"$scope.sync_scope_name")"
                if ($scope.sync_scope_name -notin $scopesList) {
                    Write-Host "WARNING:" [DataSync].[scope_config_dss].[config_id] $scope.scope_config_id "should be a leftover." -Foreground Yellow
                    Write-Host "WARNING:" [DataSync].[scope_info_dss].[scope_local_id] $scope.scope_local_id "should be a leftover." -Foreground Yellow

                    $deleteStatement = "DELETE FROM [DataSync].[scope_config_dss] WHERE [config_id] = '" + $scope.scope_config_id + "'"
                    [void]$runnableScript.AppendLine($deleteStatement)
                    [void]$runnableScript.AppendLine("GO")

                    $deleteStatement = "DELETE FROM [DataSync].[scope_info_dss] WHERE [scope_local_id] = '" + $scope.scope_local_id + "'"
                    [void]$runnableScript.AppendLine($deleteStatement)
                    [void]$runnableScript.AppendLine("GO")

                    $query = "SELECT [object_id], object_name([object_id]) as TableName FROM [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = " + $scope.scope_local_id
                    $MemberCommand.CommandText = $query
                    $provision_marker_result = $MemberCommand.ExecuteReader()
                    $provision_marker_leftovers = new-object 'System.Data.DataTable'
                    $provision_marker_leftovers.Load($provision_marker_result)

                    foreach ($provision_marker_leftover in $provision_marker_leftovers) {
                        $deleteStatement = "DELETE FROM [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = " + $scope.scope_local_id + " and [object_id] = " + $provision_marker_leftover.object_id + " --" + $provision_marker_leftover.TableName
                        Write-Host "WARNING: [DataSync].[provision_marker_dss] WHERE [owner_scope_local_id] = " $scope.scope_local_id  " and [object_id] = " $provision_marker_leftover.object_id " (" $provision_marker_leftover.TableName ") should be a leftover." -Foreground Yellow
                        [void]$runnableScript.AppendLine($deleteStatement)
                        [void]$runnableScript.AppendLine("GO")
                    }
                }
                else {
                    $xmlcontent = [xml]$scope.config_data
                    $global:scope_config_data = $xmlcontent

                    Try {
                        $sgSchema = $SyncDbMembersDataTable | Where-Object { $_.scopename -eq $scope.sync_scope_name } | Select-Object SchemaDescription
                        $global:sgSchemaXml = ([xml]$sgSchema.SchemaDescription).DssSyncScopeDescription.TableDescriptionCollection.DssTableDescription
                    }
                    Catch {
                        $global:sgSchemaXml = $null
                        $ErrorMessage = $_.Exception.Message
                        Write-Host "Was not able to get SchemaDescription:" + $ErrorMessage
                    }

                    ### Validations ###

                    #Tables
                    ValidateTablesVSLocalSchema ($xmlcontent.SqlSyncProviderScopeConfiguration.Adapter | Select-Object -ExpandProperty GlobalName)
                    ShowRowCountAndFragmentation ($xmlcontent.SqlSyncProviderScopeConfiguration.Adapter | Select-Object -ExpandProperty GlobalName)

                    foreach ($table in $xmlcontent.SqlSyncProviderScopeConfiguration.Adapter) {
                        #Tracking Tables
                        ValidateTrackingTable($table.TrackingTable)

                        ##Triggers
                        ValidateTrigger($table.InsTrig)
                        ValidateTrigger($table.UpdTrig)
                        ValidateTrigger($table.DelTrig)
                        [void]$errorSummary.AppendLine()

                        ## Procedures
                        if ($table.SelChngProc) { ValidateSP($table.SelChngProc) }
                        if ($table.SelRowProc) { ValidateSP($table.SelRowProc) }
                        if ($table.InsProc) { ValidateSP($table.InsProc) }
                        if ($table.UpdProc) { ValidateSP($table.UpdProc) }
                        if ($table.DelProc) { ValidateSP($table.DelProc) }
                        if ($table.InsMetaProc) { ValidateSP($table.InsMetaProc) }
                        if ($table.UpdMetaProc) { ValidateSP($table.UpdMetaProc) }
                        if ($table.DelMetaProc) { ValidateSP($table.DelMetaProc) }
                        if ($table.BulkInsProc) { ValidateSP($table.BulkInsProc) }
                        if ($table.BulkUpdProc) { ValidateSP($table.BulkUpdProc) }
                        if ($table.BulkDelProc) { ValidateSP($table.BulkDelProc) }
                        [void]$errorSummary.AppendLine()

                        ## BulkType
                        if ($table.BulkTableType) { ValidateBulkType $table.BulkTableType $table.Col }
                        [void]$errorSummary.AppendLine()

                        ## Indexes
                        GetIndexes $table.Name
                        GetConstraints $table.Name
                        GetCustomerTriggers $table.Name
                    }

                    #Constraints
                    ValidateFKDependencies ($xmlcontent.SqlSyncProviderScopeConfiguration.Adapter | Select-Object -ExpandProperty GlobalName)
                }
            }
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        ### Detect Leftovers ###
        DetectTrackingTableLeftovers
        DetectTriggerLeftovers
        DetectProcedureLeftovers
        DetectBulkTypeLeftovers

        ### Validations ###
        ValidateProvisionMarker

        if ($runnableScript.Length -gt 0) {
            $dumpScript = New-Object -TypeName 'System.Text.StringBuilder'
            [void]$dumpScript.AppendLine(" --*****************************************************************************************************************")
            [void]$dumpScript.AppendLine(" --LEFTOVERS CLEANUP SCRIPT : START")
            [void]$dumpScript.AppendLine(" --ONLY applicable when this database is not being used by any other sync group in other regions and/or subscription")
            [void]$dumpScript.AppendLine(" --AND Data Sync Health Checker was able to access the right Sync Metadata Database")
            [void]$dumpScript.AppendLine(" --*****************************************************************************************************************")
            [void]$dumpScript.AppendLine($runnableScript.ToString())
            [void]$dumpScript.AppendLine(" --*****************************************************************************************************************")
            [void]$dumpScript.AppendLine(" --LEFTOVERS CLEANUP SCRIPT : END")
            [void]$dumpScript.AppendLine(" --*****************************************************************************************************************")
            if ($canWriteFiles) {
                ($dumpScript.ToString()) | Out-File -filepath ('.\' + (SanitizeString $Server) + '_' + (SanitizeString $Database) + '_leftovers.sql')
            }
        }
        else {
            Write-Host
            Write-Host NO LEFTOVERS DETECTED!
        }

        if ($errorSummary.Length -gt 0) {
            Write-Host
            Write-Host "*******************************************" -Foreground Red
            Write-Host "             WARNINGS SUMMARY" -Foreground Red
            Write-Host "*******************************************" -Foreground Red
            Write-Host (RemoveDoubleEmptyLines $errorSummary.ToString()) -Foreground Red
            Write-Host
        }
        else {
            Write-Host
            Write-Host NO ERRORS DETECTED!
        }
        if (($Server -eq $MemberServer) -and ($Database -eq $MemberDatabase)) {
            $script:errorSummaryForMember = $errorSummary
        }
        if (($Server -eq $HubServer) -and ($Database -eq $HubDatabase)) {
            $script:errorSummaryForHub = $errorSummary
        }
    }
    Finally {
        if ($SyncDbConnection) {
            Write-Host Closing connection to SyncDb...
            $SyncDbConnection.Close()
        }
        if ($MemberConnection) {
            Write-Host Closing connection to Member...
            $MemberConnection.Close()
        }
    }
}

function Monitor() {

    Write-Host ****************************** -ForegroundColor Green
    Write-Host             MONITORING
    Write-Host ****************************** -ForegroundColor Green

    $monitorUntil = (Get-Date).AddMinutes($MonitoringDurationInMinutes)

    $HubConnection = New-Object System.Data.SqlClient.SQLConnection
    $HubConnection.ConnectionString = [string]::Format("Server=tcp:{0},1433;Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;", $HubServer, $HubDatabase, $HubUser, $HubPassword)
    $HubCommand = New-Object System.Data.SQLClient.SQLCommand
    $HubCommand.Connection = $HubConnection

    Write-Host Connecting to Hub $HubServer"/"$HubDatabase
    Try {
        $HubConnection.Open()
    }
    Catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Test-NetConnection $HubServer -Port 1433
        Break
    }

    $MemberConnection = New-Object System.Data.SqlClient.SQLConnection
    if ($MemberUseWindowsAuthentication) {
        $MemberConnection.ConnectionString = [string]::Format("Server={0};Initial Catalog={1};Persist Security Info=False;Integrated Security=true;MultipleActiveResultSets=False;Connection Timeout=30;", $MemberServer, $MemberDatabase)
    }
    else {
        $MemberConnection.ConnectionString = [string]::Format("Server={0};Initial Catalog={1};Persist Security Info=False;User ID={2};Password={3};MultipleActiveResultSets=False;Connection Timeout=30;", $MemberServer, $MemberDatabase, $MemberUser, $MemberPassword)
    }

    $MemberCommand = New-Object System.Data.SQLClient.SQLCommand
    $MemberCommand.Connection = $MemberConnection

    Write-Host Connecting to Member $MemberServer"/"$MemberDatabase
    Try {
        $MemberConnection.Open()
    }
    Catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Test-NetConnection $MemberServer -Port 1433
        Break
    }

    $HubCommand.CommandText = "SELECT GETUTCDATE() as now"
    $result = $HubCommand.ExecuteReader()
    $datatable = new-object 'System.Data.DataTable'
    $datatable.Load($result)
    $lasttime = $datatable.Rows[0].now

    while ((Get-Date) -le $monitorUntil) {
        $lastTimeString = ([DateTime]$lasttime).toString("yyyy-MM-dd HH:mm:ss")
        $lastTimeString = $lastTimeString.Replace('.', ':')

        Write-Host "Monitoring ("$lastTimeString")..." -ForegroundColor Green

        Try {
            $os = Get-Ciminstance Win32_OperatingSystem
            $FreePhysicalMemory = [math]::Round(($os.FreePhysicalMemory / 1024), 2)
            $FreeVirtualMemory = [math]::Round(($os.FreeVirtualMemory / 1024), 2)
            Write-Host "FreePhysicalMemory:" $FreePhysicalMemory "|" "FreeVirtualMemory:" $FreeVirtualMemory -ForegroundColor Yellow

            Get-WMIObject Win32_Process -Filter "Name='DataSyncLocalAgentHost.exe' or Name='sqlservr.exe'" | Select Name,@{n="Private Memory(mb)";e={[math]::Round($_.PrivatePageCount/1mb,2)}} | Format-Table -AutoSize
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        Try {
            $tempfolderfiles = [System.IO.Directory]::EnumerateFiles([Environment]::GetEnvironmentVariable("TEMP", "User"), "*.*", "AllDirectories")
            $batchFiles = ($tempfolderfiles | Where-Object { $_ -match "DSS2_" -and $_ -match "sync_" -and $_ -match ".batch" }).Count
            $MATSFiles = ($tempfolderfiles | Where-Object { $_ -match "DSS2_" -and $_ -match "MATS_" }).Count
            Write-Host Temp folder at user level - batch:$batchFiles MATS:$MATSFiles -ForegroundColor Yellow

            $tempfolderfiles = [System.IO.Directory]::EnumerateFiles([Environment]::GetEnvironmentVariable("TEMP", "Machine"), "*.*", "AllDirectories")
            $batchFiles = ($tempfolderfiles | Where-Object { $_ -match "DSS2_" -and $_ -match "sync_" -and $_ -match ".batch" }).Count
            $MATSFiles = ($tempfolderfiles | Where-Object { $_ -match "DSS2_" -and $_ -match "MATS_" }).Count
            Write-Host Temp folder at machine level - batch:$batchFiles MATS:$MATSFiles -ForegroundColor Yellow
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }


        $query = "select o.name AS What, p.last_execution_time AS LastExecutionTime, p.execution_count AS ExecutionCount
        from sys.dm_exec_procedure_stats p
        inner join sys.objects o on o.object_id = p.object_id
        inner join sys.schemas s on s.schema_id=o.schema_id
        where s.name = 'DataSync' and p.last_execution_time > '" + $lastTimeString + "'
        order by p.last_execution_time desc"

        Try {
            $HubCommand.CommandText = $query
            $HubResult = $HubCommand.ExecuteReader()
            $datatable = new-object 'System.Data.DataTable'
            $datatable.Load($HubResult)

            if ($datatable.Rows.Count -gt 0) {
                Write-Host "Hub Monitor (SPs) ("$lastTimeString"): new records:" -ForegroundColor Green
                $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            }
            else {
                Write-Host "- No new records from Hub Monitor (SPs)" -ForegroundColor Green
            }
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        Try {
            $MemberCommand.CommandText = $query
            $MemberResult = $MemberCommand.ExecuteReader()
            $datatable = new-object 'System.Data.DataTable'
            $datatable.Load($MemberResult)

            if ($datatable.Rows.Count -gt 0) {
                Write-Host "Member Monitor (SPs) ("$lastTimeString"): new records:" -ForegroundColor Green
                $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            }
            else {
                Write-Host "- No new records from Member Monitor (SPs)" -ForegroundColor Green
            }
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        $query = "SELECT req.session_id as Session, req.status as Status, req.command as Command,
        req.cpu_time as CPUTime, req.total_elapsed_time as TotalTime, sqltext.TEXT as What
        --SUBSTRING(sqltext.TEXT, CHARINDEX('[DataSync]', sqltext.TEXT), 100) as What
        FROM sys.dm_exec_requests req CROSS APPLY sys.dm_exec_sql_text(sql_handle) AS sqltext
        WHERE sqltext.TEXT like '%[DataSync]%' AND sqltext.TEXT not like 'SELECT req.session_id%'"

        Try {
            $HubCommand.CommandText = $query
            $HubResult = $HubCommand.ExecuteReader()
            $datatable = new-object 'System.Data.DataTable'
            $datatable.Load($HubResult)

            if ($datatable.Rows.Count -gt 0) {
                Write-Host "Hub Monitor (running commands) ("$lastTimeString"): new records:" -ForegroundColor Green
                $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            }
            else {
                Write-Host "- No new records from Hub Monitor (running)" -ForegroundColor Green
            }
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        Try {
            $MemberCommand.CommandText = $query
            $MemberResult = $MemberCommand.ExecuteReader()
            $datatable = new-object 'System.Data.DataTable'
            $datatable.Load($MemberResult)

            if ($datatable.Rows.Count -gt 0) {
                Write-Host "Member Monitor (running commands) ("$lastTimeString"): new records:" -ForegroundColor Green
                $datatable | Format-Table -Wrap -AutoSize | Out-String -Width 4096
            }
            else {
                Write-Host "- No new records from Member Monitor (running)" -ForegroundColor Green
            }
        }
        Catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        $lasttime = $lasttime.AddSeconds($MonitoringIntervalInSeconds)
        Write-Host "Waiting..." $MonitoringIntervalInSeconds "seconds..." -ForegroundColor Green
        Start-Sleep -s $MonitoringIntervalInSeconds
    }
    Write-Host
    Write-Host "Monitoring finished" -ForegroundColor Green
}

function FilterTranscript() {
    Try {
        if ($canWriteFiles) {
            $lineNumber = (Select-String -Path $file -Pattern '..TranscriptStart..').LineNumber
            if ($lineNumber) {
                (Get-Content $file | Select-Object -Skip $lineNumber) | Set-Content $file
            }
        }
    }
    Catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function SanitizeServerName([string]$ServerName) {
    $ServerName = $ServerName.Trim()
    $ServerName = $ServerName.Replace('tcp:', '')
    $ServerName = $ServerName.Replace(',1433', '')
    return $ServerName
}

function RemoveDoubleEmptyLines([string]$text) {
    do {
        $previous = $text
        $text = $text.Replace("`r`n`r`n`r`n", "`r`n`r`n")
    } while ($text -ne $previous)
    return $text
}

Try {
    Clear-Host
    $errorSummaryForSyncDB = New-Object -TypeName "System.Text.StringBuilder"
    $errorSummaryForMember
    $errorSummaryForHub
    $canWriteFiles = $true
    Try {
        Set-Location $HOME\clouddrive -ErrorAction Stop
        Write-Host "This seems to be running on Azure Cloud Shell"
        $isThisFromAzurePortal = $true
    }
    Catch {
        $isThisFromAzurePortal = $false
        Write-Host "This doesn't seem to be running on Azure Cloud Shell"
        Set-Location -Path $env:TEMP
    }
    Try {
        If (!(Test-Path DataSyncHealthChecker)) {
            New-Item DataSyncHealthChecker -ItemType directory | Out-Null
        }
        Set-Location DataSyncHealthChecker
        $outFolderName = [System.DateTime]::Now.ToString('yyyyMMddTHHmmss')
        New-Item $outFolderName -ItemType directory | Out-Null
        Set-Location $outFolderName
        $file = '.\_SyncDB_Log.txt'
        Start-Transcript -Path $file
        Write-Host '..TranscriptStart..'
    }
    Catch {
        $canWriteFiles = $false
        Write-Host Warning: Cannot write files -ForegroundColor Yellow
    }

    Try {
        Write-Host ************************************************************ -ForegroundColor Green
        Write-Host "  Azure SQL Data Sync Health Checker v6.16 Results" -ForegroundColor Green
        Write-Host ************************************************************ -ForegroundColor Green
        Write-Host
        Write-Host "Configuration:" -ForegroundColor Green
        Write-Host PowerShell $PSVersionTable.PSVersion
        Write-Host
        Write-Host "Databases:" -ForegroundColor Green
        Write-Host SyncDbServer = $SyncDbServer
        Write-Host SyncDbDatabase = $SyncDbDatabase
        Write-Host HubServer = $HubServer
        Write-Host HubDatabase = $HubDatabase
        Write-Host MemberServer = $MemberServer
        Write-Host MemberDatabase = $MemberDatabase
        Write-Host
        Write-Host "Parameters you can change:" -ForegroundColor Green
        Write-Host HealthChecksEnabled = $HealthChecksEnabled
        Write-Host MonitoringMode = $MonitoringMode
        Write-Host MonitoringIntervalInSeconds = $MonitoringIntervalInSeconds
        Write-Host MonitoringDurationInMinutes = $MonitoringDurationInMinutes
        Write-Host SendAnonymousUsageData = $SendAnonymousUsageData
        Write-Host ExtendedValidationsEnabledForHub = $ExtendedValidationsEnabledForHub
        Write-Host ExtendedValidationsEnabledForMember = $ExtendedValidationsEnabledForMember
        Write-Host ExtendedValidationsTableFilter = $ExtendedValidationsTableFilter
        Write-Host ExtendedValidationsCommandTimeout = $ExtendedValidationsCommandTimeout
        Write-Host DumpMetadataSchemasForSyncGroup = $DumpMetadataSchemasForSyncGroup
        Write-Host DumpMetadataObjectsForTable = $DumpMetadataObjectsForTable

        if ($SendAnonymousUsageData) {
            SendAnonymousUsageData
        }

        #SyncDB
        if (($null -ne $SyncDbServer) -and ('' -ne $SyncDbServer) -and ($null -ne $SyncDbDatabase) -and ('' -ne $SyncDbDatabase)) {
            Write-Host
            Write-Host ***************** Validating Sync Metadata Database ********************** -ForegroundColor Green
            Write-Host
            $SyncDbServer = SanitizeServerName $SyncDbServer
            ValidateSyncDB
            if ($DumpMetadataSchemasForSyncGroup -ne '') {
                DumpMetadataSchemasForSyncGroup $DumpMetadataSchemasForSyncGroup
            }
        }
        else {
            Write-Host 'WARNING:SyncDbServer or SyncDbDatabase was not specified' -ForegroundColor Red
        }
    }
    Finally {
        if ($canWriteFiles) {
            Try {
                Stop-Transcript | Out-Null
            }
            Catch [System.InvalidOperationException] { }
            FilterTranscript
        }
    }

    #Hub
    $Server = SanitizeServerName $HubServer
    $Database = $HubDatabase
    $MbrUseWindowsAuthentication = $false
    $MbrUser = $HubUser
    $MbrPassword = $HubPassword
    $ExtendedValidationsEnabled = $ExtendedValidationsEnabledForHub
    if ($HealthChecksEnabled -and ($null -ne $Server) -and ($Server -ne '') -and ($null -ne $Database) -and ($Database -ne '')) {
        Try {
            if ($canWriteFiles) {
                $file = '.\_Hub_Log.txt'
                Start-Transcript -Path $file
                Write-Host '..TranscriptStart..'
            }
            Write-Host
            Write-Host ***************** Validating Hub ********************** -ForegroundColor Green
            Write-Host
            ValidateDSSMember
        }
        Catch {
            Write-Host "An error occurred:"
            Write-Host $_.Exception
            Write-Host $_.ErrorDetails
            Write-Host $_.ScriptStackTrace
        }
        Finally {
            Try {
                if ($canWriteFiles) {
                    Stop-Transcript | Out-Null
                }
            }
            Catch [System.InvalidOperationException] { }
            FilterTranscript
        }
    }

    #Member
    $Server = $MemberServer
    $Database = $MemberDatabase
    $MbrUseWindowsAuthentication = $MemberUseWindowsAuthentication
    $MbrUser = $MemberUser
    $MbrPassword = $MemberPassword
    $ExtendedValidationsEnabled = $ExtendedValidationsEnabledForMember
    if ($HealthChecksEnabled -and ($null -ne $Server) -and ($Server -ne '') -and ($null -ne $Database) -and ($Database -ne '')) {
        Try {
            if ($canWriteFiles) {
                $file = '.\_Member_Log.txt'
                Start-Transcript -Path $file
                Write-Host '..TranscriptStart..'
            }
            Write-Host
            Write-Host ***************** Validating Member ********************** -ForegroundColor Green
            Write-Host
            ValidateDSSMember
        }
        Catch {
            Write-Host "An error occurred:"
            Write-Host $_.Exception
            Write-Host $_.ErrorDetails
            Write-Host $_.ScriptStackTrace
        }
        Finally {
            Try {
                if ($canWriteFiles) {
                    Stop-Transcript | Out-Null
                }
            }
            Catch [System.InvalidOperationException] { }
            FilterTranscript
        }
    }

    #Monitor
    if ($MonitoringMode -eq 'ENABLED') {
        Try {
            if ($canWriteFiles) {
                $file = '.\_Monitoring_Log.txt'
                Start-Transcript -Path $file
                Write-Host '..TranscriptStart..'
            }
            Monitor
        }
        Catch {
            Write-Host "An error occurred:"
            Write-Host $_.Exception
            Write-Host $_.ErrorDetails
            Write-Host $_.ScriptStackTrace
        }
        Finally {
            Try {
                if ($canWriteFiles) {
                    Stop-Transcript | Out-Null
                }
            }
            Catch [System.InvalidOperationException] { }
            FilterTranscript
        }
    }

    Try {
        if ($canWriteFiles) {
            $file = '.\__SummaryReport.txt'
            Start-Transcript -Path $file
            Write-Host '..TranscriptStart..'
        }
        if ($script:errorSummaryForSyncDB -and $script:errorSummaryForSyncDB.Length -gt 0) {
            Write-Host
            Write-Host "*********************************" -Foreground Red
            Write-Host "   WARNINGS SUMMARY FOR SyncDB" -Foreground Red
            Write-Host "*********************************" -Foreground Red
            Write-Host (RemoveDoubleEmptyLines $script:errorSummaryForSyncDB.ToString()) -Foreground Red
            Write-Host
        }
        else {
            Write-Host
            Write-Host "NO ERRORS DETECTED IN THE SyncDB!"
        }
        if ($script:errorSummaryForHub -and $script:errorSummaryForHub.Length -gt 0) {
            Write-Host
            Write-Host "******************************" -Foreground Red
            Write-Host "   WARNINGS SUMMARY FOR HUB" -Foreground Red
            Write-Host "******************************" -Foreground Red
            Write-Host (RemoveDoubleEmptyLines $script:errorSummaryForHub.ToString()) -Foreground Red
            Write-Host
        }
        else {
            Write-Host
            Write-Host "NO ERRORS DETECTED IN THE HUB!"
        }
        if ($script:errorSummaryForMember -and $script:errorSummaryForMember.Length -gt 0) {
            Write-Host
            Write-Host "*********************************" -Foreground Red
            Write-Host "   WARNINGS SUMMARY FOR MEMBER" -Foreground Red
            Write-Host "*********************************" -Foreground Red
            Write-Host (RemoveDoubleEmptyLines $script:errorSummaryForMember.ToString()) -Foreground Red
            Write-Host
        }
        else {
            Write-Host
            Write-Host "NO ERRORS DETECTED IN THE MEMBER!"
            Write-Host
        }
    }
    Finally {
        Try {
            if ($canWriteFiles) {
                Stop-Transcript | Out-Null
            }
        }
        Catch [System.InvalidOperationException] { }
        FilterTranscript
    }
}
Finally {
    if ($canWriteFiles) {
        Write-Host Files can be found at (Get-Location).Path
        if ($PSVersionTable.PSVersion.Major -ge 5) {
            $destAllFiles = (Get-Location).Path + '/AllFiles.zip'
            Compress-Archive -Path (Get-Location).Path -DestinationPath $destAllFiles -Force
            Write-Host 'A zip file with all the files can be found at' $destAllFiles -ForegroundColor Yellow
        }
        if (!$isThisFromAzurePortal) {
            Invoke-Item (Get-Location).Path
        }
    }
}