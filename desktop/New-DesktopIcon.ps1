# Copyright (c) Offline Backup Guard contributors. MIT licensed; see LICENSE.
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
Add-Type -AssemblyName System.Drawing
[void][IO.Directory]::CreateDirectory($OutputDirectory)
foreach($state in @('app','unknown','success','running','warning','error')){
    $images=@()
    foreach($size in @(16,24,32,48,64,128,256)){
        $bitmap=New-Object Drawing.Bitmap($size,$size)
        $g=[Drawing.Graphics]::FromImage($bitmap)
        $g.SmoothingMode='AntiAlias';$g.ScaleTransform(($size/256.0),($size/256.0))
        $white=[Drawing.Brushes]::White
        $body=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(32,113,111))
        $disk=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(39,49,62))
        $color=switch($state){'success'{'ForestGreen'}'running'{'DodgerBlue'}'warning'{'Goldenrod'}'error'{'Firebrick'}default{'Gray'}}
        $badge=New-Object Drawing.SolidBrush([Drawing.Color]::FromName($color))
        try{
            $g.Clear([Drawing.Color]::Transparent)
            $points=[Drawing.PointF[]]@([Drawing.PointF]::new(128,10),[Drawing.PointF]::new(233,49),[Drawing.PointF]::new(220,158),[Drawing.PointF]::new(179,212),[Drawing.PointF]::new(128,245),[Drawing.PointF]::new(77,212),[Drawing.PointF]::new(36,158),[Drawing.PointF]::new(23,49))
            $g.FillPolygon($body,$points);$g.FillRectangle($white,59,77,138,91);$g.FillRectangle($disk,70,88,116,68)
            $g.FillRectangle($white,81,100,70,8);$g.FillEllipse($white,162,134,10,10)
            if($state -ne 'app'){$g.FillEllipse($white,161,160,83,83);$g.FillEllipse($badge,168,167,69,69)}
            $stream=New-Object IO.MemoryStream;$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$images+=,@{Size=$size;Bytes=$stream.ToArray()};$stream.Dispose()
        }finally{$badge.Dispose();$disk.Dispose();$body.Dispose();$g.Dispose();$bitmap.Dispose()}
    }
    $path=Join-Path $OutputDirectory ($state+'.ico');$file=[IO.File]::Create($path);$writer=New-Object IO.BinaryWriter($file)
    try{
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$images.Count)
        $offset=6+16*$images.Count
        foreach($image in $images){$dimension=if($image.Size -eq 256){0}else{$image.Size};$writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$image.Bytes.Length);$writer.Write([uint32]$offset);$offset+=$image.Bytes.Length}
        foreach($image in $images){$writer.Write([byte[]]$image.Bytes)}
    }finally{$writer.Dispose();$file.Dispose()}
}
