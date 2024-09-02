local M = {}

--- Timer that triggers autopeeking and delayed enabling of autopeeking
---@type uv.uv_timer_t
-- local M.autopeek_timer

---@type uv.uv_async_t
-- local M.autopeek_dispatcher

M.dispatch_codes = {
  disable = 7,
  enable = 6,
  timer_start = 5,
  trigger_unidle = 4,
  timer_create_start = 3,
  setup_trigger = 2,
  timer_stop = 1,
  timer_stop_dispose = 0,
}

M.states = {
  disabled = 0,
  entering = 1,
  triggering = 2,
}

---@class integer
local autopeek_timeoutlen = 1000

---@class integer
local autopeek_enter_delay = 500

-- ---@class integer
-- local autopeek_scroll_delay = 500

---@type fun(): boolean
local get_visible

---@type function
local show_func

---@type function
local hide_func

---@type function
M.timer_callback_function = nil

local dispatcher_actions = {}

local function dispatcher_callback_function(action_code, bufnr, state)
  local callback = dispatcher_actions[action_code]
  if not callback then
    print("Invalid action code: ", action_code)
    return
  end
  vim.schedule(function() callback(bufnr, state) end)
end

---@param h uv.uv_handle_t?
---@return boolean is_handle
---@return string? handle_type_str
---@return integer? handle_type_int
local function is_handle(h)
  if h and type(h) == "userdata" then
    local tf, msg, int = xpcall(
      vim.uv.handle_get_type,
      function(msg) return not string.match(msg, "^bad argument #1") and msg end,
      h
    )
    if tf or not msg then
      return tf, msg, int
    else
      error(msg)
    end
  else
    return false
  end
end

local function timer_ensure_exists(nocreate)
  -- print("TIMER ENSURE EXISTS", nocreate)
  local tf, htype = is_handle(M.autopeek_timer)
  if tf then
    local tf2, is_closing = pcall(M.autopeek_timer.is_closing, M.autopeek_timer)
    if htype == "timer" then
      if tf2 and not is_closing then return true end
    else
      vim.cmd.echoerr("'Autopeek timer is a non-timer handle!'")
      return false
    end
  end
  if nocreate then return false end
  local new_timer, err, err_name = vim.uv.new_timer()
  if new_timer then
    M.autopeek_timer = new_timer
    -- print("new timer!", new_timer)
    return true
  end
  -- print("failed to create new timer: ", err_name, err)
  vim.notify(
    "Encountered error (" .. (err_name or "<unnamed>") .. ") when creating autopeek timer: " .. tostring(err),
    vim.log.levels.ERROR
  )
  return false
end

local function timer_ensure_stopped(create_if_nonexistent, state)
  if state then M.state = state end
  if timer_ensure_exists(not create_if_nonexistent) then
    local chk, err, err_name = M.autopeek_timer:is_active()
    if err then
      print("Error checking timer active status (" .. (err_name or "<no err_name>") .. "): ", err)
    elseif chk then -- timer is active
      ---@diagnostic disable-next-line:redefined-local
      local success, err, err_name = M.autopeek_timer:stop()
      if success then
        return true
      elseif err then
        print("Error stopping autopeek timer (" .. (err_name or "<no err_name>") .. "): ", err)
      end
    end
  elseif not create_if_nonexistent then
    return true
  end
  return false
end
local function timer_ensure_running(restart, state, force_state, interval, skip_exists_check)
  if
    force_state
    or M.state == M.states.disabled
    or (M.state ~= M.states.entering and M.state ~= M.states.triggering)
  then
    M.state = state
  end

  if skip_exists_check or timer_ensure_exists(false) then
    local tf, chk, err, err_name = pcall(M.autopeek_timer.is_active, M.autopeek_timer)
    if tf then
      if chk then
        if restart then
          ---@diagnostic disable-next-line:redefined-local
          local success, err, err_name = M.autopeek_timer:stop()
          if not success then
            print("Stopping timer before restart failed due to error (" .. (err_name or "<no err_name>") .. "): ", err)
            return false
          end
        else
          return true
        end
      elseif err then
        vim.cmd.echoerr(
          "'Checking autopeek timer active status raised an exception (" .. (err_name or "<no err_name>") .. "): '",
          vim.fn.string(err)
        )
        return false
      end
    else
      vim.cmd.echoerr("'Checking autopeek timer active status raised an exception: '", vim.fn.string(chk))
      return false
    end
    interval = interval or (M.state == M.states.entering and autopeek_enter_delay) or autopeek_timeoutlen
    if type(M.timer_callback_function) ~= "function" then error("Timer callback function is not a function") end
    ---@diagnostic disable-next-line:redefined-local
    local success, err, err_name =
      pcall(M.autopeek_timer.start, M.autopeek_timer, interval, 0, M.timer_callback_function)
    if success then return true end
    vim.notify(
      "Encountered error (" .. (err_name or "<unnamed>") .. ") when starting autopeek timer: " .. tostring(err),
      vim.log.levels.ERROR
    )
  end
  return false
