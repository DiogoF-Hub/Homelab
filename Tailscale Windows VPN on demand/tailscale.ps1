# Update this array with your home network SSIDs (add as many as needed)
$homeSSIDs = @(
    "Your_Home_Network_SSID_1",
    "Your_Home_Network_SSID_2"
    # Add more SSIDs as needed
)

$currentSSID = (netsh wlan show interfaces) | ForEach-Object {
    if ($_ -match "^\s+SSID\s+:\s+(.*)$") {
        $matches[1].Trim()
    }
}

Write-Output "Current SSID: '$currentSSID'"

$tailscaleStatus = tailscale status 2>&1
Write-Output "Tailscale Status: $tailscaleStatus"

if ($homeSSIDs -contains $currentSSID) {
    Write-Output "On home network. Disconnecting Tailscale..."
    tailscale down
}
else {
    Write-Output "Not on home network. Connecting Tailscale..."
    tailscale up
}
