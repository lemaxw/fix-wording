param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OriginalClipboardFile,

    [Parameter(Mandatory = $true)]
    [string]$TargetWindowHandle,

    [string]$SelectedHtmlFile,

    [string]$SelectedRtfFile,

    [string]$Mode = "polish",
    [string]$Model,
    [string]$FallbackModel,

    [switch]$DisableLogging
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptDir "fix-wording-config.ps1")
if (-not $PSBoundParameters.ContainsKey("Model")) {
    $Model = $DefaultModel
}
if (-not $PSBoundParameters.ContainsKey("FallbackModel")) {
    $FallbackModel = $DefaultFallbackModel
}

$LogPath = Join-Path $ScriptDir "fix-wording.log"
$OllamaUrl = "http://127.0.0.1:11434/api/chat"
$PasteDelayMs = 350
$LoggingEnabled = -not $DisableLogging

function Write-Log {
    param([string]$Message)

    if (-not $script:LoggingEnabled) {
        return
    }

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $LogPath -Value "$timestamp [WORKER] $Message" -Encoding UTF8
    } catch {
        # Logging failure should never hide the real operation or error.
    }
}

if ($LoggingEnabled) {
    Set-Content -LiteralPath $LogPath -Value "" -Encoding UTF8
}

Write-Log "------------------------------------------------------------"
Write-Log "Worker startup"
Write-Log "Script path: $($MyInvocation.MyCommand.Path)"
Write-Log "InputFile: $InputFile"
Write-Log "OriginalClipboardFile: $OriginalClipboardFile"
Write-Log "TargetWindowHandle: $TargetWindowHandle"
Write-Log "SelectedHtmlFile: $SelectedHtmlFile"
Write-Log "SelectedRtfFile: $SelectedRtfFile"
Write-Log "Mode: $Mode"
Write-Log "Model: $Model"
if ([string]::IsNullOrWhiteSpace($FallbackModel)) {
    Write-Log "FallbackModel: <disabled>"
} else {
    Write-Log "FallbackModel: $FallbackModel"
}
Write-Log "DisableLogging: $DisableLogging"
Write-Log "PowerShell PID: $PID"

Add-Type -AssemblyName System.Windows.Forms

$source = @"
using System;
using System.Runtime.InteropServices;

public static class LocalWordingFixerWin32
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
"@

Add-Type -TypeDefinition $source

function Read-TextFileUtf8 {
    param([string]$Path)

    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Remove-TempFileSafe {
    param([string]$Path)

    try {
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Force
            Write-Log "Removed temp file: $Path"
        }
    } catch {
        Write-Log "Failed to remove temp file '$Path': $($_.Exception.Message)"
    }
}

