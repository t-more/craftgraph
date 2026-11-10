@echo off
rem Opens CraftGraph's setup page for the optional online features.
rem Needs Python 3. The addon itself works without it.
title CraftGraph setup
cd /d "%~dp0"
where py >nul 2>nul && (py -3 craftgraph_setup.py & goto done)
where python >nul 2>nul && (python craftgraph_setup.py & goto done)
echo.
echo Python 3 was not found on this computer.
echo The addon works without it. The online features (hourly prices, sharing) need it.
echo Get it free from https://www.python.org/downloads/ and tick "Add python.exe to PATH",
echo then double-click this file again.
echo.
:done
pause
