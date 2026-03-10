# Morse-Pi

📖 **[Full Documentation](https://nerd-or-geek.github.io/Morse-Pi/)** — setup guides, usage, troubleshooting, and reference

A full-featured Morse code trainer and practice tool built with Flask, designed to run on a Raspberry Pi with a physical key or paddle. Access everything from any browser on your local network — no app to install on your phone or computer.

![Morse-Pi UI](https://img.shields.io/badge/platform-Raspberry%20Pi-red) ![Python](https://img.shields.io/badge/python-3.9%2B-blue) ![Flask](https://img.shields.io/badge/flask-3.x-lightgrey) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

| Feature | Description |
|---|---|
| **SEND mode** | Key Morse in real time and watch character-by-character decoding |
| **ENCODE** | Type any text and see the Morse equivalent instantly |
| **DECODE** | Enter dots and dashes, get the decoded text |
| **SPEED trainer** | Practice sending at a target WPM and get scored |
| **STATS** | Track accuracy, longest streak, and session history |
| **Farnsworth timing** | Stretch the gaps between letters and words independently — great for beginners |
| **Multi-Pi networking** | Discover other Morse-Pi devices on your LAN and send messages between them |
| **USB HID Keyboard** | Use your Pi as a USB keyboard — send decoded Morse directly to any computer |
| **Keyboard & on-screen keys** | Works without any hardware; `Space` = straight key, `Z`/`X` = dot/dash paddles |
| **Physical GPIO key** | Connect a real Morse key or iambic paddle via Raspberry Pi GPIO pins |
| **Configurable tones** | Adjust dot and dash frequencies, volume, and WPM from the browser |
| **Dark/light themes** | Configurable from the CONFIG panel |

---

## Hardware Requirements

A Raspberry Pi is optional — the web UI runs fine on any machine. GPIO features require a Pi.

### Minimum (software only)
- Any computer with Python 3.9+
- A modern browser on the same machine or network

### Full hardware setup (Raspberry Pi)
- Raspberry Pi (any model with 40-pin GPIO — Pi 3B+, Pi 4, Pi Zero 2 W, etc.)
- A piezo buzzer or small speaker wired to a GPIO pin
- A Morse key (straight key) **or** an iambic paddle (two-contact)

---

## GPIO Wiring

> All GPIO numbers below are **BCM** numbers (not physical pin numbers).

### Straight key (single-pin mode)
| Component | GPIO (BCM) | Physical pin | Notes |
|---|---|---|---|
| Key signal | **17** | Pin 11 | Active-low (key shorts pin to ground) |
| Key ground | GND | Pin 9 or 14 | |
| Buzzer + | **18** | Pin 12 | PWM-capable pin required |
| Buzzer − | GND | Pin 14 | |

### Iambic paddle (dual-pin mode)
| Component | GPIO (BCM) | Physical pin | Notes |
|---|---|---|---|
| Dot paddle | **22** | Pin 15 | Active-low |
| Dash paddle | **27** | Pin 13 | Active-low |
| Buzzer + | **18** | Pin 12 | |
| Buzzer − | GND | Pin 14 | |

All pin assignments are configurable in the **CONFIG** panel — no code changes needed.

```
Pi GPIO header (subset)
 ┌──────────────────────────────────┐
 │  1  3V3   │  2  5V              │
 │  3  BCM2  │  4  5V              │
 │  5  BCM3  │  6  GND  ← buzzer − │
 │  7  BCM4  │  8  BCM14           │
 │  9  GND   │ 10  BCM15           │
 │ 11  BCM17 │ 12  BCM18 ← buzzer +│  ← key (single)
 │ 13  BCM27 │ 14  GND             │  ← dash (dual)
 │ 15  BCM22 │ 16  BCM23           │  ← dot  (dual)
 └──────────────────────────────────┘
```

---

## Installation

### One-line install (Raspberry Pi OS / Debian)

```bash
curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/install.sh | sudo bash
```

The install script will:
1. **Configure USB HID keyboard gadget** — sets up the Pi to appear as a USB keyboard when plugged into a computer
2. **Install all required packages** — `python3`, `pip`, `git`, `flask`, `gpiozero`, `pigpio`
3. **Clone the repository** to `/opt/morse-pi`
4. **Set up auto-start on boot** — creates a `systemd` service so Morse-Pi runs automatically

Once complete, open your browser to the URL printed on screen, e.g.:

```
http://192.168.1.42:5000
```

---

## Auto-Start on Boot

If you used the one-line installer, Morse-Pi **automatically starts when the Pi boots** — no extra configuration needed.

The installer creates a systemd service (`morse-pi.service`) that:
- Starts the web server on boot
- Restarts automatically if it crashes
- Runs as your normal user (not root)

### Verify auto-start is working

```bash
# Check if the service is enabled (will start on boot)
sudo systemctl is-enabled morse-pi
# Should output: enabled

# Check if the service is running right now
sudo systemctl status morse-pi
```

### If auto-start isn't working

Re-run the update script to fix it:

```bash
curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/update.sh | sudo bash
```

Or manually enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable morse-pi
sudo systemctl start morse-pi
```

---

## USB HID Keyboard Mode

Morse-Pi can turn your Raspberry Pi into a **USB keyboard**. When connected to any computer via USB, the Pi appears as a standard keyboard and can send keystrokes based on decoded Morse code.

### Requirements

- **Raspberry Pi Zero, Zero W, Zero 2 W, or Pi 4** (must have USB OTG support)
- Connect the Pi to your computer using the **USB data port** (not the power-only port)
  - On Pi Zero: Use the port labeled "USB" (not "PWR")
  - On Pi 4: Use one of the USB-C or USB-A ports

### How it works

1. Key Morse code using your paddle or the on-screen keys
2. The decoded letters appear in the web UI
3. Click the **KB** tab to enable USB keyboard mode
4. Each decoded character is sent as a keystroke to the connected computer

### Setup (automatic with installer)

The installer automatically configures USB HID gadget mode:

1. Enables the `dwc2` overlay in `/boot/config.txt`
2. Loads the `dwc2` and `libcomposite` kernel modules
3. Creates `/dev/hidg0` — the USB HID device
4. Sets up a systemd service (`morse-pi-hid.service`) to configure the gadget on boot

**After installation, you must reboot for USB HID to work:**

```bash
sudo reboot
```

### Verify USB HID is working

After reboot, check that the HID device exists:

```bash
ls -la /dev/hidg0
```

You should see:
```
crw-rw-rw- 1 root root 236, 0 ... /dev/hidg0
```

Check the HID service status:

```bash
sudo systemctl status morse-pi-hid
```

### Using USB HID mode

1. Connect your Pi to a computer via USB
2. The computer should recognize it as "Morse Code Keyboard"
3. Open the Morse-Pi web UI and go to the **KB** tab
4. Enable keyboard mode
5. Open a text editor on the connected computer
6. Key Morse code — characters will be typed into the text editor

### Keyboard mode options

| Mode | Description |
|---|---|
| **Letters** | Sends decoded characters (A-Z, 0-9, punctuation) |
| **Custom** | Sends custom key codes (e.g., dot = Z, dash = X) |

### Troubleshooting USB HID

**`/dev/hidg0` doesn't exist:**
- Make sure you rebooted after installation
- Check if modules are loaded: `lsmod | grep dwc2`
- Check kernel messages: `dmesg | grep -i usb`

**Computer doesn't recognize the keyboard:**
- Use the correct USB port (data port, not power-only)
- Try a different USB cable (some are power-only)
- Check `dmesg` on the Pi for USB connection messages

**Manual USB HID setup (if automatic setup failed):**

```bash
# Enable dwc2 overlay
echo "dtoverlay=dwc2" | sudo tee -a /boot/config.txt

# Add modules
echo "dwc2" | sudo tee -a /etc/modules
echo "libcomposite" | sudo tee -a /etc/modules

# Reboot
sudo reboot
```

---

### Manual installation

```bash
# 1. Clone
git clone https://github.com/Nerd-or-Geek/Morse-Pi.git
cd Morse-Pi

# 2. Install dependencies
sudo pip3 install flask --break-system-packages

# On Raspberry Pi, also install GPIO support:
sudo apt install python3-gpiozero pigpio python3-pigpio -y
sudo systemctl enable pigpiod --now
sudo usermod -aG gpio $USER

# 3. Run
cd morse-translator
python3 app.py
```

Then open `http://localhost:5000` (or the Pi's IP from another device).

---

## Updating

Use the dedicated update script to pull the latest code:

```bash
curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/update.sh | sudo bash
```

The update script will:
1. **Verify USB HID** — ensures the HID gadget is properly configured
2. **Update all code** — pulls the latest HTML, Python, and other files from the repo
3. **Preserve your settings** — `settings.json` and `stats.json` are kept intact
4. **Ensure auto-start** — recreates the systemd service and restarts

### Update packages only

To update system and Python packages without changing application code:

```bash
curl -sSL https://raw.githubusercontent.com/Nerd-or-Geek/Morse-Pi/main/packages.sh | sudo bash
```

This upgrades `flask`, `gpiozero`, `pigpio`, and other dependencies to their latest versions, then restarts the service.

### Manual update (alternative)

```bash
sudo git -C /opt/morse-pi pull
sudo systemctl restart morse-pi
```

---

## Multi-Pi Networking

Multiple Morse-Pi devices on the same Wi-Fi or wired LAN will automatically discover each other — no configuration required.

1. Install and run Morse-Pi on two or more Raspberry Pis
2. Open the **NETWORK** tab in any browser
3. Discovered devices appear within a few seconds
4. Type a message and hit **SEND** — it arrives at the other Pi and is played as audio

Each Pi broadcasts a UDP beacon on port 5001. The receiving Pi plays the incoming message through its buzzer and adds it to the inbox.

Give each Pi a human-readable name in **CONFIG → Device Name** or directly in the NETWORK tab.

---

## Configuration

All settings are changed live from the **CONFIG** tab in the browser — no need to edit files.

| Setting | Default | Description |
|---|---|---|
| Device Name | `Morse Pi` | Name shown to other devices on the network |
| WPM | `20` | Words per minute; all timing is derived from this |
| Pin mode | `single` | `single` = straight key, `dual` = iambic paddle |
| Data pin | `17` | BCM pin for straight key |
| Dot pin | `22` | BCM pin for dot paddle |
| Dash pin | `27` | BCM pin for dash paddle |
| Speaker pin | `18` | BCM pin for buzzer (must support PWM) |
| Dot frequency | `700 Hz` | Tone pitch for dots |
| Dash frequency | `500 Hz` | Tone pitch for dashes |
| Volume | `75%` | PWM duty cycle |
| Farnsworth mode | Off | Stretch letter/word gaps independently for learners |
| Letter gap mult | `2×` | How much longer the between-letter pause is |
| Word gap mult | `2×` | How much longer the between-word pause is |

Settings are saved to `morse-translator/settings.json` and survive restarts.

---

## Keyboard Shortcuts

| Key | Action |
|---|---|
| `Space` | Straight key (hold = dash, tap = dot) |
| `Z` | Dot paddle (dual-pin mode) |
| `X` | Dash paddle (dual-pin mode) |

---

## Service management

### Main web app service

```bash
sudo systemctl status  morse-pi    # check if running
sudo systemctl restart morse-pi    # restart
sudo systemctl stop    morse-pi    # stop
sudo journalctl -u morse-pi -f     # live logs
```

### USB HID service

```bash
sudo systemctl status  morse-pi-hid    # check HID gadget status
sudo systemctl restart morse-pi-hid    # reconfigure USB gadget
```

---

## Project structure

```
Morse-Pi/
├── install.sh                  ← fresh installer (HID + packages + clone + systemd)
├── update.sh                   ← updater (verify HID + pull code + restart)
├── packages.sh                 ← package updater (upgrade apt + pip packages)
└── morse-translator/
    ├── app.py                  ← Flask app, GPIO control, Morse timing, networking
    ├── settings.json           ← saved user settings (auto-created, preserved on update)
    ├── stats.json              ← user statistics (auto-created, preserved on update)
    ├── words.json              ← word list for quiz/speed modes
    └── templates/
        ├── index.html          ← single-page web UI
        └── diag.html           ← GPIO live diagnostic popup

# Created by installer on Raspberry Pi:
/etc/systemd/system/morse-pi.service       ← main app service (auto-start on boot)
/etc/systemd/system/morse-pi-hid.service   ← USB HID gadget service
/usr/local/bin/morse-pi-hid-setup.sh       ← USB HID configuration script
/etc/udev/rules.d/99-morse-pi-hid.rules    ← udev rule for /dev/hidg0 permissions
```

---

## License

MIT — do whatever you like with it.