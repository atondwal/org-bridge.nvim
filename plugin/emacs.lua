if vim.g.loaded_emacs_nvim then return end
vim.g.loaded_emacs_nvim = true

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, function(a)
    local ok, err = pcall(fn, a)
    if not ok then require("emacs.mirror").error(tostring(err)) end
  end, opts or {})
end

-- :Emacs C-c C-t   run an Emacs key sequence in the current buffer
cmd("Emacs", function(a)
  require("emacs").exec({ keys = a.args, count = a.count })
end, { nargs = "+", count = 0 })

-- :EmacsCommand org-agenda   call an Emacs command interactively
cmd("EmacsCommand", function(a)
  require("emacs").exec({ command = a.args, count = a.count })
end, { nargs = 1, count = 0 })

cmd("EmacsEval", function(a)
  local emacs = require("emacs")
  print(emacs.eval(a.args))
  -- Show what it changed (text, folds, faces) now, not at the next key.
  if require("emacs.mirror").id(vim.api.nvim_get_current_buf()) then emacs.exec({ command = "ignore" }) end
end, { nargs = "+" })

-- :EmacsAgenda [key]   the key picks a view without the dispatcher menu
cmd("EmacsAgenda", function(a)
  require("emacs").exec({ command = "org-agenda", pending = a.args ~= "" and { a.args } or nil })
end, { nargs = "?" })
cmd("EmacsCapture", function() require("emacs").exec({ command = "org-capture" }) end)
cmd("EmacsLog", function() vim.cmd.split(require("emacs.rpc").config.log) end)
cmd("EmacsRestart", function()
  local emacs = require("emacs")
  emacs.shutdown()
  emacs.attach_all()
end)
