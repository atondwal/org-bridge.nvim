-- Connection to the headless Emacs: process lifecycle and JSON-lines RPC.
-- Calls are synchronous; while one waits, Emacs may ask us for input
-- (see `handlers`), which we answer from the normal (non-fast) context.
local M = {}

local uv = vim.loop
local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local BRIDGE_EL = PLUGIN_ROOT .. "/emacs/nvim-bridge.el"
local STARTUP_TIMEOUT_MS = 20000

M.config = {
  emacs = "emacs",
  -- Elisp file loaded before the bridge starts serving (org settings etc.).
  init = false,
  log = vim.fn.stdpath("cache") .. "/emacs-nvim.log",
}

local job, pipe
local ready = false
local lines = {}       -- raw JSON lines received, not yet decoded
local replies = {}     -- id -> message
local next_id = 0
M.depth = 0            -- > 0 while a call is in flight

-- Handlers for requests Emacs sends us, by method name. Each returns a
-- result or errors with "quit" to make Emacs signal `quit`.
M.handlers = {}

local function log(line)
  local f = io.open(M.config.log, "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
end

-- Set EMACS_NVIM_DEBUG=1 to log all traffic.
local DEBUG = os.getenv("EMACS_NVIM_DEBUG") ~= nil

local EXITED = "org-bridge.nvim: Emacs exited"

local function send(obj)
  -- Emacs can die while Neovim answers one of its prompts.
  if not pipe then error(EXITED, 0) end
  local line = vim.json.encode(obj)
  if DEBUG then log(">> " .. line) end
  pipe:write(line .. "\n")
end

-- Chunks after the last newline; joined only when a newline arrives, since
-- appending each chunk to a string is quadratic for large buffers.
local pending = {}

local function on_read(err, chunk)
  -- Emacs exiting resets the socket under a late call (the modeline timer
  -- during quit); the job's exit handler reports the exit.
  if err == "ECONNRESET" or not chunk then return end
  assert(not err, err)
  pending[#pending + 1] = chunk
  if not chunk:find("\n", 1, true) then return end
  local data = table.concat(pending)
  pending = {}
  local start = 1
  while true do
    local nl = data:find("\n", start, true)
    if not nl then break end
    lines[#lines + 1] = data:sub(start, nl - 1)
    start = nl + 1
  end
  if start <= #data then pending[1] = data:sub(start) end
  -- Between calls nothing pumps; Emacs's notifications (timer messages)
  -- would wait for the next call.
  if M.depth == 0 then vim.schedule(function() if M.depth == 0 then M.pump() end end) end
end

local function lisp_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

-- Emacs usually starts from a FileType autocmd, often inside :silent edit
-- (file pickers), which would swallow the message: echo it once the
-- autocmd is done.
local function report_later(msg)
  local function try()
    -- state() is Neovim 0.10+; 0.9 just echoes.
    if vim.fn.exists("*state") == 1 and vim.fn.state():find("x") then return vim.defer_fn(try, 20) end
    vim.api.nvim_echo({ { msg, "ErrorMsg" } }, true, {})
  end
  vim.schedule(try)
end

function M.start()
  -- A crashed Emacs may not have reported its exit yet; don't reuse it.
  if job and vim.fn.jobwait({ job }, 0)[1] ~= -1 then
    vim.wait(1000, function() return job == nil end, 5)
  end
  if job then return end
  local socket = vim.fn.tempname() .. ".sock"
  local forms = { "(progn" }
  if M.config.init then
    -- An error in the user's init must not stop the bridge; report it.
    forms[#forms + 1] = "(condition-case err (load " .. lisp_string(vim.fn.expand(M.config.init))
      .. ") (error (princ (format \"nvim-bridge: init error: %s\\n\" (error-message-string err))"
      .. " #'external-debugging-output)))"
  end
  forms[#forms + 1] = "(nvb-install)"
  -- Faces pick their light or dark variants as Neovim's 'background'.
  forms[#forms + 1] = ("(nvb-set-background '%s)"):format(vim.o.background)
  forms[#forms + 1] = "(nvb-serve " .. lisp_string(socket) .. "))"
  local cmd = { M.config.emacs, "-Q", "--batch", "-l", BRIDGE_EL, "--eval", table.concat(forms, " ") }
  vim.fn.mkdir(vim.fn.fnamemodify(M.config.log, ":h"), "p")
  log("== starting: " .. table.concat(cmd, " "))
  local stderr_partial = ""
  job = vim.fn.jobstart(cmd, {
    -- All input goes over the socket; a read that slips past the bridge
    -- gets EOF (an error) instead of hanging on an open pipe.
    stdin = "null",
    on_stderr = function(_, data)
      -- data's first item continues the last chunk's unfinished line, and
      -- its last item is unfinished (or "" at a line end).
      data[1] = stderr_partial .. data[1]
      stderr_partial = table.remove(data)
      for _, l in ipairs(data) do
        if l ~= "" then log(l) end
        local init_error = l:match("^nvim%-bridge: init error: (.*)")
        if init_error then report_later("org-bridge.nvim: your init file failed: " .. init_error) end
        if l == "READY" and not pipe then
          pipe = uv.new_pipe(false)
          pipe:connect(socket, function(cerr)
            assert(not cerr, cerr)
            pipe:read_start(on_read)
            ready = true
          end)
        end
      end
    end,
    on_exit = function(_, code)
      log("== emacs exited: " .. code)
      job, pipe, ready = nil, nil, false
      M.on_exit()
    end,
  })
  -- Stop waiting as soon as Emacs dies (a broken init file).
  if not vim.wait(STARTUP_TIMEOUT_MS, function() return ready or not job end, 10) or not ready then
    error("org-bridge.nvim: Emacs did not start; run :checkhealth emacs (log: " .. M.config.log .. ")")
  end
end

-- Called when Emacs dies; the mirror layer resets its state.
function M.on_exit() end

local QUIT_TIMEOUT_MS = 3000

-- Ask Emacs to exit (running its kill hooks); kill it if it doesn't.
function M.stop()
  if not job then return end
  if ready then
    send({ method = "quit", params = vim.empty_dict() })
    if vim.wait(QUIT_TIMEOUT_MS, function() return job == nil end, 10) then return end
    log("== emacs ignored quit; killing it")
  end
  if job then vim.fn.jobstop(job) end
  vim.wait(QUIT_TIMEOUT_MS, function() return job == nil end, 10)
end

function M.running() return job ~= nil end

local function handle_request(msg)
  local handler = M.handlers[msg.method]
  local ok, res = pcall(function()
    assert(handler, "no handler for " .. msg.method)
    return handler(msg.params)
  end)
  -- A notification (no id) gets no reply.
  if msg.id == nil then
    if not ok then error(res, 0) end
    return
  end
  if ok then
    send({ id = msg.id, result = res == nil and vim.NIL or res })
  else
    send({ id = msg.id, error = tostring(res) })
  end
end

-- Decode pending lines; requests are handled, replies stored.
function M.pump()
  while #lines > 0 do
    local line = table.remove(lines, 1)
    if DEBUG then log("<< " .. line) end
    local msg = vim.json.decode(line, { luanil = { object = true, array = true } })
    if msg.method then
      handle_request(msg)
    else
      replies[msg.id] = msg
    end
  end
end

-- A call this long is hung, not slow (the agenda takes up to ~2 s): a C-c
-- typed meanwhile interrupts it rather than starting the next command.
local HUNG_MS = 3000

-- Whether C-c waits in typeahead (getchar(1) peeks its byte, 3) after the
-- call started at `start` (vim.loop.now()) has hung.
local function ctrl_c_typed(start) return vim.loop.now() - start > HUNG_MS and vim.fn.getchar(1) == 3 end

-- Call METHOD on Emacs and wait for the result. Errors from Emacs raise.
function M.call(method, params)
  M.start()
  next_id = next_id + 1
  local id = next_id
  M.depth = M.depth + 1
  local ok, res = pcall(function()
    send({ id = id, method = method, params = params or vim.empty_dict() })
    local start = vim.loop.now()
    while not replies[id] do
      local _, status = vim.wait(1000, function() return #lines > 0 or not job or ctrl_c_typed(start) end, 1)
      -- C-c (-2, or typed: a mapped C-c, as org buffers have, doesn't
      -- interrupt). Batch Emacs can't be interrupted (SIGINT kills it), so
      -- stop it; Neovim has the text, and the next command restarts it.
      local typed = ctrl_c_typed(start)
      if (status == -2 or typed) and job then
        if typed then vim.fn.getchar() end
        log("== interrupted; stopping emacs")
        vim.fn.jobstop(job)
        vim.wait(QUIT_TIMEOUT_MS, function() return job == nil end, 10)
        error("org-bridge.nvim: interrupted; Emacs restarts with the next command", 0)
      end
      if not job then error(EXITED, 0) end
      M.pump()
    end
    local reply = replies[id]
    replies[id] = nil
    if reply.error then error("Emacs: " .. reply.error, 0) end
    return reply.result
  end)
  M.depth = M.depth - 1
  if not ok then error(res, 0) end
  return res
end

return M
