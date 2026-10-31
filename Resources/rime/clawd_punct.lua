--[[
  clawd_punct.lua —— 跟随 Clawd 菜单里的「英文标点」开关，切换 Rime 的中文 / 英文标点

  Clawd.app 把你的选择写进 ~/Library/Caches/ClawdCompanion/punct（内容是 en 或 zh）。
  这个处理器排在最前面，每次按键时读一下这个文件：选择变了，就切换 ascii_punct 选项，
  下一次按键马上生效。它从不吃掉按键（总是返回 kNoop）。

  只有在文件内容「变化」时才会切换，所以用快捷键（雾凇拼音默认 ⌃⇧3）临时手动切换不会被改回去。
  文件不存在时什么也不做，沿用方案里的默认值。
]]

local function pref_path()
  if package.config:sub(1, 1) == "\\" then
    local base = os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or "."
    return base .. "\\ClawdCompanion\\punct"
  end
  return (os.getenv("HOME") or "") .. "/Library/Caches/ClawdCompanion/punct"
end
local PREF = pref_path()

local function read_pref()
  local f = io.open(PREF, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

local function apply(env)
  local v = read_pref()
  if (v == "en" or v == "zh") and v ~= env.applied then
    env.engine.context:set_option("ascii_punct", v == "en")
    env.applied = v
  end
end

local M = {}

function M.init(env)
  env.applied = nil
  apply(env)
end

function M.func(key, env)
  apply(env)
  return 2  -- kNoop：不处理按键，交给后面的处理器
end

return M
