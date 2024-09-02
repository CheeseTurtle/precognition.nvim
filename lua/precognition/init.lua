local M = {}

---@class Precognition.HintOpts
---@field text string
---@field prio integer

---@alias Precognition.PlaceLoc integer
---
---@class (exact) Precognition.HintConfig
---@field w Precognition.HintOpts
---@field e Precognition.HintOpts
---@field b Precognition.HintOpts
---@field Zero Precognition.HintOpts
---@field MatchingPair Precognition.HintOpts
---@field Caret Precognition.HintOpts
---@field Dollar Precognition.HintOpts

---@class Precognition.GutterHintConfig
---@field G Precognition.HintOpts
---@field gg Precognition.HintOpts
---@field PrevParagraph Precognition.HintOpts
---@field NextParagraph Precognition.HintOpts

---@alias Precognition.HighlightCategory
---| "'gutter'"
---| "'virt_line'"

---@class Precognition.ExtmarkOpts
---@field hl_eol? boolean
---@field virt_text_pos? "'eol'" | "'overlay'" | "'right_align'" | "'inline'"
---@field virt_text_win_col? integer
---@field virt_text_hide? boolean # Note: Only affects 'overlay' virt text
---@field virt_text_repeat_linebreak? boolean
---@field virt_text_hl_mode? "'replace'" | "'combine'" | "'blend'"
---@field virt_lines? {[1]: string,[2]?: string}[]
---@field virt_lines_above? boolean
---@field virt_lines_leftcol? boolean
---@field strict? boolean # Defaults to true
---@field sign_text? string # Length must be 1 or 2
---@field hl_group? string # Overrides `group` option for highlight category spec!
---@field sign_hl_group? string
---@field number_hl_group? string
---@field line_hl_group? string
---@field cursorline_hl_group? string
---@field ui_watched? boolean
---@field url? boolean
---@field icon? string

---@class Precognition.HighlightSpec
---@field group? string|vim.api.keyset.highlight # Name of highlight group to apply, or spec
---@field extmark_opts? Precognition.ExtmarkOpts

---@alias Precognition.Highlight
---| vim.api.keyset.highlight
---| table<Precognition.HighlightCategory, Precognition.HighlightSpec>

---@class Precognition.Config
---@field startVisible boolean
---@field showBlankVirtLine boolean
---@field highlight Precognition.Highlight
---@field hints Precognition.HintConfig
---@field gutterHints Precognition.GutterHintConfig

---@class Precognition.PartialConfig
---@field startVisible? boolean
---@field showBlankVirtLine? boolean
---@field highlight? Precognition.Highlight
---@field hints? Precognition.HintConfig
---@field gutterHints? Precognition.GutterHintConfig

---@class (exact) Precognition.VirtLine
---@field w Precognition.PlaceLoc
---@field e Precognition.PlaceLoc
---@field b Precognition.PlaceLoc
---@field Zero Precognition.PlaceLoc
---@field Caret Precognition.PlaceLoc
---@field Dollar Precognition.PlaceLoc
---@field MatchingPair Precognition.PlaceLoc

---@class (exact) Precognition.GutterHints
---@field G Precognition.PlaceLoc
---@field gg Precognition.PlaceLoc
---@field PrevParagraph Precognition.PlaceLoc
---@field NextParagraph Precognition.PlaceLoc

---@class Precognition.ExtraPadding
---@field start integer
---@field length integer

---@type Precognition.HintConfig
local defaultHintConfig = {
  Caret = { text = "^", prio = 2 },
  Dollar = { text = "$", prio = 1 },
  MatchingPair = { text = "%", prio = 5 },
  Zero = { text = "0", prio = 1 },
  w = { text = "w", prio = 10 },
  b = { text = "b", prio = 9 },
  e = { text = "e", prio = 8 },
  W = { text = "W", prio = 7 },
  B = { text = "B", prio = 6 },
  E = { text = "E", prio = 5 },
}

---@type Precognition.Config
local default = {
  startVisible = true,
  showBlankVirtLine = true,
  highlight = { link = "Comment" },
  hints = defaultHintConfig,
  gutterHints = {
    G = { text = "G", prio = 10 },
    gg = { text = "gg", prio = 9 },
    PrevParagraph = { text = "{", prio = 8 },
    NextParagraph = { text = "}", prio = 8 },
  },
}

---@type Precognition.Config
local config = default

local autopeek = require "precognition.autopeek"
M.apk = autopeek

