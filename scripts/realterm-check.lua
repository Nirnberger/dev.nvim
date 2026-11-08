-- Used by scripts/screenshots.sh for the overlay terminals: is every painted image drawn?
-- Usage: nvim --clean -l scripts/realterm-check.lua <root> <ready.json> <screen.ppm>
-- Exit 0 when each paint recorded in the ready file (scripts/screenshots-init.lua) has inked
-- pixels in its cells; otherwise prints the blank ones and exits 1.
local root, ready_file, ppm = unpack(_G.arg)
package.path = root .. "/?.lua;" .. package.path
local ready = vim.json.decode(table.concat(vim.fn.readfile(ready_file), "\n"))
local ok, why = require("tests.realterm").drawn(ready, ppm)
if not ok then
  print(why)
  os.exit(1)
end
