-- VeeCode APIP shell-free process helpers (ADR-0008).
--
-- This module is fork-local (upstream Kong has no file at this path). It
-- concentrates the machinery that lets the Kong CLI run without /bin/sh so
-- the call-site diffs in upstream-owned files stay minimal:
--
--   * process.execute(argv, opts)  -- fork/execvp/waitpid, no shell
--   * process.signal_from_file()   -- kill(2) on a pidfile, no `kill`/`cat`
--   * process.get_rlimit_nofile()  -- getrlimit(2), no `ulimit -n`
--   * process.symlink()/chmod()    -- symlink(2)/chmod(2), no `ln`/`chmod`
--   * process.find_in_path()       -- $PATH search, no `command -v`
--
-- Everything here is POSIX-portable (Linux and macOS): the CLI also runs on
-- developer machines, so no Linux-only syscalls are used.

local ffi = require "ffi"
local bit = require "bit"


local C = ffi.C
local band = bit.band
local rshift = bit.rshift
local tostring = tostring
local tonumber = tonumber


ffi.cdef [[
  typedef int32_t kong_pid_t;

  kong_pid_t fork(void);
  int execvp(const char *file, char *const argv[]);
  kong_pid_t waitpid(kong_pid_t pid, int *status, int options);
  void _exit(int status);

  int pipe(int fds[2]);
  int close(int fd);
  int dup2(int oldfd, int newfd);
  long read(int fd, void *buf, unsigned long count);
  long write(int fd, const void *buf, unsigned long count);

  int kill(kong_pid_t pid, int sig);
  int symlink(const char *target, const char *linkpath);
  int unlink(const char *path);
  int access(const char *path, int amode);

  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);

  int sigemptyset(void *set);
  int sigaddset(void *set, int sig);
  int sigprocmask(int how, const void *set, void *oldset);

  char *strerror(int errnum);
]]

if ffi.os == "OSX" then
  ffi.cdef [[
    typedef uint16_t kong_mode_t;
    int chmod(const char *path, kong_mode_t mode);
    struct kong_rlimit { uint64_t rlim_cur; uint64_t rlim_max; };
    int getrlimit(int resource, struct kong_rlimit *rlim);
  ]]
else
  ffi.cdef [[
    typedef uint32_t kong_mode_t;
    int chmod(const char *path, kong_mode_t mode);
    struct kong_rlimit { uint64_t rlim_cur; uint64_t rlim_max; };
    int getrlimit(int resource, struct kong_rlimit *rlim);
  ]]
end


local IS_MACOS = ffi.os == "OSX"

local SIGNALS = {
  NONE  = 0,
  HUP   = 1,
  INT   = 2,
  QUIT  = 3,
  KILL  = 9,
  TERM  = 15,
  WINCH = 28,
  USR1  = IS_MACOS and 30 or 10,
  USR2  = IS_MACOS and 31 or 12,
  CHLD  = IS_MACOS and 20 or 17,
}

local SIG_BLOCK      = IS_MACOS and 1 or 0
local SIG_SETMASK    = IS_MACOS and 3 or 2
local RLIMIT_NOFILE  = IS_MACOS and 8 or 7
local RLIM_INFINITY  = IS_MACOS and 0x7FFFFFFFFFFFFFFFULL
                                or 0xFFFFFFFFFFFFFFFFULL
local X_OK   = 1
local EINTR  = 4


local function errno_string()
  return ffi.string(C.strerror(ffi.errno()))
end


-- The temporary nginx that hosts CLI code (via the resty launcher) installs
-- a SIGCHLD handler that reaps any child with waitpid(-1, ..., WNOHANG).
-- Exactly like system(3), we must block SIGCHLD around fork/waitpid or the
-- handler steals our child's exit status. The child restores the original
-- mask before exec (the signal mask survives execvp).
local function block_sigchld()
  local newset = ffi.new("long[16]") -- >= sizeof(sigset_t) on Linux and macOS
  local oldset = ffi.new("long[16]")
  C.sigemptyset(newset)
  C.sigaddset(newset, SIGNALS.CHLD)
  C.sigprocmask(SIG_BLOCK, newset, oldset)
  return oldset
end

local function restore_sigmask(oldset)
  C.sigprocmask(SIG_SETMASK, oldset, nil)
end


