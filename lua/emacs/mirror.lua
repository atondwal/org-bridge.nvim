-- Mirrors: Neovim buffers paired with Emacs buffers. Text flows both ways
-- (whole-buffer, diffed on arrival); folds, faces and concealed text flow
-- from Emacs to Neovim.
local rpc = require("emacs.rpc")
local faces = require("emacs.faces")
local api = vim.api

local M = {}

local NS = api.nvim_create_namespace("emacs")
local SYNC_DELAY_MS = 150
local POINT_SYNC_DELAY_MS = 150
-- How often a change Emacs made outside a command checks whether the
-- call in flight is done.
local PULL_RETRY_MS = 50
-- Lines fetched beyond the visible range so small scrolls stay highlighted.
local SPAN_MARGIN = 40
local HAS_0_10 = vim.fn.has("nvim-0.10") == 1
local HAS_0_11 = vim.fn.has("nvim-0.11") == 1

M.config = {
  filetypes = { "org" },
  -- Hide text Emacs makes invisible within a line (link brackets). Before
  -- Neovim 0.13 (neovim#40897, #42370), 'wrap' breaks lines at their
  -- unconcealed width, so concealed lines break early.
  conceal = vim.fn.has("nvim-0.13") == 1,
  -- Send characters typed on table lines in Insert mode through Emacs, so
  -- org-self-insert-command can blank a cell after TAB and keep columns
  -- from widening. One round trip per key, on table lines only.
  emacs_typing = true,
  -- Keys sent to Emacs in editable mirrors, by mode.
  keys = {
    n = { "<Tab>", "<S-Tab>", "<M-CR>", "<C-CR>", "<S-CR>", "<M-S-CR>", "<C-S-CR>", "<M-Left>", "<M-Right>", "<M-Up>",
      "<M-Down>", "<M-S-Left>", "<M-S-Right>", "<M-S-Up>", "<M-S-Down>", "<S-Left>",
      "<S-Right>", "<S-Up>", "<S-Down>", "<C-S-Left>", "<C-S-Right>", "<C-S-Up>", "<C-S-Down>",
      "<C-c>", "<M-x>" },
    i = { "<Tab>", "<S-Tab>", "<S-CR>", "<M-CR>", "<C-CR>", "<M-S-CR>", "<C-S-CR>", "<M-Left>",
      "<M-Right>", "<M-Up>", "<M-Down>", "<M-S-Left>", "<M-S-Right>", "<M-S-Up>", "<M-S-Down>",
      "<C-S-Left>", "<C-S-Right>", "<C-S-Up>", "<C-S-Down>", "<C-c>", "<M-Tab>" },
    x = { "<C-c>", "<M-x>", "<M-Left>", "<M-Right>", "<M-Up>", "<M-Down>", "<M-S-Left>",
      "<M-S-Right>", "<M-S-Up>", "<M-S-Down>" },
  },
  -- Text object letters in org buffers: ar/ir a subtree (inner: without
  -- its heading), ae/ie the org element at the cursor (inner: its
  -- contents). false leaves the letter alone.
  textobjects = { subtree = "r", element = "e" },
  -- Neovim fold keys in org buffers, as Emacs commands.
  fold_commands = {
    zo = "nvb-fold-open", zO = "org-fold-show-subtree", zc = "org-fold-hide-subtree",
    zC = "org-fold-hide-subtree", za = "nvb-fold-toggle", zA = "nvb-fold-toggle",
    zR = "org-fold-show-all", zM = "org-overview", zv = "org-reveal",
  },
  -- In read-only Emacs buffers (agenda) and column view, printable keys
  -- Emacs binds there go to Emacs; these stay Neovim's anyway. Digits stay
  -- counts, which become prefix arguments.
  -- g keeps gg working; the agenda's redo is still on r.
  passthrough = { "j", "k", "g", "G", ":" },
}

-- Normal-mode keys that insert after "this line": with the cursor on the
-- last character they get point at the end of the line, as a Vim user means.
local EOL_KEYS = { ["M-RET"] = true, ["<C-return>"] = true, ["<M-S-return>"] = true,
  ["<C-S-return>"] = true }
M.EOL_KEYS = EOL_KEYS

-- Special buffers whose filetype comes from their name, not their mode.
local NAME_FILETYPES = { ["*Org MD Export*"] = "markdown" }

-- Neovim filetypes for Emacs major modes whose name differs.
local FILETYPES = {
  ["emacs-lisp-mode"] = "lisp", ["lisp-interaction-mode"] = "lisp", ["c++-mode"] = "cpp",
  ["js-mode"] = "javascript", ["sh-mode"] = "sh", ["shell-script-mode"] = "sh",
  ["mhtml-mode"] = "html", ["latex-mode"] = "tex", ["LaTeX-mode"] = "tex",
}

-- Per-buffer state, keyed by Neovim buffer.
local state = {}
local by_id = {}

function M.id(buf) return state[buf] and state[buf].id end

-- Emacs reads the socket as UTF-8; raw bytes would corrupt positions.
local function check_utf8(buf, text)
  if not text:find("[\128-\255]") then return end
  local rest = text:gsub("[\194-\223][\128-\191]", "")
    :gsub("[\224-\239][\128-\191][\128-\191]", "")
    :gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
  if rest:find("[\128-\255]") then
    error(("org-bridge.nvim: %s is not valid UTF-8; Emacs can't mirror it"):format(
      api.nvim_buf_get_name(buf)), 0)
  end
end

-- Whether a buffer of one empty line has no lines at all (writes an empty
-- file): both read as { "" }. What :w writes, wordcount's bytes, tells
-- them apart; line2byte doesn't after an undo.
local function no_lines(buf)
  return api.nvim_buf_call(buf, function() return vim.fn.wordcount().bytes end) == 0
end

local function buf_text(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local lone = #lines == 1 and lines[1] == ""
  if vim.bo[buf].eol and not (lone and no_lines(buf)) then text = text .. "\n" end
  check_utf8(buf, text)
  return text
end

-- Hunks { first, count, lines } turning line list `old` into `new`: replace
-- `count` lines from 0-based `first` (old's numbering) with `lines`.
local function diff_hunks(old, new)
  -- No lines is "", not one empty line.
  local function join(lines) return #lines == 0 and "" or table.concat(lines, "\n") .. "\n" end
  local diff = vim.diff(join(old), join(new), { result_type = "indices", algorithm = "histogram" })
  return vim.tbl_map(function(d)
    local sa, ca, sb, cb = unpack(d)
    -- A pure insertion's start index is the line it follows.
    return { ca == 0 and sa or sa - 1, ca, vim.list_slice(new, sb, sb + cb - 1) }
  end, diff)
end

-- Replace lines first.. of buf, now `old`, with `new`, touching only the
-- lines that differ: a line edited in place keeps its marks (set_text),
-- so marks, the jumplist and gv survive commands that rewrite a region.
local function replace_lines(buf, first, old, new)
  local hunks = diff_hunks(old, new)
  for i = #hunks, 1, -1 do
    local from, count, lines = unpack(hunks[i])
    if count == #lines then
      for j = 1, count do
        local row = first + from + j - 1
        api.nvim_buf_set_text(buf, row, 0, row, #old[from + j], { lines[j] })
      end
    else
      api.nvim_buf_set_lines(buf, first + from, first + from + count, false, lines)
    end
  end
end

local function set_text(buf, text)
  local old = buf_text(buf)
  if old == text then return end
  local eol = text:sub(-1) == "\n"
  -- No lines at all, not one empty line: only that writes an empty file.
  local new_lines = text == "" and {} or vim.split(eol and text:sub(1, -2) or text, "\n", { plain = true })
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  replace_lines(buf, 0, api.nvim_buf_get_lines(buf, 0, -1, false), new_lines)
  vim.bo[buf].eol = eol or text == ""
  vim.bo[buf].modifiable = modifiable
end

---------------------------------------------------------------------------
-- Folds and spans
---------------------------------------------------------------------------

-- The fold's first line, in Emacs's faces when Neovim can draw them (0.10+
-- takes [text, hl] chunks), followed by Emacs's ellipsis.
function _G.EmacsFoldText()
  local buf = api.nvim_get_current_buf()
  local row = vim.v.foldstart - 1
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local st = state[buf]
  -- Agenda filters hide lines without an ellipsis.
  local ellipsis = (st and st.no_ellipsis[vim.v.foldstart]) and "" or (st and st.ellipsis or "...")
  local tab = string.rep(" ", vim.bo[buf].tabstop)
  if not HAS_0_10 then return line:gsub("\t", tab) .. ellipsis end
  -- Rebuild the line as drawn: faces, concealed text, and replacement
  -- strings (column view's cells) inserted where they are anchored.
  local hl, prio, hidden, inserts = {}, {}, {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, NS, { row, 0 }, { row, -1 }, { details = true })) do
    local d = m[4]
    local last = math.min(d.end_col or m[3], #line)
    if d.hl_group then
      for b = m[3] + 1, last do
        if (d.priority or 0) >= (prio[b] or -1) then hl[b], prio[b] = d.hl_group, d.priority or 0 end
      end
    end
    if d.conceal then
      for b = m[3] + 1, last do hidden[b] = true end
      if d.conceal ~= "" then inserts[m[3]] = { { d.conceal, "Folded" } } end
    end
    if d.virt_text and d.virt_text_pos == "inline" then
      inserts[m[3]] = vim.list_extend(inserts[m[3]] or {}, d.virt_text)
    end
  end
  local chunks = {}
  local function add(text, group)
    local last = chunks[#chunks]
    if last and last[2] == group then last[1] = last[1] .. text else chunks[#chunks + 1] = { text, group } end
  end
  for b = 0, #line do
    for _, c in ipairs(inserts[b] or {}) do add(c[1], c[2] or "Folded") end
    if b < #line and not hidden[b + 1] then
      add(line:sub(b + 1, b + 1) == "\t" and tab or line:sub(b + 1, b + 1), hl[b + 1] or "Folded")
    end
  end
  -- Emacs draws the ellipsis in the face of the text before it.
  local last = chunks[#chunks]
  chunks[#chunks + 1] = { ellipsis, (last and last[2] ~= "Folded") and last[2] or faces.group("org-ellipsis") }
  return chunks
end

-- Whether text Emacs makes invisible is hidden; read-only Emacs buffers
-- (agenda) always hide it. Display strings (\alpha as α) show either way.
local function conceals(st)
  return M.config.conceal or (st and st.kind == "menu")
end

local function setup_window(win)
  local wo = vim.wo[win]
  local st = state[api.nvim_win_get_buf(win)]
  wo.foldmethod = "manual"
  wo.foldenable = true
  wo.foldminlines = 0
  wo.foldtext = "v:lua.EmacsFoldText()"
  wo.fillchars = "fold: "
  wo.foldcolumn = "0"
  wo.conceallevel = 2
  -- In the agenda and column view, text Emacs replaces must stay replaced on
  -- the cursor line too, or the line reflows as the cursor moves.
  wo.concealcursor = (st and st.kind == "menu") and "nc" or ""
  -- Emacs's header line (e.g. "exit with C-c '") as the winbar.
  if st and st.header then
    wo.winbar = st.header:gsub("%%", "%%%%")
  elseif st and st.had_header then
    wo.winbar = ""
  end
end

local function apply_folds_in(win, folds)
  api.nvim_win_call(win, function()
    setup_window(win)
    local view = vim.fn.winsaveview()
    vim.cmd("silent! normal! zE")
    local count = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
    for _, r in ipairs(folds) do
      local first, last = math.max(r[1], 0) + 1, math.min(r[2] + 1, count)
      if last >= first then vim.cmd(("silent %d,%dfold"):format(first, last)) end
    end
    vim.fn.winrestview(view)
  end)
end

local function apply_folds(buf, folds)
  state[buf].folds = folds
  state[buf].no_ellipsis = {}
  for _, r in ipairs(folds) do
    if r[3] == false then state[buf].no_ellipsis[math.max(r[1], 0) + 1] = true end
  end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do apply_folds_in(w, folds) end
end

-- Emacs's folds some window on BUF shows open: Neovim opened them itself
-- (a search, :normal! zo), so Emacs must reveal them too. Every window's
-- folds are Emacs's again after each command.
local function revealed_folds(buf, st)
  local out = {}
  for _, r in ipairs(st.folds) do
    local first = math.max(r[1], 0) + 1
    local open = false
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      open = open or api.nvim_win_call(w, function()
        return vim.wo.foldenable and vim.fn.foldclosed(first) ~= first
      end)
    end
    if r[2] + 1 > first and open then out[#out + 1] = { r[1], r[2] } end
  end
  return out
end

function M.refresh_folds(buf)
  apply_folds(buf, state[buf].folds)
end

-- Sorted { first, last } line ranges (0-based), touching ones joined.
local function merge_ranges(ranges)
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  local out = {}
  for _, r in ipairs(ranges) do
    local prev = out[#out]
    if prev and r[1] <= prev[2] + 1 then
      prev[2] = math.max(prev[2], r[2])
    else
      out[#out + 1] = { r[1], r[2] }
    end
  end
  return out
end

-- The lines BUF's windows show, as merged ranges: of a closed fold only its
-- first line, which its fold text draws. Emacs's display likewise computes
-- faces only for visible text; in an overview the window spans the file.
local function shown_ranges(buf)
  local ranges = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    -- Before its first redraw a window reports w$ above w0: take a
    -- window's height of lines.
    local lnum = vim.fn.line("w0", w)
    local bot = math.min(math.max(vim.fn.line("w$", w), lnum + api.nvim_win_get_height(w) - 1),
      api.nvim_buf_line_count(buf))
    api.nvim_win_call(w, function()
      while lnum <= bot do
        ranges[#ranges + 1] = { lnum - 1, lnum - 1 }
        lnum = math.max(lnum, vim.fn.foldclosedend(lnum)) + 1
      end
    end)
  end
  return merge_ranges(ranges)
end

local function covered(have, need)
  for _, n in ipairs(need) do
    local inside = false
    for _, h in ipairs(have) do inside = inside or (h[1] <= n[1] and n[2] <= h[2]) end
    if not inside then return false end
  end
  return true
end

-- Fetch and draw faces/conceals for the lines visible in buf's windows.
function M.refresh_spans(buf)
  local st = state[buf]
  if not st or not api.nvim_buf_is_loaded(buf) then return end
  local need = shown_ranges(buf)
  if #need == 0 then return end
  local tick = api.nvim_buf_get_changedtick(buf)
  local sp = st.spans
  if sp and sp.tick == tick and covered(sp.ranges, need) then return end
  need[1][1] = math.max(0, need[1][1] - SPAN_MARGIN)
  need[#need][2] = math.min(api.nvim_buf_line_count(buf) - 1, need[#need][2] + SPAN_MARGIN)
  local res = rpc.call("spans", { id = st.id, ranges = need })
  faces.add(res.faces)
  for _, r in ipairs(need) do api.nvim_buf_clear_namespace(buf, NS, r[1], r[2] + 1) end
  local prio = {}
  local top_fill = 0
  local function line_len(line) return #(api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or "") end
  local function hide(line, sc, ec)
    if ec > sc then api.nvim_buf_set_extmark(buf, NS, line, sc, { end_col = ec, conceal = "", strict = false }) end
  end
  for _, s in ipairs(res.spans) do
    local line, sc, ec, face, display = s[1], s[2], s[3], s[4], s[5]
    local display_hl = display and face and faces.group(face) or "Normal"
    local chunks = { { display, display_hl } }
    if s[6] then
      chunks = vim.tbl_map(function(r) return { r[1], r[2] and faces.group(r[2]) or display_hl } end, s[6])
    end
    local opts = { end_col = ec, strict = false }
    if display and display:find("\n") then
      -- Multi-line overlay text. At a line's start (Magit's blame headings)
      -- all but its last line are lines of their own above; elsewhere
      -- (agenda entry-text mode) the first line is inline, the rest below.
      local lines = { {} }
      for _, c in ipairs(chunks) do
        for i, part in ipairs(vim.split(c[1], "\n", { plain = true })) do
          if i > 1 then lines[#lines + 1] = {} end
          if part ~= "" then table.insert(lines[#lines], { part, c[2] }) end
        end
      end
      local above = sc == 0
      local inline = table.remove(lines, above and #lines or 1)
      if above and line == 0 then top_fill = top_fill + #lines end
      hide(line, sc, ec)
      api.nvim_buf_set_extmark(buf, NS, line, ec, {
        virt_text = #inline > 0 and HAS_0_10 and inline or nil,
        virt_text_pos = #inline > 0 and HAS_0_10 and "inline" or nil,
        virt_lines = lines, virt_lines_above = above, strict = false })
    elseif display then
      -- Text Emacs draws as another string (agenda marks, pretty entities,
      -- column view). One character fits in conceal's replacement.
      if vim.fn.strchars(display) == 1 and ec > sc then
        opts.conceal = display
        api.nvim_buf_set_extmark(buf, NS, line, sc, opts)
      elseif HAS_0_10 then
        -- Hide the text and draw the string just after it, so the cursor
        -- on the hidden text sits at the string's start, where Emacs's
        -- point is (column view cells).
        hide(line, sc, ec)
        api.nvim_buf_set_extmark(buf, NS, line, ec, {
          virt_text = chunks, virt_text_pos = "inline", strict = false })
      else
        opts.virt_text, opts.virt_text_pos = chunks, "overlay"
        api.nvim_buf_set_extmark(buf, NS, line, sc, opts)
      end
    elseif face then
      -- Earlier faces in an Emacs face list win, like in Emacs.
      local key = line .. ":" .. sc
      prio[key] = (prio[key] or 200) - 1
      opts.hl_group = faces.group(face)
      opts.priority = prio[key]
      -- A span over the newline: Emacs's :extend, to the window edge.
      if ec > line_len(line) then
        opts.end_row, opts.end_col, opts.hl_eol = line + 1, 0, true
      end
      api.nvim_buf_set_extmark(buf, NS, line, sc, opts)
    elseif conceals(st) and not (sc == 0 and ec >= line_len(line)) then
      -- Wholly invisible lines are folds' business: concealing them would
      -- leave blank lines wherever Neovim opens a fold Emacs keeps closed.
      opts.conceal = ""
      api.nvim_buf_set_extmark(buf, NS, line, sc, opts)
    end
  end
  -- Line prefixes (org-indent-mode) need inline virtual text (0.10+).
  if HAS_0_10 then
    for _, p in ipairs(res.prefixes) do
      api.nvim_buf_set_extmark(buf, NS, p[1], 0, {
        virt_text = { { p[2], p[3] and faces.group(p[3]) or "Normal" } }, virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  end
  -- Emacs's right margin (Magit's log dates) at the window's edge.
  for _, m in ipairs(res.margins) do
    local chunks = vim.tbl_map(function(r) return { r[1], r[2] and faces.group(r[2]) or "Normal" } end, m[2])
    api.nvim_buf_set_extmark(buf, NS, m[1], 0, { virt_text = chunks, virt_text_pos = "right_align" })
  end
  -- Neovim scrolls lines above the first one out of view; Emacs shows them.
  -- Reset when they go, too, or 0.13 leaves a stale screen line.
  if need[1][1] == 0 then
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.fn.line("w0", w) == 1 then
        api.nvim_win_call(w, function()
          if vim.fn.winsaveview().topfill ~= top_fill then vim.fn.winrestview({ topfill = top_fill }) end
        end)
      end
    end
  end
  -- Spans are only valid for the text Emacs saw.
  if sp and sp.tick == tick then need = merge_ranges(vim.list_extend(need, sp.ranges)) end
  st.spans = { tick = tick, ranges = need }
end

---------------------------------------------------------------------------
-- Binding Neovim buffers to Emacs buffers
---------------------------------------------------------------------------

local function bind(buf, id, special)
  state[buf] = { id = id, special = special, tick = -1, folds = {}, no_ellipsis = {} }
  by_id[id] = buf
  M.on_bind(buf)
end

-- Install autocmds for a newly bound buffer (set by init.lua).
function M.on_bind(_) end

-- Install keymaps for `kind`: "edit" (text buffers) or "menu" (read-only
-- Emacs buffers like the agenda, where letters are commands).
function M.on_kind(_, _) end

local function unbind(buf)
  local st = state[buf]
  if not st then return end
  by_id[st.id] = nil
  state[buf] = nil
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  end
end

-- Neovim buffer for an Emacs buffer state, created if needed.
local function buffer_for(s)
  local buf = by_id[s.id]
  if buf and api.nvim_buf_is_valid(buf) then return buf end
  if s.file then
    buf = vim.fn.bufadd(vim.fn.fnamemodify(s.file, ":~:."))
    -- Bind first: bufload fires FileType, whose attach would otherwise
    -- overwrite Emacs's (newer) text with the disk text.
    bind(buf, s.id, false)
    -- bufload fires BufReadPost, which is not a reload of Emacs's text.
    -- An existing swap file can't be asked about mid-command (E325 would
    -- abort, and the disk text would then overwrite Emacs's change): load
    -- it as shortmess+=A does; Emacs's text replaces it next anyway.
    state[buf].loading = true
    local shortmess = vim.o.shortmess
    vim.o.shortmess = shortmess .. "A"
    local ok, err = pcall(vim.fn.bufload, buf)
    vim.o.shortmess = shortmess
    state[buf].loading = nil
    if not ok then M.error(tostring(err)) end
    vim.bo[buf].buflisted = true
    return buf
  end
  buf = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(buf, "emacs://" .. s.name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  bind(buf, s.id, true)
  return buf
end

-- Record that Emacs now has exactly buf's lines.
local function mark_synced(buf)
  state[buf].synced = api.nvim_buf_get_lines(buf, 0, -1, false)
  state[buf].tick = api.nvim_buf_get_changedtick(buf)
end

-- The hunk { first, count, lines } turning line list `old` into `new`
-- (replace `count` lines from 0-based `first`), or nil if they are equal.
local function line_hunk(old, new)
  local n, m, pre, suf = #old, #new, 0, 0
  while pre < n and pre < m and old[pre + 1] == new[pre + 1] do pre = pre + 1 end
  while suf < n - pre and suf < m - pre and old[n - suf] == new[m - suf] do suf = suf + 1 end
  if pre == n and pre == m then return nil end
  local lines = {}
  for i = pre + 1, m - suf do lines[#lines + 1] = new[i] end
  return { pre, n - pre - suf, lines }
end

-- Hunks turning `old` into `new`, one per changed region (Emacs keeps the
-- properties of unchanged lines between them), in `old`'s line numbers.
local function line_hunks(old, new)
  local outer = line_hunk(old, new)
  if not outer then return {} end
  local first, count, mid = outer[1], outer[2], outer[3]
  if count == 0 or #mid == 0 then return { outer } end
  local hunks = diff_hunks(vim.list_slice(old, first + 1, first + count), mid)
  for _, h in ipairs(hunks) do h[1] = h[1] + first end
  return hunks
end

-- Longest span checked for a swapped pair of blocks (the check is
-- quadratic at worst).
local MAX_SWAP_LINES = 2000

-- If `new` is `old` with two adjacent blocks swapped (M-up/M-down move a
-- subtree), the 0-based offset and length of the swapped part and the
-- length of its first block; else nil.
local function swapped_blocks(old, new)
  if #old ~= #new or #old > MAX_SWAP_LINES then return nil end
  local hunk = line_hunk(old, new)
  if not hunk then return nil end
  local pre, len = hunk[1], hunk[2]
  for k = 1, len - 1 do
    if new[pre + 1] == old[pre + k + 1] then
      local ok = true
      for i = 1, len do
        local from = i <= len - k and pre + k + i or pre + i - (len - k)
        if new[pre + i] ~= old[from] then ok = false break end
      end
      if ok then return pre, len, k end
    end
  end
end

local function apply_hunk(buf, hunk, join_undo)
  if not state[buf].synced then
    error(("org-bridge.nvim: %s is out of step with Emacs; run :EmacsRestart"):format(
      api.nvim_buf_get_name(buf)), 0)
  end
  -- Emacs sends the lines a command touched, which may not have changed;
  -- an unchanged buffer stays unmodified.
  local first, new = hunk[1], hunk[3]
  local old = api.nvim_buf_get_lines(buf, first, first + hunk[2], false)
  if vim.deep_equal(old, new) then return end
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  -- Fails (E790) right after an undo; then there is nothing to join.
  if join_undo then pcall(vim.cmd, "undojoin") end
  local at, len, k = swapped_blocks(old, new)
  if at then
    -- As a move, so marks and jumps on the moved lines go with them.
    local a = first + at + 1
    api.nvim_buf_call(buf, function()
      -- Ex line numbers in a closed fold mean the whole fold.
      local foldenable = vim.wo.foldenable
      vim.wo.foldenable = false
      local ok, err = pcall(vim.cmd, ("silent %d,%dmove %d"):format(a, a + k - 1, a + len - 1))
      vim.wo.foldenable = foldenable
      if not ok then error(err, 0) end
    end)
  else
    replace_lines(buf, first, old, new)
  end
  vim.bo[buf].modifiable = modifiable
end

-- Apply one buffer record from Emacs.
local function apply_buffer(s, join_undo)
  local buf = buffer_for(s)
  local st = state[buf]
  if s.text or s.hunk then
    if s.text then set_text(buf, s.text) else apply_hunk(buf, s.hunk, join_undo) end
    mark_synced(buf)
    st.spans = nil
  end
  st.speed = s.speed
  st.server = s.server
  st.visual = s.visual
  -- Read-only Emacs buffers (the agenda, a blamed file) and column view
  -- take keys the way Emacs does.
  local kind = (s.readonly or s.columns) and "menu" or "edit"
  local keys_sig = table.concat(s.keys)
  if st.kind ~= kind or (kind == "menu" and st.keys_sig ~= keys_sig) then
    st.kind, st.keys, st.keys_sig = kind, s.keys, keys_sig
    M.on_kind(buf, kind)
  end
  -- Only on a change: the user's own :set nomodifiable stays.
  if st.readonly ~= s.readonly then
    st.readonly = s.readonly
    vim.bo[buf].modifiable = not s.readonly
  end
  if st.special then
    -- :w in an editable Emacs buffer (src edit, capture) saves through Emacs.
    vim.bo[buf].buftype = s.readonly and "nofile" or "acwrite"
    local ft = s.mode == "org-mode" and "org"
      or NAME_FILETYPES[s.name]
      or (s.readonly and "emacs")
      or FILETYPES[s.mode] or s.mode:gsub("%-mode$", "")
    if vim.bo[buf].filetype ~= ft then vim.bo[buf].filetype = ft end
  end
  -- Emacs's flag, so an untouched src edit buffer closes with :bd. Setting
  -- 'modified' advances changedtick; it isn't an edit, so stay in sync if
  -- we were (not past an unsynced edit, a BufWritePre's).
  local in_sync = st.tick == api.nvim_buf_get_changedtick(buf)
  vim.bo[buf].modified = s.modified
  if in_sync then st.tick = api.nvim_buf_get_changedtick(buf) end
  if s.folds then apply_folds(buf, s.folds) end
  st.point = s.point
  st.ellipsis = s.ellipsis
  st.mode_line = s.mode_line
  st.had_header = st.had_header or st.header ~= nil
  -- Emacs sends false for no header line.
  local header = s.header or nil
  if header ~= st.header then
    st.header = header
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do setup_window(w) end
  end
  return buf
end

local function apply_buffers(list, join_undo)
  for _, s in ipairs(list) do apply_buffer(s, join_undo) end
end

-- Buffers Neovim named by wiping and refilling them (:w on a buffer
-- without a name): same buffer and mirror, but their maps and autocmds are
-- gone. Rebound once Neovim is done, or before the next call to Emacs.
local to_rebind = {}

local function rebind_pending()
  for buf in pairs(to_rebind) do
    to_rebind[buf] = nil
    if state[buf] and api.nvim_buf_is_valid(buf) then
      M.on_rename(buf)
      M.on_bind(buf)
      M.on_kind(buf, state[buf].kind)
    end
  end
end

function M.rebind_later(buf)
  to_rebind[buf] = true
  vim.schedule(rebind_pending)
end

-- Neovim's unsynced edits, and a function recording them as Emacs's once
-- the call carrying them succeeded (a failed one is sent again).
local function collect_syncs()
  rebind_pending()
  local syncs, done = {}, {}
  for buf, st in pairs(state) do
    if api.nvim_buf_is_loaded(buf) then
      local tick = api.nvim_buf_get_changedtick(buf)
      if tick ~= st.tick then
        local sync = { id = st.id }
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Line hunks assume a final newline; reloads replace everything. A
        -- lone empty line may be an empty file, which Emacs holds as no
        -- lines at all: send the text then too.
        local lone = function(l) return #l == 1 and l[1] == "" end
        if st.reload or not st.synced or not vim.bo[buf].eol or lone(st.synced) or lone(lines) then
          sync.text = buf_text(buf)
        else
          sync.hunks = line_hunks(st.synced, lines)
          for _, h in ipairs(sync.hunks) do check_utf8(buf, table.concat(h[3], "\n")) end
          if #sync.hunks == 0 then sync.hunks = nil end
        end
        if not st.special then sync.modified = vim.bo[buf].modified end
        if st.reload then sync.reload = true end
        if sync.text or sync.hunks or sync.modified ~= nil then syncs[#syncs + 1] = sync end
        -- Unless the call itself marked newer text synced (an Emacs save).
        local before = st.tick
        done[#done + 1] = function()
          if st.tick == before then st.synced, st.tick, st.reload = lines, tick, nil end
        end
      end
    end
  end
  return syncs, function() for _, f in ipairs(done) do f() end end
end

-- Folds of buffers whose Emacs died, by buffer: the next one folds them
-- again when the buffer reopens, so a restart keeps what Neovim showed.
local refold = {}

function M.attach(buf)
  if state[buf] then return end
  local name = api.nvim_buf_get_name(buf)
  local res = rpc.call("open", {
    file = name ~= "" and vim.fn.fnamemodify(name, ":p") or nil,
    name = name == "" and ("*nvim-" .. buf .. "*") or nil,
    mode = name == "" and (vim.bo[buf].filetype .. "-mode") or nil,
    text = buf_text(buf),
    modified = vim.bo[buf].modified,
    folds = refold[buf],
  })
  refold[buf] = nil
  bind(buf, res.id, false)
  mark_synced(buf)
  apply_buffer(res.state)
end

function M.detach(buf)
  local st = state[buf]
  if not st then return end
  -- A special buffer's text can be a file's (capture shows its target):
  -- keep what was typed there, as killing it in Emacs does.
  -- Reported, not raised: the buffer must still unbind and close in Emacs.
  if st.special and rpc.running() and rpc.depth == 0 then
    local ok, err = pcall(M.sync)
    if not ok then M.error(tostring(err)) end
  end
  unbind(buf)
  if rpc.running() and rpc.depth == 0 then
    -- Closing the clocked buffer clocks out (org asks first).
    M.modeline = rpc.call("close", { id = st.id }).modeline
    vim.cmd("redrawstatus")
  end
end

-- Select the lines of the org `what` ("subtree" or "element") at the
-- cursor, for an operator or in Visual mode.
function M.select(what, inner)
  M.sync()
  local cur = api.nvim_win_get_cursor(0)
  local r = rpc.call("bounds", { id = state[api.nvim_get_current_buf()].id, what = what,
    inner = inner, point = { cur[1] - 1, cur[2] } })
  if not r then return end
  if vim.fn.mode():find("^[vV\22]") then vim.cmd("normal! \27") end
  vim.cmd(("normal! %dGV%dG"):format(r[1] + 1, r[2] + 1))
end

function M.sync()
  if rpc.depth > 0 or not rpc.running() then return end
  local syncs, delivered = collect_syncs()
  if #syncs == 0 then return delivered() end
  local res = rpc.call("sync", { syncs = syncs })
  delivered()
  apply_buffers(res.buffers)
  for _, s in ipairs(syncs) do
    local buf = by_id[s.id]
    if buf then M.refresh_spans(buf) end
  end
end

-- After the cursor rests in a read-only Emacs buffer, tell Emacs it moved:
-- its post-command hooks and the agenda's follow mode see the new point.
local point_timer = vim.loop.new_timer()
function M.schedule_point_sync(buf)
  point_timer:stop()
  point_timer:start(POINT_SYNC_DELAY_MS, 0, vim.schedule_wrap(function()
    if rpc.depth > 0 or api.nvim_get_current_buf() ~= buf or not state[buf] then return end
    M.exec({ command = "nvb-point-moved" })
  end))
end

local sync_timer = vim.loop.new_timer()
function M.schedule_sync()
  sync_timer:stop()
  sync_timer:start(SYNC_DELAY_MS, 0, vim.schedule_wrap(M.sync))
end

---------------------------------------------------------------------------
-- Running commands
---------------------------------------------------------------------------

local function set_cursor(win, buf, p)
  if not p then return end
  local line = math.min(p[1] + 1, api.nvim_buf_line_count(buf))
  api.nvim_win_set_cursor(win, { line, p[2] })
end

-- Whether we entered Insert mode for an edit buffer (a capture), so
-- leaving it leaves Insert mode too.
local auto_insert

local function leave_auto_insert()
  vim.cmd("stopinsert")
  auto_insert = nil
end

-- Insert mode for the edit buffer Emacs selected: Emacs leaves capture with
-- point after the template, past the end of the line, where Normal mode
-- can't stand. Leaving the buffer leaves Insert mode.
local function follow_insert_mode(sel, p, win)
  local editing = state[sel].special and state[sel].kind == "edit"
  if editing and p and not auto_insert then
    local line = api.nvim_buf_get_lines(sel, p[1], p[1] + 1, false)[1] or ""
    if p[2] > 0 and p[2] >= #line then
      vim.cmd("startinsert!")
      auto_insert = true
    elseif api.nvim_buf_get_name(sel):find("CAPTURE%-") then
      -- A capture opens where the template's %? is: start typing there.
      vim.cmd("startinsert")
      auto_insert = true
    end
  elseif auto_insert and not editing then
    -- Leaving the capture we entered Insert mode for. Leaving Insert mode
    -- steps the cursor back; put it back where Emacs says afterwards.
    leave_auto_insert()
    vim.schedule(function()
      if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == sel then set_cursor(win, sel, p) end
    end)
  end
end

-- A region a command left active (C-c @ marks a subtree) as a Visual
-- selection, so the next region command gets it.
local function show_region(region)
  -- Mark and point in either order (org-mark-subtree leaves point first).
  local mark, point = region[1], region[2]
  if point[1] < mark[1] or (point[1] == mark[1] and point[2] < mark[2]) then mark, point = point, mark end
  api.nvim_win_set_cursor(0, { mark[1] + 1, mark[2] })
  local mode, line, col
  if mark[2] == 0 and point[2] == 0 and point[1] > mark[1] then
    -- Whole lines: the region ends at the start of the next line.
    mode, line, col = "V", point[1], 1
  elseif point[2] > 0 then
    -- Emacs's point is just after the region; Visual mode includes the cursor.
    mode, line, col = "v", point[1] + 1, point[2]
  else
    local prev = api.nvim_buf_get_lines(0, point[1] - 1, point[1], false)[1]
    mode, line, col = "v", point[1], math.max(#prev, 1)
  end
  -- Typed, not :normal, which would end Visual mode when it returns.
  api.nvim_feedkeys(api.nvim_replace_termcodes(
    ("%s<Cmd>call cursor(%d, %d)<CR>"):format(mode, line, col), true, false, true), "n", false)
end

local function is_float(win) return api.nvim_win_get_config(win).relative ~= "" end

-- The current window even when it floats: the command runs there.
local function tab_wins()
  local cur = api.nvim_get_current_win()
  return vim.tbl_filter(function(w) return w == cur or not is_float(w) end, api.nvim_tabpage_list_wins(0))
end

-- The current tab's windows in screen order, as Emacs gets them before a
-- command: { win, id (mirrors only), point, top, height }, and the current
-- one's index. Emacs sizes and scrolls its windows the same, so scrolling
-- commands (the agenda's SPC SPC) move as far as in Emacs.
local function layout()
  local wins = tab_wins()
  table.sort(wins, function(a, b)
    local pa, pb = api.nvim_win_get_position(a), api.nvim_win_get_position(b)
    return pa[1] < pb[1] or (pa[1] == pb[1] and pa[2] < pb[2])
  end)
  local out, selected = {}, nil
  for i, w in ipairs(wins) do
    local buf = api.nvim_win_get_buf(w)
    local st = state[buf]
    local cur = api.nvim_win_get_cursor(w)
    -- A file Emacs doesn't mirror is still a place to link to (capture's %a).
    local file = not st and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) or ""
    out[i] = { win = w, id = st and st.id, point = { cur[1] - 1, cur[2] },
      file = vim.fn.filereadable(file) == 1 and file or nil,
      top = vim.fn.line("w0", w) - 1, height = api.nvim_win_get_height(w) }
    if w == api.nvim_get_current_win() then selected = i end
  end
  return out, selected
end

-- Where the last command left Emacs's point. Normal mode can't put the
-- cursor after a line's last character, so while the cursor stays put
-- this, not the cursor, is point (C-c . twice makes a range at the end).
local emacs_point

-- Neovim windows split for windows Emacs made, by the negative number
-- Emacs named them with until the next command names them itself.
local made = {}

-- Emacs's windows as last applied, by Neovim window: { id, point, top }.
local reported = {}

-- Mirror Emacs's windows after a command. Each Emacs window names the
-- Neovim window it was made from: that window shows its buffer and point;
-- a window Emacs made is new (split); a sent window Emacs no longer has
-- was deleted (close it).
local function apply_windows(res, sent)
  local sent_top = {}
  for _, s in ipairs(sent) do sent_top[s.win] = s.top end
  local kept, prev, selected, now = {}, nil, nil, {}
  for i, r in ipairs(res.windows) do
    local w = made[r.win] or r.win
    if not api.nvim_win_is_valid(w) then
      -- A new window goes below the one before it, or, first on screen,
      -- above the first window that exists (a restored layout).
      local next_existing
      for j = i + 1, #res.windows do
        local nw = made[res.windows[j].win] or res.windows[j].win
        if api.nvim_win_is_valid(nw) then next_existing = nw break end
      end
      if prev then
        api.nvim_set_current_win(prev)
        vim.cmd("belowright split")
      elseif next_existing then
        api.nvim_set_current_win(next_existing)
        vim.cmd("aboveleft split")
      else
        vim.cmd("belowright split")
      end
      w = api.nvim_get_current_win()
      made[r.win] = w
    end
    kept[w] = true
    local b = r.id and by_id[r.id]
    if b then
      if api.nvim_win_get_buf(w) ~= b then api.nvim_win_set_buf(w, b) end
      setup_window(w)
      if #state[b].folds > 0 then apply_folds_in(w, state[b].folds) end
      set_cursor(w, b, r.point)
      -- Only a command that scrolled moves Neovim's view; after the
      -- cursor, which the view must keep in sight.
      if r.top and sent_top[w] and r.top ~= sent_top[w] then
        api.nvim_win_call(w, function() vim.fn.winrestview({ topline = r.top + 1 }) end)
      end
    elseif r.file and vim.fn.bufnr(r.file) > 0 then
      -- Back on a file Emacs only visited (capture from a .txt, say).
      local fb = vim.fn.bufnr(r.file)
      if api.nvim_win_get_buf(w) ~= fb then api.nvim_win_set_buf(w, fb) end
      set_cursor(w, fb, r.point)
    end
    if r.selected then
      selected = { win = w, buf = b, point = r.point }
      -- No point: a pull's, which Emacs didn't move.
      if r.point or not b then emacs_point = b and { buf = b, point = r.point } end
    end
    now[w] = { id = r.id, top = r.top, point = r.point or (reported[w] or {}).point }
    prev = w
  end
  reported = now
  -- Windows Emacs had no room for were never in its layout to delete.
  for _, w in ipairs(res.unplaced) do kept[w] = true end
  for _, s in ipairs(sent) do
    if not kept[s.win] and api.nvim_win_is_valid(s.win) and #tab_wins() > 1 then
      api.nvim_win_close(s.win, false)
    end
  end
  if selected and api.nvim_win_is_valid(selected.win) then
    api.nvim_set_current_win(selected.win)
    if selected.buf then
      follow_insert_mode(selected.buf, selected.point, selected.win)
    elseif auto_insert then
      -- Back in a buffer Emacs doesn't mirror after a capture.
      leave_auto_insert()
    end
  end
end

-- An error, reported the way Vim reports one: it also stops a running
-- macro or :normal, as an error stops an Emacs keyboard macro.
function M.error(text)
  if HAS_0_11 then
    api.nvim_echo({ { text } }, true, { err = true })
  else
    api.nvim_err_writeln(text)
  end
end

-- One line, as Emacs's echo area shows the latest message; more would make
-- Neovim ask to press Enter. Earlier messages stay in Emacs's *Messages*.
local function one_line(text)
  text = text:match("^[^\n]*")
  local room = math.max(vim.v.echospace, 10)
  if vim.fn.strdisplaywidth(text) > room then
    text = vim.fn.strcharpart(text, 0, room - 1) .. "…"
  end
  return text
end

local function echo_line(text)
  api.nvim_echo({ { one_line(text), "Normal" } }, true, {})
end

local function report(res)
  -- Clear what a prompt (confirm, input) left on the command line.
  api.nvim_echo({ { "" } }, false, {})
  if res.error then
    M.error(one_line(res.error))
  elseif #res.messages > 0 then
    echo_line(res.messages[#res.messages])
  end
end

-- Bytes in the character at 0-based byte `col` of `line` (0 past the end).
local function char_len(line, col) return #vim.fn.strcharpart(line:sub(col + 1), 0, 1) end

-- Emacs region for the current visual selection: mark and point.
local function visual_region()
  local v, cur = vim.fn.getpos("v"), vim.fn.getpos(".")
  local mode = vim.fn.mode()
  -- Not feedkeys with "x": that would also run the keys typed after C-c.
  vim.cmd([[exe "normal! \<Esc>"]])
  local s, e = v, cur
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then s, e = e, s end
  if mode == "V" then
    -- Whole lines, newline included: the region ends where the next line
    -- starts (point-max after the last line; Emacs clamps it).
    return { s[2] - 1, 0 }, { e[2], 0 }
  end
  local charlen = char_len(vim.fn.getline(e[2]), e[3] - 1)
  return { s[2] - 1, s[3] - 1 }, { e[2] - 1, e[3] - 1 + math.max(charlen, 1) }
end

-- Where the previous command left things; anything else means the user did
-- something in between, which Emacs would have seen as another command.
local after_last = {}

local function snapshot()
  return { buf = api.nvim_get_current_buf(), cursor = api.nvim_win_get_cursor(0),
    tick = api.nvim_buf_get_changedtick(0) }
end

-- Keys typed in Insert mode that must go through Emacs (emacs_typing),
-- oldest first. They run before any later command, in order.
local typed = {}
local run, apply_state, pull
-- Whether Emacs changed something outside a command since the last pull.
local changed = false

-- Neovim's newest unnamed-register yank or delete, for Emacs's kill ring
-- (sent with the next command). Emacs's kills come back the other way.
local pending_kill
api.nvim_create_autocmd("TextYankPost", { callback = function()
  local ev = vim.v.event
  if ev.regname ~= "" then return end
  pending_kill = table.concat(ev.regcontents, "\n") .. (ev.regtype == "V" and "\n" or "")
end })

-- Typing is one undo step per Insert session, as in Vim: a flush joins
-- the previous one only within the same session (and buffer).
local insert_session, last_flush = 0, nil
api.nvim_create_autocmd("InsertEnter", { callback = function() insert_session = insert_session + 1 end })

local function flush_typed()
  if #typed == 0 or rpc.depth > 0 then return end
  -- All keys queued so far in one call: on a large file each round trip
  -- costs tens of milliseconds.
  local first, after = typed[1], { unpack(typed, 2) }
  typed = {}
  local session = { buf = api.nvim_get_current_buf(), n = insert_session }
  local join_undo = vim.deep_equal(session, last_flush)
  last_flush = session
  run({ keys = first, after = after, join_undo = join_undo })
  flush_typed()
end

local function flush_or_report()
  local ok, err = pcall(flush_typed)
  if not ok then
    typed = {}
    api.nvim_echo({ { tostring(err), "ErrorMsg" } }, true, {})
  end
end

-- Runs right after each typed key, ahead of the keys that follow it (a
-- macro's <Esc>j must not move the cursor before the text lands). While
-- more characters wait in typeahead, they join the batch.
vim.keymap.set("i", "<Plug>(emacs-typed)", function()
  -- getchar(1) peeks one byte: special keys (<F12>, <Down>) are 128, and
  -- a multibyte character shows its UTF-8 lead byte.
  local b = vim.fn.getchar(1)
  if (b >= 32 and b < 127) or b >= 0xC0 then return end
  flush_or_report()
end)

-- Leaving Insert mode through a mapped key (jk) skips the <Plug>; Normal
-- mode's cursor sits on the last character, not after it.
api.nvim_create_autocmd("InsertLeave", { callback = function()
  if #typed == 0 then return end
  flush_or_report()
  local cur = api.nvim_win_get_cursor(0)
  if cur[2] > 0 then api.nvim_win_set_cursor(0, { cur[1], cur[2] - 1 }) end
end })

-- Queue a key typed in Insert mode (InsertCharPre can't change the buffer).
function M.type_key(key)
  typed[#typed + 1] = key
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Plug>(emacs-typed)", true, false, true), "mi", false)
  -- A mapped printable key (jk) can end the batch without another <Plug>.
  vim.schedule(flush_or_report)
end

-- Run Emacs keys (kbd notation) or a named command in the current buffer.
-- opts: { keys = "C-c C-t" | command = "org-agenda", count = n (0 = none), visual = bool,
--   join_undo = bool (the edit joins the previous undo step) }
function M.exec(opts)
  flush_typed()
  return run(opts)
end

run = function(opts)
  if changed then pull() end
  local buf = api.nvim_get_current_buf()
  if not state[buf] and vim.tbl_contains(M.config.filetypes, vim.bo[buf].filetype) then
    M.attach(buf)
  end
  local st = state[buf]
  local params = { keys = opts.keys, command = opts.command, count = opts.count,
    pending = opts.pending, after = opts.after }
  -- With the cursor on a line's last character, the EOL keys act after it.
  local at_eol = false
  if st then
    params.id = st.id
    local cur = api.nvim_win_get_cursor(0)
    params.point = { cur[1] - 1, cur[2] }
    local line = api.nvim_get_current_line()
    if opts.at_fold and vim.fn.foldclosed(cur[1]) ~= -1 then
      -- zo/zc act on the closed fold the cursor is on, i.e. its heading.
      params.point = { vim.fn.foldclosed(cur[1]) - 1, 0 }
    elseif EOL_KEYS[opts.keys] and vim.fn.mode() == "n" and #line > 0
        and cur[2] + char_len(line, cur[2]) >= #line then
      params.point = { cur[1] - 1, #line }
      at_eol = true
    end
    if opts.visual then
      params.mark, params.point = visual_region()
    elseif opts.region then
      params.mark, params.point = opts.region[1], opts.region[2]
    elseif opts.point then
      params.point = opts.point
    end
  end
  if st and not st.special then params.revealed = revealed_folds(buf, st) end
  params.fresh = not vim.deep_equal(snapshot(), after_last)
  if st and not params.fresh and not (opts.visual or opts.region or opts.point or opts.at_fold or at_eol)
      and emacs_point and emacs_point.buf == buf then
    params.point = emacs_point.point
  end
  params.kill, pending_kill = pending_kill, nil
  -- Emacs lays the agenda out for its window, which reorganize-frame makes
  -- full width.
  params.width = vim.o.columns
  params.cwd = vim.fn.getcwd()
  local delivered
  params.syncs, delivered = collect_syncs()
  params.layout, params.selected = layout()
  local res = rpc.call("exec", params)
  if res.stale then
    -- Emacs changed on its own just before (a commit message opened):
    -- show that instead, and drop the command, made for other windows.
    pending_kill = params.kill
    return pull()
  end
  delivered()
  -- A jump in Emacs (org-goto, a link): <C-o> comes back here.
  if res.jumped then vim.cmd("normal! m'") end
  apply_state(res, params.layout, opts.join_undo)
  if res.region then show_region(res.region) end
  after_last = snapshot()
  report(res)
  vim.cmd("redrawstatus!")
end

-- Emacs's state after a command or a pull: buffers, then windows (against
-- those Neovim sent, or a pull's), spans, mode line and kill.
apply_state = function(res, sent, join_undo)
  local st = state[api.nvim_get_current_buf()]
  for _, id in ipairs(res.dead) do
    local b = by_id[id]
    if b then
      local special = state[b].special or state[b].server
      unbind(b)
      if special and api.nvim_buf_is_valid(b) then api.nvim_buf_delete(b, { force = true }) end
    end
  end
  apply_buffers(res.buffers, join_undo)
  -- Insert mode in an edit buffer (a note, capture) ends with it, however
  -- it began (C-c C-c typed in Insert mode).
  local typing_in_edit = st and st.special and st.kind == "edit" and vim.fn.mode():find("^i")
  local was_auto_insert = auto_insert
  if typing_in_edit then auto_insert = true end
  if sent then apply_windows(res, sent) end
  -- Still there (it clears the flag on leaving): only for this command.
  if typing_in_edit and auto_insert then auto_insert = was_auto_insert end
  for b, bst in pairs(state) do
    if #vim.fn.win_findbuf(b) > 0 then
      -- Any command can change overlays (sparse trees, column view)
      -- without touching text, so spans are always refetched.
      bst.spans = nil
      M.refresh_spans(b)
    end
  end
  M.modeline = res.modeline
  if res.kill then
    -- Org's subtree cut/copy: paste it with p, as Emacs pastes with C-y.
    vim.fn.setreg('"', res.kill, res.kill:sub(-1) == "\n" and "l" or "c")
  end
end

-- Emacs changed something outside a command (Magit refreshing when git
-- exits, emacsclient opening a commit message). Neovim takes the state as
-- after a command once it isn't mid-call or in Insert mode or a prompt;
-- a command takes it first, since running one puts Neovim's windows back.
pull = function()
  changed = false
  local syncs, delivered = collect_syncs()
  local res = rpc.call("refresh", { syncs = syncs })
  delivered()
  local sent = {}
  for w, r in pairs(reported) do
    if api.nvim_win_is_valid(w) then sent[#sent + 1] = { win = w, top = r.top } end
  end
  for _, r in ipairs(res.windows) do
    local old = reported[made[r.win] or r.win]
    -- Emacs didn't move it; Neovim's cursor may have (j, k): keep that.
    if old and old.id == r.id and vim.deep_equal(old.point, r.point) then r.point = nil end
  end
  -- Before the first command Emacs's windows aren't Neovim's.
  apply_state(res, next(reported) and sent)
  vim.cmd("redrawstatus!")
end

local function pull_when_ready()
  if not changed or not rpc.running() then return end
  if rpc.depth > 0 then return vim.defer_fn(pull_when_ready, PULL_RETRY_MS) end
  if vim.fn.mode() == "n" then
    local ok, err = pcall(pull)
    if not ok then M.error(tostring(err)) end
  end
end

rpc.handlers.changed = function()
  changed = true
  vim.schedule(pull_when_ready)
end

api.nvim_create_autocmd("ModeChanged", {
  group = api.nvim_create_augroup("org-bridge.nvim.pull", { clear = true }),
  pattern = "*:n", callback = function() vim.schedule(pull_when_ready) end,
})

---------------------------------------------------------------------------
-- Requests from Emacs
---------------------------------------------------------------------------

rpc.handlers.strwidth = function(p) return vim.fn.strdisplaywidth(p.s) end

-- A message Emacs printed outside a command (a timer, like a finished
-- countdown).
rpc.handlers.message = function(p) echo_line(p.text) end

-- Emacs wants a file buffer saved: Neovim does all file writes.
rpc.handlers.save = function(p)
  local buf = buffer_for({ id = p.id, file = p.file })
  set_text(buf, p.text)
  -- Emacs has these lines; what a BufWritePre hook changes (a formatter)
  -- is Neovim's edit, synced back like any other.
  mark_synced(buf)
  api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  -- Writing resets 'modified', which advances changedtick but is no edit.
  if vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), state[buf].synced) then mark_synced(buf) end
  return true
end

-- Emacs is gone: forget every binding and the folds it produced.
function M.reset()
  for buf, st in pairs(state) do
    refold[buf] = st.folds
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      api.nvim_win_call(w, function() vim.cmd("silent! normal! zE") end)
    end
    unbind(buf)
  end
  -- The next Emacs numbers its windows afresh.
  made, reported, changed = {}, {}, false
end

-- Neovim reloaded buf from disk (:e!): Emacs's old folds no longer apply.
function M.on_reload(buf)
  local st = state[buf]
  if not st or st.loading then return end
  st.folds, st.spans = {}, nil
  st.reload = true
end

-- Neovim renamed buf's file (:saveas, :file).
function M.on_rename(buf)
  local st = state[buf]
  if not st or st.special or rpc.depth > 0 then return end
  rpc.call("rename", { id = st.id, file = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":p"),
    modified = vim.bo[buf].modified })
end

-- What Emacs shows in its mode line beyond the buffer (the org clock).
M.modeline = ""

M.state = state
return M
