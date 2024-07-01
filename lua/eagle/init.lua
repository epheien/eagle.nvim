local config = require("eagle.config")

local M = {}

-- keep track of eagle window id and eagle buffer id
local eagle_win = nil
local eagle_buf = nil

--[[lock variable to prevent multiple windows from opening
this happens when the mouse moves faster than the time it takes
for a window to be created, especially during vim.lsp.buf_request_sync()
that contains vim.wait()]]
local win_lock = 0

--- call vim.fn.wincol() once in the beginning
local index_lock = 0

--- store the value of the starting column of actual code (skip line number columns, icons etc)
local code_index

-- tables that hold the diagnostics and lsp info
local diagnostic_messages = {}
local lsp_info = {}

-- needed to block the creation of eagle_win when the mouse moves before the render delay timer is done
local last_mouse_pos

--load and sort all the diagnostics of the current buffer
local sorted_diagnostics

-- a bool variable to detect if the mouse is moving, binded with the <MouseMove> event
local isMouseMoving = false

-- store the line of the last mouse position, needed to detect scrolling
local last_mouse_line = -1

-- Initialize last_pos as a global variable
local last_pos = nil

-- a bool variable to make sure process_mouse_pos() is only called once, when the mouse goes idle
local lock_processing = false

local renderDelayTimer = vim.loop.new_timer()

