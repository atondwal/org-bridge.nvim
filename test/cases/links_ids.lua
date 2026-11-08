-- Links beyond C-c C-l: C-c l + stored links, org-id links across files,
-- #+LINK abbreviations, C-c C-o on URLs and non-org files, inline images,
-- the C-c % / C-c & mark ring. Expected results: emacs -Q --batch -l test/init.el.
local api = vim.api

-- Bind C-c l to org-store-link (unbound under -Q), with no stored links, for this test.
local function bind_store_link(t)
  t.eval([[(global-set-key (kbd "C-c l") #'org-store-link)]])
  t.after(function() t.eval([[(global-unset-key (kbd "C-c l"))]]) end)
  t.set("org-stored-links", "nil")
end

-- Record URLs browse-url is asked to open instead of starting a browser;
-- also stub vim.ui.open in case the bridge hands URLs to Neovim. Returns a
-- function giving { emacs = urls, nvim = urls }.
local function stub_browsers(t)
  t.set("browse-url-browser-function", "(lambda (url &rest _) (push url nvb-test-urls))")
  t.eval("(setq nvb-test-urls nil)")
  local nvim_urls, ui_open = {}, vim.ui.open
  vim.ui.open = function(url) nvim_urls[#nvim_urls + 1] = url; return nil, nil end
  t.after(function() vim.ui.open = ui_open end)
  return function()
    local joined = vim.json.decode(t.eval([[(mapconcat #'identity (reverse nvb-test-urls) "\n")]]))
    return { emacs = vim.split(joined, "\n", { trimempty = true }), nvim = nvim_urls }
  end
end

local function agree(t, path) t.eq(t.emacs_lines(path), t.lines(), "Emacs agrees") end

return {
  ["C-c l then C-c C-l in another file inserts the stored link by default"] = function(t)
    bind_store_link(t)
    local a = t.open("store_a.org", "* Top\n* Target\nbody\n")
    t.cursor(2)
    t.keys("C-c l")
    local stored = "file:" .. a .. "::*Target"
    t.eq(vim.json.decode(t.eval("(substring-no-properties (caar org-stored-links))")), stored, "stored")
    local b = t.open("store_b.org", "* B\nsee  here\n")
    t.cursor(2, 4)
    -- RET at both prompts: the stored link, then its default description.
    t.answer("", "Target")
    t.keys("C-c C-l")
    t.eq(t.lines()[2], "see [[file:store_a.org::*Target][Target]] here")
    t.eq(t.asked()[1].params.default, stored, "offered as the default")
    t.eq(t.eval("org-stored-links"), "nil", "inserted link leaves the list")
    agree(t, b)
  end,

  ["C-c C-l of a link stored in the same file inserts a bare heading search"] = function(t)
    bind_store_link(t)
    local a = t.open("store_same.org", "* Top\n* Target\nbody\n")
    t.cursor(2)
    t.keys("C-c l")
    t.cursor(3, 3)
    t.feed("o<Esc>")
    t.answer("", "Target")
    t.keys("C-c C-l")
    t.eq(t.lines(), { "* Top", "* Target", "body", "[[*Target][Target]]" })
    agree(t, a)
  end,


  ["C-c C-o on an id: link opens the other file at the heading"] = function(t)
    local d = t.file("id_target.org", "* D one\n* D two\n:PROPERTIES:\n:ID: 1234-abcd\n:END:\nd body\n")
    t.eval(("(org-id-update-id-locations (list %q))"):format(d))
    t.after(function() t.eval([[(remhash "1234-abcd" org-id-locations)]]) end)
    local e = t.open("id_src.org", "* E\n[[id:1234-abcd]]\n")
    local e_buf = api.nvim_get_current_buf()
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), d)
    t.eq(api.nvim_win_get_cursor(0)[1], 2, "on * D two")
    t.eq(#vim.fn.win_findbuf(e_buf), 1, e .. " still shown (other window)")
  end,

  ["a #+LINK abbreviation expands before browse-url"] = function(t)
    local urls = stub_browsers(t)
    t.open("abbrev_url.org", "#+LINK: gh https://github.com/%s\n* F\n[[gh:foo/bar]]\n")
    t.cursor(3, 3)
    t.keys("C-c C-o")
    t.eq(urls(), { emacs = { "https://github.com/foo/bar" }, nvim = {} })
  end,


  ["C-c C-o on https URLs goes to browse-url and leaves the buffer alone"] = function(t)
    local urls = stub_browsers(t)
    local g = t.open("https.org", "* G\nhttps://example.com/x and [[https://example.org][ex]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.cursor(2, 32)
    t.keys("C-c C-o")
    t.eq(urls(), { emacs = { "https://example.com/x", "https://example.org" }, nvim = {} })
    t.eq(api.nvim_buf_get_name(0), g)
    t.eq(vim.bo.modified, false)
    agree(t, g)
  end,

  -- org-file-apps: (auto-mode . emacs) visits a .txt in Emacs.
  ["C-c C-o on a file link to a .txt opens it in Neovim"] = function(t)
    local txt = t.file("plain.txt", "plain text\nline2\n")
    local h = t.open("txtlink.org", "* H\n[[file:plain.txt]]\n")
    local h_buf = api.nvim_get_current_buf()
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), txt)
    t.eq(t.lines(), { "plain text", "line2" })
    t.eq(vim.bo.modified, false)
    t.eq(#vim.fn.win_findbuf(h_buf), 1, h .. " still shown")
  end,

  ["the .txt a link opens keeps Neovim's keys but stays in sync"] = function(t)
    local txt = t.file("keys.txt", "plain\n")
    t.open("keyslink.org", "* H\n[[file:keys.txt]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), txt)
    for _, m in ipairs({ "n", "i" }) do
      t.eq(api.nvim_buf_get_keymap(0, m), {}, m .. " maps")
    end
    api.nvim_buf_set_lines(0, 0, -1, false, { "typed" })
    t.eq(t.emacs_lines(txt), { "typed" }, "Emacs has Neovim's edit")
  end,

  -- The external app is a harmless shell command that records its argument.
  ["C-c C-o on a .pdf link runs the org-file-apps command, not a viewer in Neovim"] = function(t)
    local pdf = t.file("doc.pdf", "%PDF-1.4\n")
    local out = t.WORK .. "/pdf-opened"
    t.set("org-file-apps", ('\'(("\\\\.pdf\\\\\'" . "echo %%s > %s"))'):format(out))
    local h = t.open("pdflink.org", "* H\n[[file:doc.pdf]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    -- The shell's > creates the file before echo writes to it.
    vim.wait(2000, function() return vim.fn.getfsize(out) > 0 end)
    t.eq(t.read_file(out), pdf .. "\n")
    t.eq(api.nvim_buf_get_name(0), h)
    agree(t, h)
  end,

  ["C-c C-x C-v toggles inline images without touching the text"] = function(t)
    t.file("img.png", "")
    local i = t.open("inline.org", "* I\n[[file:img.png]]\n")
    t.keys("C-c C-x C-v")
    t.keys("C-c C-x C-v")
    t.eq(t.lines(), { "* I", "[[file:img.png]]" })
    t.eq(vim.bo.modified, false)
    agree(t, i)
  end,

  ["C-c % saves the position; C-c & returns after a Neovim motion"] = function(t)
    t.open("markring.org", "* M\none\ntwo\nthree\nfour\n")
    t.cursor(4, 2)
    t.keys("C-c %")
    t.feed("gg")
    t.keys("C-c &")
    t.eq(api.nvim_win_get_cursor(0), { 4, 2 })
  end,
  ["with org-id-link-to-org-use-id, C-c l stores an id: link that C-c C-l inserts"] = function(t)
    bind_store_link(t)
    t.set("org-id-link-to-org-use-id", "t")
    local c = t.open("idstore_c.org", "* C head\ntext\n")
    t.cursor(1)
    t.keys("C-c l")
    local l = t.lines()
    t.eq({ l[1], l[2], l[4], l[5] }, { "* C head", ":PROPERTIES:", ":END:", "text" })
    local id = l[3]:match("^:ID:%s+(%x+%-%x+%-%x+%-%x+%-%x+)$")
    assert(id, "ID line: " .. l[3])
    t.eq(vim.json.decode(t.eval(("(gethash %q org-id-locations)"):format(id))), c, "location")
    agree(t, c)
    local b = t.open("idstore_b.org", "* B\n\n")
    t.cursor(2)
    t.answer("", "C head")
    t.keys("C-c C-l")
    t.eq(t.lines(), { "* B", "[[id:" .. id .. "][C head]]" })
    assert(vim.tbl_contains(t.asked()[1].params.candidates, "id:" .. id), "stored link is a candidate")
    agree(t, b)
  end,

  -- Emacs: org-mark-ring-goto shows the source in the selected window, so
  -- both windows end on the source file.
  ["C-c & after an id: link into another file goes back to the link"] = function(t)
    local d = t.file("idback_t.org", "* D one\n* D two\n:PROPERTIES:\n:ID: 5678-back\n:END:\nd body\n")
    t.eval(("(org-id-update-id-locations (list %q))"):format(d))
    t.after(function() t.eval([[(remhash "5678-back" org-id-locations)]]) end)
    local e = t.open("idback_s.org", "* E\n[[id:5678-back]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(api.nvim_buf_get_name(0), d, "followed")
    t.keys("C-c &")
    t.eq(api.nvim_buf_get_name(0), e, "back in the source")
    t.eq(api.nvim_win_get_cursor(0), { 2, 3 })
    t.eq(#api.nvim_tabpage_list_wins(0), 2, "two windows")
  end,

  -- org-file-apps: (directory . emacs) opens dired.
  ["C-c C-o on a file link to a directory shows Emacs's dired listing"] = function(t)
    vim.fn.mkdir(t.WORK .. "/linkdir", "p")
    t.file("linkdir/x.txt", "x\n")
    t.open("dirlink.org", "* Dir\n[[file:linkdir/]]\n")
    t.cursor(2, 3)
    t.keys("C-c C-o")
    t.eq(t.lines(), t.emacs_lines("linkdir"), "Neovim shows the dired buffer")
    assert(t.find_line("x%.txt$"), vim.inspect(t.lines()))
  end,
}
