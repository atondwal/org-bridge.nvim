-- org-bridge.nvim: run Emacs (org-mode) behind Neovim buffers.
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")
local keys = require("emacs.keys")
local faces = require("emacs.faces")
local ui = require("emacs.ui") -- also registers the prompt rpc.handlers
local api = vim.api

local M = {}

local group = api.nvim_create_augroup("org-bridge.nvim", { clear = true })

local function map(buf, mode, lhs, rhs)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = "org-bridge.nvim" })
end

-- Report errors from a key handler in the echo area instead of a traceback.
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then mirror.error(tostring(err)) end
  end
end

-- Redraw Emacs's faces for buf; errors go to the echo area.
local function refresh_spans(buf)
  if rpc.depth > 0 or not mirror.state[buf] then return end
  -- A plugin's FileType autocmd may start treesitter after ours stopped it.
  if vim.treesitter.highlighter.active[buf] then vim.treesitter.stop(buf) end
  guarded(function() mirror.refresh_spans(buf) end)()
end

-- Start a new undo step.
local function break_undo() vim.cmd("let &undolevels = &undolevels") end

-- . repeats the last org key that changed the text, as vim-repeat does
-- for plugins: the same keys, count and menu answers (C-c C-t's "t").
-- With vim-repeat installed its . does it (repeat#set); else org buffers
-- map . themselves.
local REPEAT_PLUG = api.nvim_replace_termcodes("<Plug>(emacs-repeat)", true, true, true)
-- { keys, count, answers, buf, tick }, or { replay, buf, tick }: keys fed
-- again, for changes Vim's own . can't redo.
local last_change

local function has_vim_repeat() return vim.fn.exists("*repeat#set") == 1 end

local function remember_change(change, count)
  local buf = api.nvim_get_current_buf()
  last_change = vim.tbl_extend("error", change, { buf = buf, tick = api.nvim_buf_get_changedtick(buf) })
  if has_vim_repeat() then vim.fn["repeat#set"](REPEAT_PLUG, count) end
end

local function remember(emacs_keys, count, answers)
  remember_change({ keys = emacs_keys, count = count, answers = answers }, count)
end

-- The keys typed since `o` opened a line through Emacs ({ buf, keys }), so
-- . can type them again: Vim's redo has the text but not the new line.
-- Needs on_key's typed keys (0.10+); 0.9's . appends the text instead.
local open_line_typing
if vim.fn.has("nvim-0.10") == 1 then
  vim.on_key(function(_, typed)
    if open_line_typing and typed ~= "" then table.insert(open_line_typing.keys, typed) end
  end, api.nvim_create_namespace("emacs_open_line"))
end

-- mirror.exec(opts), returning the answers given to Emacs's menus.
local function exec_recording(opts)
  local answers, read_key = {}, rpc.handlers.read_key
  rpc.handlers.read_key = function(p)
    local k = read_key(p)
    answers[#answers + 1] = k
    return k
  end
  local ok, err = pcall(mirror.exec, opts)
  rpc.handlers.read_key = read_key
  if not ok then error(err, 0) end
  return answers
end

local function repeat_change()
  local r = last_change
  -- Remapped, so o and the keys typed after it run as they did.
  if r.replay then return api.nvim_feedkeys(r.replay:rep(vim.v.count1), "m", false) end
  local count = vim.v.count > 0 and vim.v.count or r.count
  mirror.exec({ keys = r.keys, count = count, pending = r.answers })
  remember(r.keys, count, r.answers)
end

vim.keymap.set("n", "<Plug>(emacs-repeat)", guarded(function() if last_change then repeat_change() end end))

local function key_handler(lhs, mode)
  local emacs_key = keys.to_emacs(vim.fn.keytrans(api.nvim_replace_termcodes(lhs, true, true, true)))
  return guarded(function()
    local insert = mode == "i"
    -- Each forwarded key is its own undo step, as in Emacs.
    if insert then break_undo() end
    local tick = api.nvim_buf_get_changedtick(0)
    local answers = exec_recording({ keys = emacs_key, count = vim.v.count, visual = mode == "x" })
    if insert then break_undo() end
    -- Not the keys that start Insert mode (M-RET): what follows is typed.
    if mode == "n" and not mirror.EOL_KEYS[emacs_key] and api.nvim_buf_get_changedtick(0) ~= tick then
      remember(emacs_key, vim.v.count, answers)
    end
    -- A new heading or item from Normal mode: you want to type its text.
    if mode == "n" and mirror.EOL_KEYS[emacs_key] and vim.bo.modifiable then
      vim.cmd("startinsert!")
    end
  end)
end

-- Non-printable keys a menu buffer always sends to Emacs.
local MENU_BUFFER_KEYS = { "<CR>", "<Tab>", "<S-Tab>", "<BS>", "<Space>", "<C-c>", "<C-x>",
  "<M-x>", "<Up>", "<Down>", "<Left>", "<Right>", "<S-Left>", "<S-Right>", "<S-Up>", "<S-Down>",
  "<M-Up>", "<M-Down>", "<M-Left>", "<M-Right>", "<M-S-Up>", "<M-S-Down>", "<M-S-Left>", "<M-S-Right>",
  "<C-k>" }

-- Run Emacs's COMMAND with lines first..last as the region.
local function on_lines(command, first, last)
  local last_line = api.nvim_buf_get_lines(0, last - 1, last, false)[1]
  guarded(function()
    mirror.exec({ command = command, region = { { first - 1, 0 }, { last - 1, #last_line } } })
  end)()
end

local function on_heading() return api.nvim_get_current_line():match("^%*+%s") ~= nil end
local function on_table_row() return api.nvim_get_current_line():match("^%s*|") ~= nil end

-- gq: org fills the lines' paragraphs (keeps headings and lists intact).
-- While typing past 'textwidth', org's auto-fill: Emacs fills when a space
-- is typed, Vim asks on the next character, so a word being typed is left
-- alone and the first one after a space fills as Emacs did at the space.
function _G.EmacsFormatExpr()
  if vim.v.char ~= "" then
    local col = api.nvim_win_get_cursor(0)[2]
    if not on_heading() and api.nvim_get_current_line():sub(col, col):match("%s") then
      guarded(function() mirror.exec({ command = "nvb-auto-fill", count = vim.bo.textwidth }) end)()
    end
    return 0
  end
  on_lines("org-fill-paragraph", vim.v.lnum, vim.v.lnum + vim.v.count - 1)
  return 0
end

-- =: org indents the lines (a src block's by its language).
function _G.EmacsIndentOp()
  on_lines("indent-region", vim.fn.line("'["), vim.fn.line("']"))
end

-- Keys each menu buffer (agenda) forwards to Emacs, as keytrans names.
local menu_keys = {}

-- Keys that can follow C-u as Emacs commands: C-c sequences, M-x, the
-- Normal-mode keys in config.keys.n and a menu buffer's keys (C-u r).
local function prefixable(key)
  if key == "<C-C>" or key == "<M-x>" then return true end
  local menu = menu_keys[api.nvim_get_current_buf()]
  if menu and menu[key] then return true end
  for _, k in ipairs(mirror.config.keys.n) do
    if vim.fn.keytrans(api.nvim_replace_termcodes(k, true, true, true)) == key then return true end
  end
  return false
end

-- C-u as Emacs's universal argument when an Emacs key follows within
-- 'timeoutlen' (org's own messages say "press C-u C-c C-c"); otherwise
-- Neovim's scroll. Each press scrolls at once, so plain scrolling doesn't
-- wait; an Emacs key puts the view back before it runs.
local function universal_argument()
  local view = vim.fn.winsaveview()
  local arg = 4
  while true do
    vim.cmd([[exe "normal! \<C-u>"]])
    ui.redraw()
    if not vim.wait(vim.o.timeoutlen, function() return vim.fn.getchar(1) ~= 0 end, 10) then return end
    local key = vim.fn.keytrans(vim.fn.getcharstr())
    if key ~= "<C-U>" then
      if prefixable(key) then
        vim.fn.winrestview(view)
        mirror.exec({ keys = keys.to_emacs(key), count = arg })
      else
        api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "m", false)
      end
      return
    end
    arg = arg * 4
  end
end

-- Where Insert-mode typing goes through Emacs: table rows (columns stay
-- aligned; a TAB'd-into field is blanked) and, with org-use-speed-commands,
-- a heading's start. Elsewhere Vim inserts the text, so . and counts repeat
-- it; tags on a heading are realigned when Insert mode ends.
local function emacs_types_here()
  if on_table_row() then return true end
  local st = mirror.state[api.nvim_get_current_buf()]
  return st and st.speed and api.nvim_win_get_cursor(0)[2] == 0 and on_heading()
end

vim.keymap.set("i", "<Plug>(emacs-open-line)", guarded(function()
  break_undo()
  mirror.exec({ keys = "C-e", after = { "RET" } })
  open_line_typing = { buf = api.nvim_get_current_buf(), keys = {} }
end))

api.nvim_create_autocmd("InsertLeave", {
  group = group,
  callback = function()
    local typing = open_line_typing
    open_line_typing = nil
    if not typing or typing.buf ~= api.nvim_get_current_buf() then return end
    table.remove(typing.keys) -- the key that left Insert mode
    remember_change({ replay = "o" .. table.concat(typing.keys) .. "\27" }, -1)
  end,
})

-- Neovim's spelling of a key Emacs binds in a menu buffer: "|", or "M-m".
local MENU_KEY_NAMES = { ["|"] = "Bar", ["<"] = "lt", ["\\"] = "Bslash" }
local function menu_key_lhs(k)
  local meta = k:match("^M%-(.)$")
  if meta then return "<M-" .. (MENU_KEY_NAMES[meta] or meta) .. ">" end
  return k == "|" and "<Bar>" or k
end

local function install_menu_keys(buf)
  local keep = {}
  for _, k in ipairs(mirror.config.passthrough) do keep[k] = true end
  local forwarded = {}
  local function forward(lhs)
    map(buf, "n", lhs, key_handler(lhs, "n"))
    forwarded[vim.fn.keytrans(api.nvim_replace_termcodes(lhs, true, true, true))] = true
  end
  -- Only keys Emacs binds there: unbound ones (G, 12G) stay Neovim's
  -- instead of typing into column view's buffer.
  local st = mirror.state[buf]
  for _, k in ipairs(st.keys) do
    local lhs = menu_key_lhs(k)
    if not keep[k] then
      forward(lhs)
      -- Under evil, the selection is the region: V then s stages those lines.
      if st.visual and #k == 1 then map(buf, "x", lhs, key_handler(lhs, "x")) end
    end
  end
  for _, k in ipairs(MENU_BUFFER_KEYS) do forward(k) end
  menu_keys[buf] = forwarded
  -- Motions Neovim keeps (j, k) must reach Emacs too: follow mode shows
  -- the entry at point, and hooks know which agenda block point is in.
  api.nvim_create_autocmd("CursorMoved", {
    group = group, buffer = buf,
    callback = function() mirror.schedule_point_sync(buf) end,
  })
end

local function install_org_keys(buf)
  for lhs, command in pairs(mirror.config.fold_commands) do
    -- zv reveals the cursor line itself; the others act on its fold.
    local at_fold = command ~= "org-reveal"
    map(buf, "n", lhs, guarded(function() mirror.exec({ command = command, at_fold = at_fold }) end))
  end
  vim.bo[buf].formatexpr = "v:lua.EmacsFormatExpr()"
  -- A space typed last fills too, as in Emacs: Vim asks only on the
  -- character after it.
  api.nvim_create_autocmd("InsertLeave", {
    group = group, buffer = buf,
    callback = guarded(function()
      local tw, fo = vim.bo[buf].textwidth, vim.bo[buf].formatoptions
      if tw == 0 or not fo:find("[tc]") or on_heading() then return end
      if vim.b[buf].emacs_insert_tick == api.nvim_buf_get_changedtick(buf) then return end
      local row, col = unpack(api.nvim_buf_get_mark(buf, "^"))
      local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      if col == 0 or not line:sub(col, col):match("%s") or vim.fn.strdisplaywidth(line:sub(1, col)) <= tw then
        return
      end
      mirror.exec({ command = "nvb-auto-fill", count = tw, point = { row - 1, col } })
    end),
  })
  if not has_vim_repeat() then
    map(buf, "n", ".", function()
      local r = last_change
      if r and r.buf == buf and r.tick == api.nvim_buf_get_changedtick(buf) then
        guarded(repeat_change)()
      else
        api.nvim_feedkeys((vim.v.count > 0 and vim.v.count or "") .. ".", "n", false)
      end
    end)
  end
  for what, letter in pairs(mirror.config.textobjects) do
    if letter then
      for prefix, inner in pairs({ a = false, i = true }) do
        map(buf, { "o", "x" }, prefix .. letter, guarded(function() mirror.select(what, inner) end))
      end
    end
  end
  local function indent_op(motion)
    return function()
      vim.o.operatorfunc = "v:lua.EmacsIndentOp"
      return "g@" .. motion
    end
  end
  local opts = { buffer = buf, expr = true, desc = "org-bridge.nvim" }
  vim.keymap.set({ "n", "x" }, "=", indent_op(""), opts)
  vim.keymap.set("n", "==", indent_op("_"), opts)
  -- Text typed on a heading went in as Vim's: realign its tags as Emacs
  -- would have while typing, in the same undo step. Emacs realigns only
  -- tags that were there, typed before (org-fix-tags-on-the-fly); tags
  -- just typed stay where they are.
  local function line_tags() return on_heading() and api.nvim_get_current_line():match("%s(:[^%s]+:)%s*$") end
  api.nvim_create_autocmd("InsertEnter", {
    group = group, buffer = buf,
    callback = function()
      vim.b[buf].emacs_insert_tick = api.nvim_buf_get_changedtick(buf)
      vim.b[buf].emacs_insert_tags = line_tags() or false
    end,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = group, buffer = buf,
    callback = guarded(function()
      if vim.b[buf].emacs_insert_tick == api.nvim_buf_get_changedtick(buf) then return end
      local tags = line_tags()
      if not tags or tags ~= vim.b[buf].emacs_insert_tags then return end
      mirror.exec({ command = "nvb-align-tags" })
    end),
  })
  -- o is Emacs's C-e RET (a new line in a list item stays in the item),
  -- except on table rows, where RET means the next row.
  if mirror.config.emacs_typing then
    map(buf, "n", "o", function()
      if vim.v.count > 0 or on_table_row() then
        return api.nvim_feedkeys(vim.v.count1 .. "o", "ni", false)
      end
      -- Fed to the front of typeahead, so in reverse: A, then C-e RET
      -- from Insert mode (org-special-ctrl-e stops C-e before tags).
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Plug>(emacs-open-line)", true, false, true), "mi", false)
      api.nvim_feedkeys("A", "ni", false)
    end)
  end
  -- RET is org-return everywhere (next table row, tags stay on the
  -- heading, links followed, item bodies indented). BS and Del go
  -- through Emacs where typing does; elsewhere they are Neovim's.
  for _, k in ipairs({ "<CR>", "<BS>", "<Del>" }) do
    map(buf, "i", k, function()
      if mirror.config.emacs_typing and (k == "<CR>" or emacs_types_here()) then
        key_handler(k, "i")()
      else
        -- "i": insert at the front of typeahead, ahead of keys typed after it.
        api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "ni", false)
      end
    end)
  end
end

local function install_edit_keys(buf)
  for mode, list in pairs(mirror.config.keys) do
    for _, k in ipairs(list) do map(buf, mode, k, key_handler(k, mode)) end
  end
  if mirror.config.emacs_typing then
    api.nvim_create_autocmd("InsertCharPre", {
      group = group, buffer = buf,
      callback = function()
        if not emacs_types_here() then return end
        -- An earlier handler (an autopair) may have made v:char several
        -- characters: each is a key. The buffer can't change here; queue.
        for _, c in ipairs(vim.fn.split(vim.v.char, "\\zs")) do mirror.type_key(keys.to_emacs(c)) end
        vim.v.char = ""
      end,
    })
  end
  if vim.bo[buf].filetype == "org" then install_org_keys(buf) end
end

local function install_keys(buf, kind)
  menu_keys[buf] = nil
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, "")) do
    if m.desc == "org-bridge.nvim" then vim.keymap.del(m.mode, m.lhs, { buffer = buf }) end
  end
  -- A file of another type Emacs shows (a link to a .txt) stays in sync
  -- but keeps Neovim's keys, unless Emacs edits it for emacsclient or has
  -- it read-only (blame).
  local st = mirror.state[buf]
  if not st.special and not st.server and kind == "edit" and not vim.tbl_contains(mirror.config.filetypes, vim.bo[buf].filetype) then
    return
  end
  -- Org's messages say "press C-u C-c C-c".
  map(buf, "n", "<C-u>", guarded(universal_argument))
  if kind == "menu" then install_menu_keys(buf) else install_edit_keys(buf) end
end

mirror.on_kind = install_keys

-- Emacs provides all highlighting; Neovim's own org syntax (0.13 ships
-- one) or treesitter would add attributes under Emacs's faces.
local function own_highlighting_off(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].syntax = "OFF"
  vim.treesitter.stop(buf)
end

mirror.on_bind = function(buf)
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.schedule(function() own_highlighting_off(buf) end)
  api.nvim_create_autocmd("Syntax", {
    group = group, buffer = buf,
    callback = function() if vim.bo[buf].syntax ~= "OFF" then own_highlighting_off(buf) end end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = buf, callback = mirror.schedule_sync,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group, buffer = buf,
    callback = function()
      if rpc.depth > 0 or not mirror.state[buf] then return end
      mirror.refresh_folds(buf)
      refresh_spans(buf)
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group, buffer = buf,
    callback = function() refresh_spans(buf) end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group, buffer = buf,
    callback = function()
      local id = mirror.id(buf)
      -- :w copy.org writes a copy and leaves the buffer modified.
      if id and rpc.depth == 0 and not vim.bo[buf].modified then rpc.call("saved", { id = id }) end
    end,
  })
  api.nvim_create_autocmd("BufReadPost", {
    group = group, buffer = buf, callback = function() mirror.on_reload(buf) end,
  })
  api.nvim_create_autocmd("BufFilePost", {
    group = group, buffer = buf, callback = guarded(function() mirror.on_rename(buf) end),
  })
  if mirror.state[buf].special then
    -- Editable Emacs buffers (src edit, capture) are acwrite: :w saves
    -- through Emacs.
    api.nvim_create_autocmd("BufWriteCmd", {
      group = group, buffer = buf,
      callback = guarded(function()
        mirror.exec({ keys = "C-x C-s" })
        -- Some editors' C-x C-s also closes them (*Edit Formulas*).
        if api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end
      end),
    })
  end
  api.nvim_create_autocmd("BufUnload", {
    group = group, buffer = buf, callback = function() mirror.detach(buf) end,
  })
  -- Wiping a loaded buffer unloads it first, except when Neovim names one
  -- (:w on a buffer without a name): that keeps the buffer, and only its
  -- maps and autocmds are wiped.
  api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = buf, callback = function()
      if not api.nvim_buf_is_loaded(buf) then return mirror.detach(buf) end
      mirror.rebind_later(buf)
    end,
  })
end

local function attach_current(ev)
  -- During a call, Emacs is mid-command; buffers it creates are bound by
  -- the mirror layer itself.
  if vim.bo[ev.buf].buftype ~= "" or rpc.depth > 0 then return end
  -- Starting Emacs takes a second: show the text meanwhile. Attaching stays
  -- synchronous, so keys typed during the wait run after the org mappings
  -- exist.
  if not rpc.running() then ui.redraw() end
  local ok, err = pcall(mirror.attach, ev.buf)
  if not ok then
    api.nvim_echo({ { "org-bridge.nvim: " .. tostring(err), "ErrorMsg" } }, true, {})
    return
  end
  if api.nvim_get_current_buf() == ev.buf then refresh_spans(ev.buf) end
end

-- A table option that names its entries (textobjects, fold_commands, keys
-- by mode) takes the user's entries over the defaults; a list replaces.
local function option(default, v)
  local is_list = vim.islist or vim.tbl_islist
  if type(default) == "table" and type(v) == "table" and not is_list(default) then
    return vim.tbl_extend("force", default, v)
  end
  return v
end

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if rpc.config[k] ~= nil then rpc.config[k] = v
    elseif mirror.config[k] ~= nil then mirror.config[k] = option(mirror.config[k], v)
    elseif k == "faces" then faces.links = vim.tbl_extend("force", faces.links, v)
    else error("org-bridge.nvim: unknown option " .. k) end
  end
  -- Its own group, so calling setup() again replaces these instead of
  -- adding a second copy.
  local setup_group = api.nvim_create_augroup("org-bridge.nvim.setup", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = setup_group, pattern = mirror.config.filetypes, callback = attach_current,
  })
  -- An error in an earlier FileType handler (another org plugin's) skips
  -- ours: attach when the buffer is shown instead.
  api.nvim_create_autocmd("BufWinEnter", {
    group = setup_group,
    callback = function(ev)
      if not mirror.state[ev.buf] and vim.tbl_contains(mirror.config.filetypes, vim.bo[ev.buf].filetype) then
        attach_current(ev)
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = setup_group, callback = faces.redefine_all })
  api.nvim_create_autocmd("OptionSet", {
    group = setup_group, pattern = "background",
    callback = guarded(function()
      if not rpc.running() then return end
      rpc.call("background", { background = vim.o.background })
      for _, win in ipairs(api.nvim_list_wins()) do refresh_spans(api.nvim_win_get_buf(win)) end
    end),
  })
  -- A session's manual folds would hide what Emacs shows; like Emacs's
  -- desktop, a restored buffer gets the folds a reopened file has.
  api.nvim_create_autocmd("SessionLoadPost", {
    group = setup_group,
    callback = function()
      for buf in pairs(mirror.state) do
        if api.nvim_buf_is_loaded(buf) then mirror.refresh_folds(buf) end
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", { group = setup_group, callback = M.shutdown })
  rpc.on_exit = mirror.reset
  -- Buffers opened before setup().
  M.attach_all()
end

M.exec = mirror.exec

-- For 'statusline': what Emacs adds to its mode line, like a running org
-- clock ("[0:42] (Write report)"), and in read-only Emacs buffers their
-- own mode line ("Org-Agenda Week Log Follow").
function M.statusline()
  local st = mirror.state[api.nvim_get_current_buf()]
  local own = st and st.kind == "menu" and st.mode_line or ""
  return vim.trim(own .. " " .. mirror.modeline)
end

-- The clock's minutes change without any command; refresh while one shows.
local MODELINE_REFRESH_MS = 30000
vim.loop.new_timer():start(MODELINE_REFRESH_MS, MODELINE_REFRESH_MS, vim.schedule_wrap(function()
  if mirror.modeline == "" or rpc.depth > 0 or not rpc.running() then return end
  -- Emacs may be exiting (Neovim quits while a clock runs): skip a beat.
  local ok, modeline = pcall(rpc.call, "modeline")
  if not ok then return end
  mirror.modeline = modeline
  vim.cmd("redrawstatus!")
end))

-- Stop Emacs, offering to clock out first: a clock left running stays in
-- the file as an open CLOCK line, which the next clock-in has to resolve.
function M.shutdown()
  if mirror.modeline ~= "" and rpc.running() and rpc.depth == 0
      and rpc.call("eval", { expr = "(org-clocking-p)" }) ~= "nil"
      and vim.fn.confirm("An org clock is running. Clock out?", "&Yes\n&No", 1) == 1 then
    mirror.exec({ command = "org-clock-out" })
    vim.cmd("silent! wall")
  end
  rpc.stop()
  mirror.modeline = ""
end

-- Attach every loaded buffer of a mirrored filetype (after a restart).
function M.attach_all()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(mirror.config.filetypes, vim.bo[buf].filetype) then
      attach_current({ buf = buf })
    end
  end
end

-- Evaluate Elisp in the current buffer's mirror (if any); returns its printed value.
function M.eval(expr)
  mirror.sync()
  return rpc.call("eval", { expr = expr, id = mirror.id(api.nvim_get_current_buf()) })
end

return M
