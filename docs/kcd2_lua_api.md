# KCD2 Lua API - Verified Methods

Kingdom Come: Deliverance 2, v1.5.2, CryEngine, Lua 5.1.
All methods verified in-game. Sources extracted from `Scripts.pak`.

---

## System

```lua
System.LogAlways(msg)
System.AddCCommand(name, luaCode, description)
System.ExecuteCommand(cmd)
System.SetCVar(name, value)
System.GetCVarValue(name)                     -- returns string
System.SpawnEntity(params)                    -- returns entity or nil
System.GetEntityByName(name)
System.GetEntityByClass(class)
```

**SpawnEntity params table:**

```lua
System.SpawnEntity({
    class    = "NPC",            -- NPC, AnimObject, GeomEntity, BasicEntity, Player
    name     = "MyNPC",
    position = {x=0, y=0, z=0},
    scale    = {x=1, y=1, z=1},
})
```

---

## Script

```lua
Script.SetTimer(ms, callback)    -- runtime only, NOT from startup/init scripts
Script.ReloadScript(path)
```

---

## Entity (basic)

```lua
entity:GetWorldPos()             -- returns {x, y, z}
entity:SetWorldPos({x, y, z})
entity:GetAngles()               -- returns {x, y, z} Euler
entity:Hide(1/0)
entity:Destroy()
```

---

## ItemManager

```lua
local itemHandle = ItemManager.CreateItem(itemGuid, quantity, condition)
-- condition: 1.0 = perfect, 0.0 = broken
-- Use this instead of inventory:CreateItem() when you need to equip items
```

---

## entity.inventory

```lua
entity.inventory:AddItem(itemHandle)
entity.inventory:FindItem(guid)              -- returns slot handle or nil
entity.inventory:RemoveAllItems()
```

---

## entity.actor

```lua
-- Visual equip via clothing preset (WORKS on NPC)
entity.actor:EquipClothingPreset(clothingPresetGuid)

-- Weapon preset
entity.actor:EquipWeaponPreset(weaponPresetGuid)

-- Equip item from inventory slot (adds to inv slot but NOT visually on NPC model)
entity.actor:EquipInventoryItem(slot)

-- Read current preset
local guid = entity.actor:GetInitialClothingPreset()
```

> **Warning:** `EquipInventoryItem` on an NPC puts the item in inventory but does NOT show it
> visually on the model. Use `EquipClothingPreset` for visual equipping.

---

## Equipping Armor on a Spawned NPC

Full working pattern (verified):

```lua
local pos = player:GetWorldPos()
local npc = System.SpawnEntity({class="NPC", name="TestNPC", position=pos, scale={x=1,y=1,z=1}})
if not npc then return end

-- Step 1: add items to inventory
local GAMBESON = "00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
local CUIRASS  = "10ff6d35-8c14-4871-8656-bdc3476d8b12"  -- Cuirass07_m01_A4

npc.inventory:AddItem(ItemManager.CreateItem(GAMBESON, 1, 1))
npc.inventory:AddItem(ItemManager.CreateItem(CUIRASS,  1, 1))

-- Step 2: visually equip via ClothingPreset (GUID defined in XML)
npc.actor:EquipClothingPreset("dc000001-0000-0000-0000-000000000000")
```

### Required XML (`Libs/Tables/item/clothing_preset__modname.xml` inside pak)

```xml
<?xml version="1.0" encoding="us-ascii"?>
<database xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="barbora"
          xsi:noNamespaceSchemaLocation="../database.xsd">
    <clothing_presets version="2">
        <clothing_preset
            clothing_preset_id="dc000001-0000-0000-0000-000000000000"
            clothing_preset_name="kcd2mp_ghost_armor"
            gender="Male"
            prefers_hood_on="false">
            <Items>
                <Guid>00b7ed62-a7bd-4269-acfa-8d852366579b</Guid>
                <Guid>10ff6d35-8c14-4871-8656-bdc3476d8b12</Guid>
            </Items>
        </clothing_preset>
    </clothing_presets>
</database>
```

**Rules:**

- File must be named `clothing_preset__*.xml` (double underscore) — game merges all matching files
- `clothing_preset_id` must be a valid hex UUID (digits 0-9 and letters a-f only!)
- `EquipClothingPreset` takes the **GUID** (`clothing_preset_id`), not the name
- Items listed under `<Items>` are visually worn on the character model

---

## NPC Animation