function Set-ClipboardTextSafe {
    param([AllowNull()][string]$Text)

    try {
        if ($null -eq $Text) {
            [System.Windows.Forms.Clipboard]::Clear()
            Write-Log "Clipboard restored to empty text state"
        } else {
            Set-Clipboard -Value $Text
            Write-Log "Clipboard text set/restored. Length: $($Text.Length)"
        }
    } catch {
        Write-Log "Clipboard set/restore failed: $($_.Exception.Message)"
    }
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = "Local Wording Fixer",
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function New-SystemPrompt {
    return @"
You are my local wording assistant.

You improve wording conservatively.
Preserve the user's meaning exactly.
Preserve the selected text's language, structure, line breaks, bullet format, and item order.
Return only the rewritten selected text in the JSON shape requested by the user prompt.
"@
}

function New-WordingPrompt {
    param(
        [string]$Text,
        [string]$SelectedMode
    )

    $lineCount = ($Text -split "\r\n|\n|\r").Count
    $bulletCount = ([regex]::Matches($Text, "(?m)^\s*(?:[-*+]|\d+[.)])\s+")).Count
    $modeInstruction = switch ($SelectedMode) {
        "fix" { "Fix grammar, spelling, punctuation, and awkward wording only." }
        "polish" { "Improve clarity and flow while staying close to the original." }
        "professional" { "Make it clear and professional, but not too formal." }
        "short" { "Make it shorter and cleaner." }
        "explain" { "Improve the selected text only; do not explain unless the selected text asks for an explanation." }
        default { "Improve clarity and flow while staying close to the original." }
    }

    return @"
Fix wording only.
$modeInstruction
Do not translate.
Preserve meaning, line breaks, bullet markers, indentation, and item order.
The selected text has $lineCount lines and $bulletCount bullet items.
If there are bullet items, output exactly $bulletCount bullet items.
If non-bullet lines appear before a bullet list, keep them as separate non-bullet lines.
Keep each line in its original language.
English lines stay English. Russian lines stay Russian. Hebrew lines stay Hebrew.
Do not add advice, examples, notes, headings, or explanations.
Preserve names, commands, code, file paths, URLs, logs, and technical terms.
Return only JSON in this exact shape: {"text":"..."}

TEXT:
$Text
"@
}

function Remove-ModelPreamble {
    param([string]$Text)

    $clean = $Text.Trim()
    $patterns = @(
        "^\s*here(?:'s| is)\s+(?:your\s+)?(?:polished|improved|corrected|fixed|revised)?\s*text\s*:\s*(?:\r?\n)+",
        "^\s*here\s+is\s+the\s+(?:polished|improved|corrected|fixed|revised)?\s*text(?:\s+in\s+[A-Za-z]+)?\s*:\s*(?:\r?\n)+",
        "^\s*(?:polished|improved|corrected|fixed|revised)\s+text\s*:\s*(?:\r?\n)+",
        "^\s*(?:sure|certainly)\s*,?\s+(?:here(?:'s| is)\s+)?(?:your\s+)?(?:polished|improved|corrected|fixed|revised)?\s*text(?:\s+in\s+[A-Za-z]+)?\s*:\s*(?:\r?\n)+"
    )

    foreach ($pattern in $patterns) {
        $updated = [regex]::Replace($clean, $pattern, "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($updated -ne $clean) {
            Write-Log "Removed model preamble"
            return $updated.Trim()
        }
    }

    return $clean
}

function Convert-ModelJsonStringToText {
    param([string]$Text)

    $clean = $Text.Trim()
    if ($clean.Length -lt 2) {
        return $clean
    }

    try {
        $parsed = $clean | ConvertFrom-Json
        if ($parsed -is [string]) {
            Write-Log "Parsed model JSON string response"
            return $parsed.Trim()
        }

        if ($null -ne $parsed.text -and $parsed.text -is [string]) {
            Write-Log "Parsed model JSON object text response"
            return Convert-ModelJsonStringToText -Text $parsed.text
        }

        if ($null -ne $parsed.text -and $parsed.text -is [System.Array]) {
            Write-Log "Parsed model JSON object text array response"
            return (($parsed.text | ForEach-Object { [string]$_ }) -join "`n").Trim()
        }
    } catch {
        Write-Log "Model response was not a valid JSON string; trying wrapper removal"
    }

    $quotePairs = @(
        @{ Open = '"'; Close = '"' },
        @{ Open = "'"; Close = "'" },
        @{ Open = [string][char]0x201C; Close = [string][char]0x201D },
        @{ Open = [string][char]0x2018; Close = [string][char]0x2019 }
    )

    foreach ($pair in $quotePairs) {
        if ($clean.StartsWith($pair.Open) -and $clean.EndsWith($pair.Close)) {
            $inner = $clean.Substring(1, $clean.Length - 2).Trim()
            if (-not [string]::IsNullOrWhiteSpace($inner)) {
                Write-Log "Removed model response wrapper"
                return Convert-ModelJsonStringToText -Text $inner
            }
        }
    }

    if ($clean.StartsWith('"') -and $clean.EndsWith('"}')) {
        $trimmed = $clean
        while ($trimmed.EndsWith("}") -and -not $trimmed.EndsWith('"}"')) {
            $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).Trim()
        }

        if ($trimmed.EndsWith('"')) {
            Write-Log "Removed malformed trailing model JSON brace"
            return Convert-ModelJsonStringToText -Text $trimmed
        }
    }

    if ($clean.StartsWith("{") -and $clean.EndsWith("}")) {
        $inner = $clean.Substring(1, $clean.Length - 2).Trim()
        if (
            $inner.Length -ge 2 -and
            (
                ($inner.StartsWith('"') -and $inner.EndsWith('"')) -or
                ($inner.StartsWith("'") -and $inner.EndsWith("'"))
            )
        ) {
            Write-Log "Removed malformed model JSON wrapper"
            return Convert-ModelJsonStringToText -Text $inner
        }
    }

    return $clean
}

