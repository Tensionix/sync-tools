# Audion Sync Tools — logo v2

Put in place: 2026-10-11
Chosen by the owner from `E:\TOOLS\output\audion-sync-tools-concepts-v1`: variant A1, "S-flow" in sea blue
and copper (`audion-sync-s-flow-sea-copper.svg`, `audion-sync-s-flow-sea-copper-1024.png`). The nine variants,
their comparison sheet and the script that rendered them lie in that folder.

Concept: the two-arrow S of logo v1, refined and drawn as native vector shapes - one path, used twice, the
second turned by 180 degrees. Two gradients: sea blue (#61D8F5 - #006994 - #034968) and copper
(#FFD19A - #DB883F - #874825). Transparent background, no lettering.

Files here:

- `SyncTools.svg` - the vector source, 1024 x 1024.
- `SyncTools.png` - the same at 1024 x 1024, 32-bit with alpha: the picture the icon is built from.
- `SyncTools.ico` - built by `Engine\Launcher\Build-IconFromImage.ps1`: frames 256, 128, 64, 48, 32, 16.

Where the icon goes: `Start.exe` embeds `Assets\SyncTools.ico` when it is built
(`Engine\Launcher\Build-StartExe.ps1`); `Source\Assets\app.ico` is a copy of the same file, carried by
`App\AudionSyncTools.exe`, its window and `App\AudionPs.exe` (`builder_main.cmd build_app`). After a
change of the picture: build the icon, copy it to `Source\Assets\app.ico`, build `Start.exe`, build `App\`.

Inspection: every frame was viewed on charcoal and on a light ground; the icons the three executables
carry were taken out of the built files and viewed. The S and its two colours read from 16 pixels.

The picture, the icon and the mark of v1 (2026-09-09, generated as a raster) were replaced; `SyncTools-logo-v1.md`
keeps its description.
