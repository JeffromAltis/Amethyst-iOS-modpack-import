# Renderer benchmark plan (plain Minecraft 1.21.11)

Question: how much frame time do the translation layers cost on the iPad Air M3, to decide whether a
GL-to-Metal translator is worth building. GTNH is excluded (legacy GL outlier). The display is 60 Hz and
presentation is vsynced, so fps is capped at 60: compare frame time and the load at which 60 breaks.

## Configurations (same Fabric 1.21.11 instance copy, same world)
- A: VulkanMod (native Vulkan -> MoltenVK -> Metal). Add/remove the mod jar to switch.
- B: vanilla OpenGL via MobileGL (GL -> Vulkan -> MoltenVK -> Metal).
- C (optional): vanilla OpenGL via MobileGlues, for a third data point.
No other mods besides Fabric API. Same video settings in all runs except the variable under test.

## Fixed scene
1. New world, fixed seed, same coordinates for every run (`/tp` to the same x y z and rotation).
2. `/time set day`, `/gamerule doDaylightCycle false`, `/gamerule doWeatherCycle false`,
   `/weather clear`, `/gamerule doMobSpawning false`.
3. Stand still 60 s after teleport so chunks generate and the pipeline cache warms. Measure after that.
4. Pick a scene that is heavy: a view over trees and terrain, not a flat void.

## Logging (set in the launcher's custom environment variables, one launch per config)
- `MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=300`
- `MVK_CONFIG_LOG_LEVEL=3`
- Try `MTL_HUD_ENABLED=1` for the Metal HUD (GPU frame time). Unverified under LiveContainer; if nothing
  shows, drop it.

## Runs (per configuration, fill the table)
| Render distance | Resolution | F3 fps | Metal HUD GPU ms | Notes |
| --- | --- | --- | --- | --- |
| 12 | 100% | | | |
| 16 | 100% | | | |
| 24 | 100% | | | |
| 32 | 100% | | | |
| 12 | 50% | | | |
| 24 | 50% | | | |

Also note the first render distance at which fps falls below 60 for each configuration.

## How to read it
- Resolution 50% giving a big gain: GPU-bound, a translator would not help much.
- B much worse than A at equal load: the extra GL-to-Vulkan layer costs real time.
- MoltenVK per-frame CPU time (from the log) small versus total frame time: skip the translator.

## Afterwards
Run `python3 scripts/collect_ipad_logs.py` and read the MoltenVK performance blocks from latestlog.txt.
Do not paste raw logs. Record results here and in memory.
