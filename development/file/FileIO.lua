---@diagnostic disable: lowercase-global

local Helper_log = require("shared.helper_log")
local log = Helper_log.log
----------------------------------------------------------------
-- FileIO (FicsIt Network compatible)
-- - Auto-Mount of /dev/* on self.root (Default: "/srv")
-- - Consistent returns: ok, result|nil, err
-- - exists / isFile / isDir / list / mkdir / rm
-- - readAllText / readAllBinary / writeText / appendText / writeBinary(/Array)
-- - copy / move / tryRead*
----------------------------------------------------------------

--------------------------------
-- FileIO-Klasse
--------------------------------

---@class FileIO
---@field root string              -- Mount point (i. d. R. "/srv")
---@field readChunk integer        -- Read chunk size in Bytes
---@field autoMount boolean        -- true = mount /dev automatically if necessary
---@field searchFile string|nil    -- optional: File that must exist after mounting
---@field _mounted boolean         -- internal status: root ready/mounted
---@field _mountedDev string|nil   -- e.g. "/dev/XYZ"
---@field _mountedId string|nil    -- e.g. "XYZ"
local FileIO = {}
FileIO.__index = FileIO

-- ==== Internal Helpers =========================================================

--- Removes leading Slashes and prohibits ".." in relative paths.
---@param rel any
---@return string
local function _sanitize(rel)
    rel = tostring(rel or "")
    rel = rel:gsub("^/*", "")
    assert(not rel:find("%.%.", 1, true), "FileIO: Path is not allowed '..' contain")
    return rel
end

--- Create absolute path below root.
---@param root string
---@param rel string
---@return string
local function _join(root, rel)
    rel = _sanitize(rel)
    if root == "/" then return "/" .. rel end
    if root:sub(-1) == "/" then return root .. rel end
    return root .. "/" .. rel
end

--- Returns the parent directory of a path (real dirname).
---@param p any
---@return string
local function _dirname(p)
    p = tostring(p or "")
    p = p:gsub("/+$", "")                     -- trailing "/" removed
    local dir = p:match("^(.*)/[^/]*$") or "" -- everything before last "/"
    if dir == "" then return "/" end
    return dir
end

--- Ensures that the parent directory of the target file path exists.
---@param filePath string
local function _ensure_parent_dir(filePath)
    local dir = _dirname(filePath)
    if dir and not filesystem.exists(dir) then
        filesystem.createDir(dir, true) -- FIN-API: createDir
    end
end

-- isDir may have a different name depending on the FIN version
local _isDirFn = filesystem.isDir or filesystem.isDirectory

--- Uniform error formatting + Log
---@param where string  -- z.B. "readAllText"
---@param path  string
---@param msg   any
---@return string
local function _err(where, path, msg)
    local s = string.format("FileIO.%s(%s): %s", where, path, tostring(msg))
    log(3, s) -- error
    return s
end

--- Safe open: ok, file|nil, err
---@param path string
---@param mode string
---@return boolean, any|nil, string|nil
local function _safe_open(path, mode)
    local ok, f = pcall(function() return filesystem.open(path, mode) end)
    if not ok or not f then
        local msg = (ok and "open returned nil") or tostring(f)
        return false, nil, _err("open(" .. tostring(mode) .. ")", path, msg)
    end
    return true, f, nil
end

--- Safe call Wrapper: ok, result|nil, err
---@param where string
---@param path string
---@param fn fun():any
---@return boolean, any|nil, string|nil
local function _pcall(where, path, fn)
    local ok, res = pcall(fn)
    if not ok then
        return false, nil, _err(where, path, res)
    end
    return true, res, nil
end

-- ==== Constructor ============================================================

--- Creates a new FileIO instance.
---@param opts {root?:string, chunk?:integer, autoMount?:boolean, searchFile?:string}|nil
---@return FileIO
function FileIO.new(opts)
    local self       = setmetatable({}, FileIO)
    self.root        = (opts and opts.root) or "/srv"
    self.readChunk   = (opts and opts.chunk) or (64 * 1024)
    self.autoMount   = (opts and opts.autoMount ~= false) -- Default: true
    self.searchFile  = (opts and opts.searchFile) or nil

    self._mounted    = false
    self._mountedDev = nil -- e.g. "/dev/XYZ"
    self._mountedId  = nil -- e.g. "XYZ"
    return self
end

-- ==== Mount Logic ============================================================

--- Checks heuristically whether root is already “usable” (exists + children can be accessed).
---@return boolean
function FileIO:_rootLooksReady()
    if not filesystem.exists(self.root) then return false end
    local ok = pcall(function() return filesystem.children(self.root) end)
    return ok
end

--- Tried to mount any /dev/* on root (optionally verified via searchFile).
---@return boolean
function FileIO:_tryMount()
    -- /dev initialize (FIN)
    pcall(function() filesystem.initFileSystem("/dev") end)

    local devs = filesystem.children("/dev") or {}
    for _, dev in pairs(devs) do
        local drive = filesystem.path("/dev", dev)
        local okMnt = pcall(function() filesystem.mount(drive, self.root) end)
        if okMnt then
            -- mounted Device details
            self._mountedDev = drive
            self._mountedId  = tostring(drive):match("^/dev/(.+)$")

            if not self.searchFile then
                return true
            else
                local testPath = _join(self.root, self.searchFile)
                if filesystem.exists(testPath) then
                    return true
                else
                    -- not the right data carrier → try again
                    pcall(function() filesystem.unmount(drive) end)
                    self._mountedDev, self._mountedId = nil, nil
                end
            end
        end
    end
    return false
end

--- Ensures root is ready/mounted (performs auto-mount if necessary).
---@return boolean, nil|nil, string|nil
function FileIO:ensureMounted()
    if self._mounted then return true end
    if self:_rootLooksReady() then
        self._mounted = true
        log(1, "FileIO: root ready:", self.root)
        return true
    end
    if not self.autoMount then
        return false, nil, _err("ensureMounted", self.root, "root not ready and autoMount=false")
    end
    local ok = self:_tryMount()
    self._mounted = ok and self:_rootLooksReady() or false
    if not self._mounted then
        return false, nil, _err("ensureMounted", self.root, "could not mount any /dev/*")
    end
    log(1, "FileIO: mounted on", self.root, "device:", self._mountedDev or "?")
    return true
end

-- ==== public helpers =========================================================

--- Create absolute path below root.
---@param rel string
---@return string
function FileIO:abs(rel) return _join(self.root, rel) end

--- Returns the last mounted device (e.g. "/dev/XYZ") if known.
---@return string|nil
function FileIO:getMountedDevice() return self._mountedDev end

--- Returns the ID of the mounted device (e.g. "XYZ") if known.
---@return string|nil
function FileIO:getMountedId() return self._mountedId end

-- ==== Queries ===============================================================

--- true if the relative resource exists.
---@param rel string
---@return boolean
function FileIO:exists(rel)
    self:ensureMounted()
    return filesystem.exists(self:abs(rel))
end

--- true if the relative resource is a file.
---@param rel string
---@return boolean
function FileIO:isFile(rel)
    self:ensureMounted()
    local p = self:abs(rel)
    return filesystem.exists(p) and filesystem.isFile(p)
end

--- true if the relative resource is a directory.
---@param rel string
---@return boolean
function FileIO:isDir(rel)
    self:ensureMounted()
    local p = self:abs(rel)
    if not filesystem.exists(p) then return false end
    if _isDirFn then
        return _isDirFn(p)
    end
    -- Fallback (if neither isDir nor isDirectory exists):
    local ok = pcall(function() return filesystem.children(p) end)
    return ok
end

--- Lists children of a directory (or {} if non-existent).
---@param rel string|nil
---@return string[]
function FileIO:list(rel)
    self:ensureMounted()
    local p = self:abs(rel or "")
    if not filesystem.exists(p) then return {} end
    return filesystem.children(p) or {}
end

-- ==== Create/Delete ====================================================

--- Creates a directory (recursively if handled that way by FIN).
---@param rel string
---@return boolean, nil|nil, string|nil
function FileIO:mkdir(rel)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    local okMk, _, e = _pcall("mkdir", p, function() return filesystem.createDir(p, true) end)
    if not okMk then return false, nil, e end
    log(1, "FileIO.mkdir OK:", p)
    return true
end

--- Removes file or (recursive=true) directory including content.
---@param rel string
---@param rekursiv boolean|nil
---@return boolean, nil|nil, string|nil
function FileIO:rm(rel, rekursiv)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    rekursiv = rekursiv or true

    if rekursiv and self:isDir(rel) then
        for _, name in ipairs(filesystem.children(p) or {}) do
            local okRm, _, eRm = self:rm(_sanitize(rel) .. "/" .. name, true)
            if not okRm then return false, nil, eRm end
        end
    end

    local okDel, _, eDel = _pcall("rm", p, function() return filesystem.remove(p, rekursiv) end)
    if not okDel then return false, nil, eDel end
    log(1, "FileIO.rm OK:", p)
    return true
end

-- ==== Read/Write ========================================================

--- Reads text file completely (UTF-8/ASCII).
---@param rel string
---@return boolean, string|nil, string|nil
function FileIO:readAllText(rel)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)

    local okOpen, f, e = _safe_open(p, "r")
    if not okOpen then return false, nil, e end

    local buf = ""
    while true do
        local okRead, chunk, er = _pcall("readAllText/read", p, function() return f:read(self.readChunk) end)
        if not okRead then
            f:close(); return false, nil, er
        end
        if not chunk then break end
        buf = buf .. chunk
    end

    f:close()
    return true, buf, nil
end

--- Reads binary file completely as a string (bytes).
---@param rel string
---@return boolean, string|nil, string|nil
function FileIO:readAllBinary(rel)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)

    local okOpen, f, e = _safe_open(p, "rb")
    if not okOpen then return false, nil, e end

    local buf = ""
    while true do
        local okRead, chunk, er = _pcall("readAllBinary/read", p, function() return f:read(self.readChunk) end)
        if not okRead then
            f:close(); return false, nil, er
        end
        if not chunk then break end
        buf = buf .. chunk
    end

    f:close()
    return true, buf, nil
end

--- Writes text (overwrites file, creates parent folder if necessary).
---@param rel string
---@param text any
---@return boolean, nil|nil, string|nil
function FileIO:writeText(rel, text)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    _ensure_parent_dir(p)

    local okOpen, f, e = _safe_open(p, "w")
    if not okOpen then return false, nil, e end

    local okWrite, _, ew = _pcall("writeText/write", p, function() f:write(tostring(text or "")) end)
    f:close()
    if not okWrite then return false, nil, ew end

    log(1, "FileIO.writeText OK:", p)
    return true
end

--- Appends text (creates parent folders if necessary).
---@param rel string
---@param text any
---@return boolean, nil|nil, string|nil
function FileIO:appendText(rel, text)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    _ensure_parent_dir(p)

    local okOpen, f, e = _safe_open(p, "a")
    if not okOpen then return false, nil, e end

    local okWrite, _, ew = _pcall("appendText/write", p, function() f:write(tostring(text or "")) end)
    f:close()
    if not okWrite then return false, nil, ew end

    log(1, "FileIO.appendText OK:", p)
    return true
end

--- Writes binary data (string bytes), creates parent folders if necessary.
---@param rel string
---@param bytes string|nil
---@return boolean, nil|nil, string|nil
function FileIO:writeBinary(rel, bytes)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    _ensure_parent_dir(p)

    local okOpen, f, e = _safe_open(p, "wb")
    if not okOpen then return false, nil, e end

    local okWrite, _, ew = _pcall("writeBinary/write", p, function() f:write(bytes or "") end)
    f:close()
    if not okWrite then return false, nil, ew end

    log(1, ("FileIO.writeBinary OK: %s (%d bytes)"):format(p, bytes and #bytes or 0))
    return true
end

--- Writes a list of byte strings one at a time (e.g. chunkwise).
---@param rel string
---@param bytes string[]
---@return boolean, nil|nil, string|nil
function FileIO:writeBinaryArray(rel, bytes)
    local ok = self:ensureMounted(); if not ok then return false, nil, "not mounted" end
    local p = self:abs(rel)
    _ensure_parent_dir(p)

    local okOpen, f, e = _safe_open(p, "wb")
    if not okOpen then return false, nil, e end

    for i = 1, #bytes do
        local okWrite, _, ew = _pcall("writeBinaryArray/write", p, function() f:write(bytes[i] or "") end)
        if not okWrite then
            f:close(); return false, nil, ew
        end
    end

    f:close()
    log(1, ("FileIO.writeBinaryArray OK: %s (%d chunks)"):format(p, #bytes))
    return true
end

-- ==== Utilities ==============================================================

--- Copies file (binary).
---@param srcRel string
---@param dstRel string
---@return boolean, nil|nil, string|nil
function FileIO:copy(srcRel, dstRel)
    local okR, data, eR = self:readAllBinary(srcRel)
    if not okR then return false, nil, eR end
    local okW, _, eW = self:writeBinary(dstRel, data)
    if not okW then return false, nil, eW end
    log(1, "FileIO.copy OK:", self:abs(srcRel), "->", self:abs(dstRel))
    return true
end

--- Moves file (copy + delete).
---@param srcRel string
---@param dstRel string
---@return boolean, nil|nil, string|nil
function FileIO:move(srcRel, dstRel)
    local okC, _, eC = self:copy(srcRel, dstRel)
    if not okC then return false, nil, eC end
    local okD, _, eD = self:rm(srcRel)
    if not okD then return false, nil, eD end
    log(1, "FileIO.move OK:", self:abs(srcRel), "->", self:abs(dstRel))
    return true
end

--- Like readAllText, but error → nil + error message (convenient for call sites).
---@param rel string
---@return string|nil, string|nil
function FileIO:tryReadText(rel)
    local ok, res, err = self:readAllText(rel)
    if ok then return res, nil end
    return nil, err
end

--- Like readAllBinary, but error → nil + error message.
---@param rel string
---@return string|nil, string|nil
function FileIO:tryReadBinary(rel)
    local ok, res, err = self:readAllBinary(rel)
    if ok then return res, nil end
    return nil, err
end

return FileIO