function M.create_eagle_win()
  -- return if the mouse has moved exactly before the eagle window was to be created
  -- this can happen when the value of config.options.render_delay is very low
  local mouse_pos = vim.fn.getmousepos()
  if not vim.deep_equal(mouse_pos, last_mouse_pos) then
    win_lock = 0
    return
  end

  local messages = {}

  if #diagnostic_messages > 0 then
    table.insert(messages, "# Diagnostics")
    table.insert(messages, "")
  end

  for i, diagnostic_message in ipairs(diagnostic_messages) do
    local message_parts = vim.split(diagnostic_message.message, "\n", { trimempty = false })
    for _, part in ipairs(message_parts) do
      if #diagnostic_messages > 1 then
        table.insert(messages, i .. ". " .. part)
      else
        table.insert(messages, part)
      end
    end

    local severity = diagnostic_message.severity

    if severity == 1 then
      severity = "Error"
    elseif severity == 2 then
      severity = "Warning"
    elseif severity == 3 then
      severity = "Info"
    elseif severity == 4 then
      severity = "Hint"
    end

    table.insert(messages, "severity: " .. severity)
    table.insert(messages, "source: " .. diagnostic_message.source)

    -- some diagnostics may not fill the code field
    if diagnostic_message.code then
      table.insert(messages, "code: " .. diagnostic_message.code)
    end

    -- some diagnostics may not fill the hypertext reference field
    local href = diagnostic_message.user_data and
        diagnostic_message.user_data.lsp and diagnostic_message.user_data.lsp.codeDescription and
        diagnostic_message.user_data.lsp.codeDescription.href

    if href then
      table.insert(messages, "href: " .. diagnostic_message.user_data.lsp.codeDescription.href)
    end

    -- newline
    if i < #diagnostic_messages then
      table.insert(messages, "")
    end
  end

  if config.options.show_lsp_info and #lsp_info > 0 then
    if #diagnostic_messages > 0 then
      table.insert(messages, "---")
    end
    table.insert(messages, "# LSP Info")
    table.insert(messages, "")
    for _, md_line in ipairs(lsp_info) do
      table.insert(messages, md_line)
    end
  end

  -- create a buffer with buflisted = false and scratch = true
  if eagle_buf then
    vim.api.nvim_buf_delete(eagle_buf, {})
  end
  eagle_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(eagle_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(eagle_buf, "readonly", false)

  -- this "stylizes" the markdown messages (diagnostics + lsp info)
  -- and attaches them to the eagle_buf
  vim.lsp.util.stylize_markdown(eagle_buf, messages, {})

  -- format long lines of the buffer
  M.format_lines(math.floor(vim.o.columns / config.options.max_width_factor))

  vim.api.nvim_buf_set_option(eagle_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(eagle_buf, "readonly", true)

  -- Iterate over each line in the buffer to find the max width
  local lines = vim.api.nvim_buf_get_lines(eagle_buf, 0, -1, false)
  local max_line_width = 0
  for _, line in ipairs(lines) do
    local line_width = vim.fn.strdisplaywidth(line)
    max_line_width = math.max(max_line_width, line_width)
  end

  -- Calculate the window height based on the number of lines in the buffer
  local height = math.min(vim.api.nvim_buf_line_count(eagle_buf),
    math.floor(vim.o.lines / config.options.max_height_factor))

  -- need + 1 for hyperlinks (shift + click)
  local width = math.max(max_line_width + config.options.scrollbar_offset + 1,
    vim.fn.strdisplaywidth(config.options.title))

  local row_pos
  if mouse_pos.screenrow > math.floor(vim.o.lines / 2) then
    row_pos = mouse_pos.screenrow - height - 3
  else
    row_pos = mouse_pos.screenrow
  end

  eagle_win = vim.api.nvim_open_win(eagle_buf, false, {
    title = { { config.options.title, config.options.title_group } },
    title_pos = config.options.title_pos,
    relative = 'editor',
    row = row_pos - config.options.window_row,
    col = mouse_pos.screencol - config.options.window_col,
    width = width,
    height = height,
    style = "minimal",
    border = config.options.border,
    focusable = true,
  })
  vim.fn.setwinvar(eagle_win, '&winhighlight',
    vim.fn.printf('Normal:%s,FloatBorder:%s', config.options.normal_group, config.options.border_group))
end

-- format the lines of eagle_buf, in order to fit vim.o.columns / config.options.max_width_factor
-- for the case where an href link is splitted, I'm open to discussions on how to handle it
function M.format_lines(max_width)
  if not eagle_buf then
    -- Don't call format_lines if eagle_buf has not been created and filled with contents
    return
  end

  -- Iterate over the lines in the buffer
  local i = 0
  while i < vim.api.nvim_buf_line_count(eagle_buf) do
    -- Get the current line
    local line = vim.api.nvim_buf_get_lines(eagle_buf, i, i + 1, false)[1]

    -- If the line is too long
    if vim.fn.strdisplaywidth(line) > max_width then
      -- Check if the line is a markdown separator (contains only "─")
      if string.match(line, "^[─]+$") then
        -- If it's a markdown separator, truncate the line at max_width
        -- Notice we multiply max_width by 3, because this character takes up three bytes
        line = string.sub(line, 1, max_width * 3)
      else
        -- Find the last space character within the maximum line width
        local space_index = max_width
        while space_index > 0 and string.sub(line, space_index, space_index) ~= " " do
          space_index = space_index - 1
        end

        -- If no space character was found within max_width, just split at max_width
        if space_index == 0 then
          space_index = max_width
        end

        -- Split the line into two parts: the part that fits, and the remainder
        local part1 = string.sub(line, 1, space_index)
        local part2 = string.sub(line, space_index + 1)

        -- Replace the current line with the part that fits
        line = part1

        -- Insert the remainder as a new line after the current line
        vim.api.nvim_buf_set_lines(eagle_buf, i + 1, i + 1, false, { part2 })
      end
    end

    -- Replace the current line with the modified version
    vim.api.nvim_buf_set_lines(eagle_buf, i, i + 1, false, { line })

    -- Move to the next line
    i = i + 1
  end
end

function M.check_lsp_support()
  -- get the filetype of the current buffer
  local filetype = vim.bo.filetype

  -- get all active clients
  local clients = vim.lsp.get_active_clients()

  -- filter the clients based on the filetype of the current buffer
  local relevant_clients = {}
  for _, client in ipairs(clients) do
    if client.config.filetypes and vim.tbl_contains(client.config.filetypes, filetype) then
      table.insert(relevant_clients, client)
    end
  end

  -- check if any of the relevant clients support textDocument/hover
  for _, client in ipairs(relevant_clients) do
    if client.supports_method("textDocument/hover") then
      if config.options.debug_mode then
        print("Found LSP client supporting textDocument/hover: " .. client.name)
      end
      return true
    end
  end

  return false
end

function M.load_lsp_info(callback)
  --Ideally we need this binded with Event(s)
  --As of right now, WinEnter is a partial solution,
  --but it's not enough (for buffers etc).
  --BufEnter doesn't seem to work properly
  if not M.check_lsp_support() then
    return
  end

  lsp_info = {}

  local mouse_pos = vim.fn.getmousepos()
  local line = mouse_pos.line - 1
  local col = mouse_pos.column - 1

  local position_params = vim.lsp.util.make_position_params()

  position_params.position.line = line
  position_params.position.character = col

  local bufnr = vim.api.nvim_get_current_buf()

  -- asynchronous, so we need to use a callback function
  -- buf_request_sync contains vim.wait which is unwanted
  vim.lsp.buf_request_all(bufnr, "textDocument/hover", position_params, function(results)
    for _, result in pairs(results) do
      if result.result and result.result.contents then
        lsp_info = vim.lsp.util.convert_input_to_markdown_lines(result.result.contents)
        lsp_info = vim.lsp.util.trim_empty_lines(lsp_info)
      end
    end

    -- Call the callback function after lsp_info has been populated
    callback()
  end)
end

function M.sort_buf_diagnostics()
  sorted_diagnostics = vim.diagnostic.get(0, { bufnr = '%' })

  table.sort(sorted_diagnostics, function(a, b)
    return a.lnum < b.lnum
  end)
end

function M.load_diagnostics()
  local mouse_pos = vim.fn.getmousepos()
  local diagnostics
  local prev_diagnostics = diagnostic_messages
  diagnostic_messages = {}

  local pos_info = vim.inspect_pos(vim.api.nvim_get_current_buf(), mouse_pos.line - 1, mouse_pos.column - 1)
  for _, extmark in ipairs(pos_info.extmarks) do
    local extmark_str = vim.inspect(extmark)
    if string.find(extmark_str, "Diagnostic") then
      diagnostics = vim.diagnostic.get(0, { lnum = mouse_pos.line - 1 })

      --binary search on the sorted sorted_diagnostics table
      --needed for nested underlines (poor API)
      if #diagnostics == 0 then
        local outer_line
        if sorted_diagnostics then
          local low, high = 1, #sorted_diagnostics
          while low <= high do
            local mid = math.floor((low + high) / 2)
            local diagnostic = sorted_diagnostics[mid]
            if diagnostic.lnum < mouse_pos.line - 1 then
              outer_line = diagnostic.lnum
              low = mid + 1
            else
              high = mid - 1
            end
          end
        end
        diagnostics = vim.diagnostic.get(0, { lnum = outer_line })
      end
    end
  end

  if diagnostics and #diagnostics > 0 then
    for _, diagnostic in ipairs(diagnostics) do
      local isMouseWithinVerticalBounds, isMouseWithinHorizontalBounds

      -- check if the mouse is within the vertical bounds of the diagnostic (single-line or otherwise)
      isMouseWithinVerticalBounds = (diagnostic.lnum <= mouse_pos.line - 1) and
          (mouse_pos.line - 1 <= diagnostic.end_lnum)

      if isMouseWithinVerticalBounds then
        if diagnostic.lnum == diagnostic.end_lnum then
          -- if its a single-line diagnostic

          -- check if the mouse is within the horizontal bounds of the diagnostic
          isMouseWithinHorizontalBounds = (diagnostic.col <= mouse_pos.column - 1) and
              (mouse_pos.column <= diagnostic.end_col)
        else
          -- if its a multi-line diagnostic (nested)

          -- suppose we are always within the horizontal bounds of the diagnostic
          -- other checks (EOL, whitespace etc) were handled in process_mouse_pos (already optimized)
          isMouseWithinHorizontalBounds = true
        end
      end

      if isMouseWithinVerticalBounds and isMouseWithinHorizontalBounds then
        table.insert(diagnostic_messages, diagnostic)
      end
    end
  end

  if not vim.deep_equal(diagnostic_messages, prev_diagnostics) then
    return false
  end

  return true
end

local function render()
  renderDelayTimer:stop()

  last_mouse_pos = vim.fn.getmousepos()
  renderDelayTimer:start(config.options.render_delay, 0, vim.schedule_wrap(function()
    -- if the window is open, we need to check if there are new diagnostics on the same line
    -- this is done with the highest priority, once the mouse goes idle
    if M.load_diagnostics() then
      if win_lock == 0 then
        win_lock = 1
      else
        return
      end
    else
      if eagle_win and vim.api.nvim_win_is_valid(eagle_win) then
        vim.api.nvim_win_close(eagle_win, false)
        win_lock = 0

        -- restart the timer with half of config.options.render_delay,
        -- invoking M.create_eagle_win() and returning immediately
        renderDelayTimer:stop()
        renderDelayTimer:start(math.floor(config.options.render_delay / 2), 0, vim.schedule_wrap(M.create_eagle_win))
        return
      end
    end

    if config.options.show_lsp_info then
      -- Pass a function to M.load_lsp_info() that calls M.create_eagle_win()
      M.load_lsp_info(function()
        if #diagnostic_messages == 0 and #lsp_info == 0 then
          return
        end
        M.create_eagle_win()
      end)
    else
      -- If show_lsp_info is false, call M.create_eagle_win() directly
      if #diagnostic_messages == 0 then
        return
      end
      M.create_eagle_win()
    end
  end))
end

function M.is_mouse_on_code()
  local mouse_pos = vim.fn.getmousepos()

  -- Get the line content at the specified line number (mouse_pos.line)
  local line_content = vim.fn.getline(mouse_pos.line)

  -- this is probably a "hacky" way, but it should work reliably
  if index_lock == 0 then
    code_index = vim.fn.wincol()
    index_lock = 1
  end

  -- Check if the character under the mouse cursor is not:
  -- a) Whitespace
  -- b) After the last character of the current line
  -- c) Before the first character of the current line
  if ((mouse_pos.column ~= vim.fn.strdisplaywidth(line_content) + 1) and (line_content:sub(mouse_pos.column, mouse_pos.column):match("%S") ~= nil) and mouse_pos.screencol >= code_index) then
    last_pos = vim.fn.getmousepos()
    return true
  end
  return false
