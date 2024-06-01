local M = {}

---@enum cc
M.char_classes = {
    whitespace = 0,
    punctuation = 1,
    word = 2,
    emoji = 3,
    other = "other",
    UNKNOWN = -1,
}

---@param char string
---@param big_word boolean
---@return cc
function M.char_class(char, big_word)
    assert(type(big_word) == "boolean", "big_word must be a boolean")
    local cc = M.char_classes

    if char == "" then
        return cc.UNKNOWN
    end

    if char == "\0" then
        return cc.whitespace
    end

    local c_class = vim.fn.charclass(char)

    if big_word and c_class ~= 0 then
        return cc.punctuation
    end

    return c_class
end

---@param bufnr? integer
---@return boolean
function M.is_blacklisted_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
        return true
    end
    return false
end

---@param len integer
---@param str string
---@return string[]
function M.create_pad_array(len, str)
    local pad_array = {}
    for i = 1, len do
        pad_array[i] = str
    end
    return pad_array
end

---Add extra padding for multi byte character characters
---@param cur_line string
---@param extra_padding Precognition.ExtraPadding[]
---@param line_len integer
function M.add_multibyte_padding(cur_line, extra_padding, line_len)
    for i = 1, line_len do
        local char = vim.fn.strcharpart(cur_line, i - 1, 1)
        local width = vim.fn.strdisplaywidth(char)
        if width > 1 then
            table.insert(extra_padding, { start = i, length = width - 1 })
        end
    end
end

---Debounces calls to a function, and ensures it only runs once per delay
---even if called repeatedly.
---@param fn fun(...: any)
---@param delay integer
function M.debounce_trailing(fn, delay)
    local running = false
    local timer = assert(vim.uv.new_timer())

    -- Ugly hack to ensure timer is closed when the function is garbage collected
    -- unfortunate but necessary to avoid creating a new timer for each call.
    --
    -- In LuaJIT, only userdata can have finalizers. `newproxy` creates an opaque userdata
    -- which we can attach a finalizer to and use as a "canary."
    local proxy = newproxy(true)
    getmetatable(proxy).__gc = function()
        if not timer:is_closing() then
            timer:close()
        end
    end

    return function(...)
        local _ = proxy
        if running then
            return
        end
        running = true
        local args = { ... }
        timer:start(
            delay,
            0,
            vim.schedule_wrap(function()
                fn(unpack(args))
                running = false
            end)
        )
    end
end

return M
