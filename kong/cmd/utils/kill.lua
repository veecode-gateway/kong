local pl_path = require "pl.path"
local process = require "kong.cmd.utils.process"
local log = require "kong.cmd.utils.log"

-- VeeCode APIP (ADR-0008): signal the pid from the pidfile via kill(2)
-- instead of the `kill %s \`cat %s\`` shell template; `args` keeps its
-- historical CLI shape ("-0", "-s TERM", ...) so call sites are unchanged.

local function kill(pid_file, args)
  log.debug("sending signal to pid at: %s", pid_file)
  args = args or "-0"
  local sig = args:match("^%-s%s+(%w+)$") or args:match("^%-(%d+)$")
  if pl_path.exists(pid_file) then
    log.debug("kill -%s `cat %s`", sig or args, pid_file)
    return process.signal_from_file(pid_file, sig or "NONE")
  else
    log.debug("no pid file at: %s", pid_file)
    return 0
  end
end

local function is_running(pid_file)
  -- we do our own pid_file exists check here because
  -- we want to return `nil` in case of NOT running,
  -- and not `0` like `kill` would return.
  if pl_path.exists(pid_file) then
    return kill(pid_file) == 0
  end
end

return {
  kill = kill,
  is_running = is_running
}
