NVIM = NVIM_APPNAME=inkmath-dev nvim --headless --noplugin -u tests/minit.lua

.PHONY: test test-file deps test-worker bench doc

test:
	$(NVIM) -c "lua MiniTest.run()"

test-file:
	$(NVIM) -c "lua MiniTest.run_file('$(F)')"

deps:
	$(NVIM) -c "qa"

test-worker:
	cd worker && node --test test/

bench:
	$(NVIM) -c "luafile dev/bench.lua"

doc:
	$(NVIM) -c "luafile dev/gendoc.lua" -c "helptags doc" -c qa
