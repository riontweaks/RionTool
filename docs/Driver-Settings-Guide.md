# Manual driver app settings (AMD / NVIDIA / Intel)

These settings live inside the graphics driver apps. The AMD and NVIDIA tabs in Rion Tool can set most of them for you; use this page for the rest.

**Order of importance:**
- In-game latency tech (Reflex / Anti-Lag 2 / XeLL) is the biggest win.
- Then turn off anything that adds frames, filters or V-Sync. Keep FreeSync / G-SYNC / Adaptive Sync on if your monitor supports it.
- Everything else is small.

---

## Before any vendor: Windows and BIOS (do these first)

- **Monitor refresh rate:** Settings > System > Display > Advanced display > pick the HIGHEST refresh rate. Many PCs sit at 60 Hz by mistake.
- **Cable (desktops with a graphics card):** plug the monitor into the GRAPHICS CARD, not the motherboard. Laptops: use the port the maker says is wired to the dedicated GPU.
- **BIOS:**
  - Turn on XMP (Intel) or EXPO (AMD) so RAM runs at its rated speed.
  - Turn on Resizable BAR / Above 4G Decoding when the board supports it (AMD calls it Smart Access Memory). Intel Arc works without it but loses a lot of performance, so turn it on for Arc.
- **RAM:** two sticks in the slots the board manual says (dual channel).
- **Drivers:** install the chipset driver from AMD or Intel, and the newest graphics driver.

---

## AMD - AMD Software: Adrenalin Edition

Open AMD Software > Gaming > Graphics. Set Global Graphics, or open a game's own profile to set it per game.

| Setting | Set to | Why |
|---|---|---|
| Graphics Profile | Custom (or Esports as a start) | Esports already turns off most extras. |
| AMD Radeon Anti-Lag | ON | Driver-level input delay reduction for any game. Games that build in Anti-Lag 2 (Valorant, CS2, Fortnite) also have their own in-game Anti-Lag 2 switch: turn that on too. |
| Radeon Chill | OFF | Caps your FPS on purpose to save power. |
| Radeon Boost | OFF | Lowers resolution while you move, so enemies look blurrier. |
| Radeon Super Resolution | OFF | Upscales the whole game; only for weak GPUs. |
| Fluid Motion Frames (AFMF) | OFF for competitive | Adds fake frames and input delay. |
| Radeon Image Sharpening | Personal choice (OFF, or 50-80% if the game looks blurry) | No FPS cost to speak of. |
| Radeon Enhanced Sync | OFF | Only reduces tearing; can add stutter. |
| Wait for Vertical Refresh | Always Off (or "Off, unless application specifies") | V-Sync adds input delay. |
| Frame Rate Target Control | OFF (or set just under your refresh rate if you use FreeSync) | Uncapped = lowest delay. |
| Texture Filtering Quality | Performance | Tiny FPS gain, almost no visual change. |
| Surface Format Optimization | ON | Default; free FPS in older games. |
| Tessellation Mode | AMD Optimized | Default is fine. |
| Shader Cache | AMD Optimized | Keep it; resetting causes stutter until it rebuilds. |
| AMD FreeSync (Display tab) | ON if your monitor supports it | Smooth without V-Sync delay. |
| HYPR-RX | OFF | One button that turns on Boost + Super Resolution + Anti-Lag; set the parts yourself instead. |

**Other AMD tabs:**
- Record & Stream: turn OFF Instant Replay and the in-game overlay if you do not use them.
- Preferences: turn OFF "Notifications" and "Show Advertisements".
- Performance > Tuning: leave GPU tuning on Default unless you know how to undervolt (an undervolt usually gives higher stable clocks).

---

## NVIDIA - NVIDIA Control Panel (Manage 3D settings > Global, or Program Settings for one game)

| Setting | Set to | Why |
|---|---|---|
| Low Latency Mode | ON (Ultra only for games WITHOUT Reflex) | Fewer queued frames. In Reflex games, Reflex takes over anyway. |
| Power management mode | Prefer maximum performance | GPU does not drop clocks between frames. |
| Texture filtering - Quality | High performance | Small FPS gain. |
| Texture filtering - Anisotropic sample optimization | ON | Small FPS gain. |
| Texture filtering - Trilinear optimization | ON | Small FPS gain. |
| Threaded optimization | Auto | Default is best. |
| Vertical sync | OFF (or ON only if you use G-SYNC with an FPS cap) | V-Sync adds delay. |
| Max Frame Rate | OFF, or 3 below refresh if you use G-SYNC | Keeps G-SYNC active without V-Sync delay. |
| Shader Cache Size | Driver Default (or 10 GB / Unlimited if you play many big games) | A bigger cache means less shader-compile stutter after updates. |
| Monitor Technology | G-SYNC Compatible (if your monitor supports it) | Smooth without V-Sync delay. |
| Preferred refresh rate | Highest available | Avoids games starting at 60 Hz. |
| Image Scaling | OFF | Upscaling filter; only for weak GPUs. |

