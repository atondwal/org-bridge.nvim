-- Minimal config for trying org-bridge.nvim: nvim -u demo/init.lua demo/notes.org
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
vim.cmd("colorscheme habamax")
require("emacs").setup({ init = root .. "/demo/emacs-init.el" })
