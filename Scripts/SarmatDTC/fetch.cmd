@echo off
rem SarmatDTC: downloads SARMAT map data. Usage: fetch.cmd <out dir> <base url ending with /> <fetch id>
rem Launched hidden by fetch.vbs ("cmd /c"); must keep CRLF line endings (goto/labels break with LF).
rem The result goes to done-<fetch id>.flag, so a late run of an earlier fetch is not taken for this one.
rem Worst case ~100 s per file (retries start within 60 s, each attempt <= 40 s): keep below
rem SarmatDTC.lua FETCH_TIMEOUT.
setlocal
set "OUT=%~1"
set "BASE=%~2"
set "ID=%~3"
set "CURL=%SystemRoot%\System32\curl.exe"
set "OPTS=-s -f -L --retry 2 --retry-max-time 60 --connect-timeout 15 --max-time 40 -A SarmatDTC"

"%CURL%" %OPTS% -o "%OUT%\status-%ID%.part" "%BASE%status.json" || goto fail
"%CURL%" %OPTS% -o "%OUT%\units-%ID%.part" "%BASE%units.json" || goto fail
move /Y "%OUT%\status-%ID%.part" "%OUT%\status.json" >nul
move /Y "%OUT%\units-%ID%.part" "%OUT%\units.json" >nul
echo ok>"%OUT%\done-%ID%.flag"
exit 0

:fail
del /Q "%OUT%\status-%ID%.part" "%OUT%\units-%ID%.part" 2>nul
echo fail>"%OUT%\done-%ID%.flag"
exit 1