end

-- On AUTOPEEK ENABLE (or enable with autopeek enabled):
-- > Set up and start dispatcher
-- > Set up and start timer (triggering, not entering)
-- > Set up on_key callback for mouse scrolling (optional?)

-- ON LEAVING BUFFER:
-- > Remove precognition from buffer
-- > Stop timer
-- > Switch timer to entering mode (but don't start it)

-- ON ENTERING (non-blacklisted) buffer:
-- > (Re)start entering timer
--
-- ON ENTERING blacklisted buffer: Stop entering timer
--
-- TRIGGERING TIMER causes showing of precognition in buffer (if still current) -- check buffer ID
--
-- Restart TRIGGERING TIMER on InsertLeave,CursorHold,CursorMoved,WinScrolled?
-- Also restart when on_key picks up a scroll event --> triggers cooldown?
-- > Remove on_key callback, reinstate after a delay that is reset whenever more scrolling?

function M.dispatch_async(...)
  -- print("Dispatching: ", ...)
  local tf, success, err, err_name = pcall(M.autopeek_dispatcher.send, M.autopeek_dispatcher, ...)
  if tf then
    if success then return true end
    print("Dispatch error (" .. (err_name or "<no err_name>") .. "): ", err)
  else
    print("Dispatch error: ", success)
  end
  return false
end

local function unsetup_buffer(bufnr)
  -- print("Unsetting up buffer: ", bufnr, M.target_buf)
  vim.cmd("silent! au! precognition_autopeek * <buffer=" .. M.target_buf .. ">")
  if M.target_buf == bufnr then M.target_buf = nil end
end

local function setup_buffer_delayed_autopeek_setup(bufnr)
  -- print("Setting up delayed autopeek for buffer: ", bufnr, M.target_buf)
  M.target_buf = bufnr
  -- local aupk = vim.api.nvim_create_augroup("precognition_autopeek", { clear = false })
  M.dispatch_async(M.dispatch_codes.timer_start, bufnr, M.states.entering)
end

local function setup_buffer_autopeek(bufnr)
  -- print("Setting up buffer: ", bufnr, M.target_buf)
  if type(bufnr) ~= number or not vim.api.nvim_buf_is_valid(bufnr) then
    M.target_buf = nil
    return false
  end

  M.target_buf = bufnr
  local aupk = vim.api.nvim_create_augroup("precognition_autopeek", { clear = false })
  -- Turn off autopeek timer, deactivate on_key callback
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    buffer = bufnr,
    once = false,
    group = aupk,
    callback = function(_) M.dispatch_async(M.dispatch_codes.timer_stop, bufnr, M.states.triggering) end,
  })

  -- Hide Precognition
  -- Restart autopeek timer (triggering)
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "InsertLeave" }, {
    buffer = bufnr,
    once = false,
    group = aupk,
    callback = function(_) M.dispatch_async(M.dispatch_codes.trigger_unidle, bufnr, M.states.triggering) end,
  })

  -- Stop autopeek timer, set to entering mode; set left buffer ID
  -- Remove autocmds from buffer
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = bufnr,
    once = false, -- Remove on entering a different buf than this one
    group = aupk,
    callback = function(_)
      M.dispatch_async(M.dispatch_codes.timer_stop, bufnr, M.states.entering)
      -- aupk = vim.api.nvim_create_augroup("precognition_autopeek", { clear = true })
      -- vim.cmd("au! precognition_autopeek * <buffer=" .. tbl.abuf .. ">")
    end,
  })
  -- -- Restart autopeek timer (triggering), activate on_key callback
  -- vim.api.nvim_create_autocmd(
  --   { "InsertLeave" },
  --   { buffer = bufnr, once = false, group = aupk, callback = function(tbl) autopeek_dispatch_async(-1, tbl) end }
  -- )
  timer_ensure_running(true, M.states.triggering, false)
