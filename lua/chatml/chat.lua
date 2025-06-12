local M = {}
local data_path = vim.fn.stdpath("data"):gsub("/$", "")
local chat_dir = data_path .. "/chatml/chats"
local llm = require("chatml.llm")
local last_buf = nil

-- Helper function to ensure chat directory exists
local function ensure_chat_dir()
  if vim.fn.isdirectory(chat_dir) == 0 then
    local success = vim.fn.mkdir(chat_dir, "p")
    if success == 0 then
      error("Failed to create chat directory: " .. chat_dir)
    end
  end
end

-- Helper function to generate chat filename
local function generate_chat_filename()
  return chat_dir .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".md"
end

-- Helper function to create chat template
local function create_chat_template()
  local system_prompt = "You are a general AI assistant.\n\n"
    .. "The user provided the additional info about how they would like you to respond:\n\n"
    .. "- If you're unsure don't guess and say you don't know instead.\n"
    .. "- Ask question if you need clarification to provide better answer.\n"
    .. "- Think deeply and carefully from first principles step by step.\n"
    .. "- Zoom out first to see the big picture and then zoom in to details.\n"
    .. "- Use Socratic method to improve your thinking and coding skills.\n"
    .. "- Don't elide any code from your output if the answer requires coding.\n"
    .. "- Take a deep breath; You've got this!\n"
    .. "- Always use `----` instead of `---`!\n"

  return table.concat({
    "---",
    "model: gpt-4.1-mini",
    "stream: true",
    "---",
    "",
    "# system",
    "",
    system_prompt,
    "",
    "---",
    "",
    "# user",
    "",
  }, "\n")
end

