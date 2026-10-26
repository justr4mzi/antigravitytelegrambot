@echo off
title Antigravity Telegram Remote Bot
color 0B
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bot.ps1" %*
pause
