@echo off
title Rion Tool
rem Launches RionTool.ps1 from the same folder. The script self-elevates to
rem Administrator via UAC if it is not already elevated.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RionTool.ps1"
 