-- Helper function to handle file selection for vim.ui.select
local function handle_file_selection(chats)
  if not chats or #chats == 0 then
    vim.notify("No chat files found", vim.log.levels.INFO)
    return
  end

  -- Format filenames for display (show basename only)
  local display_names = {}
  for i, chat in ipairs(chats) do
    display_names[i] = vim.fn.fnamemodify(chat, ":t")
  end

  vim.ui.select(display_names, {
    prompt = "Select a chat file:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx then
      M.open_chat(chats[idx])
    end
  end)
end

--- Helper function to validate file path
--- @param filename string
--- @return boolean, string|nil
local function validate_file_path(filename)
  if not filename or filename == "" then
    return false, "Invalid filename provided"
  end

  if vim.fn.filereadable(filename) == 0 then
    return false, "File does not exist: " .. filename
  end

  return true, nil
end

-- Helper function to move cursor to end of buffer
local function move_cursor_to_end(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(0, { line_count, 0 })
end

-- Helper function to setup buffer keymaps
local function setup_buffer_keymaps(buf)
  -- Create buffer-local keymap for chat completion
  vim.keymap.set("n", "<leader>ll", function()
    llm.chat_completion(buf)
  end, {
    buffer = buf,
    silent = true,
    desc = "Trigger chat completion",
  })

  -- Create global keymap for pasting selection
  vim.keymap.set("x", "<leader>lp", function()
    M.paste_selection()
  end, {
    silent = true,
    desc = "Paste selection into chat",
  })
end

M.picker = function()
  local is_fzf, fzf = pcall(require, "fzf-lua")
  if is_fzf then
    fzf.files({
      cwd = chat_dir,
      fd_opts = [[--color=never --hidden --type f --type l --exclude .git --extension md]],
      prompt = "Chat Files> ",
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end
          local filename = chat_dir .. "/" .. selected[1]
          M.open_chat(filename)
        end,
      },
    })
    return
  end

  -- Fallback to vim.ui.select
  local chats = vim.fn.glob(chat_dir .. "/*.md", false, true)
  handle_file_selection(chats)
end

--- Creates a new chat file with a template and opens it
--- @return nil
M.new_chat = function()
  local ok, err = pcall(function()
    ensure_chat_dir()

    local filename = generate_chat_filename()
    local template = create_chat_template()

    -- Write the template to the file
    local lines = vim.split(template, "\n")
    local success = vim.fn.writefile(lines, filename)

    if success ~= 0 then
      error("Failed to write chat file: " .. filename)
    end

    M.open_chat(filename)
  end)

  if not ok then
    vim.notify("Error creating new chat: " .. (err or "Unknown error"), vim.log.levels.ERROR)
  end
end

--- Opens a chat file in a new buffer and sets up keymaps
--- @param filename string The path to the chat file to open
--- @return nil
M.open_chat = function(filename)
  -- Validate input
  local is_valid, error_msg = validate_file_path(filename)
  if not is_valid and error_msg then
    vim.notify(error_msg, vim.log.levels.ERROR)
    return
  end

  -- Open the file in a new buffer
  vim.cmd.edit(filename)

  -- Set up buffer-local configuration
  local buf = vim.api.nvim_get_current_buf()

  -- Store last buffer for quick access
  last_buf = buf

  -- Setup keymaps
  setup_buffer_keymaps(buf)

  -- Move cursor to the end of the buffer
  move_cursor_to_end(buf)
end

-- Get visual selection with proper bounds checking
local function get_visual_selection()
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("[vV\22]") then
    return nil, nil, nil
  end

  local current_pos = vim.api.nvim_win_get_cursor(0)
  local cline, ccol = current_pos[1], current_pos[2]
  local vline, vcol = vim.fn.line("v"), vim.fn.col("v")

  local sline, scol, eline, ecol

  if cline == vline then
    if ccol <= vcol then
      sline, scol = cline, ccol + 1
      eline, ecol = vline, vcol
    else
      sline, scol = vline, vcol
      eline, ecol = cline, ccol + 1
    end
  elseif cline < vline then
    sline, scol = cline, ccol + 1
    eline, ecol = vline, vcol
  else
    sline, scol = vline, vcol
    eline, ecol = cline, ccol + 1
  end

  -- Handle line-wise and block-wise selection
  if mode == "V" or mode == "CTRL-V" or mode == "\22" then
    scol = 1
    ecol = nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, sline - 1, eline, false)
  if #lines == 0 then
    return nil, nil, nil
  end

  -- Process selection based on number of lines
  local selection = {}
  if #lines == 1 then
    table.insert(selection, string.sub(lines[1], scol, ecol))
  else
    table.insert(selection, string.sub(lines[1], scol))
    for i = 2, #lines - 1 do
      table.insert(selection, lines[i])
    end
    if #lines > 1 then
      table.insert(selection, string.sub(lines[#lines], 1, ecol))
    end
  end

  -- Get file metadata
  local file_path = vim.fn.expand("%:p")
  local file_type = vim.bo.filetype

  return selection, file_path, file_type
end

-- Jump to window displaying the given buffer number
-- @param bufnr number: buffer number to find
-- @return boolean: success status
local function jump_to_window_with_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

-- Helper function to create paste template
local function create_paste_template(lines, file_path, file_type)
  local template = {
    string.format("I have a following selection from a file: `%s`", file_path),
    "",
    "````" .. (file_type or ""),
  }

  vim.list_extend(template, lines)
  table.insert(template, "````")
  table.insert(template, "")

  return template
end

M.paste_selection = function()
  -- Validate last buffer
  if not last_buf or not vim.api.nvim_buf_is_valid(last_buf) then
    vim.notify("No valid chat buffer found", vim.log.levels.ERROR)
    return
  end

  -- Get visual selection
  local lines, file_path, file_type = get_visual_selection()
  if not lines or #lines == 0 then
    vim.notify("No text selected", vim.log.levels.INFO)
    return
  end

  if not file_path then
    vim.notify("Failed to get file path", vim.log.levels.ERROR)
    return
  end

  -- Create and append paste template
  local paste_template = create_paste_template(lines, file_path, file_type)
  vim.api.nvim_buf_set_lines(last_buf, -1, -1, false, paste_template)

  -- Jump to chat buffer and position cursor
  if jump_to_window_with_buffer(last_buf) then
    move_cursor_to_end(last_buf)
  else
    vim.notify("Could not find window with chat buffer", vim.log.levels.WARN)
  end
end

return M
