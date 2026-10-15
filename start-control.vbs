' web-drop: double-click me.
'
' Opens the unified control panel (scripts\Control.ps1) in a visible PowerShell
' window: start / stop the Django backend (localhost or LAN), bring up a
' Cloudflare Quick Tunnel or an ngrok tunnel, read the public URL, tail the logs
' and edit repo\.env - all from one menu.
'
' Ctrl+C inside that window, choosing "0) quit", or just closing the window
' stops everything this window started (the children live in a Windows job
' object, so the OS reclaims them even on a hard kill).
'
' Prefers PowerShell 7 (pwsh), falls back to Windows PowerShell 5.1.
Option Explicit

Dim fso, shell, here, ps1Path, psExe, candidates, candidate, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(fso.BuildPath(here, "scripts"), "Control.ps1")

If Not fso.FileExists(ps1Path) Then
  MsgBox "Cannot find scripts\Control.ps1:" & vbCrLf & ps1Path, 16, "web-drop"
  WScript.Quit 1
End If

psExe = ""
candidates = Array( _
  shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe"), _
  shell.ExpandEnvironmentStrings("%ProgramW6432%\PowerShell\7\pwsh.exe"), _
  shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"), _
  shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe") _
)
For Each candidate In candidates
  If psExe = "" Then
    If fso.FileExists(candidate) Then psExe = candidate
  End If
Next
If psExe = "" Then psExe = "powershell.exe"

' No -NoExit: the panel keeps its own window open while the menu runs, and
' closing it when the user picks "quit" is the expected behaviour.
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """"
shell.Run cmd, 1, False
