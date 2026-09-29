' Copyright (c) 2026 Arron Craig
' SPDX-License-Identifier: GPL-3.0-or-later
' This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
'
' Hidden launcher for agent.ps1, used by the logon scheduled task.
' Launching powershell.exe directly with -WindowStyle Hidden is not enough on
' Windows 11: when Windows Terminal is the default terminal, the console is
' handed to a Terminal window that -WindowStyle Hidden cannot hide, and because
' the agent never exits that window stays open all session. Shell.Run with
' showWindow=0 starts powershell.exe hidden from the outset, so no console or
' Terminal window is created. Same technique as toast-callback.vbs.
'
' Waits for the agent and returns its exit code, so the task shows as Running
' while the agent is alive and the task's restart-on-failure still applies.
Option Explicit
Dim sh, fso, scriptDir, Q, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Q = Chr(34)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & _
      Q & scriptDir & "\agent.ps1" & Q
WScript.Quit sh.Run(cmd, 0, True)