function Get-BulletItemCount {
    param([string]$Text)

    return ([regex]::Matches($Text, "(?m)^\s*(?:[-*+]|\d+[.)])\s+")).Count
}

function Test-ContainsPolishLetters {
    param([string]$Text)

    return ($Text -match "[\u0104\u0105\u0106\u0107\u0118\u0119\u0141\u0142\u0143\u0144\u00D3\u00F3\u015A\u015B\u0179\u017A\u017B\u017C]")
}

function Test-NeedsFallbackResponse {
    param(
        [string]$OriginalText,
        [string]$FixedText
    )

    $originalBulletCount = Get-BulletItemCount -Text $OriginalText
    if ($originalBulletCount -gt 0) {
        $fixedBulletCount = Get-BulletItemCount -Text $FixedText
        if ($fixedBulletCount -ne $originalBulletCount) {
            Write-Log "Fallback needed: bullet count changed from $originalBulletCount to $fixedBulletCount"
            return $true
        }
    }

    if ((-not (Test-ContainsPolishLetters -Text $OriginalText)) -and (Test-ContainsPolishLetters -Text $FixedText)) {
        Write-Log "Fallback needed: output appears to introduce Polish"
        return $true
    }

    if (($OriginalText -match "[\u0590-\u05FF]") -and ($FixedText -notmatch "[\u0590-\u05FF]")) {
        Write-Log "Fallback needed: Hebrew script disappeared"
        return $true
    }

    if (($OriginalText -match "[\u0400-\u04FF]") -and ($FixedText -notmatch "[\u0400-\u04FF]")) {
        Write-Log "Fallback needed: Cyrillic script disappeared"
        return $true
    }

    return $false
}

function Get-HtmlLinks {
    param([string]$Html)

    $links = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $links
    }

    $pattern = "<a\b[^>]*href\s*=\s*(?:""([^""]*)""|'([^']*)'|([^>\s]+))[^>]*>(.*?)</a>"
    $matches = [regex]::Matches(
        $Html,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    foreach ($match in $matches) {
        $href = $match.Groups[1].Value
        if (-not $href) { $href = $match.Groups[2].Value }
        if (-not $href) { $href = $match.Groups[3].Value }

        $innerHtml = $match.Groups[4].Value
        $text = [regex]::Replace($innerHtml, "<[^>]+>", "")
        $text = [System.Net.WebUtility]::HtmlDecode($text).Trim()

        if ($href -and $text) {
            $links.Add([pscustomobject]@{
                Text = $text
                Href = [System.Net.WebUtility]::HtmlDecode($href)
            })
        }
    }

    return $links
}

function Convert-RtfEscapedText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $decoded = [regex]::Replace($Text, "\\'([0-9a-fA-F]{2})", {
        param($m)
        [char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })

    $decoded = $decoded -replace "\\u(-?\d+)\??", {
        param($m)
        $code = [int]$m.Groups[1].Value
        if ($code -lt 0) { $code += 65536 }
        return [char]$code
    }

    $decoded = $decoded -replace "\\tab", "`t"
    $decoded = $decoded -replace "\\par[d]?", "`n"
    $decoded = $decoded -replace "\\[a-zA-Z]+\d* ?", ""
    $decoded = $decoded -replace "\\[{}\\]", {
        param($m)
        $m.Value.Substring(1)
    }
    $decoded = $decoded -replace "[{}]", ""

    return $decoded.Trim()
}