---@type integer?
local extmark -- the active extmark in the current buffer
---@type boolean
local dirty -- whether a redraw is needed
---@type boolean
local visible = false

---@type string
local gutter_name_prefix = "precognition_gutter_" -- prefix for gutter signs object naame
---@type {SupportedGutterHints: { line: integer, id: integer }} -- cache for gutter signs
local gutter_signs_cache = {} -- cache for gutter signs

---@type integer
local au = vim.api.nvim_create_augroup("precognition", { clear = true })
---@type integer
local ns = vim.api.nvim_create_namespace("precognition")
---@type string
local gutter_group = "precognition_gutter"

M.set_extmark_virt_line = vim.api.nvim_buf_set_extmark
M.sign_define_gutter = vim.fn.sign_define

local hi_default = default.highlight
hi_default.default = true
hi_default.force = false
vim.api.nvim_set_hl(0, "PrecognitionHighlight", hi_default)
for _, kind in ipairs({ "Gutter", "VirtLine" }) do
  local hl_name_base = "Precognition" .. kind
  vim.api.nvim_set_hl(0, hl_name_base, { default = true, force = false, link = "PrecognitionHighlight" })
  for _, subkind in ipairs({ "Sign", "Cursorline" }) do -- don't link 'Number'
    vim.api.nvim_set_hl(0, hl_name_base .. subkind, { default = true, force = false, link = hl_name_base })
  end
end

---@param marks Precognition.VirtLine
---@param line_len integer
---@param extra_padding Precognition.ExtraPadding
---@return {[1]: string, [2]: string}[]
local function build_virt_line(marks, line_len, extra_padding, exclude_hl)
  if not marks then return {} end
  if line_len == 0 then return {} end
  local virt_line = {}
  local line_table = require("precognition.utils").create_pad_array(line_len, " ")
  local hl_name = (not exclude_hl) and "PrecognitionHighlight"

  for mark, loc in pairs(marks) do
    local hint = config.hints[mark].text or mark
    local prio = config.hints[mark].prio or 0
    local col = loc

    if col ~= 0 and prio > 0 then
      local existing = line_table[col]
      if existing == " " and existing ~= hint then
        line_table[col] = hint
      else -- if the character is not a space, then we need to check the prio
        local existing_key
        for key, value in pairs(config.hints) do
          if value.text == existing then
            existing_key = key
            break
          end
        end
        if existing ~= " " and config.hints[mark].prio > config.hints[existing_key].prio then line_table[col] = hint end
      end
    end
  end

  if #extra_padding > 0 then
    for _, padding in ipairs(extra_padding) do
      line_table[padding.start] = line_table[padding.start] .. string.rep(" ", padding.length)
    end
  end

  local line = table.concat(line_table)
  if line:match("^%s+$") then return {} end
  table.insert(virt_line, { line, hl_name })
  return virt_line
end

---@return Precognition.GutterHints
local function build_gutter_hints()
  local vm = require("precognition.vertical_motions")
  ---@type Precognition.GutterHints
  local gutter_hints = {
    G = vm.file_end(),
    gg = vm.file_start(),
    PrevParagraph = vm.prev_paragraph_line(),
    NextParagraph = vm.next_paragraph_line(),
  }
  return gutter_hints
end