```lua
entity:StartAnimation(slot, animName)         -- WORKS: "run", "walk", "idle", ...
entity:StopAnimation(slot, layer)
entity:IsAnimationRunning(slot, layer)
entity:SetAnimationSpeed(slot, layer, speed)
entity:GetAnimationTime(slot, layer)
entity:GetAnimationLength(slot, animName)
entity:ForceCharacterUpdate(slot, bool)

-- NOT available on NPC:
-- SetAnimationInput, SetMotionParameter, PlayAnimation
```

---

## NPC AI (entity.AI)

```lua
entity.AI:SetRefPointPosition({x, y, z})
entity.AI:GoTo({x, y, z})
entity.AI:SetForcedNavigation({x, y, z})
-- 50+ additional AI functions available
```

---

## Player-specific

```lua
player:GetWorldPos()                          -- {x, y, z}
player.human:IsInDialog()
player.soul:IsInCombatDanger()
player.soul:HaveSkill('thievery')
player.soul:GetSkillLevel("thievery")
```

---

## UIAction — CryEngine's Flash UI, and it is fully live

> **Look here first for any Lua API question:** the KCD2 Modding Tools ship
> Warhorse's own generated scriptbind reference at
> `Tools/modding/docs/script_bind/script_bind.zip` (5,014 pages, dated
> 2025-01-14). It is authoritative for `System.*`, `UIAction.*`, `Script.*` and
> the entity bindings. Still cross-check against the shipping DLL's scriptbind
> registration strings — the docs describe a source tree and list at least one
> method (`System.DrawTriStrip`) this build does not register.

Verified present in the mod's Lua sandbox, 2026-07-29:

```lua
UIAction.CallFunction( elementName, instanceID, functionName, [arg1], [arg2], ... )
UIAction.ShowElement( elementName, instanceID )
UIAction.HideElement( elementName, instanceID )
UIAction.SetVariable( elementName, instanceID, varName, value )
UIAction.SetArray( elementName, instanceID, arrayName, luaTable )
UIAction.SetPos( elementName, instanceID, movieClipName, vec3 )
UIAction.SetScale / SetRotation / SetAlpha / SetVisible   -- same shape
UIAction.GotoAndPlay( elementName, instanceID, movieClipName, frame )
UIAction.RegisterElementListener( table, elementName, instanceID, eventName, callbackName )
-- callback form: Callback(elementName, instanceId, eventName, argTable)
UIAction.UnregisterElementListener( table, elementName )
```

`instanceID` is `-1` for all instances; an id that does not exist is created.

**Elements and their functions are declared in `Libs/UI/UIElements/*.xml`**
inside `Data/IPL_GameData.pak` — 28 of them, each binding named functions to a
`.gfx`. That is the list of everything callable.

**Trap:** `HUD.xml` declares `<UIElement name="hud">` — **lowercase**. Passing
`"HUD"` is a silent no-op, not an error.

Useful ones (from `HUD.xml` / `ApseModalDialog.xml`):

```lua
UIAction.CallFunction("hud", -1, "ShowInfoText", text, priority, durationMs, background)
UIAction.CallFunction("hud", -1, "ShowNotification", text)
UIAction.CallFunction("hud", -1, "ShowTutorial", id, htmlText, durationMs, inDialogue, priority, layout, actionHint, overlayLink)
UIAction.CallFunction("hud", -1, "ShowSkillCheckResult", name, result)  -- 0 fail, 1 success
UIAction.CallFunction("hud", -1, "ShowDiceScore", target, playerName, curP, totP, selP,
                      badgePName, badgePCur, badgePTot, curN, totN, selN, badgeNName, badgeNCur, badgeNTot)
UIAction.CallFunction("hud", -1, "AddDiceSelector", id, x, y, isPlayer)   -- x,y in 1920x1080 space
UIAction.CallFunction("ApseModalDialog", -1, "OpenQuestionDialog", question, actionConfirm, actionCancel, hintConfirm, hintCancel)
```

Whether any of these render when pushed from **outside** their normal game
context is a separate question — see `docs/WO-6-visual-capability.md`.

Older note, still true: `UIAction.RegisterElementListener(state, element, -1,
"OnShow"/"OnHide", "callbackName")`, elements `"Menu"`, `"ApseModalDialog"`.

## Drawing from Lua

