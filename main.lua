--- @since 26.1.22
--- @sync entry

local DEFAULT_KIND = "@autosession"

local function _default_save_path()
	local appdata = os.getenv("APPDATA")
	if appdata and appdata ~= "" then
		-- Use forward slashes for portability.
		return appdata:gsub("\\", "/") .. "/yazi/state/autosession.lua"
	end
	local home = os.getenv("HOME")
	if home and home ~= "" then
		return home .. "/.local/state/yazi/autosession.lua"
	end
	-- Fallback: relative to current directory.
	return "autosession.lua"
end

local function _is_windows()
	local appdata = os.getenv("APPDATA")
	return appdata ~= nil and appdata ~= ""
end

local function _read_all(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	io.close(f)
	return s
end

local function _write_all(path, content)
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(content)
	io.close(f)
	return true
end

local function _is_array(t)
	if type(t) ~= "table" then
		return false
	end
	local n = #t
	for k, _ in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
			return false
		end
	end
	return true
end

local function _lua_quote(s)
	return string.format("%q", s)
end

local function _serialize_lua(v)
	local tv = type(v)
	if tv == "nil" then
		return "nil"
	elseif tv == "boolean" or tv == "number" then
		return tostring(v)
	elseif tv == "string" then
		return _lua_quote(v)
	elseif tv == "table" then
		if _is_array(v) then
			local parts = {}
			for i = 1, #v do
				parts[#parts + 1] = _serialize_lua(v[i])
			end
			return "{" .. table.concat(parts, ",") .. "}"
		else
			local parts = {}
			for k, val in pairs(v) do
				if type(k) ~= "string" then
					error("autosession: cannot serialize non-string key: " .. type(k))
				end
				parts[#parts + 1] = "[" .. _lua_quote(k) .. "]=" .. _serialize_lua(val)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	error("autosession: cannot serialize type: " .. tv)
end

local function _deserialize_lua(content)
	if type(content) ~= "string" or content == "" then
		return nil
	end
	-- Load as data-only chunk; sandbox with empty env.
	local loader, err = load(content, "=autosession", "t", {})
	if not loader then
		return nil, err
	end
	local ok, res = pcall(loader)
	if not ok then
		return nil, res
	end
	return res
end

local function _len(v)
	if v == nil then
		return 0
	end
	local ok, n = pcall(function()
		return #v
	end)
	if ok and type(n) == "number" then
		return n
	end
	return 0
end

local function _is_empty_launch()
	local args = rt and rt.args or nil
	if not args then
		return false
	end

	local entries_empty = _len(args.entries) == 0
	local has_cwd_file = args.cwd_file ~= nil
	local has_chooser_file = args.chooser_file ~= nil

	return entries_empty and (not has_cwd_file) and (not has_chooser_file)
end

local function _clamp_idx0(idx, n)
	local v = tonumber(idx)
	if not v then
		return 0
	end
	v = math.floor(v)
	if type(n) ~= "number" or n <= 0 then
		return math.max(0, v)
	end
	if v < 0 then
		return 0
	end
	if v > (n - 1) then
		return n - 1
	end
	return v
end

local function _notify(level, msg)
	ya.notify({
		title = "Autosession",
		content = msg,
		level = level,
		timeout = 3,
	})
end

local function _get_current_session()
	if not cx or not cx.tabs then
		return nil
	end

	local tabs = cx.tabs
	local tab_count = #tabs

	local session = {
		-- Persist the active tab idx as-is, and restore using the same idx value.
		active_idx = tonumber(tabs.idx) or 0,
		tabs = {},
	}

	for idx = 1, tab_count do
		local tab = tabs[idx]
		if tab then
			session.tabs[idx] = {
				-- Store as raw string; keep Windows paths intact.
				cwd = tostring(tab.current.cwd),
				sort = {
					by = tab.pref.sort_by,
					sensitive = tab.pref.sort_sensitive,
					reverse = tab.pref.sort_reverse,
					dir_first = tab.pref.sort_dir_first,
					translit = tab.pref.sort_translit,
				},
				linemode = tab.pref.linemode,
				show_hidden = tab.pref.show_hidden and "show" or "hide",
			}
		end
	end

	return session
end

local function _restore_session(state, overwrite)
	local session = state.session
	if not session or type(session) ~= "table" or type(session.tabs) ~= "table" or #session.tabs == 0 then
		return false
	end

	if overwrite then
		ya.emit("tab_switch", { 0 })
		-- NOTE: During `setup()` cx can be nil. Only close existing tabs when cx is available.
		if cx and cx.tabs then
			for i = #cx.tabs - 1, 1, -1 do
				ya.emit("tab_close", { i })
			end
		end
	end

	for idx, tab in ipairs(session.tabs) do
		local cwd = tab.cwd and Url(tab.cwd) or nil
		if cwd then
			if idx == 1 then
				ya.emit("cd", { cwd })
			else
				ya.emit("tab_create", { cwd })
			end
		end

		if tab.sort then
			ya.emit("sort", tab.sort)
		end
		if tab.linemode then
			ya.emit("linemode", { tab.linemode })
		end
		if tab.show_hidden then
			ya.emit("hidden", { tab.show_hidden })
		end
	end

	local active_idx = _clamp_idx0((tonumber(session.active_idx) or 0) - 1, #session.tabs)
	ya.emit("tab_switch", { active_idx })

	state.restored = true
	return true
end

local function _on_session_message(state, body, source)
	-- `source` is just for logging/diagnostics.
	ya.dbg("autosession: received", source, state.kind, body and "(non-nil)" or "(nil)")
	state.session = body
	if state.should_auto_restore and not state.restored and body then
		_restore_session(state, state.overwrite)
	end
end

local function _persist_session_lua(state, session)
	local ok, err = pcall(function()
		local payload = {
			version = 1,
			saved_at = os.time(),
			session = session,
		}
		local content = "return " .. _serialize_lua(payload) .. "\n"
		local saved = _write_all(state.lua_save_path, content)
		if not saved then
			error("failed to write file: " .. tostring(state.lua_save_path))
		end
	end)
	if not ok then
		ya.err("autosession: lua persist failed", err)
		_notify("error", "Save failed (cannot write state file)")
		return false
	end
	return true
end

local function _load_session_lua(state)
	local content = _read_all(state.lua_save_path)
	if not content then
		return nil
	end
	local parsed, err = _deserialize_lua(content)
	if not parsed then
		ya.err("autosession: lua load failed", err)
		return nil
	end
	if type(parsed) == "table" and type(parsed.session) == "table" then
		return parsed.session
	end
	return nil
end

local function _persist_session(state, session)
	if state.save_method == "lua" then
		return _persist_session_lua(state, session)
	end

	-- DDS static message: a kind starting with '@' is persisted and restored on next start.
	-- IMPORTANT: restoration is delivered to the *local* instance, so we must use ps.sub/ps.pub.
	-- Wrap in pcall so failures show up in logs/notifications instead of silently breaking save.
	local ok, err = pcall(function()
		ps.pub(state.kind, session)
		-- Optional: also broadcast to other instances (cross-instance sync) if enabled.
		if state.broadcast then
			ps.pub_to(0, state.kind, session)
		end
	end)
	if not ok then
		ya.err("autosession: ps.pub failed", state.kind, err)
		_notify("error", "Save failed (see yazi.log)")
		return false
	end

	ya.dbg("autosession: persisted", state.kind, { tabs = session and session.tabs and #session.tabs or 0, active = session and session.active_idx })
	return true
end

local function _clear_session(state)
	if state.save_method == "lua" then
		pcall(function()
			_write_all(state.lua_save_path, "return nil\n")
		end)
		return
	end

	pcall(function()
		ps.pub(state.kind, nil)
		if state.broadcast then
			ps.pub_to(0, state.kind, nil)
		end
	end)
end

local function _save_session(state)
	local session = _get_current_session()
	if not session then
		ya.err("autosession: cannot capture session (cx is not available)")
		return false
	end
	local ok = _persist_session(state, session)
	if not ok then
		return false
	end
	state.session = session
	return true
end

local function _save_and_quit(state)
	local ok = _save_session(state)
	if ok == false then
		return
	end
	if state.save_method == "lua" then
		-- File IO is synchronous; no need to delay.
		ya.emit("quit", {})
		return
	end

	-- Give DDS a moment to flush the static message before quitting.
	-- Quitting immediately can race with persistence on some platforms.
	ya.async(function()
		ya.sleep(0.05)
		ya.emit("quit", {})
	end)
end

return {
	setup = function(state, opts)
		opts = opts or {}
		state.kind = opts.kind or DEFAULT_KIND
		state.auto_restore = opts.auto_restore == true
		state.overwrite = opts.overwrite ~= false
		state.broadcast = opts.broadcast == true
		state.save_on_quit = opts.save_on_quit ~= false
		state.lua_save_path = opts.lua_save_path or _default_save_path()
		state.save_method = opts.save_method
			or (opts.save and opts.save.method)
			or (_is_windows() and "lua" or "yazi")
		state.restored = false
		state.should_auto_restore = state.auto_restore and _is_empty_launch()

		-- Lua persistence (Windows-friendly): read once on startup.
		if state.save_method == "lua" then
			state.session = _load_session_lua(state)
			if state.should_auto_restore and not state.restored and state.session then
				_restore_session(state, state.overwrite)
			end
		end

		if state.save_on_quit then
			ps.sub("key-quit", function(_)
				-- Save before quit, even when user exits via other commands.
				_save_session(state)
				ya.emit("quit", {})
				return true
			end)
		end

		if state.save_method ~= "lua" then
			-- Local subscription is required for persisted (static) message restoration on new start.
			ps.sub(state.kind, function(body)
				_on_session_message(state, body, "local")
			end)
			-- Keep remote subscription as well (useful if broadcast=true or other instances publish).
			ps.sub_remote(state.kind, function(body)
				_on_session_message(state, body, "remote")
			end)
		end
	end,

	entry = function(state, job)
		state.kind = state.kind or DEFAULT_KIND
		state.overwrite = state.overwrite ~= false

		local action = job.args[1]
		if action == "save-and-quit" then
			_save_and_quit(state)
		elseif action == "save" then
			local ok = _save_session(state)
			if ok then
				_notify("info", "Session saved")
			end
		elseif action == "restore" then
			local ok = _restore_session(state, true)
			if not ok then
				_notify("warn", "No saved session")
			end
		elseif action == "clear" then
			_clear_session(state)
			state.session = nil
			state.restored = false
			_notify("info", "Saved session cleared")
		end
	end,
}
