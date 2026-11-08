-- Dates some days from today, in calendar days: adding days of seconds
-- lands on the wrong day late in the evening after a clock change.
local M = {}

-- Noon of the day `days` from today.
function M.time(days)
  local now = os.date("*t")
  return os.time({ year = now.year, month = now.month, day = now.day + days, hour = 12 })
end

-- Org's spelling of that day: "2026-11-07 Sat".
function M.org(days) return os.date("%Y-%m-%d %a", M.time(days)) end

return M
