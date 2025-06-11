local M = {}
local data_path = vim.fn.stdpath("data"):gsub("/$", "")
local chat_dir = data_path .. "/chatml/chats"
local llm = require("chatml.llm")

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

  -- Create buffer-local keymap for chat completion
  vim.keymap.set("n", "<leader>ll", function()
    llm.chat_completion(buf)
  end, {
    buffer = buf,
    silent = true,
    desc = "Trigger chat completion",
  })
end

return M
