param(
    [switch]$ShowWindow,
    [switch]$DisableLogging
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$WorkerPath = Join-Path $ScriptDir "fix-wording.ps1"
$LogPath = Join-Path $ScriptDir "fix-wording-listener.log"
$LoggingEnabled = -not $DisableLogging

function Write-Log {
    param([string]$Message)

    if (-not $script:LoggingEnabled) {
        return
    }

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $LogPath -Value "$timestamp [LISTENER] $Message" -Encoding UTF8
    } catch {
        # Logging must not break the hotkey listener.
    }
}

if ($LoggingEnabled) {
    Set-Content -LiteralPath $LogPath -Value "" -Encoding UTF8
}

Write-Log "------------------------------------------------------------"
Write-Log "Listener startup"
Write-Log "Script path: $($MyInvocation.MyCommand.Path)"
Write-Log "Script dir: $ScriptDir"
Write-Log "Worker path: $WorkerPath"
Write-Log "PowerShell PID: $PID"
Write-Log "ShowWindow: $ShowWindow"
Write-Log "DisableLogging: $DisableLogging"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class LocalWordingFixerHotkeyForm : Form
{
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError=true)]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public event EventHandler HotkeyPressed;
    public event Action<string> LogMessage;

    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 12012;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const byte VK_CONTROL = 0x11;
    private const byte VK_MENU = 0x12;
    private const byte VK_F12 = 0x7B;
    private const byte VK_C = 0x43;

    public static void ReleaseHotkeyKeys()
    {
        keybd_event(VK_F12, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void SendCtrlC()
    {
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_C, 0, 0, UIntPtr.Zero);
        keybd_event(VK_C, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);

        if (LogMessage != null) {
            LogMessage("Message window handle created: " + this.Handle.ToString());
        }

        // MOD_ALT 0x0001, MOD_CONTROL 0x0002, VK_F12 0x7B
        bool ok = RegisterHotKey(this.Handle, HOTKEY_ID, 0x0001 | 0x0002, VK_F12);

        if (ok) {
            if (LogMessage != null) {
                LogMessage("Hotkey registration success: Ctrl+Alt+F12");
            }
        } else {
            int error = Marshal.GetLastWin32Error();
            if (LogMessage != null) {
                LogMessage("Hotkey registration failure. Win32 error: " + error);
            }

            MessageBox.Show(
                "Failed to register Ctrl+Alt+F12. Win32 error: " + error,
                "Local Wording Fixer",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY) {
            if (LogMessage != null) {
                LogMessage("WM_HOTKEY received");
            }

            if (HotkeyPressed != null) {
                HotkeyPressed(this, EventArgs.Empty);
            }
        }

        base.WndProc(ref m);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        UnregisterHotKey(this.Handle, HOTKEY_ID);

        if (LogMessage != null) {
            LogMessage("Hotkey unregistered");
        }

        base.OnFormClosed(e);
    }
}
"@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms,System.Drawing

function Get-ClipboardTextSafe {
    try {
        return Get-Clipboard -Raw -Format Text -ErrorAction Stop
    } catch {
        Write-Log "Clipboard read failed or no text clipboard is available: $($_.Exception.Message)"
        return $null
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
            Write-Log "Clipboard text restored. Length: $($Text.Length)"
        }
    } catch {
        Write-Log "Clipboard restore failed: $($_.Exception.Message)"
    }
}

function Write-TextFileUtf8 {
    param(
        [string]$Path,
        [AllowNull()][string]$Text
    )

    if ($null -eq $Text) {
        $Text = ""
    }

    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-ClipboardHtmlSafe {
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::Html)) {
            return [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::Html)
        }
    } catch {
        Write-Log "Clipboard HTML read failed: $($_.Exception.Message)"
    }

    return $null
}

function Get-ClipboardRtfSafe {
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::Rtf)) {
            return [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::Rtf)
        }
    } catch {
        Write-Log "Clipboard RTF read failed: $($_.Exception.Message)"
    }

    return $null
}

