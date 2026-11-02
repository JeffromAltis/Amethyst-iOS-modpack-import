# Instance icons

The built-in icons an instance can use (the icon picker) come from Prism Launcher.

## Source and licence
- Project: https://github.com/PrismLauncher/PrismLauncher (GPL-3.0, same as this app).
- Files: `launcher/resources/multimc/scalable/instances/*.svg`, pinned at commit
  `6e6f81779a2f32fd98550004051ec834cf4c5e30` (the Prism `develop` branch on 2026-11-02).
- Every SVG lists "Prism Launcher" as its creator in its metadata. Prism's `COPYING.md` has no separate licence
  entry for these icons, so the project licence (GPL-3.0) is the basis for reusing them. (This is not legal advice.)
- Not used on purpose: Prism's "Batch" toolbar icon set (its licence forbids hosting the icon set), the
  17 legacy PNG icons (unclear origin), and the logos of other projects (fabricmc, quiltmc, neoforged, modrinth,
  ftb_logo, prismlauncher).
- Several icons are Minecraft-themed fan artwork (creeper, steve, enderman, herobrine ...). Minecraft is a trademark
  of Mojang AB / Microsoft.

## The 24 icons
bee, brick, chicken, creeper, diamond, dirt, enderman, enderpearl, flame, fox, gear, gold, grass, herobrine,
iron, magitech, meat, netherstar, planks, skeleton, squarecreeper, steve, stone, tnt.

## Files
- `scripts/instance-icons/src/*.svg`: the original vector files (not shipped in the app).
- `scripts/instance-icons/render.sh [size]`: renders them to `Natives/resources/InstanceIcons/*.png` (default
  512x512). The icons are vectors, so any size stays sharp; re-run with another size to change it.
- `Natives/resources/InstanceIcons/*.png`: what the app ships. The Linux build copies `Natives/resources/` into
  the app wholesale, which is why these are plain PNGs and not asset-catalog entries (the catalog is only compiled on
  a Mac).

## How an instance's icon is stored and shown
A profile's `icon` value is one of:
- an **icon key** such as `grass`, or the name of an icon you added (new): looked up first in the app's built-in
  icons, then in `Documents/icons/`. A key never contains `/`, `\`, `:` or control characters, never starts with `.`,
  and is at most 120 characters, so it can't point outside those two folders and no URL can be mistaken for one;
- a **URL or `data:image/png;base64,...`** string, which is what modpack installs store. These load exactly as before.

`InstanceIcons` (Natives/InstanceIcons.m) does the lookup; the instance dashboard, the sidebar and the profile list
all go through `+setIconString:onImageView:placeholder:`.

## The icon picker (Natives/LauncherIconPickerViewController.m)
Modelled on Prism's: category filter (All, Modern, Custom; a Modpacks tab appears once there are icons saved with the
`modrinth_`, `curseforge_`, `ftb_`, `technic_` or `atl_` prefix), search by name, an icon grid, and Add Icon /
Remove Icon / Open Folder. Tap selects, double-tap or OK picks. Currently opened by tapping the icon on the instance
dashboard.
- **Add Icon** takes images from Files (PNG, JPG, GIF, WebP, ICO; several at once) or dropped onto the grid. SVG files
  can't be added: iOS cannot decode SVG. Images are decoded at no more than 512 px on their longest side with ImageIO
  (never the full bitmap), files over 100 megapixels or 64 MB of in-memory data are refused, and animated images
  become a still of their first frame. Names never replace an existing icon, ignoring case ("name 2", "name 3").
- **Remove Icon** only works for icons you added, asks first, and refreshes everything that was showing the icon.
- Deviations from Prism: no Legacy category; no hardware-keyboard Delete/+ shortcuts; Remove asks for confirmation
  (the icon is deleted, not moved to a trash).

## Known, inherited behaviour (not changed here)
Profile icon strings that are URLs go through the existing image loader, which accepts any URL scheme including
`file:`. That was already the case before the picker existed.

## Review
Reviewed adversarially by Codex (two passes) before the first build; every finding was checked by hand. Fixed: a crash
when a profile's `icon` isn't a string, unbounded image decoding, case-only name collisions, a race between concurrent
imports, Open Folder needing a long press, emoji names producing invalid keys, stale rows after Remove, and a missing
`-framework ImageIO` in the link list (found with a real link test, which a syntax check cannot catch).
Not tested on a device yet.
