# LocalWordingFixer

LocalWordingFixer is a fully local Windows wording fixer. Select text in any app, press `Ctrl+Alt+F12`, and the listener sends the selected text to your local Ollama model, pastes the improved wording back into the original app, and restores your original text clipboard.

No cloud services are used. The default model is `mistral-nemo:12b` through Ollama at `http://127.0.0.1:11434`.

## Files

- `.gitignore` excludes runtime logs and local editor files.
- `.gitattributes` keeps script and docs line endings consistent on Windows.
- `fix-wording-listener.ps1` registers the global hotkey and copies selected text while the original application still has focus.
- `fix-wording.ps1` calls Ollama, restores focus, pastes the fixed text, and restores the original text clipboard.
- `install-startup-shortcut.ps1` creates a Startup folder shortcut.
- `stop-listener.ps1` stops a running listener.
- `fix-wording-listener.log` and `fix-wording.log` are written beside the scripts and cleared at the start of each run, unless logging is disabled.

## Start Manually

Run this from PowerShell to start the listener hidden:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\bin\fix-wording\fix-wording-listener.ps1"
```

The listener must keep running for the global hotkey to work. `-WindowStyle Hidden` hides the PowerShell host window, and the listener itself now runs without showing its small status window by default.

For debugging, you can show the small listener window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "C:\bin\fix-wording\fix-wording-listener.ps1" -ShowWindow
```

The debug window says:

```text
Local Wording Fixer Listener is running. Hotkey: Ctrl+Alt+F12
```

Closing the debug window stops that visible listener instance.

## Start With Windows

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\bin\fix-wording\install-startup-shortcut.ps1"
```

The startup shortcut target is:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\bin\fix-wording\fix-wording-listener.ps1"
```

To install the startup shortcut with logging disabled:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\bin\fix-wording\install-startup-shortcut.ps1" -DisableLogging
```

## Logging

Logging is enabled by default while testing. To disable logging for normal use, start the listener with `-DisableLogging`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\bin\fix-wording\fix-wording-listener.ps1" -DisableLogging
```

When `-DisableLogging` is used:

- `fix-wording-listener.log` is not cleared or written.
- `fix-wording.log` is not cleared or written.
- The listener passes logging-disabled mode to the worker automatically.

For troubleshooting, start the listener without `-DisableLogging`.

## Stop Listener

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\bin\fix-wording\stop-listener.ps1"
```

## Ollama Setup

Start Ollama, then pull the model:

```powershell
ollama pull mistral-nemo:12b
```

LocalWordingFixer posts to:

```text
http://127.0.0.1:11434/api/chat
```

It uses `stream: false`, `temperature: 0.2`, `num_ctx: 2048`, and a timeout of 180 seconds.

## Ollama In WSL openSUSE

You can run Ollama inside WSL and keep LocalWordingFixer on Windows. The important part is that Windows must be able to reach Ollama at:

```text
http://127.0.0.1:11434
```

In your openSUSE WSL shell, make sure `curl` is available:

```bash
sudo zypper refresh
sudo zypper install curl
```

Install Ollama using the official Linux installer:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Pull the model:

```bash
ollama pull mistral-nemo:12b
```

If systemd is enabled in your openSUSE WSL distro, Ollama usually runs as a service after install. Check it:

```bash
systemctl status ollama --no-pager
```

If the service exists but is stopped, start it:

```bash
sudo systemctl start ollama
```

If systemd is not enabled in WSL, start Ollama manually in an openSUSE WSL terminal:

```bash
ollama serve
```

From Windows PowerShell, test that Windows can reach WSL Ollama:

```powershell
Invoke-RestMethod http://127.0.0.1:11434/api/tags
```

If Windows cannot reach it, start Ollama in WSL bound to all local interfaces:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

Then test again from Windows PowerShell. Keep the `ollama serve` terminal open unless Ollama is running as a WSL systemd service.

To enable systemd in openSUSE WSL, create or edit `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then from Windows PowerShell, restart WSL:

```powershell
wsl --shutdown
```

Open openSUSE again and check:

```bash
systemctl status ollama --no-pager
```

## Clipboard Note

The original clipboard is preserved as text only. Preserving images, files, RTF, and all rich clipboard formats would require Win32 clipboard format enumeration and data handling.

When the selected text includes HTML clipboard data with links, LocalWordingFixer tries to paste the fixed text back as HTML and reapply those links. This is intentionally simple link preservation, not full formatting preservation.

## Manual Test Plan

1. Start Ollama.
2. Run `ollama pull mistral-nemo:12b`.
3. Start the listener.
4. Open Notepad.
5. Type a bad sentence.
6. Select the sentence.
7. Press `Ctrl+Alt+F12`.
8. Expected: the selected text is replaced and the original text clipboard is restored.
9. If it fails, check `fix-wording-listener.log` and `fix-wording.log`.

## Troubleshooting

If Ollama is not running, the worker shows:

```text
Ollama is not reachable at http://127.0.0.1:11434
```

If the model is missing, run:

```powershell
ollama pull mistral-nemo:12b
```
