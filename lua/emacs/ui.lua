-- Answers to Emacs's requests for user input. All of these block: they run
-- inside an RPC call, when Neovim is not processing typeahead itself.
local rpc = require("emacs.rpc")
local keys = require("emacs.keys")
local faces = require("emacs.faces")

local M = {}

local function quit() error("quit", 0) end

-- Show the prompt before blocking on a key. Only a UI needs it; headless
-- Neovim 0.13-dev can hit a redraw assertion here (grid_line_flush).
local function redraw()
  if #vim.api.nvim_list_uis() > 0 then vim.cmd("redraw") end
end
M.redraw = redraw

local function float_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  -- Gone with its window, so menus and previews leave no buffers behind.
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

-- Show Emacs's menu text (org's fast-selection and dispatcher buffers) in a
-- float while a key is read.
local MENU_NS = vim.api.nvim_create_namespace("emacs.menu")

-- p: { context = text, context_spans, context_top } from Emacs.
local function show_context(p, text)
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
  if #lines == 0 then return nil end
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  local buf = float_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, s in ipairs(p.context_spans or {}) do
    -- Emacs's default face is the window's own colors: the float's, not
    -- Normal's (the tag menu marks unchosen tags with it).
    if s[4] and s[4] ~= "default" and s[1] < #lines then
      vim.api.nvim_buf_set_extmark(buf, MENU_NS, s[1], s[2],
        { end_col = s[3], hl_group = faces.group(s[4]), strict = false })
    end
  end
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = "rounded",
    row = math.max(0, vim.o.lines - height - 4), col = 0,
    width = math.min(width, vim.o.columns - 2), height = height,
    -- Emacs scrolls long menus with SPC and DEL.
    title = height < #lines and " SPC/DEL scroll " or nil,
  })
  if p.context_top and p.context_top > 0 then
    vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = p.context_top + 1 }) end)
  end
  redraw()
  return win
end

-- How long a prefix (C-c) waits for the next key before showing them all.
local WHICH_KEY_DELAY_MS = 500
-- Longer command names are cut, so more columns fit.
local WHICH_KEY_NAME_WIDTH = 30

vim.api.nvim_set_hl(0, "EmacsWhichKey", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "EmacsWhichKeyGroup", { link = "Keyword", default = true })
vim.api.nvim_set_hl(0, "EmacsWhichKeySeparator", { link = "Comment", default = true })

