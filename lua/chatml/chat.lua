local M = {}
local data_path = vim.fn.stdpath("data"):gsub("/$", "")
local chat_dir = data_path .. "/chatml/chats"
local llm = require("chatml.llm")

M.picker = function()
  local is_fzf, fzf = pcall(require, "fzf-lua")
  if is_fzf then
    fzf.files({
      cwd = chat_dir,
      fd_opts = [[--color=never --hidden --type f --type l --exclude .git]],
      actions = {
        ["default"] = function(selected)
          if selected == nil or #selected == 0 then
            return
          end
          local filename = chat_dir .. "/" .. selected[1]
          M.open_chat(filename)
        end,
      },
    })
    return
  end

  local chats = vim.fn.glob(chat_dir .. "/*.md", false, true)
  vim.ui.select(chats, {
    prompt = "Select a chat file",
  }, function(choice)
    if choice == nil then
      return
    end
    M.open_chat(choice)
  end)
end

M.new_chat = function()
  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(chat_dir) == 0 then
    vim.fn.mkdir(chat_dir, "p")
  end

  -- Compose filename
  local filename = chat_dir .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".md"

  -- Compose the template for the new chat markdown file
  local template = table.concat({
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

  -- Write the template to the file
  vim.fn.writefile(vim.split(template, "\n"), filename)

  return M.open_chat(filename)
end

--- Opens a chat file in a new buffer and sets up a keymap to trigger chat completion.
---
--- @param filename string The path to the chat file to open.
--- @return nil
M.open_chat = function(filename)
  -- Check if the file exists
  if vim.fn.filereadable(filename) == 0 then
    error("File does not exist: " .. filename)
  end

  -- Open the file in a new buffer
  vim.cmd.edit(filename)

  -- Create a local keymap to trigger chat_completion
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>ll", "", {
    silent = true,
    noremap = true,
    callback = function()
      llm.chat_completion(buf)
    end,
  })
end

return M
