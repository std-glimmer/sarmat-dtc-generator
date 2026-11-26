' SarmatDTC: runs fetch.cmd hidden and returns immediately.
' Usage: wscript fetch.vbs <base url> [fetch id] [URL-encoded website code]
' Downloads go to the 'cache' folder next to this script; the result to cache\done-<fetch id>.flag.
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
id = "manual"
code = ""
If WScript.Arguments.Count > 1 Then id = WScript.Arguments(1)
If WScript.Arguments.Count > 2 Then code = WScript.Arguments(2)
cmd = "cmd.exe /c """"" & dir & "fetch.cmd"" """ & dir & "cache"" """ & WScript.Arguments(0) & """ """ & id & """ """ & code & """"""
CreateObject("WScript.Shell").Run cmd, 0, False
