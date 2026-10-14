Add-Type -AssemblyName System.Drawing

$target = Join-Path $PSScriptRoot 'CodexUsageWidget.ico'
$bitmap = [System.Drawing.Bitmap]::new(256, 256)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::FromArgb(12, 19, 33))

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$card = New-RoundedPath 13 13 230 230 54
$g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(23, 36, 58)), $card)
$g.DrawPath([System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(99, 133, 179), 5), $card)
$g.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(81, 224, 206)), 179, 55, 22, 22)

foreach ($bar in @(@(89,118,[System.Drawing.Color]::FromArgb(81,224,206)), @(142,61,[System.Drawing.Color]::FromArgb(115,151,255)))) {
    $track = New-RoundedPath 48 $bar[0] 160 23 11
    $fill = New-RoundedPath 48 $bar[0] $bar[1] 23 11
    $g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55,69,92)), $track)
    $g.FillPath([System.Drawing.SolidBrush]::new($bar[2]), $fill)
}
$g.DrawLine([System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(143,168,202), 10), 48, 193, 154, 193)

$png = [System.IO.MemoryStream]::new()
$bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bytes = $png.ToArray()
$stream = [System.IO.File]::Open($target, [System.IO.FileMode]::Create)
$writer = [System.IO.BinaryWriter]::new($stream)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]1)
$writer.Write([Byte]0); $writer.Write([Byte]0); $writer.Write([Byte]0); $writer.Write([Byte]0)
$writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]$bytes.Length); $writer.Write([UInt32]22)
$writer.Write($bytes)
$writer.Close(); $png.Close(); $g.Dispose(); $bitmap.Dispose()
Write-Output $target
