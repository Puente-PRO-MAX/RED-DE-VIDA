$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$rootPrefix = $root.TrimEnd("\") + "\"
$probe = [System.Net.HttpWebRequest]::Create("http://localhost:5500/index.html")
$probe.Timeout = 2000
$probe.Proxy = $null
$existingResponse = $null
try {
    $existingResponse = $probe.GetResponse()
} catch [System.Net.WebException] {
    if ($_.Exception.Status -ne [System.Net.WebExceptionStatus]::ConnectFailure) {
        throw
    }
}

if ($existingResponse) {
    try {
        $reader = [System.IO.StreamReader]::new($existingResponse.GetResponseStream())
        $existingPage = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $existingResponse.Close()
    }

    if ($existingPage -notmatch "<title>Red de Vida") {
        throw "El puerto 5500 ya está ocupado por otro servicio."
    }

    Write-Output "Servidor Red de Vida listo en http://localhost:5500/"
    exit 0
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:5500/")
$listener.Start()
Write-Output "Servidor Red de Vida listo en http://localhost:5500/"

$contentTypes = @{
    ".css"  = "text/css; charset=utf-8"
    ".html" = "text/html; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".mp3"  = "audio/mpeg"
    ".png"  = "image/png"
    ".wav"  = "audio/wav"
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $response = $context.Response
    $relativePath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart("/"))
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        $relativePath = "index.html"
    }

    if ($relativePath -eq "preview") {
        $trackId = $context.Request.QueryString["id"]
        $allowedTrackIds = @("1557745322", "2238153377", "2813262722", "3886148671")
        if ($allowedTrackIds -notcontains $trackId) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        $client = [System.Net.WebClient]::new()
        try {
            $track = ConvertFrom-Json -InputObject $client.DownloadString("https://api.deezer.com/track/$trackId")
            if ([string]::IsNullOrWhiteSpace($track.preview)) {
                [Console]::Error.WriteLine("Deezer no devolvió una vista previa para la pista $trackId.")
                $response.StatusCode = 502
                $response.Close()
                continue
            }
            $bytes = $client.DownloadData($track.preview)
        } catch [System.Net.WebException] {
            [Console]::Error.WriteLine("No se pudo obtener la vista previa de Deezer: $($_.Exception.Message)")
            $response.StatusCode = 502
            $response.Close()
            continue
        } finally {
            $client.Dispose()
        }

        $contentType = "audio/mpeg"
        $response.Headers.Add("Cache-Control", "no-store")
    } else {
        $filePath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath.Replace("/", "\")))
        if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
        $contentType = $contentTypes[$extension]
        if (-not $contentType) {
            $contentType = "application/octet-stream"
        }
    }

    $start = 0
    $end = $bytes.Length - 1
    $range = $context.Request.Headers["Range"]
    if ($range) {
        $match = [System.Text.RegularExpressions.Regex]::Match($range, "^bytes=(\d*)-(\d*)$")
        if (-not $match.Success -or $bytes.Length -eq 0) {
            $response.StatusCode = 416
            $response.Close()
            continue
        }

        if ($match.Groups[1].Value) {
            $start = [long]$match.Groups[1].Value
        }
        if ($match.Groups[2].Value) {
            $end = [long]$match.Groups[2].Value
        } elseif (-not $match.Groups[1].Value) {
            $response.StatusCode = 416
            $response.Close()
            continue
        }

        if (-not $match.Groups[1].Value) {
            $suffixLength = [long]$match.Groups[2].Value
            $start = [Math]::Max(0, $bytes.Length - $suffixLength)
        }
        $end = [Math]::Min($end, $bytes.Length - 1)
        if ($start -gt $end -or $start -ge $bytes.Length) {
            $response.StatusCode = 416
            $response.Close()
            continue
        }

        $response.StatusCode = 206
        $response.Headers.Add("Content-Range", "bytes $start-$end/$($bytes.Length)")
    }

    $response.ContentType = $contentType
    $response.Headers.Add("Accept-Ranges", "bytes")
    $response.ContentLength64 = $end - $start + 1
    try {
        if ($context.Request.HttpMethod -ne "HEAD") {
            $response.OutputStream.Write($bytes, [int]$start, [int]($end - $start + 1))
        }
    } catch [System.Net.HttpListenerException] {
        [Console]::Error.WriteLine("El navegador cerró la conexión de la vista previa.")
    } finally {
        $response.Close()
    }
}

$listener.Stop()
Write-Output "Servidor detenido"
