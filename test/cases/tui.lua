-- What the screen shows: menus, splits, faces, folds and the echo area.
-- Expected behavior comes from emacs -nw -Q (tmux, 100 columns) and
-- emacs -Q --batch with test/init.el.
local api = vim.api
local rpc = require("emacs.rpc")
local keys = require("emacs.keys")
local mirror = require("emacs.mirror")

local NS = api.nvim_create_namespace("emacs")
local TASKS = "* TODO Write report :work:\nSCHEDULED: <%s>\n* TODO Call Bob\n"

local function setup_agenda(t)
  local path = t.open("tasks.org", TASKS:format(os.date("%Y-%m-%d %a")))
  t.eval(([[(setq org-agenda-files (list %q) org-directory %q)]]):format(path, t.WORK))
  return api.nvim_get_current_buf()
end

-- Emacs face groups on 0-based `line` of buf.
local function groups_on(buf, line)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, NS, { line, 0 }, { line, -1 }, { details = true })) do
    if m[4].hl_group then out[m[4].hl_group] = true end
  end
  return out
end

local function floats()
  local out = {}
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
  end
  return out
end

-- Run fn with the plugin's real prompt handlers (the harness stubs them)
-- and keys.read answering from `answers`; returns what each read saw.
local function with_real_ui(answers, fn)
  local stubs = {}
  for k, v in pairs(rpc.handlers) do stubs[k] = v end
  package.loaded["emacs.ui"] = nil
  require("emacs.ui")
  local seen, read = {}, keys.read
  keys.read = function()
    local f = floats()[1]
    seen[#seen + 1] = f and api.nvim_buf_get_lines(api.nvim_win_get_buf(f), 0, -1, false) or {}
    return table.remove(answers, 1)
  end
  local ok, err = pcall(fn)
  keys.read = read
  for k, v in pairs(stubs) do rpc.handlers[k] = v end
  assert(ok, err)
  return seen
end

return {
  ["C-c C-t shows the fast-selection menu in a float, closed after the key"] = function(t)
    t.open("menu.org", "* A\n")
    local seen = with_real_ui({ "C-t", "n" }, function() t.keys("C-c") end)
    t.eq(seen[1], {}, "no float for the C-c- prefix")
    t.eq(seen[2], { "{ [t] TODO   [n] NEXT   [d] DONE   }" }, "menu float")
    t.eq(#floats(), 0, "float closed")
    t.eq(t.lines(), { "* NEXT A" })
  end,

  ["agenda opens below the file with point on today, q restores one window"] = function(t)
    local file_buf = setup_agenda(t)
    local file_win = api.nvim_get_current_win()
    t.answer("a")
    t.command("org-agenda")
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "split")
    assert(api.nvim_win_get_position(0)[1] > api.nvim_win_get_position(file_win)[1], "agenda below")
    -- Emacs leaves point on today's date line, e.g. "Saturday    7 November 2026".
    local today = api.nvim_get_current_line()
    assert(today:find("^" .. os.date("%A") .. "%s+" .. tonumber(os.date("%d")) .. " "), "point on today: " .. today)
    vim.api.nvim_feedkeys("q", "x", false)
    t.eq(#api.nvim_tabpage_list_wins(0), 1, "agenda closed")
    t.eq(api.nvim_get_current_buf(), file_buf)
  end,

  ["the agenda dispatcher prompt is gone from the echo area afterwards"] = function(t)
    setup_agenda(t)
    local echoed, echo = {}, api.nvim_echo
    api.nvim_echo = function(chunks, ...)
      echoed[#echoed + 1] = chunks[1] and chunks[1][1] or ""
      return echo(chunks, ...)
    end
    t.answer("a")
    local ok, err = pcall(t.command, "org-agenda")
    api.nvim_echo = echo
    assert(ok, err)
    vim.api.nvim_feedkeys("q", "x", false)
    -- emacs -nw: after `a` the echo area is empty; read-char-exclusive
    -- consumed the prompt that org-agenda showed with `message`.
    assert(not (echoed[#echoed] or ""):find("Press key for agenda command", 1, true),
      "echo area still shows the prompt: " .. vim.inspect(echoed))
  end,

  ["agenda tags align to the Neovim window's width"] = function(t)
    setup_agenda(t)
    t.answer("a")
    t.command("org-agenda")
    local width = api.nvim_win_get_width(0)
    local line
    for _, l in ipairs(t.lines()) do
      if l:find(":work:", 1, true) then line = l end
    end
    vim.api.nvim_feedkeys("q", "x", false)
    -- emacs -nw in a 100-column window ends the tags at column 99.
    t.eq(#line, width - 1, "tag end column in a " .. width .. "-column window")
  end,

  ["the capture buffer gets Emacs faces"] = function(t)
    setup_agenda(t)
    t.file("inbox.org", "")
    t.answer("t")
    t.command("org-capture")
    local groups = groups_on(0, 0)
    t.keys("C-c C-k")
    -- Interactive Emacs fontifies it: "TODO" has (org-todo org-level-1).
    assert(groups.EmacsFace_org_todo, "org-todo on the capture heading: " .. vim.inspect(groups))
  end,

  ["typed text gets highlighted by the debounced sync"] = function(t)
    t.open("typed.org", "* A\n")
    api.nvim_buf_set_lines(0, 1, 1, false, { "some *bold* text" })
    -- feedkeys in a headless script doesn't fire TextChanged; fire it as
    -- the main loop would after an edit.
    api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
    assert(vim.wait(1000, function() return groups_on(0, 1).EmacsFace_bold end, 20),
      "bold after the sync: " .. vim.inspect(groups_on(0, 1)))
  end,

  ["a concealed link line wraps at its displayed width"] = function(t)
    if vim.fn.has("nvim-0.13") == 0 then t.skip("conceal-aware wrap needs Neovim 0.13") end
    local link = "[[https://example.com/" .. string.rep("a", 60) .. "][one]]"
    local text = "Long: " .. link .. " " .. string.rep("word ", 12) .. "end"
    -- The cursor stays on the heading: 'concealcursor' is empty, so the
    -- cursor line shows its brackets.
    t.open("wrap.org", "* H\n" .. text .. "\n")
    local shown = #text - #link + #"one"
    assert(#text > vim.o.columns and shown < vim.o.columns, "setup: line wraps only unconcealed")
    t.eq(vim.wo.conceallevel, 2)
    t.eq(api.nvim_win_text_height(0, { start_row = 1, end_row = 1 }).all, 1, "screen lines")
  end,

  -- Emacs: C-g at read-passwd quits; Neovim's Escape cancels as at other prompts.
  ["Escape and C-g cancel a password prompt; RET answers"] = function(t)
    t.open("passwd.org", "* A\n")
    t.eval([[(defun nvb-test-passwd () (interactive) (insert (read-passwd "Password: ")))]])
    t.after(function() t.eval("(fmakunbound 'nvb-test-passwd)") end)
    with_real_ui({}, function()
      for _, keys in ipairs({ "pw<Esc>", "pw<C-g>", "pw<CR>" }) do
        api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "t", false)
        t.command("nvb-test-passwd")
      end
    end)
    t.eq(t.lines(), { "pw* A" })
  end,

  ["Neovim's own org syntax doesn't add attributes under Emacs faces"] = function(t)
    vim.cmd("syntax on")
    t.open("syntax.org", "* Heading\n")
    local id = vim.fn.synIDtrans(vim.fn.synID(1, 3, 1))
    local bold = vim.fn.synIDattr(id, "bold")
    vim.cmd("syntax off")
    -- org-level-1 isn't bold in emacs -nw; Vim's orgHeadline links to Title.
    t.eq(bold, "", "bold from " .. vim.fn.synIDattr(id, "name"))
  end,
}
