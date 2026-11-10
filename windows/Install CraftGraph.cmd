@echo off
rem Double-click this to install CraftGraph into World of Warcraft Forever.
rem It only starts install.ps1, which sits next to it and can be read in Notepad.
title CraftGraph installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 9009 (
  echo PowerShell was not found. Install by hand: copy the CraftGraph folder into
  echo   World of Warcraft\_forever_\Interface\AddOns\
  pause
)
