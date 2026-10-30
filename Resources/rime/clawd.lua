--[[
  clawd.lua —— 输入栏里的 Claude 小螃蟹 Clawd

  原理：librime 会把「最后一个 segment 的 prompt」插在光标 ‸ 后面显示。
  本翻译器不产出任何候选，只在每次按键后改写 prompt：
    · 光标后面是 Claude Code「思考中」的火花，每按一个键转一格（· ✢ ✳ ✶ ✻ ✽）；
    · 拼音下面一行住着像素 Clawd，你每打一个字母它就往右横爬一步，
      腿交替迈步、眼睛朝前看，时不时眨眼；
    · 退格时它眼睛朝左，往回退；
    · 编码里出现 claude / kelaode 时它举起双钳；
    · 编码很长时火花旁边会冒出「…」，它累了。

  需要鼠须管 inline_preedit: false（拼音显示在候选框里）才看得到。

  可在 rime_ice.custom.yaml 里改：
    clawd/style:   companion（默认，像素 Clawd 由伴随程序画在候选框上沿）
                   | clawd（两行方块字 Clawd）| crab（单行颜文字 V(•ᴗ•)V）| emoji | off
    clawd/sparkle: true | false   是否显示 ✻ 火花
]]

local FE0E = "\u{FE0E}"   -- 强制文本样式，避免 ✳ 被渲染成彩色 emoji
local STEP = "\u{2002}"   -- EN SPACE：Clawd 每爬一步的距离，约等于一个拼音字母宽
-- 换行用 U+2028（行分隔符）而不是 \n：\n 会让鼠须管当成新段落，
-- 在两行之间加段落间距，把螃蟹上下劈开
local NL = "\u{2028}"

local SPARKS = { "·", "✢", "✳" .. FE0E, "✶", "✻", "✽", "✻", "✶", "✳" .. FE0E, "✢" }

-- 像素 Clawd：每帧两行，用 Menlo 的四分块字符拼成（每个字符 2×2 像素）。
-- 每行第一个字符都不是空格，这样两行左边严格对齐。
local CLAWD = {
  walk  = { { "▗▐█▜██▛▌▖", "▝▀▛▛▀▜▜▀▘" }, { "▗▐█▜██▛▌▖", "▝▀▜▜▀▀▛▛▘" } },
  back  = { { "▗▐▜██▛█▌▖", "▝▀▛▛▀▜▜▀▘" }, { "▗▐▜██▛█▌▖", "▝▜▜▀▀▛▛▀▘" } },
  blink = { "▗▐█████▌▖", "▝▀▛▛▀▜▜▀▘" },
  cheer = { "▐▐▛███▜▌▌", "▝▀▛▛▀▜▜▀▘" },
}

-- 单行风格
local ONELINE = {
  crab = {
    walk  = { "V(•ᴗ•)v", "v(•ᴗ•)V" },
    back  = { "V(°□°)V", "v(°□°)v" },
    blink = "V(-ᴗ-)V",
    cheer = "\\V(≧ᴗ≦)V/",
  },
  emoji = {
    walk  = { "🦀", "🦀" },
    back  = { "🦀", "🦀" },
    blink = "🦀",
    cheer = "🦀🎉",
  },
}

local BLINK_EVERY = 7   -- 每 7 个键眨一次眼
local TIRED_LEN = 24    -- 编码超过这么长，小螃蟹累了
local LAG = 2           -- 前几个键 Clawd 先原地踏步，之后每键往右爬一步

-- companion 模式：把输入状态写给伴随程序 ~/Applications/Clawd.app，
-- 由它把真正的像素 Clawd 画在候选框上沿（项目主页 https://github.com/yzysiu777/rime-clawd）
local STATE_FILE = (os.getenv("HOME") or "") .. "/Library/Caches/ClawdCompanion/state"

