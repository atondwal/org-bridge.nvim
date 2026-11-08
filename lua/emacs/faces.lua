-- Emacs faces as Neovim highlight groups. Colors come from the Neovim
-- colorscheme: each face links (through its Emacs :inherit chain) to a
-- standard group, unless the face itself names explicit colors.
local M = {}

-- Starting points of Emacs face inheritance, mapped to Neovim groups.
M.links = {
  ["default"] = "Normal",
  ["bold"] = { bold = true },
  ["italic"] = { italic = true },
  ["bold-italic"] = { bold = true, italic = true },
  ["underline"] = { underline = true },
  ["shadow"] = "Comment",
  ["link"] = "Underlined",
  ["link-visited"] = "Underlined",
  ["highlight"] = "Visual",
  ["region"] = "Visual",
  ["secondary-selection"] = "Visual",
  ["match"] = "Search",
  ["isearch"] = "IncSearch",
  ["lazy-highlight"] = "Search",
  ["error"] = "ErrorMsg",
  ["warning"] = "WarningMsg",
  ["success"] = "DiagnosticOk",
  ["minibuffer-prompt"] = "Question",
  ["escape-glyph"] = "SpecialKey",
  ["trailing-whitespace"] = "Error",
  ["header-line"] = "TabLine",
  ["fixed-pitch"] = {},
  ["fixed-pitch-serif"] = {},
  ["variable-pitch"] = {},
  ["font-lock-comment-face"] = "Comment",
  ["font-lock-comment-delimiter-face"] = "Comment",
  ["font-lock-doc-face"] = "Comment",
  ["font-lock-doc-markup-face"] = "SpecialComment",
  ["font-lock-string-face"] = "String",
  ["font-lock-keyword-face"] = "Keyword",
  ["font-lock-builtin-face"] = "Special",
  ["font-lock-function-name-face"] = "Function",
  ["font-lock-variable-name-face"] = "Identifier",
  ["font-lock-type-face"] = "Type",
  ["font-lock-constant-face"] = "Constant",
  ["font-lock-warning-face"] = "WarningMsg",
  ["font-lock-preprocessor-face"] = "PreProc",
  ["font-lock-negation-char-face"] = "Operator",
  ["font-lock-regexp-grouping-backslash"] = "SpecialChar",
  ["font-lock-regexp-grouping-construct"] = "SpecialChar",
  ["org-todo"] = { link = "DiagnosticError", bold = true },
  ["org-done"] = { link = "DiagnosticOk", bold = true },
  ["org-headline-done"] = "Comment",
  -- Bold only: the heading's color shows through, as in Emacs.
  ["org-tag"] = { bold = true },
  ["org-date"] = "Underlined",
  ["org-special-keyword"] = "Special",
  ["org-drawer"] = "Function",
  ["org-property-value"] = "String",
  ["org-block"] = {},
  ["org-block-begin-line"] = "Comment",
  ["org-block-end-line"] = "Comment",
  ["org-meta-line"] = "Comment",
  ["org-document-title"] = { link = "Title", bold = true },
  ["org-document-info"] = "Title",
  ["org-table"] = "Constant",
  ["org-formula"] = "Number",
  ["org-code"] = "String",
  ["org-verbatim"] = "String",
  ["org-checkbox"] = { bold = true },
  ["org-priority"] = "Special",
  -- Leading stars Emacs paints in the background color.
  ["org-hide"] = { link = "Normal", fg_from_bg = true },
  ["org-ellipsis"] = "NonText",
  ["org-agenda-structure"] = "Title",
  ["org-agenda-date"] = "Function",
  ["org-agenda-date-today"] = { link = "Function", bold = true, italic = true },
  ["org-agenda-date-weekend"] = { link = "Function", bold = true },
  ["org-scheduled"] = "DiagnosticOk",
  ["org-scheduled-today"] = "DiagnosticOk",
  ["org-scheduled-previously"] = "WarningMsg",
  ["org-upcoming-deadline"] = "WarningMsg",
  ["org-imminent-deadline"] = { link = "ErrorMsg", bold = true },
  ["org-warning"] = { link = "ErrorMsg", bold = true },
  ["org-time-grid"] = "Comment",
  ["org-agenda-current-time"] = "Comment",
}

local known = {}   -- face name -> info from Emacs
local defined = {} -- face name -> group name

