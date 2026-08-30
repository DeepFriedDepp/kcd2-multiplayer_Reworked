-- KCD2 Multiplayer - deterministic module bootstrap
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = { modules = {} }

local moduleOrder = {
    "utils",
    "state",
    "transport",
    "interaction",
    "dice",
    "npc_sync",
    "ghosts",
    "animation",
    "appearance",
    "diagnostics",
    "items",
    "commands",
    "input",
}

for _, moduleName in ipairs(moduleOrder) do
    local path = "Scripts/KCD2MP/" .. moduleName .. ".lua"
    local ok, err = pcall(function()
        Script.ReloadScript(path)
    end)
    if not ok or not KCD2MP.modules[moduleName] then
        error("[KCD2-MP] module load failed: " .. path .. " (" .. tostring(err) .. ")")
    end
end

KCD2MP.util.log("MOD INIT; loaded " .. tostring(#moduleOrder) .. " modules")