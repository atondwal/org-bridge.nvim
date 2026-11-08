-- Translation between Neovim key notation and Emacs `kbd` notation.
local M = {}

local SPECIAL = {
  CR = "RET", Tab = "TAB", Esc = "ESC", BS = "DEL",
  -- Terminals send C-j as LF, which keytrans spells <NL>.
  NL = "C-j",
  Space = "SPC", lt = "<", Bslash = "\\", Bar = "|", Del = "<deletechar>",
  Up = "<up>", Down = "<down>", Left = "<left>", Right = "<right>",
  Home = "<home>", End = "<end>", PageUp = "<prior>", PageDown = "<next>",
  Insert = "<insert>", Nul = "C-@",
}

-- Named keys that take modifiers as `C-<name>` in Emacs.
local MOD_NAMES = {
  CR = "<return>", Tab = "<tab>", BS = "<backspace>", Esc = "<escape>", Space = "SPC",
}

-- Emacs spelling of a named key with no modifiers.
local function named(name)
  local fnum = name:match("^F(%d+)$")
  return SPECIAL[name] or (fnum and "<f" .. fnum .. ">") or ("<" .. name:lower() .. ">")
end

-- Emacs notation for one Neovim key in `keytrans` form ("a", "<C-A>", "<M-CR>").
function M.to_emacs(key)
  if #key == 1 then
    if key == " " then return "SPC" end
    return key
  end
  local inner = key:match("^<(.+)>$")
  if not inner then
    -- Multibyte character.
    return key
  end
  local mods = ""
  while inner:match("^%a%-.") do
    mods = mods .. inner:sub(1, 2)
    inner = inner:sub(3)
  end
  local name = inner
  if mods == "" then return named(name) end
  local m = {}
  for c in mods:gmatch("(%a)%-") do m[c] = true end
  if m.S and name == "Tab" and not (m.C or m.M or m.A) then return "<backtab>" end
  -- Meta alone on RET/TAB/DEL/ESC/SPC keeps the ASCII spelling, as terminals send it.
  if m.M and not (m.C or m.S or m.A or m.D) and MOD_NAMES[name] then
    return "M-" .. SPECIAL[name]
  end
  local base
  if #name == 1 then
    base = name
    if name:match("%a") then
      -- Neovim spells C-a as <C-A>; Emacs's C-a is lowercase and C-A means C-a.
      if m.C then base = name:lower()
      elseif m.S then base = name:upper(); m.S = nil end
    end
  else
    base = MOD_NAMES[name] or named(name)
  end
  -- Emacs writes modifiers on <name> keys inside the brackets: C-<return>.
  local prefix = (m.A and "A-" or "") .. (m.C and "C-" or "") .. (m.D and "s-" or "")
    .. (m.M and "M-" or "") .. (m.S and "S-" or "")
  if base:match("^<.+>$") then
    return "<" .. prefix .. base:sub(2)
  end
  return prefix .. base
end

-- Read one key from the user; returns its Emacs notation, or nil on Escape,
-- Ctrl-G and Ctrl-C (which cancel, like C-g in Emacs).
function M.read()
  -- Ctrl-C makes getcharstr raise "Keyboard interrupt".
  local ok, raw = pcall(vim.fn.getcharstr)
  if not ok then return nil end
  local key = vim.fn.keytrans(raw)
  if key == "<Esc>" or key == "<C-G>" then return nil end
  return M.to_emacs(key)
end

return M