local function group_name(face)
  return "EmacsFace_" .. face:gsub("[^%w]", "_")
end

local function attrs_of(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

-- Emacs weights as Neovim's bold (others leave the inherited one).
local BOLD = { bold = true, ["extra-bold"] = true, ["ultra-bold"] = true, ["semi-bold"] = true,
  normal = false, regular = false, light = false, ["semi-light"] = false }

local function resolve(face, seen)
  local info = known[face]
  local base = M.links[face]
  local attrs = {}
  if type(base) == "string" then
    attrs = vim.deepcopy(attrs_of(base))
  elseif type(base) == "table" then
    if base.link then attrs = vim.deepcopy(attrs_of(base.link)) end
    for k, v in pairs(base) do if k ~= "link" and k ~= "fg_from_bg" then attrs[k] = v end end
    if base.fg_from_bg then attrs.fg = attrs.bg end
  elseif info then
    for _, parent in ipairs(info.inherit) do
      if not seen[parent] then
        seen[parent] = true
        for k, v in pairs(resolve(parent, seen)) do
          if attrs[k] == nil then attrs[k] = v end
        end
      end
    end
  end
  -- A known face follows Neovim's colorscheme unless Emacs's colors for it
  -- were set on purpose (set-face-attribute, a theme).
  if info and (not base or info.custom) then
    -- Its own colors also replace inherited cterm ones.
    if info.fg then attrs.fg, attrs.ctermfg = info.fg, nil end
    if info.bg then attrs.bg, attrs.ctermbg = info.bg, nil end
    if BOLD[info.weight] ~= nil then attrs.bold = BOLD[info.weight] end
    if info.italic then attrs.italic = true end
    if info.underline == "wave" then attrs.undercurl = true elseif info.underline then attrs.underline = true end
    if info.strike then attrs.strikethrough = true end
  end
  return attrs
end

-- Groups that existed before Emacs defined them: the user's, which win.
local user_owned = {}

-- What each group we set looked like, to tell a later :hi by the user.
local last_set = {}

-- Nearest xterm-256 color for a "#rrggbb" or color-name value.
local function cterm(color)
  if color == nil then return nil end
  local rgb = type(color) == "number" and color or vim.api.nvim_get_color_by_name(color)
  if rgb < 0 then return nil end
  local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
  local function level(v) return v < 48 and 0 or v < 115 and 1 or math.floor((v - 35) / 40) end
  return 16 + 36 * level(r) + 6 * level(g) + level(b)
end

local function define(face)
  local group = group_name(face)
  defined[face] = group
  -- A user's group stays: one they defined before Emacs did, or changed
  -- since we last set it; an empty one (:hi clear) is ours again. Ours
  -- follow Emacs (set-face-attribute, a theme).
  local now = vim.api.nvim_get_hl(0, { name = group })
  if next(now) == nil then
    user_owned[group] = false
  elseif user_owned[group] == nil then
    user_owned[group] = last_set[group] == nil
  elseif last_set[group] and not vim.deep_equal(now, last_set[group]) then
    user_owned[group] = true
  end
  if user_owned[group] then return group end
  local attrs = resolve(face, { [face] = true })
  -- Without 'termguicolors' only cterm colors show (habit graphs).
  attrs.ctermfg = attrs.ctermfg or cterm(attrs.fg)
  attrs.ctermbg = attrs.ctermbg or cterm(attrs.bg)
  -- Emacs color names Neovim doesn't know are dropped rather than fatal.
  local ok = pcall(vim.api.nvim_set_hl, 0, group, attrs)
  if not ok then
    attrs.fg, attrs.bg = nil, nil
    vim.api.nvim_set_hl(0, group, attrs)
  end
  last_set[group] = vim.api.nvim_get_hl(0, { name = group })
  return group
end

-- Record face definitions sent by Emacs.
function M.add(infos)
  for _, info in ipairs(infos) do
    known[info.name] = info
    defined[info.name] = nil
  end
end

function M.group(face)
  return defined[face] or define(face)
end

-- After :colorscheme (which clears every group): a group that has
-- attributes again was set by the user (their ColorScheme autocmd).
function M.redefine_all()
  for face, group in pairs(defined) do
    if next(vim.api.nvim_get_hl(0, { name = group })) ~= nil then user_owned[group] = true end
    last_set[group] = nil
    define(face)
  end
end

return M
