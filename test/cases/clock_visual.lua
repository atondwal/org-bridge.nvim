-- Clocking and Visual-mode region commands. Expected text comes from
-- emacs -Q --batch with transient-mark-mode on, as in an interactive Emacs.
local api = vim.api
local mirror = require("emacs.mirror")

local DOC = "* A\n* B\n* C\n* D\n"
local CLOCK_OPEN = "^CLOCK: %[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]$"
local CLOCK_CLOSED = "^CLOCK: %[[^]]+%]%-%-%[[^]]+%] =>  0:00$"

-- Select with `motion` (from the cursor), then run `opts` with visual = true
-- from an x-mode mapping, the way a real Visual-mode key would.
local function visual(motion, opts)
  vim.keymap.set("x", "<F9>", function()
    mirror.exec(vim.tbl_extend("force", opts, { visual = true }))
  end, { buffer = 0 })
  api.nvim_feedkeys(api.nvim_replace_termcodes(motion .. "<F9>", true, false, true), "x", false)
end

local function killed(t)
  return t.eval("(substring-no-properties (car kill-ring))")
end

local function clock_out_everywhere(t)
  t.eval("(when (org-clocking-p) (org-clock-out))")
end

return {
  ["C-c C-x C-i opens a LOGBOOK clock, C-c C-x C-o closes it"] = function(t)
    t.open("clock.org", "* Task\nbody\n* Other\n")
    t.keys("C-c C-x C-i")
    local l = t.lines()
    t.eq({ l[1], l[2], l[4], l[5] }, { "* Task", ":LOGBOOK:", ":END:", "body" }, "drawer")
    assert(l[3]:find(CLOCK_OPEN), "open clock line: " .. l[3])
    t.eq(t.eval("(buffer-name (marker-buffer org-clock-marker))"), '"clock.org"')
    t.cursor(6)
    t.keys("C-c C-x C-o")
    l = t.lines()
    assert(l[3]:find(CLOCK_CLOSED), "closed clock line: " .. l[3])
    t.eq(#l, 6, "no extra lines")
    t.eq(t.eval("(org-clocking-p)"), "nil")
  end,

  ["clocking in a second task closes the first clock"] = function(t)
    t.open("clock2.org", "* A\n* B\n")
    t.keys("C-c C-x C-i")
    t.cursor(5)
    t.eq(t.lines()[5], "* B")
    t.keys("C-c C-x C-i")
    local l = t.lines()
    t.eq({ l[2], l[4], l[5], l[6], l[8] }, { ":LOGBOOK:", ":END:", "* B", ":LOGBOOK:", ":END:" })
    assert(l[3]:find(CLOCK_CLOSED), "A closed: " .. l[3])
    assert(l[7]:find(CLOCK_OPEN), "B open: " .. l[7])
    clock_out_everywhere(t)
  end,

  ["clock-in on a subheading puts the drawer under it"] = function(t)
    t.open("clock3.org", "* A\n** A1\ntext\n")
    t.cursor(2)
    t.keys("C-c C-x C-i")
    local l = t.lines()
    t.eq({ l[1], l[2], l[3], l[5], l[6] }, { "* A", "** A1", ":LOGBOOK:", ":END:", "text" })
    clock_out_everywhere(t)
  end,

  ["linewise M-right demotes every heading in the selection"] = function(t)
    t.open("demote.org", DOC)
    t.cursor(2)
    visual("Vj", { keys = "M-<right>" })
    t.eq(t.lines(), { "* A", "** B", "** C", "* D" })
  end,

  ["linewise M-left selected upward promotes every heading"] = function(t)
    t.open("promote.org", "* A\n** B\n** C\n* D\n")
    t.cursor(3)
    visual("Vk", { keys = "M-<left>" })
    t.eq(t.lines(), { "* A", "* B", "* C", "* D" })
  end,

  ["C-c C-x C-f in charwise Visual wraps the selection"] = function(t)
    t.open("emph.org", "hello world here\n")
    t.cursor(1, 6)
    t.answer("C-x", "C-f", "*")
    -- Through the plugin's own x-mode <C-c> mapping.
    api.nvim_feedkeys(api.nvim_replace_termcodes("ve<C-c>", true, false, true), "x", false)
    t.eq(t.lines(), { "hello *world* here" })
    -- Emacs shows this in the echo area while read-char-exclusive waits.
    local q = t.asked()[3].params
    local shown = (q.prompt or "") .. (q.context or "")
    assert(shown:find("Emphasis marker or tag", 1, true), "marker prompt shown: " .. vim.inspect(q))
  end,

  ["charwise region is exactly the selection, multibyte and backward"] = function(t)
    t.open("region.org", "héllo wörld ünd\n")
    t.cursor(1, 7) -- the "w": "héllo " is 7 bytes
    visual("ve", { command = "kill-ring-save" })
    t.eq(killed(t), '"wörld"', "forward")
    t.cursor(1, 12) -- the last "d" of "wörld"
    visual("vb", { command = "kill-ring-save" })
    t.eq(killed(t), '"wörld"', "backward")
    t.cursor(1, 14) -- "ü"
    visual("v", { command = "kill-ring-save" })
    t.eq(killed(t), '"ü"', "one multibyte char")
  end,

  -- Whole lines, newline included, so killing them leaves no empty line.
  ["a linewise region covers whole lines, newline included"] = function(t)
    t.open("lregion.org", DOC)
    t.cursor(2, 2)
    visual("Vj", { command = "kill-ring-save" })
    t.eq(killed(t), '"* B\n* C\n"')
  end,

  ["a running clock shows in the statusline component"] = function(t)
    t.open("clockline.org", "* Write report\n")
    t.keys("C-c C-x C-i")
    assert(require("emacs").statusline():find("Write report"), "statusline: " .. require("emacs").statusline())
    t.keys("C-c C-x C-o")
    t.eq(require("emacs").statusline(), "")
  end,

  -- org-clock-resolve asks with a 45s timed read, in a loop until answered.
  ["clocking in over a dangling clock asks how to resolve it"] = function(t)
    t.open("dangling.org", "* Old\n:LOGBOOK:\nCLOCK: [2026-11-07 Sat 05:02]\n:END:\n* New\n")
    t.cursor(5)
    t.answer("K", "") -- keep the dangling minutes (default) and close that clock
    t.keys("C-c C-x C-i")
    t.eq(t.asked()[1].method, "read_key")
    assert(require("emacs").statusline():find("New"), "clocked in: " .. require("emacs").statusline())
    t.keys("C-c C-x C-o")
  end,

  ["a message from an Emacs timer reaches Neovim between commands"] = function(t)
    t.open("timer.org", "* A\n")
    t.eval([[(run-at-time 0.2 nil (lambda () (message "Timer done")))]])
    vim.wait(3000, function()
      return vim.api.nvim_exec2("messages", { output = true }).output:find("Timer done") ~= nil
    end, 20)
    assert(vim.api.nvim_exec2("messages", { output = true }).output:find("Timer done"), "message shown")
  end,
}
