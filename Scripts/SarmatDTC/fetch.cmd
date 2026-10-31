@echo off
rem SarmatDTC: downloads SARMAT map data. Usage: fetch.cmd <out dir> <base url ending with /> <fetch id>
rem Launched hidden by fetch.vbs ("cmd /c"); must keep CRLF line endings (goto/labels break with LF).
rem The files stay as status-<id>.part / units-<id>.part and the result goes to done-<fetch id>.flag
rem ("ok" or "fail <file> <curl exit code>"). SarmatDTC.lua puts the pair in place itself: a late run
rem of an earlier fetch is not taken for this one, and a half-updated pair is never read.
rem Worst case ~100 s per file (retries start within 60 s, each attempt <= 40 s): keep below
rem SarmatDTC.lua FETCH_TIMEOUT. HTTPS only (file:// is for the offline test, the base url is fixed
rem in SarmatDTC.lua), redirects only to HTTPS, at most 5 MB per file (the data is parsed on the GUI thread).
setlocal
set "OUT=%~1"
set "BASE=%~2"
set "ID=%~3"
set "CURL=%SystemRoot%\System32\curl.exe"
set "OPTS=-s -f -L --retry 2 --retry-max-time 60 --connect-timeout 15 --max-time 40 --max-filesize 5M --proto =https,file --proto-redir =https -A SarmatDTC"

set "FILE=status.json"
"%CURL%" %OPTS% -o "%OUT%\status-%ID%.part" "%BASE%status.json" || goto fail
set "FILE=units.json"
"%CURL%" %OPTS% -o "%OUT%\units-%ID%.part" "%BASE%units.json" || goto fail
>"%OUT%\done-%ID%.flag" echo ok
exit 0

:fail
set "RC=%ERRORLEVEL%"
del /Q "%OUT%\status-%ID%.part" "%OUT%\units-%ID%.part" 2>nul
>"%OUT%\done-%ID%.flag" echo fail %FILE% %RC%
exit 1
