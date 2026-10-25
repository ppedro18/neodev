local M = {}

-- Helper to read a file completely
local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

-- Memoized per cwd, not forever: a long-lived nvim session that changes
-- project (:cd, Snacks.picker.projects, yazi) would otherwise keep scanning
-- the FIRST project it ever saw, silently pointing <leader>an/etc. at the
-- wrong module (or none) after switching.
local cached_cwd, cached_module_path = nil, nil

function M.get_app_module_path()
  local cwd = vim.fn.getcwd()
  if cached_cwd == cwd then return cached_module_path end

  local function cache_and_return(path)
    cached_cwd, cached_module_path = cwd, path
    return path
  end

  -- Search for build.gradle or build.gradle.kts recursively
  local gradle_files = vim.fn.globpath(cwd, "**/build.gradle*", false, true)
  for _, file in ipairs(gradle_files) do
    if not file:match("/build/") and not file:match("/%.gradle/") then
      local content = read_file(file)
      if content and (content:match("com%.android%.application") or content:match("applicationId")) then
        return cache_and_return(vim.fn.fnamemodify(file, ":h"))
      end
    end
  end

  -- Fallback: Look for an AndroidManifest.xml that contains the MAIN action
  local manifests = vim.fn.globpath(cwd, "**/AndroidManifest.xml", false, true)
  for _, file in ipairs(manifests) do
    if not file:match("/build/") then
      local content = read_file(file)
      if content and content:match("android%.intent%.action%.MAIN") then
        return cache_and_return(vim.fn.fnamemodify(file, ":h:h:h"))
      end
    end
  end

  return cache_and_return(cwd .. "/app")
end

-- Tries to find applicationId in the dynamically detected module
function M.get_package_name()
  local module_path = M.get_app_module_path()

  -- Try finding in build.gradle
  local content = read_file(module_path .. "/build.gradle") or read_file(module_path .. "/build.gradle.kts")
  if content then
    local package_name = content:match('applicationId%s*=?%s*["\'](.-)["\']')
    if package_name then return package_name end

    local namespace = content:match('namespace%s*=?%s*["\'](.-)["\']')
    if namespace then return namespace end
  end

  -- Fallback to AndroidManifest.xml
  content = read_file(module_path .. "/src/main/AndroidManifest.xml")
  if content then
    local package_name = content:match('package=["\'](.-)["\']')
    if package_name then return package_name end
  end

  -- Extra fallback: resolve from gradle.properties (ANDROID_APPLICATION_ID)
  local gp = read_file(vim.fn.getcwd() .. "/gradle.properties")
  if gp then
    local pid = gp:match("ANDROID_APPLICATION_ID%s*=%s*(%S+)")
    if pid then return pid end
  end

  return nil
end

return M
