# Capture ONLY the maru D3D11 render window. Never the whole desktop, never the console window.
#
# Targeting history - this matters, the harness was wrong once:
#   1. FindWindowW(class) returned 0 in this environment.
#   2. Process.MainWindowHandle "worked" until it grabbed the CONSOLE window instead. A console
#      subsystem app owns two top-level windows, and the console exists BEFORE the D3D11 window,
#      so MainWindowHandle can settle on it. That produced a black screenshot that looked plausible.
#   3. Now: enumerate every visible top-level window owned by a maru process and keep the one whose
#      class is exactly the render window class. Class is the only thing that separates them.
#
# D3D11 windows can come back black via plain PrintWindow, so try PW_RENDERFULLCONTENT(2) first and
# fall back to BitBlt of the window rect. Always print which path was used and the class - a silent
# fallback would make "captured" a lie.
param(
  [string]$OutPath,
  [string]$ClassName = "MaruWindowClass",
  [string]$ProcName = "maru",
  [int]$TimeoutMs = 20000
)

Add-Type -AssemblyName System.Drawing
$sig = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Cap {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  public static List<string> Windows(int[] pids) {
    var found = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      int wpid; GetWindowThreadProcessId(h, out wpid);
      if (Array.IndexOf(pids, wpid) < 0) return true;
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
      found.Add(h.ToInt64() + "|" + sb.ToString());
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
Add-Type -TypeDefinition $sig

$sw = [Diagnostics.Stopwatch]::StartNew()
$h = [IntPtr]::Zero
$seen = @()
while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
  $pids = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  if ($pids.Count -gt 0) {
    $seen = [Cap]::Windows($pids)
    foreach ($row in $seen) {
      $parts = $row.Split('|')
      if ($parts[1] -eq $ClassName) { $h = [IntPtr][int64]$parts[0]; break }
    }
  }
  if ($h -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 150
}
if ($h -eq [IntPtr]::Zero) {
  Write-Output "CAPTURE-FAIL: no window of class '$ClassName' on any '$ProcName' process"
  if ($seen.Count -gt 0) { Write-Output ("  windows seen: " + ($seen -join ", ")) }
  exit 1
}

$r = New-Object Cap+RECT
[void][Cap]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L
$ht = $r.B - $r.T
if ($w -le 0 -or $ht -le 0) { Write-Output "CAPTURE-FAIL: window size ${w}x${ht}"; exit 1 }

# Sample the INTERIOR only. Sampling the whole bitmap counts title bar and border pixels, so a
# blank client area still scored 6 distinct colors and sailed past a "<= 2 is flat" check - that is
# exactly how this harness once reported a blank window as a successful capture.
function Get-DistinctSample($bmp) {
  $seenc = @{}
  $top = [Math]::Min(48, [int]($bmp.Height / 4))   # skip the title bar
  $pad = [Math]::Min(12, [int]($bmp.Width / 8))    # skip the frame
  $stepY = [Math]::Max(1, [int]($bmp.Height / 60))
  $stepX = [Math]::Max(1, [int]($bmp.Width / 60))
  for ($y = $top; $y -lt ($bmp.Height - $pad); $y += $stepY) {
    for ($x = $pad; $x -lt ($bmp.Width - $pad); $x += $stepX) {
      $seenc[$bmp.GetPixel($x, $y).ToArgb()] = $true
    }
  }
  return $seenc.Count
}

# The window exists before anything is drawn (the scan runs first), so capturing on first sight
# yields a blank frame. Retry until the interior actually has content, with a deadline.
$bmp = $null
$colors = 0
$how = "PrintWindow(PW_RENDERFULLCONTENT)"
$ok = $false
$deadline = [Diagnostics.Stopwatch]::StartNew()
while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
  if ($bmp) { $bmp.Dispose() }
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = [Cap]::PrintWindow($h, $hdc, 2)
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  $colors = Get-DistinctSample $bmp
  if ($ok -and $colors -gt 2) { break }
  Start-Sleep -Milliseconds 200
}

if ((-not $ok) -or ($colors -le 2)) {
  $bmp.Dispose()
  [void][Cap]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 700
  [void][Cap]::GetWindowRect($h, [ref]$r)
  $w = $r.R - $r.L
  $ht = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
  $g.Dispose()
  $colors = Get-DistinctSample $bmp
  $how = "BitBlt(window rect from screen)"
}

$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "CAPTURE-OK path=$OutPath class=$ClassName size=${w}x${ht} how=$how distinct_colors=$colors"
if ($colors -le 2) { Write-Output "CAPTURE-WARN: effectively flat - nothing may have been drawn" }
