-- MathJax worker pool: requests spread over the workers, every callback exactly once,
-- also when a worker dies or times out mid-flight, and a per-worker restart cap.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
local config = require("inkmath.config")
local mathjax = require("inkmath.render.mathjax")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mathjax.shutdown()
      config.setup({ workers = 2 })
    end,
    post_case = function()
      mathjax.shutdown()
      config.setup({})
    end,
  },
})
local eq = MiniTest.expect.equality

local function req(i)
  return { tex = ("x_{%d} + \\frac{%d}{y}"):format(i, i), display = i % 2 == 0, macros = {}, color = "#ffffff",
    cell_w = 10, cell_h = 20, container_px = 800, x_height = 0.45, baseline = 0.78, scale = 1,
    out = vim.fn.tempname() .. ".png" }
end

--- send n requests; returns the per-request callback counts and results
local function send(n)
  local counts, results = {}, {}
  for i = 1, n do
    counts[i] = 0
    mathjax.request(req(i), function(res, err)
      counts[i] = counts[i] + 1
      results[i] = { res = res, err = err }
    end)
  end
  return counts, results
end

local function all_done(counts)
  for _, c in ipairs(counts) do
    if c == 0 then return false end
  end
  return true
end

T["two workers serve the requests"] = function()
  local counts, results = send(20)
  eq(#mathjax.pids(), 2)
  vim.wait(20000, function() return all_done(counts) end, 5)
  vim.wait(200) -- no late second callback
  for i = 1, 20 do
    eq(counts[i], 1)
    eq(results[i].err, nil)
  end
end

T["killing a worker mid-flight: every callback exactly once"] = function()
  local counts, results = send(40)
  local pids = mathjax.pids()
  eq(#pids, 2)
  vim.uv.kill(pids[1], "sigkill")
  vim.wait(20000, function() return all_done(counts) end, 5)
  vim.wait(300)
  local failed = 0
  for i = 1, 40 do
    eq(counts[i], 1)
    if results[i].err then
      eq(results[i].err, "worker exited")
      failed = failed + 1
    end
  end
  -- the other worker kept rendering
  MiniTest.expect.equality(failed < 40, true)
  -- the dead slot restarts on the next request
  local c2 = send(4)
  vim.wait(20000, function() return all_done(c2) end, 5)
  eq(#mathjax.pids(), 2)
end

T["timeout: exactly one callback, the worker is replaced"] = function()
  local orig = mathjax.timeout_ms
  mathjax.timeout_ms = 1
  local counts, results = send(6)
  vim.wait(5000, function() return all_done(counts) end, 5)
  mathjax.timeout_ms = orig
  vim.wait(300)
  for i = 1, 6 do
    eq(counts[i], 1)
    MiniTest.expect.equality(results[i].err == "worker timeout" or results[i].err == "worker exited", true)
  end
  local c2, r2 = send(2)
  vim.wait(20000, function() return all_done(c2) end, 5)
  eq(r2[1].err, nil)
end

T["restart cap is per worker"] = function()
  config.setup({ workers = 2 })
  mathjax.start_all()
  -- kill the first slot's worker until its cap is used up; the other keeps working
  for _ = 1, 4 do
    local pid = mathjax.pids()[1]
    vim.uv.kill(pid, "sigkill")
    vim.wait(2000, function() return not vim.tbl_contains(mathjax.pids(), pid) end, 5)
    mathjax.start_all()
  end
  local counts, results = send(4)
  vim.wait(20000, function() return all_done(counts) end, 5)
  for i = 1, 4 do eq(results[i].err, nil) end
  eq(#mathjax.pids(), 1) -- the first slot stays down, the second never restarted
end

T["warm starts one worker; the pool grows on demand"] = function()
  mathjax.warm()
  eq(#mathjax.pids(), 1)
  local pids = mathjax.pids()
  mathjax.warm() -- idempotent: no new processes
  eq(mathjax.pids(), pids)
  vim.wait(5000, function() return false end, 50) -- (the warm-up render finishes)
  local one = send(1) -- an idle worker takes it
  eq(#mathjax.pids(), 1)
  vim.wait(20000, function() return all_done(one) end, 5)
  local counts, results = send(3) -- requests queue up: the second worker starts
  eq(#mathjax.pids(), 2)
  vim.wait(20000, function() return all_done(counts) end, 5)
  for i = 1, 3 do
    eq(counts[i], 1)
    eq(results[i].err, nil)
  end
end

T["the warm-up render has the normal timeout"] = function()
  local orig = mathjax.timeout_ms
  mathjax.timeout_ms = 1
  mathjax.warm()
  local pid = mathjax.pids()[1]
  vim.wait(3000, function() return not vim.tbl_contains(mathjax.pids(), pid) end, 5)
  mathjax.timeout_ms = orig
  eq(vim.tbl_contains(mathjax.pids(), pid), false) -- timed out: the worker was killed
end

--- run fn(core) with the terminal stubbed; restores the stubs even when fn fails
local function with_term(fn)
  local core = require("inkmath.core")
  local kitty = require("inkmath.term.kitty")
  local cells = require("inkmath.term.cells")
  local tmux = require("inkmath.term.tmux")
  local o = { kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size }
  kitty.send, kitty.supported = function() end, function() return true end
  tmux.in_tmux, cells.cell_size = function() return false end, function() return { w = 10, h = 20 } end
  vim.o.termguicolors = true
  local ok, err = pcall(fn, core)
  kitty.send, kitty.supported, tmux.in_tmux, cells.cell_size = unpack(o)
  if not ok then error(err, 0) end
end

T["warm open spawns no worker; InsertEnter warms one"] = function()
  with_term(function(core)
    mathjax.shutdown()
    local buf = require("tests.helpers").buf({ "no math here" }, "markdown")
    vim.api.nvim_win_set_buf(0, buf)
    core.attach(buf)
    vim.wait(300, function() return false end, 10)
    eq(#mathjax.pids(), 0) -- nothing to render: no worker
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
    vim.wait(1000, function() return #mathjax.pids() == 1 end, 5)
    eq(#mathjax.pids(), 1)
    core.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

-- final review #10: a buffer attached before :InkMath build (tectonic only) warms a
-- worker on InsertEnter once MathJax is available
T["InsertEnter warms a worker once MathJax became available after attach"] = function()
  with_term(function(core)
    mathjax.shutdown()
    local render = require("inkmath.render")
    local orig_av, orig_mav = render.available, mathjax.available
    render.available = function() return { mathjax = false, tectonic = true } end
    mathjax.available = function() return false end
    local buf = require("tests.helpers").buf({ "no math here" }, "markdown")
    vim.api.nvim_win_set_buf(0, buf)
    local ok, err = pcall(function()
      core.attach(buf)
      render.available, mathjax.available = orig_av, orig_mav -- "built"
      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
      vim.wait(1000, function() return #mathjax.pids() == 1 end, 5)
      eq(#mathjax.pids(), 1)
    end)
    render.available, mathjax.available = orig_av, orig_mav
    core.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then error(err, 0) end
  end)
end

T["first miss spawns"] = function()
  with_term(function(core)
    mathjax.shutdown()
    vim.env.XDG_CACHE_HOME = vim.fn.tempname()
    local buf = require("tests.helpers").buf({ "a $q_{" .. vim.uv.hrtime() .. "}$ b" }, "markdown")
    vim.api.nvim_win_set_buf(0, buf)
    core.attach(buf)
    vim.wait(2000, function() return #mathjax.pids() >= 1 end, 5)
    eq(#mathjax.pids() >= 1, true)
    core.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

return T
