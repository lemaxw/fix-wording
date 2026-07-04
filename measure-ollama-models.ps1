param(
    [string[]]$Models = @(
        "gpt-oss:20b",
        "llama3.1:8b-instruct-q4_K_M",
        "gemma3:12b",
        "mistral-nemo:12b"
    ),

    [string]$OllamaUrl = "http://127.0.0.1:11434/api/chat",
    [string]$OutputDir = $PSScriptRoot,
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"

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

function Convert-ModelResponseToText {
    param([string]$Text)

    $clean = $Text.Trim()
    if ($clean.Length -lt 2) {
        return $clean
    }

    try {
        $parsed = $clean | ConvertFrom-Json
        if ($parsed -is [string]) {
            return $parsed.Trim()
        }

        if ($null -ne $parsed.text -and $parsed.text -is [string]) {
            return Convert-ModelResponseToText -Text $parsed.text
        }

        if ($null -ne $parsed.text -and $parsed.text -is [System.Array]) {
            return (($parsed.text | ForEach-Object { [string]$_ }) -join "`n").Trim()
        }
    } catch {
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
                return Convert-ModelResponseToText -Text $inner
            }
        }
    }

    if ($clean.StartsWith('"') -and $clean.EndsWith('"}')) {
        $trimmed = $clean
        while ($trimmed.EndsWith("}") -and -not $trimmed.EndsWith('"}"')) {
            $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).Trim()
        }

        if ($trimmed.EndsWith('"')) {
            return Convert-ModelResponseToText -Text $trimmed
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
            return Convert-ModelResponseToText -Text $inner
        }
    }

    return $clean
}

function Get-QualityFlags {
    param(
        [string]$Raw,
        [string]$Normalized,
        [string]$Language
    )

    $flags = New-Object System.Collections.Generic.List[string]

    if ($Raw.Trim() -match '^(?i)(here|sure|certainly|improved|corrected|polished)') {
        $flags.Add("preamble")
    }

    if ($Raw -match "/think|<think|</think>") {
        $flags.Add("thinking-artifact")
    }

    if ($Language -eq "he" -and $Normalized -notmatch "[\u0590-\u05FF]") {
        $flags.Add("language-drift")
    }

    if ($Language -eq "ru" -and $Normalized -notmatch "[\u0400-\u04FF]") {
        $flags.Add("language-drift")
    }

    if ($Language -eq "es" -and $Normalized -match "\b(Hello|could|please|quickly|sure|clear)\b") {
        $flags.Add("language-drift")
    }

    if ($Language -eq "fr" -and $Normalized -match "\b(I want|this message|clearer|formal)\b") {
        $flags.Add("language-drift")
    }

    if ($Language -eq "en" -and $Normalized -match "[\u0590-\u05FF\u0400-\u04FF]") {
        $flags.Add("language-drift")
    }

    if ($Normalized.Trim() -match '^\{.+\}$|^".+\}$') {
        $flags.Add("wrapper-leak")
    }

    if ($flags.Count -eq 0) {
        return "ok"
    }

    return ($flags -join ",")
}

function Get-ResponseShape {
    param([string]$Raw)

    $clean = $Raw.Trim()
    if ($clean.StartsWith("{") -and $clean.EndsWith("}")) {
        return "json-object"
    }

    if ($clean.StartsWith('"') -and $clean.EndsWith('"')) {
        return "json-string"
    }

    if (
        ($clean.StartsWith("'") -and $clean.EndsWith("'")) -or
        ($clean.StartsWith([string][char]0x201C) -and $clean.EndsWith([string][char]0x201D)) -or
        ($clean.StartsWith([string][char]0x2018) -and $clean.EndsWith([string][char]0x2019))
    ) {
        return "wrapped-text"
    }

    return "plain"
}

function Convert-EscapedUnicode {
    param([string]$Text)

    return [System.Text.RegularExpressions.Regex]::Unescape($Text)
}

$cases = @(
    @{
        Id = "en-short"
        Language = "en"
        Mode = "polish"
        Text = "it doesnt help"
    },
    @{
        Id = "en-fragment"
        Language = "en"
        Mode = "polish"
        Text = "sometimes it retrieves fixed statement in quotes"
    },
    @{
        Id = "en-email"
        Language = "en"
        Mode = "professional"
        Text = "hi, i need the report today because customer ask me twice and i dont know what should i tell him"
    },
    @{
        Id = "en-bullets"
        Language = "en"
        Mode = "polish"
        Text = "My current email needs improvement so that it can be effectively used. I'm unsure how to make it better, but here are my goals:`n- it should be clear`n- it should be quick`n- now it doesnt work as expected"
    },
    @{
        Id = "he-short"
        Language = "he"
        Mode = "polish"
        Text = Convert-EscapedUnicode "\u05d6\u05d4 \u05dc\u05d0 \u05e2\u05d5\u05d1\u05d3 \u05d8\u05d5\u05d1 \u05d5\u05d0\u05e0\u05d9 \u05dc\u05d0 \u05d9\u05d5\u05d3\u05e2 \u05dc\u05de\u05d4"
    },
    @{
        Id = "es-short"
        Language = "es"
        Mode = "polish"
        Text = "hola, puedes revisar esto rapido porque no estoy seguro si esta claro"
    },
    @{
        Id = "fr-short"
        Language = "fr"
        Mode = "polish"
        Text = "je veux que ce message soit plus clair mais pas trop formel"
    },
    @{
        Id = "ru-short"
        Language = "ru"
        Mode = "polish"
        Text = Convert-EscapedUnicode "\u043f\u0440\u0438\u0432\u0435\u0442, \u043c\u043e\u0436\u0435\u0448\u044c \u0441\u0434\u0435\u043b\u0430\u0442\u044c \u044d\u0442\u043e \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u0435 \u043f\u043e\u043d\u044f\u0442\u043d\u0435\u0435 \u0438 \u043a\u043e\u0440\u043e\u0447\u0435"
    },
    @{
        Id = "mixed-tech"
        Language = "en"
        Mode = "fix"
        Text = "please dont change path C:\bin\fix-wording or command ollama pull gemma3:12b, only fix wording"
    }
)

