-- Extra expectations for mini.test.
local M = {}

--- string `s` matches Lua pattern `pat`
M.match = MiniTest.new_expectation("string matching", function(s, pat)
  return type(s) == "string" and s:find(pat) ~= nil
end, function(s, pat) return ("Pattern: %s\nObserved: %s"):format(pat, vim.inspect(s)) end)

return M
