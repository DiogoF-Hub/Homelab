# Tailscale Windows VPN On-Demand

This folder contains a **custom automation solution** for Windows to automatically connect/disconnect Tailscale VPN based on your current network.

The **Windows Tailscale client doesn't natively support automatic connection based on network detection**, so I built this solution manually using PowerShell and Windows Task Scheduler.

---

## 📂 Structure

```
Tailscale Windows VPN on demand/
├── tailscale.ps1           # PowerShell script that detects SSID and controls Tailscale
├── tailscale-launcher.vbs  # VBScript wrapper for silent execution (no console window)
├── Task Scheduler.xml      # Windows Task Scheduler configuration
└── README.md               # This documentation
```

---

## 🎯 How It Works

1. **Network change detection**: Windows Task Scheduler monitors network profile changes (Event IDs 10000 and 10002)
2. **Silent execution**: When triggered, it runs `tailscale-launcher.vbs` (no visible window)
3. **SSID detection**: The VBScript launches `tailscale.ps1`, which checks your current WiFi SSID
4. **Automatic control**:
   - If connected to a **home network** (SSID matches your list) → Disconnect Tailscale
   - If connected to any **other network** → Connect Tailscale

This ensures you're always protected on public/external networks while avoiding unnecessary VPN overhead at home.

---

## ⚙️ Setup Instructions

### **1. Configure Your Home SSIDs**

Edit `tailscale.ps1` and update the SSID list:

```powershell
$homeSSIDs = @(
    "Your_Home_Network_SSID_1",
    "Your_Home_Network_SSID_2"
    # Add more SSIDs as needed
)
```

### **2. Place the Scripts**

Choose a permanent location for your scripts (they must not move after setup):

```
C:\Users\YourUsername\Documents\Tailscale\
├── tailscale.ps1
└── tailscale-launcher.vbs
```

### **3. Update the VBS Path**

Edit `tailscale-launcher.vbs` and update the path to `tailscale.ps1`:

```vb
objShell.Run "powershell.exe -ExecutionPolicy Bypass -File ""C:\Path\To\Your\tailscale.ps1""", 0, False
```

### **4. Update Task Scheduler XML**

Edit `Task Scheduler.xml` and update the path to `tailscale-launcher.vbs`:

```xml
<Arguments>"C:\Path\To\Your\tailscale-launcher.vbs"</Arguments>
```

### **5. Import the Scheduled Task**

1. Open **Task Scheduler** (`taskschd.msc`)
2. Click **Import Task** in the right panel
3. Select the `Task Scheduler.xml` file
4. Review the settings (paths will be automatically updated with your user info)
5. Click **OK** to create the task

### **6. Test the Setup**

Manually run the task to verify it works:

1. In Task Scheduler, find **"Tailscale VPN On Demand"**
2. Right-click → **Run**
3. Check that Tailscale connects/disconnects based on your current network

---

## 🔒 Security Notes

- The script uses `-ExecutionPolicy Bypass` to allow execution without signing
- VBScript runs with `0` window mode for silent operation
- Task runs with **HighestAvailable** privileges (required for Tailscale control)
- No sensitive data is stored in these scripts

---

## 🛠 Troubleshooting

**Task doesn't trigger automatically**:
- Verify the task is **Enabled** in Task Scheduler
- Check that Event IDs 10000 and 10002 exist in `Microsoft-Windows-NetworkProfile/Operational` log
- Ensure paths in both VBS and XML are correct and absolute

**Tailscale doesn't connect/disconnect**:
- Run `tailscale.ps1` manually in PowerShell to see output
- Verify your SSID is correctly listed in `$homeSSIDs`
- Check that Tailscale CLI is in PATH: `tailscale status`

**Script shows execution errors**:
- Ensure PowerShell execution policy allows scripts: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
- Verify Tailscale is installed and CLI is accessible

---

## 📝 How to Modify

**Add more home networks**: Just add SSIDs to the `$homeSSIDs` array in `tailscale.ps1`

**Change trigger conditions**: Edit the task in Task Scheduler to use different events or schedules

**See script output**: Remove the `0` in the VBS file (change to `1`) to see the PowerShell window during execution