local function write_state(env, ctx, committed)
  if committed then env.commits = env.commits + 1 end
  local composing = ctx:is_composing()
  local pre = ""
  if composing then
    local p = ctx:get_preedit()
    if p and p.text then pre = p.text:sub(1, p.caret_pos or #p.text) end
  end
  local line = table.concat({ "v1", env.sid, composing and "1" or "0", tostring(env.commits),
                              (ctx.input:gsub("[\t\n]", " ")), (pre:gsub("[\t\n]", " ")) }, "\t")
  if line == env.last_line then return end
  env.last_line = line
  env.seq = env.seq + 1
  local f = io.open(STATE_FILE, "w")
  if f then
    f:write(env.seq, "\t", line, "\n")
    f:close()
  end
end

local M = {}

function M.init(env)
  local config = env.engine.schema.config
  env.style = config:get_string("clawd/style") or "companion"
  if env.style == "companion" then
    env.sid = tostring(math.random(100000, 999999))
    env.commits, env.seq = 0, 0
    local ctx = env.engine.context
    env.conn_update = ctx.update_notifier:connect(function(c) write_state(env, c, false) end)
    env.conn_commit = ctx.commit_notifier:connect(function(c) write_state(env, c, true) end)
  end
  local sparkle = config:get_bool("clawd/sparkle")
  env.sparkle = (sparkle == nil) and true or sparkle
  env.prev_len = 0
  env.dir = 1
  env.last = nil   -- 上一次写进 prompt 的串，用来避免重复叠加
end

function M.fini(env)
  if env.conn_update then env.conn_update:disconnect() end
  if env.conn_commit then env.conn_commit:disconnect() end
end

local function strip_last(prompt, last)
  if last and last ~= "" and prompt and prompt ~= "" then
    local i = prompt:find(last, 1, true)
    if i then
      return prompt:sub(1, i - 1) .. prompt:sub(i + #last)
    end
  end
  return prompt or ""
end

-- 根据状态挑一帧：mood = walk / back / blink / cheer
local function pick(set, mood, n)
  local v = set[mood]
  if mood == "walk" or mood == "back" then
    return v[n % #v + 1]
  end
  return v
end

function M.func(input, seg, env)
  if env.style ~= "clawd" and env.style ~= "companion" and not ONELINE[env.style] then return end
  local ctx = env.engine.context
  local full = ctx.input
  -- 只装饰最后一个 segment（prompt 只取 composition 的最后一段），标点不管
  if seg._end ~= #full or seg:has_tag("punct") then return end
  -- 传进来的 seg 是副本，改它不生效；要改 composition 里真正的那一段
  local comp = ctx.composition
  if comp:empty() then return end
  local target = comp:back()
  if target._start ~= seg._start then return end

  local n = #full
  if n <= 1 or n > env.prev_len then
    env.dir = 1
  elseif n < env.prev_len then
    env.dir = -1
  end
  env.prev_len = n

  local lower = full:lower()
  local mood
  if lower:find("claude", 1, true) or lower:find("kelaode", 1, true) then
    mood = "cheer"
  elseif env.dir < 0 then
    mood = "back"
  elseif n % BLINK_EVERY == 0 or n >= TIRED_LEN then
    mood = "blink"
  else
    mood = "walk"
  end

  local spark = env.sparkle and SPARKS[n % #SPARKS + 1] or ""
  if n >= TIRED_LEN then spark = spark .. " …" end

  local deco
  if env.style == "companion" then
    -- Clawd 本体由伴随程序画；输入栏里只留 Claude 的 ✻ 火花
    if spark == "" then return end
    deco = " " .. spark
  elseif env.style == "clawd" then
    local f = pick(CLAWD, mood, n)
    local pad = string.rep(STEP, math.max(0, n - LAG))
    deco = (spark ~= "" and (" " .. spark) or "") .. NL .. pad .. f[1] .. NL .. pad .. f[2]
  else
    local body = pick(ONELINE[env.style], mood, n)
    if spark == "" then
      deco = "  " .. body
    elseif env.dir < 0 then
      deco = "  " .. body .. " " .. spark
    else
      deco = " " .. spark .. " " .. body
    end
  end

  target.prompt = strip_last(target.prompt, env.last) .. deco
  env.last = deco
end

return M
