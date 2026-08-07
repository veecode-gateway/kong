-- VeeCode APIP (ADR-0008): unit tests for the shell-free process helpers
-- that back the Kong CLI (kong/cmd/utils/process.lua).

local process = require "kong.cmd.utils.process"
local kill = require "kong.cmd.utils.kill"
local pl_path = require "pl.path"
local pl_file = require "pl.file"
local ffi = require "ffi"

ffi.cdef("int32_t getpid(void);")

local TMP = os.getenv("TMPDIR") or "/tmp"

local function tmpname()
  return pl_path.join(TMP, "kong_process_spec_" .. tostring(math.random(1e9)))
end

describe("kong.cmd.utils.process", function()
  describe("execute()", function()
    it("runs an argv array and reports exit code 0", function()
      local ok, code = process.execute({ "true" })
      assert.is_true(ok)
      assert.equal(0, code)
    end)

    it("reports non-zero exit codes", function()
      local ok, code = process.execute({ "false" })
      assert.is_false(ok)
      assert.is_true(code > 0)
    end)

    it("captures stdout and stderr separately", function()
      local ok, code, stdout, stderr =
        process.execute({ "resty", "-e", "io.stdout:write('out') io.stderr:write('err')" },
                        { capture = true })
      assert.is_true(ok)
      assert.equal(0, code)
      assert.equal("out", stdout)
      assert.equal("err", stderr)
    end)

    it("propagates the child exit code", function()
      local ok, code = process.execute({ "resty", "-e", "os.exit(3)" },
                                       { capture = true })
      assert.is_false(ok)
      assert.equal(3, code)
    end)

    it("does not involve a shell", function()
      -- a shell would expand $HOME; execvp must pass it through verbatim
      local ok, _, stdout = process.execute({ "echo", "$HOME" },
                                            { capture = true })
      assert.is_true(ok)
      assert.equal("$HOME\n", stdout)
    end)

    it("returns exit code 127 and a message for a missing executable", function()
      local ok, code, _, stderr =
        process.execute({ "kong-does-not-exist-anywhere" }, { capture = true })
      assert.is_false(ok)
      assert.equal(127, code)
      assert.matches("could not execute", stderr)
    end)

    it("passes opts.env to the child without leaking into the parent", function()
      local ok, _, stdout =
        process.execute({ "resty", "-e", "print(os.getenv('KONG_PROCESS_SPEC_VAR'))" },
                        { capture = true, env = { KONG_PROCESS_SPEC_VAR = "hello" } })
      assert.is_true(ok)
      assert.equal("hello\n", stdout)
      assert.is_nil(os.getenv("KONG_PROCESS_SPEC_VAR"))
    end)
  end)

  describe("get_rlimit_nofile()", function()
    it("returns the soft NOFILE limit as a positive number", function()
      local limit, err = process.get_rlimit_nofile()
      assert.is_nil(err)
      assert.is_number(limit)
      assert.is_true(limit > 0)
    end)
  end)

  describe("signal_from_file()", function()
    it("signals the pid read from a pidfile (sig 0 probe)", function()
      local pidfile = tmpname()
      -- our own pid is definitely alive
      assert(pl_file.write(pidfile, tostring(ffi.C.getpid()) .. "\n"))
      assert.equal(0, process.signal_from_file(pidfile, "NONE"))
      assert.equal(0, process.signal_from_file(pidfile, "0"))
      os.remove(pidfile)
    end)

    it("returns 1 for a garbage pidfile", function()
      local pidfile = tmpname()
      assert(pl_file.write(pidfile, "not-a-pid\n"))
      assert.equal(1, process.signal_from_file(pidfile, "NONE"))
      os.remove(pidfile)
    end)

    it("returns 1 for a missing pidfile", function()
      assert.equal(1, process.signal_from_file(tmpname(), "NONE"))
    end)

    it("returns 1 for an unknown signal name", function()
      local pidfile = tmpname()
      assert(pl_file.write(pidfile, "1\n"))
      assert.equal(1, process.signal_from_file(pidfile, "NOSUCHSIG"))
      os.remove(pidfile)
    end)
  end)

  describe("symlink()", function()
    it("creates a symlink and fails on an existing destination", function()
      local target = tmpname()
      local link = tmpname()
      assert(pl_file.write(target, "x"))
      assert.is_true((process.symlink(target, link)))
      assert.equal("x", pl_file.read(link))
      local ok, err = process.symlink(target, link)
      assert.is_nil(ok)
      assert.matches("could not create symlink", err)
      os.remove(link)
      os.remove(target)
    end)
  end)

  describe("chmod()", function()
    it("applies an octal string mode", function()
      local path = tmpname()
      assert(pl_file.write(path, "x"))
      assert.is_true((process.chmod(path, "600")))
      local ok, code, stdout = process.execute({ "ls", "-l", path }, { capture = true })
      assert.is_true(ok and code == 0)
      assert.matches("^%-rw%-%-%-%-%-%-", stdout)
      os.remove(path)
    end)

    it("rejects an invalid mode", function()
      local ok, err = process.chmod("/tmp", "notamode")
      assert.is_nil(ok)
      assert.matches("invalid mode", err)
    end)
  end)

  describe("find_in_path()", function()
    it("resolves a bare executable name to an absolute path", function()
      local found = process.find_in_path("resty")
      assert.is_string(found)
      assert.matches("/resty$", found)
      assert.is_true(pl_path.isabs(found))
    end)

    it("returns nil + error for an unknown name", function()
      local found, err = process.find_in_path("kong-does-not-exist-anywhere")
      assert.is_nil(found)
      assert.matches("could not find", err)
    end)
  end)
end)

describe("kong.cmd.utils.kill (shell-free)", function()
  it("kill() with no args probes the pid with signal 0", function()
    local pidfile = tmpname()
    assert(pl_file.write(pidfile, tostring(ffi.C.getpid()) .. "\n"))
    assert.equal(0, kill.kill(pidfile))
    assert.is_true(kill.is_running(pidfile))
    os.remove(pidfile)
  end)

  it("kill() returns 0 when the pidfile does not exist", function()
    assert.equal(0, kill.kill(tmpname()))
  end)

  it("is_running() returns nil when the pidfile does not exist", function()
    assert.is_nil(kill.is_running(tmpname()))
  end)

  it("kill() accepts the historical argument shapes", function()
    local pidfile = tmpname()
    assert(pl_file.write(pidfile, tostring(ffi.C.getpid()) .. "\n"))
    assert.equal(0, kill.kill(pidfile, "-0"))
    assert.equal(1, kill.kill(pidfile, "-s NOSUCHSIG"))
    os.remove(pidfile)
  end)
end)