end

-- local function on_key_callback(keys, _typed)
--   if keys[1] ==
--
-- end

-- local function autopeek_timer_stop() autopeek_timer:stop() end
--
-- local function autopeek_timer_start(new_state)
--   if new_state then M.state = new_state end
--   if not M.state or M.state == M.autopeek_states.disabled then return end
--   local interval
--   if M.state == M.autopeek_states.entering then
--     interval = autopeek_enter_delay
--   else -- triggering or idle
--     interval = autopeek_timeoutlen
--   end
--   autopeek_timer:start(interval, 0, M.timer_callback_function)
-- end

local function unsetup_autopeek()
  -- print("Unsetup autopeek")
  vim.cmd("silent! au! precognition_autopeek")
  timer_ensure_stopped(false, M.states.disabled)
  if M.target_buf then
    unsetup_buffer(M.target_buf)
    M.target_buf = nil
  end
end

-- Set up autopeek timer and dispatcher
-- Create autocmds
-- Create on_key callback and activate
local function setup_autopeek() -- bufnr)
  -- print("Setting up autopeek")
  -- if not autopeek_enabled then return end
  -- if bufnr then
  --   if vim.api.nvim_get_current_buf() ~= bufnr then return end
  -- else
  --   bufnr = vim.api.nvim_get_current_buf()
  -- end

  timer_ensure_exists(false)
  -- Start entering timer OR create autocmds for buffer
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
    group = vim.api.nvim_create_augroup("precognition_autopeek", { clear = true }),
    ---@param tbl {id:integer, event:string, group?:integer, match:string, buf:integer, file:string, data?:any}
    callback = function(tbl)
      -- if tbl.buf == M.target_buf then
      --   if M.enabled and not get_visible() then timer_ensure_running(false, M.states.triggering, false) end
      --   return
      -- else
      if M.target_buf then
        if tbl.buf ~= M.target_buf then
          vim.cmd("silent! au! precognition_autopeek * <buffer=" .. M.target_buf .. ">")
          M.target_buf = tbl.buf
        end
      else
        M.target_buf = tbl.buf
      end
      if require "precognition.utils".is_blacklisted_buffer(M.target_buf) then return end
      M.target_buf = nil
      vim.cmd("silent! au! precognition_autopeek * <buffer=" .. tbl.buf .. ">")
      if autopeek_enter_delay and autopeek_enter_delay > 0 then
        setup_buffer_delayed_autopeek_setup(tbl.buf)
      else
        setup_buffer_autopeek(tbl.buf)
      end
    end,
  })
end

