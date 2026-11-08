-- Filetype -> how to find its math: treesitter language, detector module and the
-- kind of render ctx (macro sources). A new filetype is one register() call.
local M = {}

---@class inkmath.FiletypeSpec
---@field lang string treesitter language the detector parses
---@field detector string module with detect(buf, srow?, erow?) -> nodes, has_error
---@field ctx? "tex"|"markdown"|fun(buf: integer): {macros?: table, preamble?: string[]}

local specs = {} ---@type table<string, inkmath.FiletypeSpec>

---@param ft string
---@param spec inkmath.FiletypeSpec
function M.register(ft, spec)
  vim.validate("ft", ft, "string")
  vim.validate("spec", spec, "table")
  vim.validate("spec.lang", spec.lang, "string")
  vim.validate("spec.detector", spec.detector, "string")
  vim.validate(
    "spec.ctx",
    spec.ctx,
    function(v) return v == nil or v == "tex" or v == "markdown" or type(v) == "function" end,
    "nil, 'tex', 'markdown' or function"
  )
  specs[ft] = spec
end

---@param ft string
---@return inkmath.FiletypeSpec|nil
function M.get(ft) return specs[ft] end

--- spec of the buffer's filetype
---@param buf integer
---@return inkmath.FiletypeSpec|nil
function M.of(buf) return specs[vim.bo[buf].filetype] end

---@return string[] sorted
function M.filetypes()
  local out = vim.tbl_keys(specs)
  table.sort(out)
  return out
end

M.register("tex", { lang = "latex", detector = "inkmath.detect.latex", ctx = "tex" })
for _, ft in ipairs({ "markdown", "quarto", "rmd" }) do
  M.register(ft, { lang = "markdown", detector = "inkmath.detect.markdown", ctx = "markdown" })
  -- quarto/rmd buffers parse as markdown (highlighting, get_parser(buf)) unless the
  -- user or another plugin registered a parser for them already
  if ft ~= "markdown" and vim.treesitter.language.get_lang(ft) == ft then
    pcall(vim.treesitter.language.register, "markdown", ft)
  end
end

return M
