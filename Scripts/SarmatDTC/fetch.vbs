' SarmatDTC: runs fetch.cmd hidden and returns immediately. Usage: wscript fetch.vbs <base url> [fetch id]
' Downloads go to the 'cache' folder next to this script; the result to cache\done-<fetch id>.flag.
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
id = "manual"
If WScript.Arguments.Count > 1 Then id = WScript.Arguments(1)
cmd = "cmd.exe /c """"" & dir & "fetch.cmd"" """ & dir & "cache"" """ & WScript.Arguments(0) & """ """ & id & """"""
CreateObject("WScript.Shell").Run cmd, 0, False
