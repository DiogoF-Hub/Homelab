' Update the path below to where you stored tailscale.ps1
' Example: "C:\Users\YourUsername\Documents\tailscale.ps1"
Set objShell = CreateObject("Wscript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -File ""C:\Path\To\Your\tailscale.ps1""", 0, False
