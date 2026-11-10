@echo off
rem Double-click to bring a CraftGraph prices file (.cg.json) into the game,
rem or drop such a file onto this one. It only starts import-prices.ps1.
title CraftGraph: import shared prices
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0import-prices.ps1" %1