end

function M.process_mouse_pos()
  -- return if not in normal mode or if the mouse is not hovering over actual code
  if vim.fn.mode() ~= 'n' or not M.is_mouse_on_code() then
    renderDelayTimer:stop()
    if eagle_win and vim.api.nvim_win_is_valid(eagle_win) and vim.api.nvim_get_current_win() ~= eagle_win then
      M.manage_windows()
    end
    return
  end

  if eagle_win and vim.api.nvim_win_is_valid(eagle_win) then
    M.manage_windows()
  end

  if vim.api.nvim_get_current_win() ~= eagle_win then
    render()
  end
end

function M.manage_windows()
  -- if the eagle window is not open, return and make sure it can be re-rendered
  -- this is done with win_lock, to prevent the case where the user presses :q for the eagle window
  if not eagle_win or not vim.api.nvim_win_is_valid(eagle_win) then
    win_lock = 0
    return
  end

  local win_height = vim.api.nvim_win_get_height(eagle_win)
  local win_width = vim.api.nvim_win_get_width(eagle_win)
  local win_pad = vim.api.nvim_win_get_position(eagle_win)
  local mouse_pos = vim.fn.getmousepos()

  --[[
      referenced corner
      (0,0)
       ~###########################################
       #       ^                                  #
       #       |                                  #
       #   win_pad[1]                             #
       #       |       <- win_width ->            #
       #       v       ***************     ^      #
       #               *             *     |      #
       #               *             * win_height #
       #               *             *     |      #
       #               ***************     v      #
       #<- win_pad[2] ->                          #
       ############################################
  --]]

  -- west side shouldn't be completely accurate, we need an extra column for better user experience
  -- for this reason we include win_pad[2]
  local isMouseWithinWestSide = (mouse_pos.screencol >= win_pad[2])

  -- east will always have an extra column
  -- keep in mind that win_width already includes config.options.scrollbar_offset
  local isMouseWithinEastSide = (mouse_pos.screencol <= (win_pad[2] + win_width + 2))

  local isMouseWithinNorthSide = (mouse_pos.screenrow >= win_pad[1] + 1)
  local isMouseWithinSouthSide = (mouse_pos.screenrow <= (win_pad[1] + win_height + 2))

  -- if the mouse pointer is inside the eagle window and it's not already in focus, set it as the focused window
  if isMouseWithinWestSide and isMouseWithinEastSide and isMouseWithinNorthSide and isMouseWithinSouthSide then
    if config.options.focus_eagle_window_by_mouse then
      if vim.api.nvim_get_current_win() ~= eagle_win then
        vim.api.nvim_set_current_win(eagle_win)
        vim.api.nvim_win_set_cursor(eagle_win, { 1, 0 })
      end
    end
  else
    if eagle_win and vim.api.nvim_win_is_valid(eagle_win) and vim.fn.mode() == "n" then
      -- close the window if the mouse is over or comes from a special character
      if not M.check_char(mouse_pos) and vim.api.nvim_get_current_win() ~= eagle_win then -- and (last_mouse_line ~= mouse_pos.line) then
        return
      end
    end
    vim.api.nvim_win_close(eagle_win, false)
    win_lock = 0
  end
