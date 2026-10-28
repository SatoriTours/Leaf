# Windows entry point. Compile the verified instrumented Release producer first.
# One case per child process; no background collector and no per-frame disk IO.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$SourceSha256,
 [Parameter(Mandatory=$true)][string]$ToolchainManifest,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidateSet(100,1000,10000)][int[]]$Objects=@(100,1000,10000),
 [ValidateSet('staticFrame','properties','geometry')][string[]]$Loads=@('staticFrame','properties','geometry'),
 [ValidateRange(1,3)][int]$Repetitions=3,
 [ValidateRange(0,60000)][int]$WarmupMs=5000,
 [ValidateRange(100,120000)][int]$SampleMs=30000,
 [ValidateRange(5,300)][int]$ProcessTimeoutSeconds=90
)
$ErrorActionPreference='Stop'
if($SourceSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid verified source hash'}
if(($Objects|Select-Object -Unique).Count -ne $Objects.Count -or ($Loads|Select-Object -Unique).Count -ne $Loads.Count){throw 'Duplicate workload parameters'}
if($ProcessTimeoutSeconds*1000 -le $WarmupMs+$SampleMs){throw 'Timeout must allow startup and cleanup after the full duration'}
$toolchainBytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ToolchainManifest).Path)
if($toolchainBytes.Length -lt 1 -or $toolchainBytes.Length -gt 65536){throw 'Invalid toolchain document size'}
if($toolchainBytes.Length -ge 3 -and $toolchainBytes[0] -eq 239 -and $toolchainBytes[1] -eq 187 -and $toolchainBytes[2] -eq 191){throw 'Toolchain document must be UTF-8 without BOM'}
$toolchainJson=[Text.Encoding]::UTF8.GetString($toolchainBytes)
$toolchainDocument=$toolchainJson|ConvertFrom-Json
if($toolchainDocument.schema -ne 1 -or -not $toolchainDocument.nim_version -or -not $toolchainDocument.cc_version -or -not $toolchainDocument.flags){throw 'Incomplete toolchain document'}
$sha=[Security.Cryptography.SHA256]::Create()
try {$toolchainHash=([BitConverter]::ToString($sha.ComputeHash($toolchainBytes))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
$Executable=(Resolve-Path -LiteralPath $Executable).Path
if(Test-Path -LiteralPath $OutputDirectory){throw 'OutputDirectory must be new; existing evidence is never overwritten'}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LeafCanvasEnvironment {
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
 [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr w);
 [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr w,IntPtr dc);
 [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc,int i);
}
'@
function Public-Environment {
 $os=Get-CimInstance Win32_OperatingSystem
 $cpu=Get-CimInstance Win32_Processor
 $gpu=@(Get-CimInstance Win32_VideoController | Sort-Object Name)
 $system=Get-CimInstance Win32_ComputerSystem
 $identity=Get-CimInstance Win32_ComputerSystemProduct
 $sha=[Security.Cryptography.SHA256]::Create()
 try {$machine=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity.UUID+'|'+$env:COMPUTERNAME)))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
 $dc=[LeafCanvasEnvironment]::GetDC([IntPtr]::Zero)
 if($dc -eq [IntPtr]::Zero){throw 'Desktop DC unavailable'}
 try {$hz=[LeafCanvasEnvironment]::GetDeviceCaps($dc,116)} finally {[void][LeafCanvasEnvironment]::ReleaseDC([IntPtr]::Zero,$dc)}
 $gpuName=$null;$driver=$null
 if($gpu.Count -gt 0){$gpuName=($gpu|ForEach-Object {$_.Name}) -join ' | ';$driver=($gpu|ForEach-Object {$_.DriverVersion}) -join ' | '}
 $refresh=$null;if($hz -gt 1){$refresh=$hz}
 return [ordered]@{machine=$machine;os=($os.Caption+' '+$os.Version+' build '+$os.BuildNumber);
  cpu=(($cpu|ForEach-Object {$_.Name.Trim()+' logical='+$_.NumberOfLogicalProcessors}) -join ' | ');
  gpu=$gpuName;driver=$driver;vm=(($system.Manufacturer+' '+$system.Model) -match 'QEMU|KVM|VMware|VirtualBox|Virtual Machine|Bochs');
  remote_desktop=([LeafCanvasEnvironment]::GetSystemMetrics(0x1000) -ne 0);refresh_hz=$refresh}
}
$index=[ordered]@{schema=1;kind='leaf-canvas-run-index';stage='failed';source_sha256=$SourceSha256;
 executable_sha256=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant();
 toolchain_sha256=$toolchainHash;toolchain_json=$toolchainJson;
 warmup_ms=$WarmupMs;sample_ms=$SampleMs;environment_before=$null;environment_after=$null;entries=@()}
