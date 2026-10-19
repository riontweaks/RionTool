# Rion Tool

A Windows tweak utility for gaming PCs. It is a single PowerShell script with a WPF interface. It reads how your PC is set up, explains what each change does and what it can break, and can undo anything it applied.

Made for Windows 11 (Windows 10 works for most features). Needs Windows PowerShell 5.1 and administrator rights.

![Games tab](docs/screenshots/games.png)

## Features

**PC health**
- Scores the PC out of 100 and lists findings in five groups: tweaks, drivers, security, maintenance and hardware.
- Flags single-channel memory, missing chipset drivers (named one by one), devices with errors, failing or worn drives, old BIOS on Ryzen fTPM systems, junk files and harmful leftovers from old tweak guides.
- Checks the services games and installers need (Windows Installer, Store install, BITS, audio, network, time, Easy Anti-Cheat, BattlEye) and the Visual C++ and DirectX runtimes, with a one-click fix for each.
- Lists harmful and placebo registry values one by one (forced TCP window, GPU timeout changes, ASLR or SEHOP off, page file off, old IRQ and kernel values), each with its own revert.
- Leaves out things you turned off on purpose, like a disabled Bluetooth radio, a Wi-Fi card without a driver on a wired PC, or Windows Update.

**One-click optimize**
- The Rion button in the bottom left ticks every Safe and Moderate gaming tweak, resets placebo tweaks and cleans junk files. You see the full list before anything changes.
- Never touches Defender, Windows Update, Xbox, Bluetooth, Wi-Fi, Ethernet or anti-cheat settings.

**Tweaks**
- About 360 settings across services, startup apps, scheduled tasks, privacy, AI features, power, CPU scheduling, GPU, memory, storage and input.
- Each setting is labelled Safe, Moderate or Risky and shows in red what stops working.
- Settings that can lower FPS have a warning icon.
- Presets: Recommended, Gamer max, Minimal and Max.

**Hardware-aware pages**
- AMD, NVIDIA and Intel tabs only show up on PCs with that hardware.
- Network adapter settings match the driver you have: Intel, Realtek, Killer, Qualcomm, MediaTek and Broadcom Ethernet and Wi-Fi.
- Power plan editor with every hidden setting, plus Rion's power plan.

**Game settings editor**
- Valorant and Fortnite settings in plain dropdowns: resolution, window mode, FPS caps, NVIDIA Reflex, AMD Anti-Lag 2, quality levels and more.
- When a setting lives in more than one file, every copy is updated together. Valorant keeps its settings in RiotUserSettings.ini and GameUserSettings.ini.
- Finds the right Valorant account folder on its own.
- Run as administrator and Disable fullscreen optimizations for the game exe.
- Backup before every save, and one-click undo.

**Cleanup and fixes**
- Temp files, update caches, error reports, driver leftovers, shader caches and launcher web caches.
- Repairs for Windows files, the Microsoft Store, Start menu search, Wi-Fi, Ethernet, Bluetooth, Xbox and anti-cheat requirements.
- One-click buttons to turn Windows Update and Microsoft Defender back on, including blocks left by other tools.

**Debloat**
- Removes preinstalled Store apps. The Store, Photos, Settings and other core apps are always kept.
- A "Not installed" list shows Microsoft apps missing from the PC. Tick one to reinstall it from local files or the Microsoft Store catalog.

**Profiles**
- Save every ticked setting to a .json file and load it on another PC to set it up the same way.

**Search**
- The search box at the top searches every tab, cleanup option and fix.

## Getting started

1. Download or clone this repository.
2. Double-click `Run-RionTool.bat`. Accept the UAC prompt.
3. Wait a few seconds for the scan, then start on the Home tab.

To run the script directly, open PowerShell in the repository folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\RionTool.ps1
```

Add `-Cleanup` to run the recommended cleanup without opening the window. It still asks for administrator rights, and the cleanup output appears in the new elevated window.

## Undoing changes

- Unticking an applied setting restores the value it had before.
- Original values are saved to `C:\ProgramData\RionTool` the first time a setting is changed.
- Fixes > Undo Rion Tool changes reverts everything at once.
- Create a restore point first with the button on the Home tab.

## Good to know

- Microsoft Defender: Windows 11 blocks changes to the Defender services, even for administrators. The Defender option writes the official policies. They only take effect once Tamper Protection is off.
- Game settings must be changed while the game is closed, because games write their settings back when they exit.
- Driver app settings (AMD Software, NVIDIA Control Panel, Intel Graphics Software) can't be set safely from outside those apps. See [docs/Driver-Settings-Guide.md](docs/Driver-Settings-Guide.md) for what to change by hand.
- NVIDIA profile options use NVIDIA Profile Inspector. The tool links to the official release page and never bundles it.

## Screenshots

![Networking tab](docs/screenshots/networking.png)

## Disclaimer

This tool changes system settings. Every change can be undone, but you use it at your own risk. Create a restore point before large changes.
