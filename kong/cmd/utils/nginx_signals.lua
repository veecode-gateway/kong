local ffi = require "ffi"
local log = require "kong.cmd.utils.log"
local kill = require "kong.cmd.utils.kill"
local meta = require "kong.meta"
local pl_path = require "pl.path"
local version = require "version"
local process = require "kong.cmd.utils.process"
local process_secrets = require "kong.cmd.utils.process_secrets"


local fmt = string.format
local ipairs = ipairs
local unpack = unpack
local tostring = tostring


local C = ffi.C


ffi.cdef([[
  int setenv(const char *name, const char *value, int overwrite);
  int unsetenv(const char *name);
]])


local nginx_bin_name = "nginx"
local nginx_search_paths = {
  "",
  "/usr/local/openresty/nginx/sbin",
  "/opt/openresty/nginx/sbin",
}


local nginx_version_pattern = "^nginx.-openresty.-([%d%.]+)"
local nginx_compatible = version.set(unpack(meta._DEPENDENCIES.nginx))


local function is_openresty(bin_path)
  local cmd = fmt("%s -v", bin_path)
  local ok, _, _, stderr = process.execute({ bin_path, "-v" }, { capture = true })
  log.debug("%s: '%s'", cmd, stderr:sub(1, -2))
  if ok and stderr then
    local version_match = stderr:match(nginx_version_pattern)
    if not version_match or not nginx_compatible:matches(version_match) then
      log.verbose("incompatible OpenResty found at %s. Kong requires version" ..
                  " %s, got %s", bin_path, tostring(nginx_compatible),
                  version_match)
      return false
    end
    return true
  end
  log.debug("OpenResty 'nginx' executable not found at %s", bin_path)
end


local function send_signal(kong_conf, signal)
  if not kill.is_running(kong_conf.nginx_pid) then
    return nil, fmt("nginx not running in prefix: %s", kong_conf.prefix)
  end

  log.verbose("sending %s signal to nginx running at %s", signal, kong_conf.nginx_pid)

  local code = kill.kill(kong_conf.nginx_pid, "-s " .. signal)
  if code ~= 0 then
    return nil, "could not send signal"
  end

  return true
end


local function set_process_secrets_env(kong_conf)
  local secrets = process_secrets.extract(kong_conf)
  if not secrets then
    return false
  end

  local err
  secrets, err = process_secrets.serialize(secrets, kong_conf.kong_env)
  if not secrets then
    return nil, err
  end

  local ok_sub_http
  if kong_conf.role == "control_plane" or #kong_conf.proxy_listeners > 0
    or #kong_conf.admin_listeners > 0 or #kong_conf.status_listeners > 0 then
      ok_sub_http = C.setenv("KONG_PROCESS_SECRETS_HTTP", secrets, 1) == 0
  end

  local ok_sub_stream
  if #kong_conf.stream_listeners > 0 then
    ok_sub_stream = C.setenv("KONG_PROCESS_SECRETS_STREAM", secrets, 1) == 0
  end

  return ok_sub_http or ok_sub_stream
end


local function unset_process_secrets_env(has_process_secrets)
  if has_process_secrets then
    C.unsetenv("KONG_PROCESS_SECRETS_HTTP")
    C.unsetenv("KONG_PROCESS_SECRETS_STREAM")
  end
end


local _M = {}


function _M.find_nginx_bin(kong_conf)
  log.debug("searching for OpenResty 'nginx' executable")

  local search_paths = nginx_search_paths
  if kong_conf and kong_conf.openresty_path then
    log.debug("using custom OpenResty path: %s", kong_conf.openresty_path)
    search_paths = {
      pl_path.join(kong_conf.openresty_path, "nginx", "sbin"),
    }
  end

  local found
  for _, path in ipairs(search_paths) do
    local path_to_check = pl_path.join(path, nginx_bin_name)
    if is_openresty(path_to_check) then
      if path_to_check == "nginx" then
        log.debug("finding executable absolute path from $PATH...")
        local resolved, err = process.find_in_path("nginx")
        if resolved then
          path_to_check = resolved

        else
          log.error("could not find executable absolute path: %s", err)
        end
      end

      found = path_to_check
      log.debug("found OpenResty 'nginx' executable at %s", found)
      break
    end
  end

  if not found then
    return nil, fmt("could not find OpenResty 'nginx' executable. Kong requires version %s",
                    tostring(nginx_compatible))
  end

  return found
end


function _M.start(kong_conf)
  local nginx_bin, err = _M.find_nginx_bin(kong_conf)
  if not nginx_bin then
    return nil, err
  end

  if kill.is_running(kong_conf.nginx_pid) then
    return nil, "nginx is already running in " .. kong_conf.prefix
  end

  local has_process_secrets, err = set_process_secrets_env(kong_conf)
  if err then
    return nil, err
  end

  local argv = { nginx_bin, "-p", kong_conf.prefix, "-c", "nginx.conf" }

  log.debug("starting nginx: %s", table.concat(argv, " "))

  if kong_conf.nginx_main_daemon == "on" then
    -- running as daemon: capture command output, only surfaced on failure
    local ok, _, _, stderr = process.execute(argv, { capture = true })
    if not ok then
      unset_process_secrets_env(has_process_secrets)
      return nil, stderr
    end

    log.debug("nginx started")

  else
    -- running in foreground: do not redirect output since long running
    -- processes would produce output filling the disk; the child inherits
    -- our stdout/stderr instead.
    local ok, retcode = process.execute(argv)
    if not ok then
      unset_process_secrets_env(has_process_secrets)
      return nil, fmt("failed to start nginx (exit code: %s)", retcode)
    end
  end

  unset_process_secrets_env(has_process_secrets)
  return true
end


function _M.check_conf(kong_conf)
  local nginx_bin, err = _M.find_nginx_bin(kong_conf)
  if not nginx_bin then
    return nil, err
  end

  local argv = { nginx_bin, "-t", "-p", kong_conf.prefix, "-c", "nginx.conf" }

  log.debug("testing nginx configuration: KONG_NGINX_CONF_CHECK=true %s",
            table.concat(argv, " "))

  local ok, retcode, _, stderr = process.execute(argv, {
    capture = true,
    env = { KONG_NGINX_CONF_CHECK = "true" },
  })
  if not ok then
    return nil, fmt("nginx configuration is invalid (exit code %d):\n%s",
                    retcode, stderr)
  end

  return true
end


function _M.stop(kong_conf)
  return send_signal(kong_conf, "TERM")
end


function _M.quit(kong_conf)
  return send_signal(kong_conf, "QUIT")
end


function _M.reload(kong_conf)
  if not kill.is_running(kong_conf.nginx_pid) then
    return nil, fmt("nginx not running in prefix: %s", kong_conf.prefix)
  end

  local nginx_bin, err = _M.find_nginx_bin(kong_conf)
  if not nginx_bin then
    return nil, err
  end

  local argv = { nginx_bin, "-p", kong_conf.prefix, "-c", "nginx.conf",
                 "-s", "reload" }

  log.debug("reloading nginx: %s", table.concat(argv, " "))

  local ok, _, _, stderr = process.execute(argv, { capture = true })
  if not ok then
    return nil, stderr
  end

  return true
end


return _M