try {
 $index.environment_before=Public-Environment
 $environmentFile=Join-Path $OutputDirectory 'environment.json'
 [IO.File]::WriteAllText($environmentFile,($index.environment_before|ConvertTo-Json -Depth 5))
 foreach($count in $Objects){foreach($load in $Loads){for($iteration=1;$iteration -le $Repetitions;$iteration++){
  if((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() -ne $index.executable_sha256){throw 'Executable changed during collection'}
  $case=$load+'-'+$count+'-r'+$iteration
  $entry=[ordered]@{case=$case;objects=$count;load=$load;repetition=$iteration;pid=0;exit_code=$null;
   timed_out=$false;cleanup_confirmed=$false;report_sha256=$null}
  $prefix=Join-Path $OutputDirectory $case
  $arguments=@('--objects',"$count",'--load',$load,'--warmup-ms',"$WarmupMs",'--sample-ms',"$SampleMs",'--environment',$environmentFile,'--output',$prefix)
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Executable
  $info.Arguments=(($arguments|ForEach-Object {'"'+$_+'"'}) -join ' ')
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $child=[Diagnostics.Process]::new();$child.StartInfo=$info
  try {
   if(-not $child.Start()){throw 'Producer did not start'}
   $entry.pid=$child.Id
   $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
   if(-not $child.WaitForExit($ProcessTimeoutSeconds*1000)){
    $entry.timed_out=$true
    $child.Kill() # Only this owned producer; it does not spawn child processes.
    if(-not $child.WaitForExit(5000)){throw 'Owned producer termination is unconfirmed'}
   }
   $entry.cleanup_confirmed=$child.HasExited
   $entry.exit_code=$child.ExitCode
   [IO.File]::WriteAllText($prefix+'.stdout.log',$stdout.GetAwaiter().GetResult())
   [IO.File]::WriteAllText($prefix+'.stderr.log',$stderr.GetAwaiter().GetResult())
   if(Test-Path -LiteralPath ($prefix+'.json')){$entry.report_sha256=(Get-FileHash -LiteralPath ($prefix+'.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
  } finally {
   if($entry.pid -ne 0 -and -not $child.HasExited){
    $child.Kill();$entry.cleanup_confirmed=$child.WaitForExit(5000)
   }
   $child.Dispose();$index.entries+=,$entry
  }
  if($entry.exit_code -eq 0 -and $entry.report_sha256){
   $metadata=(Get-Content -LiteralPath ($prefix+'.json') -Raw|ConvertFrom-Json).metadata
   if($metadata.toolchain_sha256 -cne $toolchainHash){throw 'Producer was compiled with a different toolchain identity'}
  }
  if($entry.timed_out -or -not $entry.cleanup_confirmed -or $entry.exit_code -ne 0 -or $null -eq $entry.report_sha256){throw ('Case failed: '+$case)}
 }}}
 $index.environment_after=Public-Environment
 if(($index.environment_before|ConvertTo-Json -Compress) -cne ($index.environment_after|ConvertTo-Json -Compress)){throw 'Public environment changed'}
 $index.stage='complete'
} catch {
 $index.error=$_.Exception.Message
 throw
} finally {
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'run-index.json'),($index|ConvertTo-Json -Depth 12))
}
