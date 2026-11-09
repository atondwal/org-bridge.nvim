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

rpc.handlers.read_string = function(p)
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

rpc.handlers.completing_read = function(p)
  candidates = p.candidates or {}
  local s = input({
    prompt = p.prompt, default = p.initial or "", cancelreturn = CANCELLED,
    completion = "customlist,EmacsComplete",
  }, p.history)
  candidates = {}
  if s == CANCELLED then quit() end
  return s
end

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
