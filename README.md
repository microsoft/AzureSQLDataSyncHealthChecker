# Azure SQL Data Sync Health Checker

This PowerShell script will check if all the metadata of a hub and member is in place and also validate the scopes against the information we have on the sync metadata database (among other validations). 
This script will not make any changes, will just validate data sync and user objects. 
It will also gather some useful information for faster troubleshooting during a support request.

**In order to run it you need to:**
1. Open Windows PowerShell ISE
 
2. Open a New Script window
 
3. Paste the following in the script window (please note that, except databases and credentials, the other parameters are optional):

```powershell
$parameters = @{
    ## Databases and credentials
    # Sync metadata database credentials (Only SQL Authentication is supported)
    SyncDbServer = '.database.windows.net'
    SyncDbDatabase = ''
    SyncDbUser = ''
    SyncDbPassword = ''

    # Hub credentials (Only SQL Authentication is supported)
    HubServer = '.database.windows.net'
    HubDatabase = ''
    HubUser = ''
    HubPassword = ''

    # Member credentials (Azure SQL DB or SQL Server)
    MemberServer = ''
    MemberDatabase = ''
    MemberUser = ''
    MemberPassword = ''
    # set MemberUseWindowsAuthentication to $true in case you wish to use integrated Windows authentication (MemberUser and MemberPassword will be ignored)
    MemberUseWindowsAuthentication = $false

    ## Optional parameters (default values will be used if ommited)

    ## Health checks
    HealthChecksEnabled = $true  #Set as $true (default) or $false

    ## Monitoring
    MonitoringMode = 'AUTO'  #Set as AUTO (default), ENABLED or DISABLED
    MonitoringIntervalInSeconds = 20
    MonitoringDurationInMinutes = 2

    ## Tracking Record Validations
    ExtendedValidationsTableFilter = @('All')  #Set as "All" or the tables you need using '[dbo].[TableName1]','[dbo].[TableName2]'
    ExtendedValidationsEnabledForHub = $false  #Set as $true or $false (default)
    ExtendedValidationsEnabledForMember = $false  #Set as $true or $false (default)
    ExtendedValidationsCommandTimeout = 900 #seconds (default)

    ## Other
    SendAnonymousUsageData = $true  #Set as $true (default) or $false
    DumpMetadataSchemasForSyncGroup = '' #leave empty for automatic detection
    DumpMetadataObjectsForTable = '' #needs to be formatted like [SchemaName].[TableName]
}
 
$scriptUrlBase = 'https://raw.githubusercontent.com/Microsoft/AzureSQLDataSyncHealthChecker/master'
Invoke-Command -ScriptBlock ([Scriptblock]::Create((iwr ($scriptUrlBase+'/AzureSQLDataSyncHealthChecker.ps1')).Content)) -ArgumentList $parameters
#end
```
4. Set the parameters on the script, you need to set server names, database names, users and passwords.

5. Run it.

6. The major results can be seen in the output window. 
If the user has the permissions to create folders, a folder with all the resulting files will be created.
When running on Windows, the folder will be opened automatically after the script completes.
When running on Azure Portal Cloud Shell the files will be stored in the file share (clouddrive).
A zip file with all the files (AllFiles.zip) will be created.

## Roadmap
1. Detect issues and export action plans automatically is the next major goal.


## Data / Telemetry

This project collects usage data and sends it to Microsoft to help improve our products and services.
Read our [privacy statement](https://go.microsoft.com/fwlink/?LinkId=521839) to learn more.
Telemetry can be disabled by setting the parameter SendAnonymousUsageData = $false (default value is $true).


## Reporting Security Issues

Security issues and bugs should be reported privately, via email, to the Microsoft Security
Response Center (MSRC) at [secure@microsoft.com](mailto:secure@microsoft.com). You should
receive a response within 24 hours. If for some reason you do not, please follow up via
email to ensure we received your original message. Further information, including the
[MSRC PGP](https://technet.microsoft.com/en-us/security/dn606155) key, can be found in
the [Security TechCenter](https://technet.microsoft.com/en-us/security/default).


## License

Copyright (c) Microsoft Corporation. All rights reserved.

Licensed under the [MIT License](./LICENSE).