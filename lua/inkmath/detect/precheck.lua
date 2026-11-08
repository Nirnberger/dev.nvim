-- Trigger scan of edited text: text without any of these cannot start, end or hide
-- math, so an edit that leaves only such text (and touches no known formula) needs
-- no parse and no query (detect/incr only shifts the previous nodes).
local M = {}

-- plain substrings: $ \( \) \[ \] \begin \end % ``` \\
M.TRIGGERS = { "$", "\\(", "\\)", "\\[", "\\]", "\\begin", "\\end", "%", "```", "\\\\" }

---@param lines string[]
---@return boolean
function M.triggers(lines)
  for _, l in ipairs(lines) do
    -- most prose has no backslash, `$`, `%` or backtick: one scan for those
    if l:find("[%$\\%%`]") then
      for _, t in ipairs(M.TRIGGERS) do
        if l:find(t, 1, true) then return true end
      end
    end
  end
  return false
end

return M