---@param gutter_hints Precognition.GutterHints
---@param bufnr? integer -- buffer number
---@return nil
local function apply_gutter_hints(gutter_hints, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if require("precognition.utils").is_blacklisted_buffer(bufnr) then return end

  local gutter_table = {}
  for hint, loc in pairs(gutter_hints) do
    if gutter_signs_cache[hint] then
      vim.fn.sign_unplace(gutter_group, { id = gutter_signs_cache[hint].id })
      gutter_signs_cache[hint] = nil
    end

    local prio = config.gutterHints[hint].prio

    -- Build table of valid and priorised gutter hints.
    if loc ~= 0 and loc ~= nil and prio > 0 then
      local existing = gutter_table[loc]
      if not existing or existing.prio < prio then gutter_table[loc] = { hint = hint, prio = prio } end
    end
  end

  -- Only render valid and prioritised gutter hints.
  for loc, data in pairs(gutter_table) do
    local hint = data.hint
    local sign_name = gutter_name_prefix .. hint
    M.sign_define_gutter(sign_name, {
      text = config.gutterHints[hint].text,
      texthl = "PrecognitionGutterSign",
    })
    local ok, res = pcall(vim.fn.sign_place, 0, gutter_group, sign_name, bufnr, {
      lnum = loc,
      priority = 100,
    })
    if ok then gutter_signs_cache[hint] = { line = loc, id = res } end
    if not ok and loc ~= 0 then
      vim.notify_once("Failed to place sign: " .. hint .. " at line " .. loc .. vim.inspect(res), vim.log.levels.WARN)
    end
  end
end

local function display_marks()
  local bufnr = vim.api.nvim_get_current_buf()
  if require("precognition.utils").is_blacklisted_buffer(bufnr) then return end
  local cursorline = vim.fn.line(".")
  local cursorcol = vim.fn.charcol(".")
  if extmark and not dirty then return end

  -- TODO: Handle 'vartabstop'?
  local tab_width = vim.bo.expandtab and vim.bo.shiftwidth or vim.bo.tabstop
  local cur_line = vim.api.nvim_get_current_line():gsub("\t", string.rep(" ", tab_width))

  local tf, line_len = pcall(vim.fn.strcharlen, cur_line)
  if not tf then -- Probably "Error executing vim.schedule lua callback: Vim:E976: Using a Blob as a String"
    cur_line = vim.fn.getline("."):gsub("\t", string.rep(" ", tab_width))
    cur_line = vim.fn.strtrans(cur_line)
    line_len = vim.fn.strcharlen(cur_line)
  end
  ---@type Precognition.ExtraPadding[]
  local extra_padding = {}
  -- local after_cursor = vim.fn.strcharpart(cur_line, cursorcol + 1)
  -- local before_cursor = vim.fn.strcharpart(cur_line, 0, cursorcol - 1)
  -- local before_cursor_rev = string.reverse(before_cursor)
  -- local under_cursor = vim.fn.strcharpart(cur_line, cursorcol - 1, 1)

  local hm = require("precognition.horizontal_motions")

  -- FIXME: Lua patterns don't play nice with utf-8, we need a better way to
  -- get char offsets for more complex motions.
  --
  ---@type Precognition.VirtLine
  local virtual_line_marks = {
    Caret = hm.line_start_non_whitespace(cur_line, cursorcol, line_len),
    w = hm.next_word_boundary(cur_line, cursorcol, line_len, false),
    e = hm.end_of_word(cur_line, cursorcol, line_len, false),
    b = hm.prev_word_boundary(cur_line, cursorcol, line_len, false),
    W = hm.next_word_boundary(cur_line, cursorcol, line_len, true),
    E = hm.end_of_word(cur_line, cursorcol, line_len, true),
    B = hm.prev_word_boundary(cur_line, cursorcol, line_len, true),
    MatchingPair = hm.matching_pair(cur_line, cursorcol, line_len)(cur_line, cursorcol, line_len),
    Dollar = hm.line_end(cur_line, cursorcol, line_len),
    Zero = 1,
  }

  --multicharacter padding

  require("precognition.utils").add_multibyte_padding(cur_line, extra_padding, line_len)

  local virt_line = build_virt_line(virtual_line_marks, line_len, extra_padding)

  -- TODO: can we add indent lines to the virt line to match indent-blankline or similar (if installed)?

  -- create (or overwrite) the extmark
  if config.showBlankVirtLine or (virt_line and #virt_line > 0) then
    extmark = vim.api.nvim_buf_set_extmark(0, ns, cursorline - 1, 0, {
      id = extmark, -- reuse the same extmark if it exists
      virt_lines = { virt_line },
    })
  end
  apply_gutter_hints(build_gutter_hints())

  dirty = false
end

local function show_func()
  dirty = true
  display_marks()
end

local function hide_func()
  visible = false
  if extmark then
    vim.api.nvim_buf_del_extmark(0, ns, extmark)
    extmark = nil
  end
  vim.fn.sign_unplace(gutter_group)
  gutter_signs_cache = {}
end

local function on_cursor_moved(ev)
  local buf = ev and ev.buf or vim.api.nvim_get_current_buf()
  if extmark then
    local ext = vim.api.nvim_buf_get_extmark_by_id(buf, ns, extmark, {
      details = true,
    })
    if ext and ext[1] ~= vim.api.nvim_win_get_cursor(0)[1] - 1 then
      vim.api.nvim_buf_del_extmark(0, ns, extmark)
      extmark = nil
    end
  end
  dirty = true
  if not autopeek.enabled then
    display_marks()
  else
    vim.fn.sign_unplace(gutter_group)
    gutter_signs_cache = {}
  end
end

local function on_insert_enter(ev)
  if extmark then
    vim.api.nvim_buf_del_extmark(ev.buf, ns, extmark)
    extmark = nil
  end
  dirty = true
end

local function on_buf_edit() apply_gutter_hints(build_gutter_hints()) end

local function on_buf_leave(ev)
  vim.api.nvim_buf_clear_namespace(ev.buf, ns, 0, -1)
  extmark = nil
  gutter_signs_cache = {}
  vim.fn.sign_unplace(gutter_group)
  dirty = true
  if autopeek.enabled then
    autopeek.dispatch_async(autopeek.dispatch_codes.timer_stop, ev.buf, autopeek.states.entering)
  elseif autopeek.initialized then
    autopeek.dispatch_async(autopeek.dispatch_codes.disable, ev.buf, false)
  end
end

-- ---@return boolean # success
-- local function autopeek_start(hide_first)
--   local timer = autopeek_start_timer()
--   if not timer then return false end
--   if hide_first and visible then M.hide() end
--   return true
-- end
--
-- ---@return boolean #success
-- local function autopeek_stop(show_afterwards, close_timer)
--   if close_timer then return autopeek_close_timer() and true or false end
--   return autopeek_stop_timer(show_afterwards) and true or false
-- end

function M.autopeek_enable(keep_initial_visibility)
  local tbl = {
    getvisible_func = function(bufnr) return (not bufnr or vim.api.nvim_get_current_buf() == bufnr) and visible end,
    show_func = function(bufnr)
      if not bufnr or vim.api.nvim_get_current_buf() == bufnr then show_func() end
    end,
    hide_func = function(bufnr)
      if not bufnr or vim.api.nvim_get_current_buf() == bufnr then hide_func() end
    end,
  }
  if autopeek.initialized then
    autopeek.dispatch_async(autopeek.dispatch_codes.enable, nil, keep_initial_visibility, tbl)
  else
    autopeek.init(true, tbl.getvisible_func, tbl.show_func, tbl.hide_func)
    autopeek.dispatch_async(autopeek.dispatch_codes.enable, nil, keep_initial_visibility, nil)
  end
end

function M.autopeek_disable(visible_afterwards)
  autopeek.dispatch_async(autopeek.dispatch_codes.disable, nil, visible_afterwards)
  if not visible_afterwards and visible then
    M.hide()
    local linenr = vim.fn.line('.')
    vim.api.nvim__redraw({range={linenr-1,linenr+1}})
  end
end

function M.autopeek_toggle(on, keep_initial_visibility)
  -- if on == nil then on = not autopeek_enabled end
  if on == nil and not autopeek.enabled or on then
    M.autopeek_enable(keep_initial_visibility)
  else
    M.autopeek_disable(true)
  end
end

---@param arg? "'on'" | "'off'" | "'toggle'"
function M.autopeek(arg)
  if arg == nil or arg == "toggle" then
    M.autopeek_toggle(not autopeek_enabled, true)
  elseif arg == "off" or not arg then
    M.autopeek_disable()
  else
    M.autopeek_enable(true)
  end
end

local function create_command()
  local subcommands = {
    peek = M.peek,
    toggle = M.toggle,
    show = M.show,
    hide = M.hide,
    autopeek = M.autopeek,
  }

  local function execute(args)
    local cmd_args = args.fargs
    local subcmd = cmd_args[1]
    if not subcmd then return end
    if subcommands[subcmd] then
      subcommands[subcmd](cmd_args[2])
    else
      vim.notify("Invalid subcommand: " .. subcmd, vim.log.levels.ERROR, {
        title = "Precognition",
      })
    end
  end

  ---@diagnostic disable-next-line:unused-local
  local function complete(arg_lead, line, pos)
    if string.find(line, "P[a-z]* autopeek ", 1, false) == 1 then
      return { "on", "off", "toggle" }
    else
      return vim.tbl_keys(subcommands)
    end
  end

  vim.api.nvim_create_user_command("Precognition", execute, {
    nargs = "*",
    complete = complete,
    bar = true,
  })
end

--- Show the hints until the next keypress or CursorMoved event
function M.peek()
  display_marks()

  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    group = au,
    callback = on_buf_leave,
  })
