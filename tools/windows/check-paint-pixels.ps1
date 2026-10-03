# Pixel contract for the fixed chrome paint fixtures in d3d11-cells-smoke.
# Capture the owned render window with capture-window.ps1. Client offsets are
# explicit because DPI/window chrome determine them; never assume desktop origin.
param(
  [Parameter(Mandatory=$true)][string]$ImagePath,
  [Parameter(Mandatory=$true)][int]$ClientX,
  [Parameter(Mandatory=$true)][int]$ClientY
)
Add-Type -AssemblyName System.Drawing
$paintBitmap = [System.Drawing.Bitmap]::new($ImagePath)
# name, client x/y, expected RGB; samples avoid the antialiased edge transition.
$paintSamples = @(
  @('vertical top',96,20,243,0,12),
  @('vertical middle',96,64,126,0,129),
  @('vertical bottom',96,108,9,0,246),
  @('horizontal left',196,64,248,0,7),
  @('horizontal middle',272,64,127,0,128),
  @('clipped gradient left',400,64,190,0,64),
  @('clipped gradient middle',440,64,127,0,128),
  @('transparent fill',96,150,32,32,32),
  @('opaque bottom only',96,234,0,255,0),
  @('bottom only has no left stroke',18,190,32,32,32),
  @('asymmetric left stroke',198,190,0,255,0),
  @('asymmetric left inner',202,190,238,0,17),
  @('asymmetric right stroke',350,190,0,255,0),
  @('asymmetric right inner',342,190,15,0,240),
  @('asymmetric top stroke',272,144,0,255,0),
  @('asymmetric top inner',272,148,127,0,128),
  @('asymmetric bottom stroke',272,236,0,255,0),
  @('asymmetric bottom inner',272,230,127,0,128),
  @('clip creates no left stroke',400,190,190,0,64),
  @('clip creates no right stroke',479,190,64,0,190),
  @('clipped top stroke',440,146,0,255,0),
  @('clipped bottom stroke',440,236,0,255,0),
  @('missing end is solid',96,292,255,0,0),
  @('missing end retains border',96,318,0,255,0),
  @('rounded corner exposes background',192,144,32,32,32),
  @('missing border role ignores widths',198,292,245,0,10),
  @('translucent border independent alpha',440,318,16,144,16),
  @('empty clip paints nothing',580,64,32,32,32)
)
$paintFailures = 0
try {
  foreach ($sample in $paintSamples) {
    $color = $paintBitmap.GetPixel($ClientX+$sample[1],$ClientY+$sample[2])
    if ([Math]::Abs($color.R-$sample[3]) -gt 3 -or [Math]::Abs($color.G-$sample[4]) -gt 3 -or [Math]::Abs($color.B-$sample[5]) -gt 3) {
      Write-Output "PIXEL-FAIL $($sample[0]) actual=$($color.R),$($color.G),$($color.B) expected=$($sample[3]),$($sample[4]),$($sample[5])"
      $paintFailures++
    }
  }
} finally { $paintBitmap.Dispose() }
if ($paintFailures -gt 0) { throw "Chrome paint pixel verification failed: $paintFailures samples" }
Write-Output "PAINT-PIXELS-OK samples=$($paintSamples.Count)"
