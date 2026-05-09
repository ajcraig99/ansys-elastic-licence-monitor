' Copyright (c) 2026 Arron Craig
' SPDX-License-Identifier: GPL-3.0-or-later
' This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
'
' Hidden launcher for toast-callback.ps1.
' wscript.exe runs this file without a visible window, then Shell.Run with
' showWindow=0 spawns powershell.exe also windowless. End result is a click
' handler that runs invisibly.
Option Explicit
Dim sh, fso, scriptDir, arg, Q, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
arg = ""
If WScript.Arguments.Count > 0 Then arg = WScript.Arguments(0)
Q = Chr(34)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & _
      Q & scriptDir & "\toast-callback.ps1" & Q & " " & Q & arg & Q
sh.Run cmd, 0, False
