-- VeeCode APIP: the CLI's Lua ngx.shared mock (kong/globalpatches.lua) must
-- support compare_expire, which lua-resty-lock >= 0.10 requires. The mock
-- only activates in CLI mode, so these checks run in a separate resty process.

local pl_utils = require "pl.utils"


local function run_cli(code)
  local script = os.tmpname()
  local f = assert(io.open(script, "w"))
  f:write('require("kong.globalpatches")({ cli = true })\n', code)
  f:close()
  local ok, _, stdout, stderr = pl_utils.executeex("resty -I . " .. script)
  os.remove(script)
  return ok, stdout, stderr
end


describe("CLI shared dict mock", function()
  it("lets resty.lock lock, expire and unlock", function()
    local ok, stdout, stderr = run_cli([[
      local d = ngx.shared.kong_locks
      local lock = assert(require("resty.lock"):new("kong_locks", { exptime = 5 }))
      assert(lock:lock("k") == 0)
      assert(d:get("k"))
      assert(lock:expire(10) == true)
      assert(d:ttl("k") > 5)
      assert(lock:unlock() == 1)
      assert(d:get("k") == nil)
      print("ok")
    ]])
    assert(ok, stderr)
    assert.matches("ok", stdout)
  end)

  it("matches resty.core.shdict compare_expire results", function()
    local ok, stdout, stderr = run_cli([[
      local d = ngx.shared.test
      d:set("x", "a")
      print(select(2, d:compare_expire("x", "b")))
      print(select(2, d:compare_expire("missing", "a")))
      print(select(2, d:compare_expire("x", 1)))
      print(select(2, d:compare_expire("x", "a", -1)))
      assert(d:compare_expire("x", "a", 0) == true)
      assert(d:ttl("x") == 0)
      assert(d:compare_expire("x", "a") == true)
      assert(d:get("x") == nil)
      print("done")
    ]])
    assert(ok, stderr)
    assert.same({
      "lock ownership lost",
      "lock ownership lost",
      "bad value type",
      'bad "exptime" argument',
      "done",
    }, pl_utils.split(stdout, "\n"))
  end)
end)