end

--- Enable automatic showing of hints
function M.show()
  if visible then return end
  visible = true

  -- clear the extmark entirely when leaving a buffer (hints should only show in current buffer)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = au,
    callback = on_buf_leave,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = au,
    callback = on_buf_edit,
  })
  -- clear the extmark when the cursor moves, or when insert mode is entered
  --
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = au,
    callback = on_cursor_moved,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = au,
    callback = on_insert_enter,
  })

  display_marks()
end

--- Disable automatic showing of hints
function M.hide()
  if not visible then return end
  visible = false
  if extmark then
    vim.api.nvim_buf_del_extmark(0, ns, extmark)
    extmark = nil
  end
  au = vim.api.nvim_create_augroup("precognition", { clear = true })
  vim.fn.sign_unplace(gutter_group)
  gutter_signs_cache = {}
end

--- Toggle automatic showing of hints
function M.toggle()
  if visible then
    M.hide()
  else
    M.show()
  end
end

local function process_hl_option(hl_name_prefix, spec)
  local function alter_spec(subtype)
    local key = subtype == "" and "hl_group" or (subtype .. "_hl_group")
    local value = spec[key]
    if not value then
      spec[key] = nil
      return
    end
    local hl_subname = "Precognition" .. hl_name_prefix
    if subtype and subtype ~= "" then hl_subname = hl_subname .. string.upper(subtype[1]) .. string.sub(subtype, 2) end

    local hl_spec = type(value) == "string" and { link = value } or value
    vim.api.nvim_set_hl(0, hl_subname, hl_spec)
    spec[key] = hl_subname
  end
  for _, subtype in ipairs({ "", "sign", "number", "line", "cursorline" }) do
    alter_spec(subtype)
  end
  return spec