-- The keys that can follow a prefix, { key, command } pairs from Emacs, in
-- columns across the bottom of the screen, as which-key shows them.
local function show_which(which)
  local key_width, name_width = 0, 0
  for _, kc in ipairs(which) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(kc[1]))
    name_width = math.max(name_width, math.min(vim.fn.strdisplaywidth(kc[2]), WHICH_KEY_NAME_WIDTH))
  end
  local cell = key_width + 3 + name_width + 2
  local cols = math.max(1, math.floor((vim.o.columns - 2) / cell))
  local rows = math.ceil(#which / cols)
  local height = math.min(rows, vim.o.lines - 4)
  local lines, marks = {}, {}
  for i = 1, height do lines[i] = "" end
  -- Down each column, then across.
  for i, kc in ipairs(which) do
    local row, col = (i - 1) % rows + 1, math.floor((i - 1) / rows)
    if row <= height then
      local name = vim.fn.strcharpart(kc[2], 0, WHICH_KEY_NAME_WIDTH)
      if name ~= kc[2] then name = vim.fn.strcharpart(name, 0, WHICH_KEY_NAME_WIDTH - 1) .. "…" end
      local start = #lines[row]
      local key = kc[1] .. (" "):rep(key_width - vim.fn.strdisplaywidth(kc[1]))
      local text = key .. " → " .. name
      lines[row] = lines[row] .. text .. (" "):rep(col < cols - 1 and cell - vim.fn.strdisplaywidth(text) or 0)
      marks[#marks + 1] = { row - 1, start, start + #key, "EmacsWhichKey" }
      marks[#marks + 1] = { row - 1, start + #key, start + #key + #" → ", "EmacsWhichKeySeparator" }
      marks[#marks + 1] = { row - 1, start + #key + #" → ", start + #text,
        kc[2] == "+prefix" and "EmacsWhichKeyGroup" or "Normal" }
    end
  end
  local buf = float_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, MENU_NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = "rounded",
    row = vim.o.lines - height - 4, col = 0, width = vim.o.columns - 2, height = height,
    title = height < rows and (" %d more not shown "):format(#which - height * cols) or nil,
  })
  redraw()
  return win
end

-- Clear what a prompt left on the command line, so the next message
-- doesn't stack under it and ask to press Enter.
local function clear_cmdline()
  vim.api.nvim_echo({ { "" } }, false, {})
  redraw()
end

local function echo_prompt(prompt)
  vim.api.nvim_echo({ { prompt, "Question" } }, false, {})
  redraw()
end

rpc.handlers.read_key = function(p)
  -- A prompt that doesn't fit the command line (bulk-action menus) goes in
  -- the float, which would otherwise ask to press Enter.
  local long = p.prompt:find("\n") or vim.fn.strdisplaywidth(p.prompt) >= vim.v.echospace
  local text = long and (p.prompt .. (p.context and "\n\n" .. p.context or "")) or p.context
  if p.faces then faces.add(p.faces) end -- only sent with a menu
  local win = text and show_context(long and {} or p, text)
  echo_prompt(long and "" or p.prompt)
  if not win and p.which and #p.which > 0
      and not vim.wait(WHICH_KEY_DELAY_MS, function() return vim.fn.getchar(1) ~= 0 end, 10) then
    win = show_which(p.which)
  end
  local k = keys.read()
  if win then vim.api.nvim_win_close(win, true) end
  clear_cmdline()
  if not k then quit() end
  return k
end

local CANCELLED = "\1emacs-cancel\1"

-- Replace Neovim's input history with `items` (newest first); returns a
-- function putting the old history back.
local function swap_history(items)
  local saved = {}
  for i = 1, vim.fn.histnr("@") do
    local h = vim.fn.histget("@", i)
    if h ~= "" then saved[#saved + 1] = h end
  end
  vim.fn.histdel("@")
  for i = #items, 1, -1 do vim.fn.histadd("@", items[i]) end
  return function()
    vim.fn.histdel("@")
    for _, h in ipairs(saved) do vim.fn.histadd("@", h) end
  end
end

-- read(arg) where C-g cancels the command line too, as Emacs users press
-- by reflex.
local function with_cg(read, arg)
  local own = vim.fn.maparg("<C-g>", "c") == ""
  if own then vim.keymap.set("c", "<C-g>", "<C-c>") end
  local ok, s = pcall(read, arg)
  if own then vim.keymap.del("c", "<C-g>") end
  if not ok then error(s, 0) end
  return s
end

-- vim.fn.input where C-g cancels too, and Up/Down walk Emacs's history for
-- this prompt (stored links, say).
local function input(opts, history)
  local restore = swap_history(history or {})
  local ok, s = pcall(with_cg, vim.fn.input, opts)
  restore()
  if not ok then error(s, 0) end
  return s
end

-- vim.fn.inputsecret, cancelled as `input`: it has no cancelreturn, so a
-- cancel shows only as the command line's abort.
local function inputsecret(prompt)
  local aborted
  vim.api.nvim_create_autocmd("CmdlineLeave", { once = true,
    callback = function() aborted = vim.v.event.abort end })
  local s = with_cg(vim.fn.inputsecret, prompt)
  return aborted and CANCELLED or s
end

local CALENDAR_NS = vim.api.nvim_create_namespace("emacs_calendar")

-- A float above the command line (and, as Emacs keeps the mode line, the
-- statusline) with org's calendar around a date and its "=> <date>"
-- reading, the day highlighted.
local function calendar_float()
  local buf = float_buf()
  local win
  -- Text that doesn't parse yet keeps the last calendar; the months it
  -- shows stay while the date is in them, as in Emacs.
  local calendar, cursor, view = {}, nil, nil
  local cal = {}
  -- `text` with its date moved by Emacs's calendar `command`.
  function cal.move(text, command)
    local moved = rpc.call("date_move", { text = text, command = command, view = view })
    view = moved.view
    return moved.text
  end
  -- Emacs's reading of `text`, between optional `header` and `footer` lines.
  function cal.show(text, header, footer)
    local preview = rpc.call("date_preview", { text = text, view = view })
    if preview.calendar then calendar, cursor, view = preview.calendar, preview.cursor, preview.view end
    local lines = header and { header } or {}
    local top = #lines
    vim.list_extend(lines, calendar)
    lines[#lines + 1] = preview.text
    if footer then lines[#lines + 1] = footer end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, CALENDAR_NS, 0, -1)
    if cursor then
      vim.api.nvim_buf_set_extmark(buf, CALENDAR_NS, top + cursor[1], cursor[2],
        { end_col = cursor[2] + 2, hl_group = "Search" })
    end
    local width = 1
    for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
    local statusline = (vim.o.laststatus == 3 or vim.o.laststatus == 2 or
      (vim.o.laststatus == 1 and #vim.api.nvim_tabpage_list_wins(0) > 1)) and 1 or 0
    local cfg = { relative = "editor", style = "minimal",
      row = vim.o.lines - vim.o.cmdheight - statusline - #lines,
      col = 0, width = width, height = #lines }
    if win then vim.api.nvim_win_set_config(win, cfg) else win = vim.api.nvim_open_win(buf, false, cfg) end
    redraw()
  end
  function cal.close()
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  return cal
end

-- Keys that move the picked date: Emacs's calendar commands.
local PICK_MOVES = {
  h = "calendar-backward-day", l = "calendar-forward-day",
  j = "calendar-forward-week", k = "calendar-backward-week",
  H = "calendar-backward-month", L = "calendar-forward-month", t = "calendar-goto-today",
  ["<Left>"] = "calendar-backward-day", ["<Right>"] = "calendar-forward-day",
  ["<Down>"] = "calendar-forward-week", ["<Up>"] = "calendar-backward-week",
}
local PICK_HELP = "h/l day  j/k week  H/L month  t today  Enter pick  Esc back to typing"

-- Browse the calendar from `answer` (the prompt's text) with keys; the
-- picked date, or nil to go back to typing.
local function pick_date(prompt, answer)
  local cal = calendar_float()
  local ok, res = pcall(function()
    -- From the answer's date, as a date the keys can move.
    local date = cal.move(answer, "ignore")
    while true do
      cal.show(date, prompt, PICK_HELP)
      local key = vim.fn.keytrans(vim.fn.getcharstr())
      if PICK_MOVES[key] then
        date = cal.move(date, PICK_MOVES[key])
      elseif key == "<CR>" then
        return date
      elseif key == "<Esc>" or key == "<C-G>" or key == "q" then
        return nil
      end
    end
  end)
  cal.close()
  if not ok then error(res, 0) end
  return res
end

-- The keys of org's date prompt (`org-read-date-minibuffer-local-map`) and
-- the calendar commands they run.
local DATE_KEYS = {
  ["<S-Left>"] = "calendar-backward-day", ["<S-Right>"] = "calendar-forward-day",
  ["<S-Up>"] = "calendar-backward-week", ["<S-Down>"] = "calendar-forward-week",
  ["<M-S-Left>"] = "calendar-backward-month", ["<M-S-Right>"] = "calendar-forward-month",
  ["<M-S-Up>"] = "calendar-backward-year", ["<M-S-Down>"] = "calendar-forward-year",
  ["<lt>"] = "calendar-scroll-right", [">"] = "calendar-scroll-left",
  ["<M-v>"] = "calendar-scroll-right-three-months", ["<C-v>"] = "calendar-scroll-left-three-months",
  ["<C-.>"] = "calendar-goto-today",
}

-- While an org date prompt is typed into, show what Emacs makes of the
-- text, as org does in its minibuffer, under the calendar it pops up.
local function date_preview(prompt)
  local cal = calendar_float()
  -- From the moment the prompt opens, not only after the first key.
  local au = vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" },
    { callback = function() cal.show(vim.fn.getcmdline()) end })
  -- Keys the user maps in the command line stay theirs.
  local mapped = {}
  local function map(key, fn)
    if vim.fn.maparg(key, "c") == "" then
      vim.keymap.set("c", key, fn)
      mapped[#mapped + 1] = key
    end
  end
  for key, command in pairs(DATE_KEYS) do
    map(key, function() vim.fn.setcmdline(cal.move(vim.fn.getcmdline(), command)) end)
  end
  -- As in org, "." at the start of the answer is today; elsewhere it's typed.
  map(".", function()
    local text, pos = vim.fn.getcmdline(), vim.fn.getcmdpos()
    if pos == 1 then
      vim.fn.setcmdline(cal.move(text, "calendar-goto-today"))
    else
      vim.fn.setcmdline(text:sub(1, pos - 1) .. "." .. text:sub(pos), pos + 1)
    end
  end)
  -- C-o browses the calendar with keys; the date picked is the answer.
  map("<C-o>", function()
    local date = pick_date(prompt, vim.fn.getcmdline())
    if date then
      vim.fn.setcmdline(date)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  end)
  return function()
    for _, key in ipairs(mapped) do vim.keymap.del("c", key) end
    vim.api.nvim_del_autocmd(au)
    cal.close()
  end
end

-- Keys getcharstr spells with Neovim's internal codes, as a terminal sends
-- them; control characters and text pass as they are.
local TERM_KEYS = {
  ["<Up>"] = "\27[A", ["<Down>"] = "\27[B", ["<Right>"] = "\27[C", ["<Left>"] = "\27[D",
  ["<Home>"] = "\27[H", ["<End>"] = "\27[F", ["<Del>"] = "\27[3~",
  ["<PageUp>"] = "\27[5~", ["<PageDown>"] = "\27[6~", ["<S-Tab>"] = "\27[Z",
  ["<BS>"] = "\127", ["<M-CR>"] = "\27\r",
}

local function term_bytes(raw)
  if raw:byte(1) ~= 0x80 then return raw end
  local key = vim.fn.keytrans(raw)
  local meta = key:match("^<M%-(.)>$")
  return TERM_KEYS[key] or (meta and "\27" .. meta) or ""
end

-- fzf.vim's fzf#run on spec.items, each with its key binding (if any) as a
-- dim second column. Returns the item picked, the query when nothing
-- matches (or on M-CR, to answer with the text typed), or nil if cancelled.
-- With spec.multi, the first spec.selected items start ticked and it
-- returns a list: the ticked items, plus the text typed on M-CR.
local function fzf_pick(spec)
  local width = 0
  if spec.bindings then
    for _, item in ipairs(spec.items) do width = math.max(width, vim.fn.strdisplaywidth(item)) end
  end
  -- Each line starts with its item's index, hidden, so the answer is the
  -- item exactly; only the item, not its binding, is matched.
  local lines = {}
  for i, item in ipairs(spec.items) do
    local key = spec.bindings and spec.bindings[item] or ""
    lines[i] = key == "" and i .. "\t" .. item
      or ("%d\t%s%s\t\27[2m%s\27[0m"):format(i, item, (" "):rep(width - vim.fn.strdisplaywidth(item)), key)
  end
  local insert = vim.fn.mode() == "i"
  local out, done
  local options = { "--prompt", spec.prompt, "--query", spec.query, "--print-query", "--ansi",
    "--delimiter", "\t", "--with-nth", "2..", "--nth", "1",
    -- The shorter item first, not the shorter line: padding before a binding counts there.
    "--tiebreak", "chunk" }
  if spec.multi then
    -- Enter after a search takes the match under the cursor too. Without
    -- one it takes only the ticked items (Tab unticks and moves on), and
    -- none at all if none are: accept alone would take the one under the cursor.
    vim.list_extend(options, { "--multi", "--expect", "alt-enter", "--bind", "enter:transform:"
      .. [[[ -n "$FZF_QUERY" ] && echo select+accept || ]]
      .. [[{ [ "$FZF_SELECT_COUNT" = 0 ] && echo print-query || echo accept; }]] })
    if spec.selected > 0 then
      local ticks = {}
      for i = 1, spec.selected do ticks[i] = ("pos(%d)+select"):format(i) end
      vim.list_extend(options, { "--bind", "load:" .. table.concat(ticks, "+") .. "+first" })
    end
  else
    vim.list_extend(options, { "--bind", "alt-enter:print-query" })
  end
  vim.fn["fzf#run"](vim.fn["fzf#wrap"]({
    source = lines,
    options = options,
    ["sink*"] = function(res) out = res end,
    exit = function() done = true end,
  }))
  -- We're inside an RPC call, so Neovim never enters Terminal mode in
  -- fzf's window: pass the keys typed to fzf here.
  local chan = vim.bo.channel
  while true do
    redraw()
    local typed, status = vim.wait(20, function() return done or vim.fn.getchar(1) ~= 0 end, 5)
    if done then break end
    if typed then
      vim.fn.chansend(chan, term_bytes(vim.fn.getcharstr()))
    elseif status == -2 then
      vim.fn.chansend(chan, "\3")
    end
  end
  -- fzf#run's startinsert would put the org buffer in Insert mode.
  if not insert then vim.cmd("stopinsert") end
  if not out then return nil end
  local function item(line) return spec.items[tonumber(line:match("^(%d+)\t"))] end
  if spec.multi then
    -- Lines: the query, the --expect key pressed, then the ticked items.
    local picked = vim.tbl_map(item, vim.list_slice(out, 3))
    if out[2] == "alt-enter" and out[1] ~= "" then picked[#picked + 1] = out[1] end
    return picked
  end
  return out[2] and item(out[2]) or out[1]
end

-- Picks a completing_read answer from a list. Tests set it; otherwise fzf,
-- when fzf.vim is loaded and there's a screen to show it on.
M.picker = nil

local function picker()
  if M.picker then return M.picker end
  if #vim.api.nvim_list_uis() > 0 and vim.fn.exists("*fzf#run") == 1 then return fzf_pick end
end

-- completing-read-multiple (org's tags): the items already given come
-- first, ticked; the answer is the ticked items joined as Emacs splits them.
local function pick_many(pick, p)
  local items, given = {}, {}
  for _, s in ipairs(p.selected) do
    given[s] = true
    items[#items + 1] = s
  end
  for _, c in ipairs(p.multiple) do
    if not given[c] then items[#items + 1] = c end
  end
  local picked = pick({ prompt = p.prompt, query = "", items = items, multi = true, selected = #p.selected })
  if not picked then quit() end
  return table.concat(picked, p.joiner)
end

function M.read_string(p)
  local pick = p.multiple and picker()
  if pick then return pick_many(pick, p) end
  local opts = { prompt = p.prompt, default = p.initial or "", cancelreturn = CANCELLED,
    completion = p.completion }
  local s
  if p.secret then
    s = inputsecret(p.prompt)
  else
    local close = p.date and date_preview(p.prompt)
    local ok, res = pcall(input, opts, p.history)
    if close then close() end
    if not ok then error(res, 0) end
    s = res
  end
  if s == CANCELLED then quit() end
  return s
end
rpc.handlers.read_string = M.read_string

-- Candidates for the completing_read in progress, used by EmacsComplete().
local candidates = {}

function M.complete(arglead)
  -- Ask Emacs: its tables can be dynamic (outline paths complete one
  -- segment at a time). With no prefix matches, try substrings, as
  -- Emacs's completion styles would.
  local live = rpc.call("complete", { prefix = arglead })
  if #live > 1 then
    -- Like Emacs's TAB: first extend to what all candidates share.
    local common = live[1]
    for _, c in ipairs(live) do
      while c:sub(1, #common) ~= common do
        -- Whole characters, so the prefix stays valid UTF-8.
        common = vim.fn.strcharpart(common, 0, vim.fn.strchars(common) - 1)
      end
    end
    if #common > #arglead then return { common } end
  end
  if #live > 0 then return live end
  local out = {}
  local lower = arglead:lower()
  for _, c in ipairs(candidates) do
    if c:lower():find(lower, 1, true) then out[#out + 1] = c end
  end
  return out
end

vim.cmd([[
function! EmacsComplete(A, L, P) abort
  return luaeval('require("emacs.ui").complete(_A)', a:A)
endfunction
]])

-- The answers to show, in order: the default, Emacs's history for this
-- prompt (newest first), then the candidates.
local function picker_items(p)
  local is_candidate = {}
  for _, c in ipairs(p.candidates or {}) do is_candidate[c] = true end
  local items, seen = {}, {}
  local function add(c)
    -- With require_match, only candidates are answers.
    if c and c ~= "" and not seen[c] and (is_candidate[c] or not p.require_match) then
      seen[c] = true
      items[#items + 1] = c
    end
  end
  add(p.default)
  for _, h in ipairs(p.history or {}) do add(h) end
  for _, c in ipairs(p.candidates or {}) do add(c) end
  return items
end

function M.completing_read(p)
  local pick = picker()
  -- A dynamic table's candidates aren't all its answers: complete with Tab.
  if pick and not p.dynamic then
    local bindings
    if p.bindings then
      bindings = {}
      for i, c in ipairs(p.candidates) do bindings[c] = p.bindings[i] end
    end
    local s = pick({ prompt = p.prompt, query = p.initial or "", items = picker_items(p), bindings = bindings })
    if not s then quit() end
    return s
  end
  candidates = p.candidates or {}
  local s = input({
    prompt = p.prompt, default = p.initial or "", cancelreturn = CANCELLED,
    completion = "customlist,EmacsComplete",
  }, p.history)
  candidates = {}
  if s == CANCELLED then quit() end
  return s
end
rpc.handlers.completing_read = M.completing_read

rpc.handlers.confirm = function(p)
  if p.typed then
    -- yes-or-no-p: Emacs makes you type the word for risky actions.
    while true do
      local s = rpc.handlers.read_string({ prompt = p.prompt .. "(yes or no) " })
      clear_cmdline()
      if s == "yes" or s == "no" then return s == "yes" end
    end
  end
  local choice = vim.fn.confirm(p.prompt, "&Yes\n&No", 2)
  clear_cmdline()
  if choice == 0 then quit() end
  return choice == 1
end

return M