local function read_all(fd)
  local chunks = {}
  local buf = ffi.new("uint8_t[4096]")
  while true do
    local n = tonumber(C.read(fd, buf, 4096))
    if n > 0 then
      chunks[#chunks + 1] = ffi.string(buf, n)
    elseif n == 0 then
      break
    elseif ffi.errno() ~= EINTR then
      break
    end
  end
  return table.concat(chunks)
end


local _M = {}


_M.SIGNALS = SIGNALS


--- Run argv (a plain array of strings, argv[1] is looked up on $PATH) with
-- no shell involved, and wait for it to finish.
-- opts.capture: capture stdout/stderr instead of inheriting them.
-- opts.env: table of env vars visible to the child only.
-- Mirrors pl.utils.executeex's return shape:
--   ok (exit status == 0), exit code, stdout ("" unless capture), stderr.
-- A child killed by signal N reports exit code 128 + N (shell convention).
function _M.execute(argv, opts)
  opts = opts or {}

  local out_fds, err_fds
  if opts.capture then
    out_fds = ffi.new("int[2]")
    err_fds = ffi.new("int[2]")
    if C.pipe(out_fds) ~= 0 or C.pipe(err_fds) ~= 0 then
      return false, -1, "", "pipe() failed: " .. errno_string()
    end
  end

  -- apply opts.env to our own environment right before fork so the child
  -- inherits it, then restore; this matches `VAR=val cmd` shell semantics
  -- without touching the child post-fork (no allocations between fork and
  -- exec).
  local saved_env
  if opts.env then
    saved_env = {}
    for k, v in pairs(opts.env) do
      saved_env[k] = os.getenv(k) or false
      C.setenv(k, tostring(v), 1)
    end
  end

  local n = #argv
  local cargv = ffi.new("const char *[?]", n + 1)
  for i = 1, n do
    cargv[i - 1] = argv[i]
  end
  cargv[n] = nil

  local oldset = block_sigchld()
  local pid = C.fork()

  if pid == 0 then
    -- child: restore the pre-fork signal mask, wire fds, exec
    restore_sigmask(oldset)
    if opts.capture then
      C.dup2(out_fds[1], 1)
      C.dup2(err_fds[1], 2)
      C.close(out_fds[0]); C.close(out_fds[1])
      C.close(err_fds[0]); C.close(err_fds[1])
    end
    C.execvp(argv[1], ffi.cast("char *const *", cargv))
    local msg = "could not execute '" .. argv[1] .. "': " .. errno_string() .. "\n"
    C.write(2, msg, #msg)
    C._exit(127)
  end

  -- parent
  if saved_env then
    for k, old in pairs(saved_env) do
      if old == false then
        C.unsetenv(k)
      else
        C.setenv(k, old, 1)
      end
    end
  end

  if pid < 0 then
    restore_sigmask(oldset)
    if opts.capture then
      C.close(out_fds[0]); C.close(out_fds[1])
      C.close(err_fds[0]); C.close(err_fds[1])
    end
    return false, -1, "", "fork() failed: " .. errno_string()
  end

  local stdout_str, stderr_str = "", ""
  if opts.capture then
    C.close(out_fds[1])
    C.close(err_fds[1])
    stdout_str = read_all(out_fds[0])
    stderr_str = read_all(err_fds[0])
    C.close(out_fds[0])
    C.close(err_fds[0])
  end

  local status = ffi.new("int[1]")
  local ret
  repeat
    ret = C.waitpid(pid, status, 0)
  until ret ~= -1 or ffi.errno() ~= EINTR

  restore_sigmask(oldset)

  if ret == -1 then
    return false, -1, stdout_str, "waitpid() failed: " .. errno_string()
  end

  local st = status[0]
  local code
  if band(st, 0x7f) == 0 then
    code = band(rshift(st, 8), 0xff)   -- WIFEXITED -> WEXITSTATUS
  else
    code = 128 + band(st, 0x7f)        -- WIFSIGNALED -> 128 + WTERMSIG
  end

  return code == 0, code, stdout_str, stderr_str
end


--- Send a signal to the pid stored in a pidfile. `sig` is a signal name
-- ("TERM", "QUIT", ...), a number, or a numeric string ("0", "9").
-- Returns 0 on success and 1 on any failure (unreadable/garbage pidfile,
-- unknown signal, kill(2) error) -- the exit-code convention of the
-- `kill %s \`cat %s\`` shell template this replaces.
function _M.signal_from_file(pid_file, sig)
  local fd = io.open(pid_file, "r")
  if not fd then
    return 1
  end

  local content = fd:read("*a")
  fd:close()

  local pid = tonumber(content and content:match("^%s*(%d+)%s*$"))
  if not pid then
    return 1
  end

  local signum = tonumber(sig) or SIGNALS[sig]
  if not signum then
    return 1
  end

  return C.kill(pid, signum) == 0 and 0 or 1
end


--- Soft RLIMIT_NOFILE, i.e. what `ulimit -n` reports.
-- Returns math.huge for RLIM_INFINITY ("unlimited").
function _M.get_rlimit_nofile()
  local rlim = ffi.new("struct kong_rlimit")
  if C.getrlimit(RLIMIT_NOFILE, rlim) ~= 0 then
    return nil, "getrlimit() failed: " .. errno_string()
  end

  if rlim.rlim_cur == RLIM_INFINITY then
    return math.huge
  end

  return tonumber(rlim.rlim_cur)
end


--- symlink(2): create `linkpath` pointing at `target` (no `ln -s`).
function _M.symlink(target, linkpath)
  if C.symlink(target, linkpath) ~= 0 then
    return nil, "could not create symlink " .. linkpath .. " -> " .. target
                .. ": " .. errno_string()
  end
  return true
end


--- chmod(2) with an octal string mode ("755", "0644") or a number (no
-- `chmod` binary).
function _M.chmod(path, mode)
  local mode_num = type(mode) == "number" and mode or tonumber(mode, 8)
  if not mode_num then
    return nil, "invalid mode: " .. tostring(mode)
  end

  if C.chmod(path, mode_num) ~= 0 then
    return nil, "could not chmod " .. path .. ": " .. errno_string()
  end
  return true
end


--- $PATH search for an executable, like `command -v` for a bare name.
function _M.find_in_path(name)
  local path_env = os.getenv("PATH") or ""
  for dir in path_env:gmatch("[^:]+") do
    local candidate = dir .. "/" .. name
    if C.access(candidate, X_OK) == 0 then
      return candidate
    end
  end
  return nil, "could not find '" .. name .. "' in PATH"
end


return _M