end

function M.check_char(mouse_pos)
  if last_pos and last_pos.line ~= mouse_pos.line then
    last_pos = mouse_pos
    return true
  end
  -- Get the content of the current line using Vim's getline function
  local mouse_line_content = vim.fn.getline(mouse_pos.line)
  local last_line_content = last_pos and vim.fn.getline(last_pos.line)

  -- Extract the characters under last_pos and mouse_pos
  local mouse_char = mouse_line_content:sub(mouse_pos.column, mouse_pos.column)
  local last_char = last_pos and last_line_content and last_line_content:sub(last_pos.column, last_pos.column)

  -- If the characters are the same, return false
  if mouse_char == last_char then
    last_pos = mouse_pos
    return false
  end

  local function is_special_char(pos)
    local specialCharacters = ":<>{}%[%]()|+-%=`~?.,"

    -- Get the content of the current line using Vim's getline function
    local line_content = vim.fn.getline(pos.line)

    -- Check if the column is within the bounds of the line
    if pos.column <= #line_content then
      local char = line_content:sub(pos.column, pos.column)

      -- Check if the character is a special character or whitespace
      if string.find(specialCharacters, char, 1, true) or char:match("%s") then
        return true
      end
    end

    return false
  end

  -- Check if the current or last position was a special character
  local isCurrentSpecial = is_special_char(mouse_pos)
  local isLastSpecial = last_pos and is_special_char(last_pos)

  -- Always update last_pos
  last_pos = mouse_pos

  -- Return true if either the current or last position was a special character
  return isCurrentSpecial or isLastSpecial