function Get-RtfLinks {
    param([string]$Rtf)

    $links = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Rtf)) {
        return $links
    }

    $pattern = "HYPERLINK\s+(?:\\l\s+)?(?:`"([^`"]+)`"|([^}\r\n]+))"
    $matches = [regex]::Matches($Rtf, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($match in $matches) {
        $href = $match.Groups[1].Value
        if (-not $href) {
            $href = ($match.Groups[2].Value -replace "\\\S+\s*", "").Trim()
        }

        if (-not $href) {
            continue
        }

        $after = $Rtf.Substring($match.Index + $match.Length)
        $resultText = $null
        $resultMatch = [regex]::Match(
            $after,
            "\\fldrslt(?:\s+|[{}\\a-zA-Z0-9*;-]+)*([^{}]+)",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($resultMatch.Success) {
            $resultText = Convert-RtfEscapedText -Text $resultMatch.Groups[1].Value
        }

        if (-not $resultText) {
            $resultText = [System.IO.Path]::GetFileNameWithoutExtension($href)
            if (-not $resultText) {
                $resultText = $href
            }
        }

        $links.Add([pscustomobject]@{
            Text = $resultText
            Href = $href.Trim()
        })
    }

    return $links
}

function Merge-Links {
    param(
        $Primary,
        $Secondary
    )

    $merged = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($collection in @($Primary, $Secondary)) {
        if ($null -eq $collection) {
            continue
        }

        foreach ($link in $collection) {
            $key = "$($link.Text)`n$($link.Href)"
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $merged.Add($link)
            }
        }
    }

    return $merged
}

function Convert-TextChunkToHtml {
    param([string]$Text)

    $escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    return ($escaped -replace "`r`n|`n|`r", "<br>`r`n")
}

function Get-HtmlFragment {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $null
    }

    $match = [regex]::Match($Html, "<!--StartFragment-->(.*)<!--EndFragment-->", [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $Html
}

function Protect-SourceHtmlMarkup {
    param(
        [string]$PlainHtml,
        [string]$SourceHtml
    )

    $fragment = Get-HtmlFragment -Html $SourceHtml
    if ([string]::IsNullOrWhiteSpace($fragment)) {
        return $PlainHtml
    }

    $result = $PlainHtml

    # Some apps store links in app-specific attributes rather than plain <a href>.
    # Preserve wrapped runs such as <span data-...>HTML</span> when the visible
    # text still appears in the model output.
    $pattern = "((?:<[^/!][^>]*>\s*)+)([^<>]+?)((?:\s*</[^>]+>)+)"
    $matches = [regex]::Matches($fragment, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $used = @{}
    $preserved = 0

    foreach ($match in $matches) {
        $openTags = $match.Groups[1].Value
        $inner = $match.Groups[2].Value
        $closeTags = $match.Groups[3].Value
        $visible = [System.Net.WebUtility]::HtmlDecode(($inner -replace "`r|`n", " ")).Trim()

        if ([string]::IsNullOrWhiteSpace($visible)) {
            continue
        }

        if ($visible.Length -lt 2) {
            continue
        }

        $key = $visible.ToLowerInvariant()
        if ($used.ContainsKey($key)) {
            continue
        }

        $escapedVisible = [System.Net.WebUtility]::HtmlEncode($visible)
        $replacement = $openTags + $escapedVisible + $closeTags
        $regexVisible = [regex]::Escape($escapedVisible)

        $updated = [regex]::Replace(
            $result,
            $regexVisible,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
            [TimeSpan]::FromSeconds(1)
        )

        if ($updated -ne $result) {
            $result = $updated
            $used[$key] = $true
            $preserved += 1
        }
    }

    Write-Log "Source HTML wrapped text runs preserved: $preserved"
    return $result
}

function Convert-FixedTextToHtmlFragment {
    param(
        [string]$Text,
        $Links
    )

    if ($null -eq $Links -or $Links.Count -eq 0) {
        return Convert-TextChunkToHtml -Text $Text
    }

    $orderedLinks = @($Links | Sort-Object { $_.Text.Length } -Descending)
    $builder = New-Object System.Text.StringBuilder
    $index = 0

    while ($index -lt $Text.Length) {
        $found = $null

        foreach ($link in $orderedLinks) {
            $linkText = [string]$link.Text
            if ([string]::IsNullOrEmpty($linkText)) {
                continue
            }

            if ($index + $linkText.Length -le $Text.Length) {
                $candidate = $Text.Substring($index, $linkText.Length)
                if ([string]::Compare($candidate, $linkText, $true, [Globalization.CultureInfo]::InvariantCulture) -eq 0) {
                    $found = [pscustomobject]@{
                        Text = $candidate
                        Href = [string]$link.Href
                    }
                    break
                }
            }
        }

        if ($found) {
            $safeHref = [System.Net.WebUtility]::HtmlEncode($found.Href)
            $safeText = Convert-TextChunkToHtml -Text $found.Text
            [void]$builder.Append('<a href="')
            [void]$builder.Append($safeHref)
            [void]$builder.Append('">')
            [void]$builder.Append($safeText)
            [void]$builder.Append('</a>')
            $index += $found.Text.Length
        } else {
            [void]$builder.Append((Convert-TextChunkToHtml -Text $Text.Substring($index, 1)))
            $index += 1
        }
    }

    return $builder.ToString()
}

function New-ClipboardHtml {
    param([string]$Fragment)

    $prefix = "<html><body><!--StartFragment-->"
    $suffix = "<!--EndFragment--></body></html>"
    $html = $prefix + $Fragment + $suffix
    $headerTemplate = "Version:0.9`r`nStartHTML:{0:0000000000}`r`nEndHTML:{1:0000000000}`r`nStartFragment:{2:0000000000}`r`nEndFragment:{3:0000000000}`r`n"
    $dummyHeader = [string]::Format($headerTemplate, 0, 0, 0, 0)

    $encoding = [System.Text.Encoding]::UTF8
    $startHtml = $encoding.GetByteCount($dummyHeader)
    $startFragment = $startHtml + $encoding.GetByteCount($prefix)
    $endFragment = $startFragment + $encoding.GetByteCount($Fragment)
    $endHtml = $startHtml + $encoding.GetByteCount($html)
    $header = [string]::Format($headerTemplate, $startHtml, $endHtml, $startFragment, $endFragment)

    return $header + $html
}

function Set-FixedClipboard {
    param(
        [string]$PlainText,
        [string]$SourceHtml,
        [string]$SourceRtf
    )

    $htmlLinks = Get-HtmlLinks -Html $SourceHtml
    $rtfLinks = Get-RtfLinks -Rtf $SourceRtf
    Write-Log "HTML links detected: $($htmlLinks.Count)"
    Write-Log "RTF links detected: $($rtfLinks.Count)"
    $links = Merge-Links -Primary $htmlLinks -Secondary $rtfLinks

    if ($links.Count -gt 0) {
        Write-Log "Total links available for preservation: $($links.Count)"
        $fragment = Convert-FixedTextToHtmlFragment -Text $PlainText -Links $links
        $clipboardHtml = New-ClipboardHtml -Fragment $fragment
        $dataObject = New-Object System.Windows.Forms.DataObject
        $dataObject.SetText($PlainText, [System.Windows.Forms.TextDataFormat]::UnicodeText)
        $dataObject.SetText($clipboardHtml, [System.Windows.Forms.TextDataFormat]::Html)
        [System.Windows.Forms.Clipboard]::SetDataObject($dataObject, $true)
        Write-Log "Fixed text placed in clipboard with HTML link preservation"
    } elseif ($SourceHtml) {
        Write-Log "No explicit links detected; trying to preserve wrapped source HTML markup"
        $fragment = Protect-SourceHtmlMarkup -PlainHtml (Convert-TextChunkToHtml -Text $PlainText) -SourceHtml $SourceHtml
        $clipboardHtml = New-ClipboardHtml -Fragment $fragment
        $dataObject = New-Object System.Windows.Forms.DataObject
        $dataObject.SetText($PlainText, [System.Windows.Forms.TextDataFormat]::UnicodeText)
        $dataObject.SetText($clipboardHtml, [System.Windows.Forms.TextDataFormat]::Html)
        [System.Windows.Forms.Clipboard]::SetDataObject($dataObject, $true)
        Write-Log "Fixed text placed in clipboard with source HTML markup preservation"
    } else {
        if ($SourceHtml -or $SourceRtf) {
            Write-Log "Rich clipboard data was present, but no links were detected"
        }
        Set-Clipboard -Value $PlainText
        Write-Log "Fixed text placed in clipboard as plain text"
    }
}

function Get-HttpErrorBody {
    param([System.Exception]$Exception)

    try {
        $response = $Exception.Response
        if ($null -eq $response) {
            return $null
        }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) {
            return $null
        }

        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } catch {
        return $null
    }
}

function Invoke-OllamaChat {
    param(
        [string]$SystemPrompt,
        [string]$Prompt,
        [string]$SelectedModel
    )

    $bodyObject = @{
        model = $SelectedModel
        messages = @(
            @{
                role = "user"
                content = $Prompt
            }
        )
        stream = $false
        options = @{
            temperature = 0.2
            num_ctx = 2048
        }
    }

    $body = $bodyObject | ConvertTo-Json -Depth 10
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    Write-Log "Ollama request start: $OllamaUrl"
    Write-Log "Ollama request model: $SelectedModel"

    try {
        $response = Invoke-RestMethod `
            -Uri $OllamaUrl `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $bodyBytes `
            -TimeoutSec 180
    } catch {
        $message = $_.Exception.Message
        $bodyText = Get-HttpErrorBody -Exception $_.Exception
        Write-Log "Ollama request failed: $message"
        if ($bodyText) {
            Write-Log "Ollama error body: $bodyText"
        }

        if ($message -match "Unable to connect|actively refused|No connection|timed out|NameResolutionFailure|ConnectFailure") {
            throw "Ollama is not reachable at http://127.0.0.1:11434"
        }

        if (($bodyText -match "model.*not.*found|not found|pull") -or ($message -match "404|not found")) {
            throw "Model '$SelectedModel' is missing. Run: ollama pull $SelectedModel"
        }

        throw
    }

    Write-Log "Ollama request end"

    if ($null -eq $response.message -or $null -eq $response.message.content) {
        Write-Log "Unexpected Ollama response shape"
        throw "Unexpected Ollama response from local Ollama."
    }

    return [string]$response.message.content
}

function Restore-Focus {
    param([Int64]$HandleValue)

    if ($HandleValue -le 0) {
        Write-Log "Target handle is zero or invalid"
        return $false
    }

    $handle = [IntPtr]::new($HandleValue)
    $ok = [LocalWordingFixerWin32]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 250
    $current = [LocalWordingFixerWin32]::GetForegroundWindow().ToInt64()

    Write-Log "SetForegroundWindow returned: $ok"
    Write-Log "Foreground after restore attempt: $current"

    return ($ok -and ($current -eq $HandleValue))
}

$originalClipboard = $null
$fixedText = $null
$selectedHtml = $null
$selectedRtf = $null

try {
    if (-not (Test-Path -LiteralPath $InputFile)) {
        throw "Input file not found: $InputFile"
    }

    if (-not (Test-Path -LiteralPath $OriginalClipboardFile)) {
        throw "Original clipboard file not found: $OriginalClipboardFile"
    }

    $selectedText = Read-TextFileUtf8 -Path $InputFile
    $originalClipboard = Read-TextFileUtf8 -Path $OriginalClipboardFile
    if ($SelectedHtmlFile -and (Test-Path -LiteralPath $SelectedHtmlFile)) {
        $selectedHtml = Read-TextFileUtf8 -Path $SelectedHtmlFile
    }
    if ($SelectedRtfFile -and (Test-Path -LiteralPath $SelectedRtfFile)) {
        $selectedRtf = Read-TextFileUtf8 -Path $SelectedRtfFile
    }

    Write-Log "Selected text length: $($selectedText.Length)"
    Write-Log "Original clipboard text length: $($originalClipboard.Length)"
    if ($selectedHtml) {
        Write-Log "Selected HTML length: $($selectedHtml.Length)"
    } else {
        Write-Log "Selected HTML length: <none>"
    }
    if ($selectedRtf) {
        Write-Log "Selected RTF length: $($selectedRtf.Length)"
    } else {
        Write-Log "Selected RTF length: <none>"
    }

    if ([string]::IsNullOrWhiteSpace($selectedText)) {
        Write-Log "Selected text is empty"
        Set-ClipboardTextSafe $originalClipboard
        Show-Message -Text "Selected text is empty. Select text first, then press Ctrl+Alt+F12." -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)
        exit 1
    }

    $systemPrompt = New-SystemPrompt
    $prompt = New-WordingPrompt -Text $selectedText -SelectedMode $Mode
    Write-Log "System prompt length: $($systemPrompt.Length)"
    Write-Log "Prompt length: $($prompt.Length)"

    $fixedText = Convert-ModelJsonStringToText -Text (Remove-ModelPreamble -Text (Invoke-OllamaChat -SystemPrompt $systemPrompt -Prompt $prompt -SelectedModel $Model))

    if (
        (-not [string]::IsNullOrWhiteSpace($FallbackModel)) -and
        (Test-NeedsFallbackResponse -OriginalText $selectedText -FixedText $fixedText) -and
        ($Model -ne $FallbackModel)
    ) {
        Write-Log "Retrying with fallback model: $FallbackModel"
        $fixedText = Convert-ModelJsonStringToText -Text (Remove-ModelPreamble -Text (Invoke-OllamaChat -SystemPrompt $systemPrompt -Prompt $prompt -SelectedModel $FallbackModel))
    }

    Write-Log "Response length: $($fixedText.Length)"

    if ([string]::IsNullOrWhiteSpace($fixedText)) {
        throw "The local model returned an empty response."
    }

    Write-Log "Putting fixed text into clipboard for paste"
    Set-FixedClipboard -PlainText $fixedText -SourceHtml $selectedHtml -SourceRtf $selectedRtf
    Start-Sleep -Milliseconds 150

    $targetHandleValue = [Int64]::Parse($TargetWindowHandle)
    $focusRestored = Restore-Focus -HandleValue $targetHandleValue

    if (-not $focusRestored) {
        Write-Log "Paste failed before SendKeys because target focus could not be restored"
        Show-Message `
            -Text "The fixed text is ready, but Local Wording Fixer could not restore focus to the original window. The fixed text has been left in the clipboard." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)
        exit 1
    }

    try {
        Write-Log "Paste action start"
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds $PasteDelayMs
        Write-Log "Paste action end"
    } catch {
        Write-Log "Paste action failed: $($_.Exception.Message)"
        Set-FixedClipboard -PlainText $fixedText -SourceHtml $selectedHtml -SourceRtf $selectedRtf
        Show-Message `
            -Text "The fixed text is ready, but paste failed. The fixed text has been left in the clipboard." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)
        exit 1
    }

    Write-Log "Clipboard restore action start"
    Set-ClipboardTextSafe $originalClipboard
    Write-Log "Clipboard restore action end"

    Remove-TempFileSafe -Path $InputFile
    Remove-TempFileSafe -Path $OriginalClipboardFile
    Remove-TempFileSafe -Path $SelectedHtmlFile
    Remove-TempFileSafe -Path $SelectedRtfFile

    Write-Log "Worker finished successfully"
    exit 0
} catch {
    $message = $_.Exception.Message
    Write-Log "ERROR: $message"

    if ($fixedText) {
        try {
            Set-FixedClipboard -PlainText $fixedText -SourceHtml $selectedHtml -SourceRtf $selectedRtf
            Write-Log "Failure occurred after fixed text was created; fixed text left in clipboard"
        } catch {
            Write-Log "Failed to leave fixed text in clipboard after error: $($_.Exception.Message)"
        }
    } elseif ($null -ne $originalClipboard) {
        Write-Log "Trying to restore original clipboard after failure"
        Set-ClipboardTextSafe $originalClipboard
    }

    $displayMessage = $message
    if ($message -match "model.*missing|model.*not.*found|not found") {
        $displayMessage = "Model '$Model' is missing. Run: ollama pull $Model"
    } elseif ($message -match "Unable to connect|actively refused|No connection|timed out|Ollama is not reachable") {
        $displayMessage = "Ollama is not reachable at http://127.0.0.1:11434"
    }

    Show-Message `
        -Text "Failed to fix wording:`r`n`r`n$displayMessage" `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)

    Write-Log "Worker finished with error"
    exit 1
}