**Other NVIDIA Control Panel pages:**
- Change resolution: set Output dynamic range to match your display (Full for most PC monitors, Limited for many TVs), colour depth = highest. A mismatch makes blacks grey or crushed.
- Adjust desktop size and position: Scaling = No scaling or Aspect ratio. "Perform scaling on" = Display (only matters for stretched res).
- Set up G-SYNC: Enable for full screen mode (or windowed + full screen if you play borderless).

**NVIDIA app (or GeForce Experience):**
- Settings > Features > Overlay: turn OFF "Game Filters and Photo Mode". These were measured costing up to about 15% FPS while switched on.
- Turn OFF Instant Replay and the overlay entirely if you do not record.
- Turn OFF "Automatically optimize newly added games" so it does not change your in-game settings.

**In game:** NVIDIA Reflex = ON + Boost (Valorant, Fortnite, CS2, Apex...).

---

## Intel - Intel Graphics Software (Arc and newer iGPUs; older iGPUs use Intel Graphics Command Center)

| Setting | Set to | Why |
|---|---|---|
| Low Latency Mode | ON (On + Boost if offered) | Fewer queued frames in DirectX 9 and DirectX 11 games. DirectX 12 and Vulkan games need in-game XeLL instead. |
| Vertical Sync | Application Choice, with V-Sync OFF in game | Avoid forced V-Sync delay. |
| Smooth Sync | OFF on a FreeSync/Adaptive-Sync monitor; optional on a 60 Hz/fixed monitor | Blurs tear lines with a tiny bit of delay. |
| Adaptive Sync / VRR | ON if the monitor supports it | Smooth without V-Sync delay. |
| Frame Rate Limiter | OFF, or a few below refresh if you use VRR | Uncapped = lowest delay. |
| Endurance Gaming (laptops) | OFF / Performance when plugged in | It caps FPS to save battery. |
| Anisotropic Filtering / Anti-aliasing overrides | Application Choice | Let the game decide. |
| Power plan / Graphics power (laptops) | Maximum Performance when plugged in | Stops the iGPU downclocking. |

**Other Intel items:**
- In games that have it, turn on Intel XeLL (Xe Low Latency) for lower input delay. Turn on XeSS only if you need more FPS; it upscales.
- Intel Arc works without Resizable BAR but loses a lot of FPS, so turn it on in BIOS when the board supports it.

---

## Valorant in-game (works with all three vendors)

The Games tab can set display mode, FPS limits, Reflex / Anti-Lag 2, quality and effects, anti-aliasing, anisotropic filtering and VSync. Set **Multithreaded Rendering**, **Improve Clarity**, **Experimental Sharpening** and **Network Buffering** by hand in Valorant.

- **Display Mode:** Fullscreen.
- **Limit FPS:** Off. Or cap at a stable number if you use FreeSync/G-SYNC.
- **NVIDIA Reflex Low Latency:** On + Boost. On AMD: turn on the in-game AMD Anti-Lag 2 setting (and Radeon Anti-Lag in AMD Software).
- **Multithreaded Rendering:** ON.
- **Material / Texture / Detail / UI quality:** Low. Valorant is CPU-bound, and these barely cost FPS but add clutter.
- **Vignette, Improve Clarity, Experimental Sharpening, Bloom, Distortion, Cast Shadows:** OFF.
- **Anti-Aliasing:** None for the highest FPS (what the Games tab competitive values pick), or MSAA 2x if jagged edges bother you; it costs a little FPS. **Anisotropic Filtering:** 1x to 4x; 4x is sharper at almost no cost on modern GPUs.
- **VSync:** OFF.
- **Raw Input Buffer:** nothing to set. Since patch 11.06 it is always on and the toggle is gone.
- **Settings > General > Network Buffering:** Minimum. Raise it only if enemies teleport on a bad connection.

---

## Quick "what actually matters" summary

1. Correct refresh rate, monitor on the GPU, XMP/EXPO, dual-channel RAM, Resizable BAR.
2. In-game Reflex / Anti-Lag 2 / XeLL ON, V-Sync OFF.
3. Turn off frame-changing extras: Chill, Boost, AFMF, Super Resolution, Image Scaling, NVIDIA Game Filters.
4. Everything else gives a few FPS at most.