$systemPrompt = New-SystemPrompt
$rows = New-Object System.Collections.Generic.List[object]

foreach ($model in $Models) {
    foreach ($case in $cases) {
        Write-Host "Running $model / $($case.Id)..."

        $bodyObject = @{
            model = $model
            messages = @(
                @{
                    role = "user"
                    content = New-WordingPrompt -Text $case.Text -SelectedMode $case.Mode
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
        $timer = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $response = Invoke-RestMethod `
                -Uri $OllamaUrl `
                -Method Post `
                -ContentType "application/json; charset=utf-8" `
                -Body $bodyBytes `
                -TimeoutSec $TimeoutSec

            $timer.Stop()
            $raw = [string]$response.message.content
            $normalized = Convert-ModelResponseToText -Text $raw
            $flags = Get-QualityFlags -Raw $raw -Normalized $normalized -Language $case.Language

            $rows.Add([pscustomobject]@{
                Model = $model
                CaseId = $case.Id
                Language = $case.Language
                Mode = $case.Mode
                Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
                RawLength = $raw.Length
                OutputLength = $normalized.Length
                Shape = Get-ResponseShape -Raw $raw
                Flags = $flags
                Input = $case.Text
                Output = $normalized
                RawOutput = $raw
            })
        } catch {
            $timer.Stop()
            $rows.Add([pscustomobject]@{
                Model = $model
                CaseId = $case.Id
                Language = $case.Language
                Mode = $case.Mode
                Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
                RawLength = 0
                OutputLength = 0
                Shape = "error"
                Flags = "error"
                Input = $case.Text
                Output = $_.Exception.Message
                RawOutput = ""
            })
        }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutputDir "ollama-model-benchmark-$timestamp.csv"
$mdPath = Join-Path $OutputDir "ollama-model-benchmark-$timestamp.md"

$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$summary = $rows |
    Group-Object Model |
    ForEach-Object {
        $modelRows = $_.Group
        $okRows = $modelRows | Where-Object { $_.Flags -ne "error" }
        [pscustomobject]@{
            Model = $_.Name
            Cases = $modelRows.Count
            AvgSeconds = [math]::Round(($okRows | Measure-Object Seconds -Average).Average, 3)
            MedianSeconds = [math]::Round((($okRows.Seconds | Sort-Object)[[math]::Floor(($okRows.Count - 1) / 2)]), 3)
            MaxSeconds = [math]::Round(($okRows | Measure-Object Seconds -Maximum).Maximum, 3)
            Issues = ($modelRows | Where-Object { $_.Flags -ne "ok" }).Count
        }
    } |
    Sort-Object AvgSeconds

$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Ollama Model Benchmark")
$markdown.Add("")
$markdown.Add("Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$markdown.Add("")
$markdown.Add("## Summary")
$markdown.Add("")
$markdown.Add("| Model | Cases | Avg seconds | Median seconds | Max seconds | Quality flags |")
$markdown.Add("| --- | ---: | ---: | ---: | ---: | ---: |")
foreach ($item in $summary) {
    $markdown.Add("| $($item.Model) | $($item.Cases) | $($item.AvgSeconds) | $($item.MedianSeconds) | $($item.MaxSeconds) | $($item.Issues) |")
}

$markdown.Add("")
$markdown.Add("## Case Results")
$markdown.Add("")
$markdown.Add("| Model | Case | Lang | Seconds | Shape | Flags | Output |")
$markdown.Add("| --- | --- | --- | ---: | --- | --- | --- |")
foreach ($row in ($rows | Sort-Object Model, CaseId)) {
    $output = (($row.Output -replace "\r?\n", "<br>") -replace "\|", "\|")
    if ($output.Length -gt 180) {
        $output = $output.Substring(0, 177) + "..."
    }
    $markdown.Add("| $($row.Model) | $($row.CaseId) | $($row.Language) | $($row.Seconds) | $($row.Shape) | $($row.Flags) | $output |")
}

$markdown | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host ""
Write-Host "Summary:"
$summary | Format-Table -AutoSize
Write-Host "CSV: $csvPath"
Write-Host "Markdown: $mdPath"