end

---@param opts Precognition.PartialConfig
function M.setup(opts)
  config = vim.tbl_deep_extend("force", default, opts or {})

  ns = vim.api.nvim_create_namespace("precognition")
  au = vim.api.nvim_create_augroup("precognition", { clear = true })

  local hl_name = "PrecognitionHighlight"

  if opts.highlight then
    if type(opts.highlight) == "string" then
      config.highlight = { link = opts.highlight }
    elseif next(opts.highlight) then -- Assume table
      for _, pair in ipairs({ { "gutter", "Gutter" }, { "virt_line", "VirtLine" } }) do
        local k, prefix = pair[1], pair[2]
        if opts.highlight[k] == false then
          if k == "gutter" then
            M.sign_define_gutter = vim.fn.sign_define
          else
            M.set_extmark_virt_line = vim.api.nvim_buf_set_extmark
          end
        elseif type(opts.highlight[k]) == "string" then
          vim.api.nvim_set_hl(0, "Precognition" .. prefix, { link = opts.highlight[k] })
        elseif opts.highlight[k] then -- assume table
          opts.highlight[k].group = process_hl_option("prefix", opts.highlight[k].group)
          local extmark_opts = opts.highlight[k].extmark_opts
          if extmark_opts and next(extmark_opts) then
            if k == "gutter" then
              local sign_opts = {
                icon = extmark_opts.icon,
                linehl = extmark_opts.line_hl_group,
                numhl = extmark_opts.number_hl_group,
                texthl = extmark_opts.sign_hl_group,
                culhl = extmark_opts.cursorline_hl_group,
              }
              ---@diagnostic disable-next-line:duplicate-set-field
              M.sign_define_gutter = next(sign_opts)
                  and function(sign_name, dict)
                    dict = vim.tbl_extend("force", dict, sign_opts)
                    vim.fn.sign_define(sign_name, dict)
                  end
                or vim.fn.sign_define
            else -- k == 'virt_line'
              ---@diagnostic disable-next-line:duplicate-set-field
              M.set_extmark_virt_line = function(buf, ns_id, line, col, options)
                opts = vim.tbl_extend("keep", options, extmark_opts)
                return vim.api.nvim_buf_set_extmark(buf, ns_id, line, col, options)
              end
            end
          end
        else -- nil
          vim.api.nvim_set_hl(0, "Precognition" .. prefix, { link = hl_name })
        end
      end
    end
    config.highlight = default.highlight
  end

  vim.api.nvim_set_hl(0, "PrecognitionHighlight", config.highlight)

  create_command()

  if config.startVisible then M.show() end
end

-- This is for testing purposes, since we need to
-- access these variables from outside the module
-- but we don't want to expose them to the user
local state = {
  build_virt_line = function() return build_virt_line end,
  build_gutter_hints = function() return build_gutter_hints end,
  on_cursor_moved = function() return on_cursor_moved end,
  extmark = function() return extmark end,
  gutter_group = function() return gutter_group end,
  ns = function() return ns end,
}

setmetatable(M, {
  __index = function(_, k)
    if state[k] then return state[k]() end
  end,
})

return M
