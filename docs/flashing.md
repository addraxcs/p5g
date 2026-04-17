# Flashing the Pi

---

## Which OS to use

**Raspberry Pi OS Lite (Bookworm)** - no desktop, headless.

**Recommended: Raspberry Pi 4.** It has full-size USB-A ports for the dongle, a dedicated ethernet port for the management interface, and enough RAM to run everything comfortably. The Pi 3B+ works but is slower. Pi Zero models are not suitable - they lack a USB-A port and ethernet.

| Model | Build to use |
|---|---|
| Pi 4 (recommended) | 32-bit or 64-bit - both work |
| Pi 5 | 32-bit or 64-bit - both work |
| Pi 3B / 3B+ | 32-bit or 64-bit - both work |
| Pi Zero / Zero W | Not recommended - no USB-A or ethernet |

---

## What you need

- SD card (16GB+, Class 10 or A1 rated)
- SD card reader (built-in or USB)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installed on your Mac or Linux machine

---

## Step-by-step

### 1. Open Raspberry Pi Imager

Launch Imager. You will see three dropdowns: Device, OS, Storage.

### 2. Choose Device

Click **Choose Device** and select your Pi model. This filters the OS list to compatible builds.

### 3. Choose OS

Click **Choose OS**:

```
Raspberry Pi OS (other)
  -> Raspberry Pi OS Lite (32-bit)   <-- works on all supported models, more widely available
  -> Raspberry Pi OS Lite (64-bit)   <-- also fine if you prefer it
```

Select Lite - not the full desktop version. This router runs headless.

### 4. Choose Storage

Click **Choose Storage** and select your SD card. Double-check the size - do not select your laptop drive.

### 5. Open advanced settings

Click **Next**. Imager will ask "Would you like to apply OS customisation settings?" - click **Edit Settings**.

Fill in:

| Setting | Value |
|---|---|
| Hostname | anything you like, e.g. `p5r` |
| Enable SSH | checked - Use password authentication |
| Username | your choice, e.g. `pi` |
| Password | set a strong password |
| Configure wifi | optional - only needed if you want the Pi on your wifi before eth0 is set up |
| Locale / timezone | set to your region |

Click **Save**, then **Yes** to apply.

### 6. Flash

Click **Yes** to confirm. Imager will write and verify the image. Takes 2-5 minutes depending on your card.

### 7. Eject and insert

Safely eject the SD card. Insert it into the Pi.

---

## First boot

Plug in the Pi to your LAN via the ethernet port and Power the Pi. Wait 30-60 seconds for first boot to complete (it expands the filesystem and applies settings on first run).

Find the Pi's IP from your router's DHCP table, or use:

```sh
# macOS
dns-sd -B _ssh._tcp .

# Linux
avahi-browse -t _ssh._tcp

# macOS or Linux (fallback)
arp -a | grep p5r
```

Connect over SSH:

```sh
ssh <username>@<pi-ip>
```

If SSH times out, wait another 30 seconds and retry. First boot is slower than subsequent boots.

---

Once SSH works, return to [setup.md](setup.md) and continue from Step 2.
