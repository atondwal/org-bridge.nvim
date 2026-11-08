-- Randomized consistency check: Neovim edits and Emacs commands, interleaved,
-- must leave both sides with the same text.
--   nvim --headless -u NONE -l test/fuzz.lua [seed] [steps]
-- FUZZ_FILE=notes.org starts from a copy of that file instead of START.
local ROOT = vim.fn.fnamemodify(arg[0], ":p:h:h")
vim.cmd("filetype on")
vim.opt.rtp:prepend(ROOT)
vim.o.swapfile = false

local SEED = tonumber(arg[1]) or os.time()
local STEPS = tonumber(arg[2]) or 300
math.randomseed(SEED)

local WORK = os.getenv("FUZZ_DIR") or vim.fn.tempname()
vim.fn.mkdir(WORK, "p")
local rpc = require("emacs.rpc")
local mirror = require("emacs.mirror")
local emacs = require("emacs")
emacs.setup({ log = WORK .. "/emacs.log", init = ROOT .. "/test/init.el" })

-- Prompts get a plausible answer instead of a script.
rpc.handlers.read_key = function() return ({ "t", "n", "d", "q" })[math.random(4)] end
-- Some answer must be a number: read-number asks again until it gets one.
rpc.handlers.read_string = function() return ({ "", "1", "x" })[math.random(3)] end
rpc.handlers.completing_read = function() return "" end
rpc.handlers.confirm = function() return true end

local WORDS = { "alpha", "beta", "日本", "café", "🎉", "x", "", "TODO", ":tag:", "[[link][desc]]" }
local function word() return WORDS[math.random(#WORDS)] end

local function random_line()
  local r = math.random(10)
  if r <= 3 then return string.rep("*", math.random(3)) .. " " .. word() .. " " .. word() end
  if r == 4 then return "| " .. word() .. " | " .. word() .. " |" end
  if r == 5 then return "- [ ] " .. word() end
  if r == 6 then return "" end
  return word() .. " " .. word() .. " " .. word()
end

local START = table.concat({
  "* TODO Alpha :work:", "body text", "** Child", "| a | b |", "|---+---|", "| 1 | 2 |",
  "* Beta", "- [ ] one", "- [X] two", "* Gamma", "SCHEDULED: <2026-11-07 Sat>", "",
}, "\n")

local function nlines() return vim.api.nvim_buf_line_count(0) end
local function goto_random_line()
  vim.api.nvim_win_set_cursor(0, { math.random(nlines()), 0 })
end

-- Key sequences typed in Neovim: Insert-mode typing (Vim's on headings,
-- Emacs's on table rows), o, ., org text objects, =, Visual org keys, folds.
local TYPED = { "AWORD", "IWORD", "aWORD", "oWORD", "cwWORD", ".", "3.", "dar", "yarP", "die",
  "=ie", ">>", "<<", "Vj<M-Right>", "Vj<M-Left>", "zc", "zo", "zR", "zM", "zv", "xp" }

-- Neovim-side edits.
local NVIM_OPS = {
  function() -- replace a range of lines
    local a = math.random(nlines()) - 1
    local b = math.min(nlines(), a + math.random(0, 2))
    local new = {}
    for _ = 1, math.random(0, 3) do new[#new + 1] = random_line() end
    vim.api.nvim_buf_set_lines(0, a, b, false, new)
    return "set_lines " .. a .. "-" .. b .. " (" .. #new .. ")"
  end,
  function() -- edit within a line
    goto_random_line()
    local line = vim.api.nvim_get_current_line()
    local col = math.random(0, #line)
    -- Stay on a character boundary.
    while col > 0 and col < #line and line:byte(col + 1) >= 0x80 and line:byte(col + 1) < 0xC0 do col = col - 1 end
    vim.api.nvim_buf_set_text(0, vim.fn.line(".") - 1, col, vim.fn.line(".") - 1, col, { word() })
    return "insert text"
  end,
  function() vim.cmd("silent! normal! u") return "undo" end,
  function() vim.cmd("silent! normal! \18") return "redo" end,
  function() goto_random_line() vim.cmd("silent! normal! dd") return "dd" end,
  function() goto_random_line() vim.cmd("silent! normal! yyp") return "yyp" end,
  function() goto_random_line() vim.cmd("silent! normal! J") return "J" end,
  function() -- keys as typed, through the plugin's mappings
    goto_random_line()
    local seq = TYPED[math.random(#TYPED)]:gsub("WORD", word())
    -- "x": run now; Escape last so no step ends in Insert or Visual mode.
    pcall(vim.api.nvim_feedkeys, vim.api.nvim_replace_termcodes(seq .. "<Esc>", true, false, true), "xt", false)
    return "typed " .. seq
  end,
}

-- Emacs commands at a random line.
local EMACS_KEYS = { "TAB", "<backtab>", "M-RET", "<M-up>", "<M-down>", "<M-left>", "<M-right>",
  "C-c C-t", "<S-up>", "<S-down>", "<S-left>", "<S-right>", "C-c -", "C-c *", "C-c C-c",
  "<M-S-left>", "<M-S-right>", "C-c ^" }

local function emacs_text()
  return vim.json.decode(emacs.eval([[(with-current-buffer "fuzz.org"
    (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))]]))
end

local function nvim_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo.eol and not (#lines == 1 and lines[1] == "") then text = text .. "\n" end
  return text
end

local path = WORK .. "/fuzz.org"
local start_file = os.getenv("FUZZ_FILE")
vim.fn.writefile(start_file and vim.fn.readfile(start_file) or vim.split(START, "\n"), path)
vim.cmd("silent edit " .. path)

local history = {}
local failed
local start_ns = vim.loop.hrtime()
for step = 1, STEPS do
  local desc
  local ok, err = pcall(function()
    if math.random() < 0.5 then
      desc = NVIM_OPS[math.random(#NVIM_OPS)]()
      if math.random() < 0.3 then mirror.sync() desc = desc .. " +sync" end
    else
      goto_random_line()
      local k = EMACS_KEYS[math.random(#EMACS_KEYS)]
      desc = "emacs " .. k .. " @" .. vim.fn.line(".")
      emacs.exec({ keys = k })
    end
  end)
  history[#history + 1] = desc or "?"
  -- FUZZ_VERBOSE=1: one line per step, to find where a run stalls.
  if os.getenv("FUZZ_VERBOSE") then io.stderr:write(("%d %.1fs %s\n"):format(step, (vim.loop.hrtime() - start_ns) / 1e9, desc or "?")) end
  if not ok then
    failed = ("step %d (%s): error %s"):format(step, desc or "?", err)
    break
  end
  mirror.sync()
  local et, nt = emacs_text(), nvim_text()
  -- A lone empty line is both "" and "\n" to Neovim (it writes the file,
  -- so Emacs's extra newline never reaches disk).
  if et == "\n" and nt == "" then et = "" end
  if et ~= nt then
    failed = ("step %d (%s): texts differ\n--- emacs\n%s\n--- nvim\n%s"):format(step, desc, et, nt)
    break
  end
end

if failed then
  io.stdout:write(("FUZZ FAIL seed=%d\n%s\nlast steps:\n  %s\n"):format(SEED, failed,
    table.concat(vim.list_slice(history, math.max(1, #history - 8)), "\n  ")))
else
  io.stdout:write(("FUZZ OK seed=%d steps=%d\n"):format(SEED, STEPS))
end
rpc.stop()
vim.cmd(failed and "cquit" or "qall!")
