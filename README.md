# Morse-Pi

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

The script will:
1. Install system packages (`python3`, `pip`, `git`, `python3-gpiozero`, `python3-lgpio`)
2. Clone this repo to `/opt/morse-pi`
3. Install Flask and dependencies to the system Python with `pip3`
4. Register and start a `systemd` service that auto-starts on boot
5. Open port 5000 in `ufw` if the firewall is active

Once complete, open your browser to the URL printed on screen, e.g.:

```
http://192.168.1.42:5000
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
sudo apt install python3-gpiozero python3-lgpio -y
sudo usermod -aG gpio $USER

# 3. Run
cd morse-translator
python3 app.py
```

Then open `http://localhost:5000` (or the Pi's IP from another device).

---

## Updating

If you used the installer:

```bash
sudo git -C /opt/morse-pi pull
sudo systemctl restart morse-pi
```

Or just re-run the install script — it will pull the latest code and restart the service automatically.

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

```bash
sudo systemctl status  morse-pi    # check if running
sudo systemctl restart morse-pi    # restart
sudo systemctl stop    morse-pi    # stop
sudo journalctl -u morse-pi -f     # live logs
```

---

## Project structure

```
Morse-Pi/
├── install.sh                  ← one-line installer for Raspberry Pi
└── morse-translator/
    ├── app.py                  ← Flask app, GPIO control, Morse timing, networking
    ├── settings.json           ← saved user settings (auto-created)
    ├── words.json              ← word list for quiz/speed modes
    └── templates/
        ├── index.html          ← single-page web UI
        └── diag.html           ← GPIO live diagnostic popup
```

---

## License

MIT — do whatever you like with it.
