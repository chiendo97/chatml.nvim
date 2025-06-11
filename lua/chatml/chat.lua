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
  return table.concat({
    "---",
    "model: gpt-4.1-mini",
    "stream: true",
    "---",
    "",
    "# system",
    "",
    "You are a general AI assistant.\n\n"
      .. "The user provided the additional info about how they would like you to respond:\n\n"
      .. "- If you're unsure don't guess and say you don't know instead.\n"
      .. "- Ask question if you need clarification to provide better answer.\n"
      .. "- Think deeply and carefully from first principles step by step.\n"
      .. "- Zoom out first to see the big picture and then zoom in to details.\n"
      .. "- Use Socratic method to improve your thinking and coding skills.\n"
      .. "- Don't elide any code from your output if the answer requires coding.\n"
      .. "- Take a deep breath; You've got this!\n",
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
  if not filename or filename == "" then
    vim.notify("Invalid filename provided", vim.log.levels.ERROR)
    return
  end

  -- Check if the file exists
  if vim.fn.filereadable(filename) == 0 then
    vim.notify("File does not exist: " .. filename, vim.log.levels.ERROR)
    return
  end

  -- Open the file in a new buffer
  vim.cmd.edit(filename)

  -- Set up buffer-local configuration
  local buf = vim.api.nvim_get_current_buf()

  -- Store last buffer for quick access
  last_buf = buf

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

  -- Move cursor to the end of the buffer
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(last_buf), 0 })
end

local function get_visual_selection()
  local mode = vim.api.nvim_get_mode().mode

  local cline, ccol = unpack(vim.api.nvim_win_get_cursor(0))
  local vline, vcol = vim.fn.line("v"), vim.fn.col("v")

  local sline, scol
  local eline, ecol
  if cline == vline then
    if ccol <= vcol then
      sline, scol = cline, ccol
      eline, ecol = vline, vcol
      scol = scol + 1
    else
      sline, scol = vline, vcol
      eline, ecol = cline, ccol
      ecol = ecol + 1
    end
  elseif cline < vline then
    sline, scol = cline, ccol
    eline, ecol = vline, vcol
    scol = scol + 1
  else
    sline, scol = vline, vcol
    eline, ecol = cline, ccol
    ecol = ecol + 1
  end

  if mode == "V" or mode == "CTRL-V" or mode == "\22" then
    scol = 1
    ecol = nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, sline - 1, eline, 0)
  if #lines == 0 then
    return
  end

  local startText, endText
  if #lines == 1 then
    startText = string.sub(lines[1], scol, ecol)
  else
    startText = string.sub(lines[1], scol)
    endText = string.sub(lines[#lines], 1, ecol)
  end

  local selection = { startText }
  if #lines > 2 then
    vim.list_extend(selection, vim.list_slice(lines, 2, #lines - 1))
  end
  table.insert(selection, endText)

  -- get current file path
  local file_path = vim.fn.expand("%:p")

  -- get current file type
  local file_type = vim.bo.filetype

  return selection, file_path, file_type
end

-- Jump to window displaying the given buffer number
-- @param bufnr number: buffer number to find
local function jump_to_window_with_buffer(bufnr)
  -- Get list of all windows
  local windows = vim.api.nvim_list_wins()
  -- Iterate through windows to find one showing the target buffer
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      -- Set focus to this window
      vim.api.nvim_set_current_win(win)
      return true -- Found and jumped successfully
    end
  end
  return false -- No window found with the given buffer
end

M.paste_selection = function()
  -- Check if the last buffer is set
  if not last_buf or not vim.api.nvim_buf_is_valid(last_buf) then
    vim.notify("No valid chat buffer found", vim.log.levels.ERROR)
    return
  end

  local lines, file_path, file_type = get_visual_selection()
  if not lines or #lines == 0 then
    vim.notify("No text selected", vim.log.levels.INFO)
    return
  end
  if not file_path or not file_type then
    vim.notify("Failed to get file path or type", vim.log.levels.ERROR)
    return
  end

  -- build selection template with file info
  local paste_template = {
    string.format("I have a following selection from a file: `%s`", file_path),
    "",
    "````" .. file_type,
  }

  vim.list_extend(paste_template, lines)
  vim.list_extend(paste_template, { "````", "" })

  -- Append the selection to the chat file
  vim.api.nvim_buf_set_lines(last_buf, -1, -1, false, paste_template)

  -- Jump to the last buffer's window
  jump_to_window_with_buffer(last_buf)

  -- Move cursor to the end of the buffer
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(last_buf), 0 })
end

return M