function Quote-Arg {
    param([string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

$script:IsBusy = $false

$form = New-Object LocalWordingFixerHotkeyForm
$form.Text = "Local Wording Fixer Listener"
$form.Width = 520
$form.Height = 130
$form.StartPosition = "CenterScreen"
$form.TopMost = $false

$label = New-Object System.Windows.Forms.Label
$label.Text = "Local Wording Fixer Listener is running. Hotkey: Ctrl+Alt+F12"
$label.Dock = "Fill"
$label.TextAlign = "MiddleCenter"
$label.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($label)

$form.add_LogMessage({
    param($msg)
    Write-Log $msg
})

$form.Add_HotkeyPressed({
    if ($script:IsBusy) {
        Write-Log "Hotkey pressed while listener is busy; ignoring"
        return
    }

    $script:IsBusy = $true

    try {
        Write-Log "Hotkey pressed"

        if (-not (Test-Path -LiteralPath $WorkerPath)) {
            Write-Log "ERROR: Worker script not found: $WorkerPath"
            [System.Windows.Forms.MessageBox]::Show(
                "Worker script not found:`r`n$WorkerPath",
                "Local Wording Fixer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        $targetHandle = [LocalWordingFixerHotkeyForm]::GetForegroundWindow()
        $targetHandleValue = $targetHandle.ToInt64()
        Write-Log "Foreground window handle captured: $targetHandleValue"

        # This first version preserves only the text clipboard. Preserving images,
        # files, HTML, RTF, and other rich formats requires Win32 clipboard format
        # enumeration, ownership, and delayed-rendering handling.
        $originalClipboard = Get-ClipboardTextSafe
        if ($null -eq $originalClipboard) {
            Write-Log "Original text clipboard length: <none>"
        } else {
            Write-Log "Original text clipboard length: $($originalClipboard.Length)"
        }

        $marker = "__LOCAL_WORDING_FIXER_COPY_MARKER__$([guid]::NewGuid().ToString('N'))"
        Write-Log "Clipboard marker: $marker"
        Set-Clipboard -Value $marker
        Start-Sleep -Milliseconds 80

        Write-Log "Releasing hotkey modifier keys before copy"
        [LocalWordingFixerHotkeyForm]::ReleaseHotkeyKeys()
        Start-Sleep -Milliseconds 30

        Write-Log "Sending Ctrl+C while original target should still have focus"
        [LocalWordingFixerHotkeyForm]::SendCtrlC()
        Start-Sleep -Milliseconds 250

        $selectedText = Get-ClipboardTextSafe
        $selectedHtml = Get-ClipboardHtmlSafe
        $selectedRtf = Get-ClipboardRtfSafe

        if ($selectedText -eq $marker) {
            Write-Log "ERROR: Clipboard still contains marker; no selected text was copied"
            Set-ClipboardTextSafe $originalClipboard

            [System.Windows.Forms.MessageBox]::Show(
                "No text was copied. Select text first, then press Ctrl+Alt+F12.",
                "Local Wording Fixer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        if ([string]::IsNullOrWhiteSpace($selectedText)) {
            Write-Log "ERROR: Selected text is empty"
            Set-ClipboardTextSafe $originalClipboard

            [System.Windows.Forms.MessageBox]::Show(
                "Selected text is empty. Select text first, then press Ctrl+Alt+F12.",
                "Local Wording Fixer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        Write-Log "Selected text length: $($selectedText.Length)"
        if ($selectedHtml) {
            Write-Log "Selected HTML clipboard length: $($selectedHtml.Length)"
        } else {
            Write-Log "Selected HTML clipboard length: <none>"
        }
        if ($selectedRtf) {
            Write-Log "Selected RTF clipboard length: $($selectedRtf.Length)"
        } else {
            Write-Log "Selected RTF clipboard length: <none>"
        }

        $runId = [guid]::NewGuid().ToString("N")
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "LocalWordingFixer"
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        $inputFile = Join-Path $tempRoot "selected-$runId.txt"
        $originalClipboardFile = Join-Path $tempRoot "clipboard-$runId.txt"
        $selectedHtmlFile = Join-Path $tempRoot "selected-$runId.html"
        $selectedRtfFile = Join-Path $tempRoot "selected-$runId.rtf"

        Write-TextFileUtf8 -Path $inputFile -Text $selectedText
        Write-TextFileUtf8 -Path $originalClipboardFile -Text $originalClipboard
        if ($selectedHtml) {
            Write-TextFileUtf8 -Path $selectedHtmlFile -Text $selectedHtml
            Write-Log "Temporary selected HTML file: $selectedHtmlFile"
        }
        if ($selectedRtf) {
            Write-TextFileUtf8 -Path $selectedRtfFile -Text $selectedRtf
            Write-Log "Temporary selected RTF file: $selectedRtfFile"
        }
        Write-Log "Temporary input file: $inputFile"
        Write-Log "Temporary original clipboard file: $originalClipboardFile"

        Write-Log "Restoring original clipboard while model is processing"
        Set-ClipboardTextSafe $originalClipboard

        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-STA",
            "-WindowStyle", "Hidden",
            "-File", (Quote-Arg $WorkerPath),
            "-InputFile", (Quote-Arg $inputFile),
            "-OriginalClipboardFile", (Quote-Arg $originalClipboardFile),
            "-TargetWindowHandle", $targetHandleValue.ToString(),
            "-Mode", "polish",
            "-Model", "mistral-nemo:12b"
        ) -join " "

        if ($selectedHtml) {
            $arguments = $arguments + " -SelectedHtmlFile " + (Quote-Arg $selectedHtmlFile)
        }
        if ($selectedRtf) {
            $arguments = $arguments + " -SelectedRtfFile " + (Quote-Arg $selectedRtfFile)
        }
        if ($DisableLogging) {
            $arguments = $arguments + " -DisableLogging"
        }

        Write-Log "Starting worker after selected text was copied"
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden
        Write-Log "Worker started"
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        try {
            if (Get-Variable -Name originalClipboard -Scope Local -ErrorAction SilentlyContinue) {
                Set-ClipboardTextSafe $originalClipboard
            }
        } catch {
            Write-Log "ERROR while trying to restore clipboard after listener failure: $($_.Exception.Message)"
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Local Wording Fixer listener error:`r`n`r`n$($_.Exception.Message)",
            "Local Wording Fixer",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $script:IsBusy = $false
    }
})

if ($ShowWindow) {
    Write-Log "Starting Windows Forms message loop with visible listener window"
    [System.Windows.Forms.Application]::Run($form)
} else {
    Write-Log "Creating hidden listener window handle"
    $form.ShowInTaskbar = $false
    $null = $form.Handle
    Write-Log "Starting Windows Forms message loop hidden"
    [System.Windows.Forms.Application]::Run()
}
Write-Log "Listener stopped"
