' SarmatDTC: runs fetch.cmd hidden and returns immediately. Usage: wscript fetch.vbs <base url>
' Downloads go to the 'cache' folder next to this script.
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "cmd.exe /c """"" & dir & "fetch.cmd"" """ & dir & "cache"" """ & WScript.Arguments(0) & """"""
CreateObject("WScript.Shell").Run cmd, 0, False