dispatcher_actions = {
  [M.dispatch_codes.setup_trigger] = function(bufnr, state)
    -- print("SETUP TRIGGER", bufnr, state)
    if M.initialized then
      M.state = state or M.states.triggering
      setup_buffer_autopeek(bufnr)
    end
  end,
  [M.dispatch_codes.timer_start] = function(_, state)
    -- print("TIMER START", state)
    if M.initialized then
      timer_ensure_running(true, state, true, nil, false)
    else
      timer_ensure_stopped(false)
    end
  end,
  [M.dispatch_codes.timer_stop] = function(_, state)
    -- print("TIMER STOP", state)
    timer_ensure_stopped(true, state)
  end,
  [M.dispatch_codes.timer_stop_dispose] = function(_, state, callback)
    if timer_ensure_stopped(false, state) then
      if timer_ensure_exists(true) then
        if not M.autopeek_timer:is_closing() then M.autopeek_timer:close(callback) end
      elseif callback then
        callback()
      end
      -- autopeek_timer:unref()
    end
  end,
  [M.dispatch_codes.timer_create_start] = function(_, state, callback)
    if M.initialized then
      if timer_ensure_running(true, state, true, nil, false) and callback then callback() end
    else
      timer_ensure_stopped(false)
    end
  end,
  [M.dispatch_codes.trigger_unidle] = function(bufnr, state)
    -- print("TRIGGER UNIDLE", bufnr, state)
    if --[[bufnr == vim.api.nvim_get_current_buf() and]]
      M.enabled
    then
      if get_visible() and hide_func then hide_func(bufnr) end
      if state then M.state = state end
      if M.initialized and bufnr == M.target_buf then
        timer_ensure_running(true, M.states.triggering, true, nil, true)
      end
    else
      pcall(timer_ensure_stopped, false, nil)
      local tf, msg = pcall(unsetup_buffer, bufnr)
      if get_visible() and hide_func then hide_func(bufnr) end
      if not tf then error(msg) end
    end
  end,
  [M.dispatch_codes.enable] = function(_, keep_initial_visibility, tbl)
    -- print("ENABLE", keep_initial_visibility)
    if M.enabled or not M.initialized then return end
    if tbl then
      M.init(true, tbl.getvisible_func, tbl.show_func, tbl.hide_func)
    else
      M.enabled = true
    end
  end,
  [M.dispatch_codes.disable] = function(bufnr, visible_afterwards)
    -- print("DISABLE", bufnr, visible_afterwards)
    if bufnr and bufnr ~= M.target_buf then unsetup_buffer(bufnr) end
    -- unsetup_buffer(M.target_buf)
    -- M.target_buf = nil
    unsetup_autopeek()
    timer_ensure_stopped(false, M.states.disabled)
    if timer_ensure_stopped(false, M.states.disabled) then
      M.enabled = false
      if get_visible and visible_afterwards ~= nil then
        if visible_afterwards and not get_visible() then
          show_func()
        elseif get_visible() then
          hide_func()
        end
      end
    end
  end,
}

local default_init_callback = function()
  -- print("Default init callback")
  if not M.initialized then return end
  setup_autopeek()
  M.enabled = true
  bufnr = vim.api.nvim_get_current_buf()
  if require "precognition.utils".is_blacklisted_buffer(bufnr) then return end
  if get_visible and hide_func and get_visible() and not keep_initial_visibility then hide_func() end
  setup_buffer_autopeek(bufnr)
end

local function finish_init(callback)
  local dispatcher, err, err_name = vim.uv.new_async(dispatcher_callback_function)
  if err then
    vim.notify(
      "Error (" .. (err_name or "<no err_name>") .. ") when creating autopeek dispatcher: " .. tostring(err),
      vim.log.levels.ERROR
    )
    return
  elseif dispatcher then
    M.autopeek_dispatcher = dispatcher
    M.initialized = true
    if callback then callback() end
  else
    error("Nil error and nil dispatcher!")
  end
end

function M.init(init_dispatcher, getvisible_func, show_func_, hide_func_, callback)
  get_visible = getvisible_func or get_visible
  show_func = show_func_ or show_func
  hide_func = hide_func_ or hide_func

  local full_init = get_visible and show_func and hide_func
  if not full_init then error("Partial init!") end
  if init_dispatcher then
    M.initialized = false
    local tf = is_handle(M.autopeek_dispatcher)
    if tf then
      if not M.autopeek_dispatcher:is_closing() then
        M.autopeek_dispatcher:close(full_init and function() finish_init(callback or default_init_callback) end)
      end
    elseif full_init then
      finish_init(callback or default_init_callback)
    end
  end
  return full_init
end

M.timer_callback_function = function(_) -- called with own id
  -- print(
  --   "TIMER CALLBACK",
  --   -- tostring(vim.api.nvim_get_current_buf()),
  --   tostring(M.target_buf),
  --   tostring(get_visible and get_visible())
  -- )
  -- if vim.api.nvim_get_current_buf() ~= M.target_buf then
  --   if M.target_buf then vim.cmd("silent! au! precognition_autopeek * <buffer=" .. M.target_buf .. ">") end
  --   return
  if M.state == M.states.triggering then
    if get_visible and get_visible() then
      return
    else
      -- show_func(bufnr)
      vim.schedule(show_func)
    end
  elseif M.state ~= M.states.disabled then -- M.state == M.states.entering then
    M.dispatch_async(M.dispatch_codes.setup_trigger, M.target_buf, M.states.triggering)
  else
    return
  end
end

return M