end

-- Function that detects if the user scrolled with the mouse wheel, based on vim.fn.getmousepos().line
function M.handle_scroll()
  local mousePos = vim.fn.getmousepos()

  if mousePos.line ~= last_mouse_line then
    last_mouse_line = mousePos.line
    M.manage_windows()
  end
end

local append_keymap = require("eagle.keymap")

append_keymap("n", "<MouseMove>", function(preceding)
  preceding()

  if config.options.debug_mode then
    print("eagle.nvim: MouseMove detected at " .. os.clock())
  end

  vim.schedule(function()
    M.manage_windows()
    isMouseMoving = true
  end)
end, { silent = true, expr = true })

-- in the future, I may need to bind this to CmdlineEnter and/or CmdWinEnter, instead of setting a keymap
append_keymap({ "n", "v" }, ":", function(preceding)
  preceding()

  if eagle_win and vim.api.nvim_win_is_valid(eagle_win) and vim.api.nvim_get_current_win() == eagle_win and config.options.close_on_cmd then
    vim.api.nvim_win_close(eagle_win, false)
    win_lock = 0
  end
end, { silent = true })

-- detect changes in Neovim modes (close the eagle window when leaving normal mode)
vim.api.nvim_create_autocmd("ModeChanged", {
  callback = function()
    -- when entering normal mode, dont call process_mouse_pos(),
    -- because we should let the user move the mouse again to "unlock" the plugin.
    -- If we do otherwise, then when the user is focusing on typing something, the eagle window will keep popping up
    -- whenever he enters normal mode (assuming the mouse is on code with diagnostics and/or lsp info).
    if vim.fn.mode() ~= "n" then
      M.process_mouse_pos()
    end
  end
})

vim.api.nvim_create_autocmd("CursorMoved", {
  callback = function()
    if eagle_win and vim.api.nvim_win_is_valid(eagle_win) and vim.api.nvim_get_current_win() ~= eagle_win then
      vim.api.nvim_win_close(eagle_win, false)
      win_lock = 0
    end
  end
})

-- when the diagnostics of the file change, sort them
vim.api.nvim_create_autocmd("DiagnosticChanged", { callback = M.sort_buf_diagnostics })

function M.setup(opts)
  -- Call the config setup functon to initialize the options
  config.setup(opts)

  if config.options.debug_mode then
    print("eagle.nvim is running")
  end

  -- handle the cases where the user overrides the default values to something unreasonable

  if config.options.render_delay < 0 then
    config.options.render_delay = 500
  end

  if config.options.detect_idle_timer < 0 then
    config.options.detect_idle_timer = 50
  end

  if config.options.max_width_factor < 1.1 or config.options.max_width_factor > 5.0 then
    config.options.max_width_factor = 2
  end

  if config.options.max_height_factor < 2.5 or config.options.max_height_factor > 5.0 then
    config.options.max_height_factor = 2.5
  end

  -- start the timer that handles the whole plugin
  vim.loop.new_timer():start(0, config.options.detect_idle_timer, vim.schedule_wrap(function()
    if config.options.debug_mode then
      print("eagle.nvim: Timer restarted at " .. os.clock())
    end

    -- check if the view is scrolled, when the mouse is idle and the eagle window is not focused
    if not isMouseMoving and vim.api.nvim_get_current_win() ~= eagle_win then
      M.handle_scroll()
    end

    if isMouseMoving then
      isMouseMoving = false
      lock_processing = false
    else
      if not lock_processing then
        M.process_mouse_pos()
        lock_processing = true
      end
    end
  end))
end

return M
