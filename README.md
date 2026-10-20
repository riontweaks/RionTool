# Rion Tool

A Windows tweak utility for gaming PCs. It is a single PowerShell script with a WPF interface. It reads how your PC is set up, explains what each change does and what it can break, and saves original values for reversible settings.

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
- Never turns off Defender, Windows Update, Xbox services, Bluetooth, Wi-Fi or Ethernet, and leaves VBS and anti-cheat settings alone. It can still apply Safe tweaks inside those areas, such as Wi-Fi and Ethernet power saving.

**Tweaks**
- About 360 settings across services, startup apps, scheduled tasks, privacy, AI features, power, CPU scheduling, GPU, memory, storage and input.
- Each setting is labelled Safe, Moderate or Risky and shows in red what stops working.
- Settings that can lower FPS have a warning icon.
- Presets: Recommended, Gamer max, Minimal and Max.

**Hardware-aware pages**
- AMD, NVIDIA and Intel tabs only show up on PCs with that hardware.
- AMD tab: the AMD Software settings, read live from the driver. Radeon Anti-Lag, Chill, Boost, Image Sharpening, Enhanced Sync, VSync, frame rate target, anti-aliasing, anisotropic filtering, tessellation, FreeSync, VSR, GPU scaling, color depth, pixel format, GPU clocks, voltage, VRAM clock and timing, power and TDC limit, Smart Access Memory, Zero RPM and fan curve. Live GPU clocks, temperatures, board power and fan RPM. GPU and fan tuning changes undo themselves after 15 seconds unless you keep them.
- NVIDIA tab: the main NVIDIA Control Panel 3D settings (Low Latency Mode, power management, texture filtering, VSync, max frame rate, shader cache and more) written straight to the driver's global profile.
- Network adapter settings match the driver you have: Intel, Realtek, Killer, Qualcomm, MediaTek and Broadcom Ethernet and Wi-Fi.
- Power plan editor with hidden settings and a Rion plan based on Ultimate Performance (High performance or the active plan if unavailable). Its AC and battery idle timers keep the display and PC awake.

**Game settings editor**
- Valorant and Fortnite settings in plain dropdowns: resolution, window mode, FPS caps, NVIDIA Reflex, AMD Anti-Lag 2, quality levels and more.
- When a setting lives in more than one file, every copy is updated together. Valorant keeps its settings in RiotUserSettings.ini and GameUserSettings.ini.
- Finds the right Valorant account folder on its own.
- Run as administrator and Disable fullscreen optimizations for the game exe.
- Backup before every save, and one-click undo. Saves preserve encoding, spacing and line endings; undo also removes files created by that save.

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

Add `-Cleanup` to run the recommended cleanup without opening the window. It still asks for administrator rights, and the cleanup output appears in the new elevated window. When Rion opens that window through UAC, press Enter after reading the results to close it.

## Undoing changes

- Unticking a setting changed by Rion restores its saved original value. Settings with no saved original are left alone.
- Original values are saved to `C:\ProgramData\RionTool` the first time a setting is changed.
- Fixes > Undo Rion Tool changes restores recorded system settings. Use the Games tab undo button for game configuration backups.
- Create a restore point first with the button on the Home tab.

## Good to know

- Microsoft Defender: Windows 11 blocks changes to the Defender services, even for administrators. The Defender option writes the official policies. They only take effect once Tamper Protection is off.
- Game settings must be changed while the game is closed, because games write their settings back when they exit.
- AMD Software and NVIDIA 3D settings are changed through the drivers' own interfaces (AMD ADLX and NVIDIA NVAPI), so the AMD and NVIDIA apps show the same values. Rows only appear for settings your GPU and driver support. NVIDIA overclocking and fan control are not offered: NVIDIA does not publish an interface for them. Intel Graphics Software settings still have to be changed in that app. See [docs/Driver-Settings-Guide.md](docs/Driver-Settings-Guide.md) for the rest.
- NVIDIA tab: choose **Performance**, **Fortnite Potato**, or **Restore Defaults**, then **Apply profile**. The three bundled `.nip` files supply the settings; Fortnite is routed to the profile the driver associates with `FortniteClient-Win64-Shipping.exe`. Imports use merge mode and are verified afterward. Restore Defaults resets the settings in the supplied defaults file; an exact previous configuration requires the exported backup.
- Download [NVIDIA Profile Inspector 3.0.1.14 or newer](https://github.com/Orbmu2k/nvidiaProfileInspector/releases) and extract it beside `RionTool.ps1`. It is not bundled. Import stops if the backup export fails. Generated profiles go under `C:\ProgramData\RionTool\nvidia`; repository originals are kept intact.
- Home > Shortcuts and automation opens the bundled Microsoft Sysinternals `Autoruns.exe` after Windows validates its Microsoft signature.
- Fixes > Gaming and anti-cheat > **Repair Xbox app and services (Microsoft Gaming Repair Tool + reinstall)** runs the bundled Microsoft-signed `GamingRepairTool.exe`, then repairs/reinstalls Xbox, Game Bar, Gaming Services and Xbox Identity Provider. If the executable is absent, untrusted or fails, package repair still runs. WinGet and internet access are needed for package downloads.
- Install or reapply **Rion's power plan** in the Power tab to update an existing copy. New copies use Ultimate Performance, falling back to High performance or the active plan when Windows does not expose those templates. Reapplying preserves every processor setting in an existing Rion plan. Display (including lock screen), sleep, hibernate and unattended sleep idle timers are set to Never on AC and battery where Windows exposes them. Manual sleep, lid/power buttons, critical-battery protection, managed policy and screen savers remain separate. Keeping a laptop awake drains its battery; measured performance depends on the hardware.

## Screenshots

![Networking tab](docs/screenshots/networking.png)

## Disclaimer

This tool changes system settings. Cleanup permanently deletes files. Removed apps may need reinstallation, and drive decryption must be reversed manually with a recovery-key plan. Some older undo records lack enough information for automatic restoration. You use the tool at your own risk. Create a restore point before large changes.




The checks parse the application and use mocked Windows operations and temporary game files. They do not launch the app or change system settings. WPF and native Windows behavior still need verification on Windows.
