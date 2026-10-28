@echo off
rem SarmatDTC: downloads SARMAT map data. Usage: fetch.cmd <out dir> <base url ending with />
rem Launched hidden by fetch.vbs ("cmd /c"); must keep CRLF line endings (goto/labels break with LF).
setlocal
set "OUT=%~1"
set "BASE=%~2"
set "CURL=%SystemRoot%\System32\curl.exe"
set "OPTS=-s -f -L --retry 2 --connect-timeout 20 --max-time 60 -A SarmatDTC"

"%CURL%" %OPTS% -o "%OUT%\status.part" "%BASE%status.json" || goto fail
"%CURL%" %OPTS% -o "%OUT%\units.part" "%BASE%units.json" || goto fail
move /Y "%OUT%\status.part" "%OUT%\status.json" >nul
move /Y "%OUT%\units.part" "%OUT%\units.json" >nul
echo ok>"%OUT%\done.flag"
exit 0

:fail
del /Q "%OUT%\status.part" "%OUT%\units.part" 2>nul
echo fail>"%OUT%\done.flag"
exit 1