Registered by `CScriptBind_System` in this build (checked against
`CryScriptSystem.dll`'s own registration table, then confirmed live):

```lua
System.DrawText( x, y, text, font, size, r, g, b )     -- screen space
System.DrawLabel( vPos, fSize, text, r, g, b, alpha )  -- world space
System.Draw2DLine( p1x, p1y, p2x, p2y, r, g, b, alpha )
System.DrawLine( p1, p2, r, g, b, alpha )              -- world space
System.SetScissor( x, y, w, h )
System.ProjectToScreen( point )
System.GetViewport()   -- returns a TABLE {x, y, width, height} -- NOT four values
```

- **There is no image / sprite / texture draw primitive.** Confirmed negative.
- **`System.DrawTriStrip` is documented but not registered** — returns `nil`.
- Fonts live in `Engine/Engine.pak` under `Fonts/`: `default`, `hud`, `console`
  (all VeraMono) and **`subtitles`, which is `AlexanderQuill.ttf`** — the game's
  medieval quill hand, with a built-in drop-shadow pass. Pass `"subtitles"` as
  the `font` argument.
- `System.DrawText`'s arity in this build is **unverified**: `kdcmp.lua`
  historically called the 4-argument form `(x, y, text, size)`, which under the
  documented signature would put that number in the `font` slot.

## Dice tables

```lua
System.GetEntitiesByClass("DiceInteractor")                    -- every loaded table
System.GetEntitiesInSphereByClass(pos, radius, "DiceInteractor")
System.GetNearestEntityByClass(pos, radius, className)
```

`DiceInteractor` is the in-world dice board (registered by `Scripts.pak`'s
`Entities/DiceInteractor.ent`); instances are named
`Table/table_diceN_<guid>`. `DiceMinigameCup` is the cup. Verified live.

---

## Debug REST API (localhost:1403)

| Endpoint                                            | Description                  |
| --------------------------------------------------- | ---------------------------- |
| `GET /api/rpg/SoulList/PlayerSoul?depth=1`          | Player position, name, state |
| `GET /api/rpg/Calendar?depth=1`                     | GameTime (0 = main menu)     |
| `GET /api/System/Console/ExecuteString?command=...` | Execute console command      |
| `GET /api/System/Console/GetCvarValue?name=...`     | Read CVar value              |
| `GET /api/<path>?info`                              | Discover properties/methods  |
| `GET /api/<path>?depth=1`                           | Read values                  |

Lua execution: prefix command with `#`, e.g. `#System.SetCVar("x","y")`

Eval trick: write to CVar via Lua, read back via GetCvarValue.

> **WSL2 note:** `curl` from WSL2 cannot reach Windows localhost:1403.
> Use `powershell.exe` or `cmd.exe /c curl.exe`.

---

## Known Item GUIDs

| Item                   | GUID                                   |
| ---------------------- | -------------------------------------- |
| GambesonShort01_m04_D2 | `00b7ed62-a7bd-4269-acfa-8d852366579b` |
| Cuirass07_m01_A4       | `10ff6d35-8c14-4871-8656-bdc3476d8b12` |

Item data source: `Data/Tables.pak → Libs/Tables/item/item.xml`

---

## Pak Build Script (PowerShell)

```powershell
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$pakPath = 'D:\kcd2multiplayer\kdcmp\Data\kdcmp.pak'
$srcRoot  = 'D:\kcd2multiplayer\kdcmp\Data'
$files    = @(
    'Scripts\Startup\kdcmp.lua',
    'Libs\Tables\item\clothing_preset__kdcmp.xml'
)

Remove-Item $pakPath -Force -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::Open($pakPath, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($rel in $files) {
    $entry  = $zip.CreateEntry($rel.Replace('\','/'), [System.IO.Compression.CompressionLevel]::NoCompression)
    $stream = $entry.Open()
    $bytes  = [System.IO.File]::ReadAllBytes((Join-Path $srcRoot $rel))
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
}
$zip.Dispose()
```

> Always close the game before rebuilding the pak (file is locked while running).

---

## Source References (Scripts.pak)

| File                                           | Contents                                                             |
| ---------------------------------------------- | -------------------------------------------------------------------- |
| `Scripts/Debug/CombatDebug.lua`                | SpawnEnemy, EquipClothingPreset, EquipWeaponPreset, tblArmor presets |
| `Scripts/Entities/actor/player.lua`            | ItemManager.CreateItem, AddItem, EquipClothingPreset (cheat gear)    |
| `Scripts/Entities/AI/InventoryDummyPlayer.lua` | NPC entity structure, BasicActor/BasicAI                             |
| `Scripts/Entities/WH/Stash/AnimStash.lua`      | inventory patterns, stash interaction                                |
| `Scripts/FlowNodes/InventoryWeapon.lua`        | weapon inventory flow nodes                                          |
