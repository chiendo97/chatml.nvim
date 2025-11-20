---@class ChatMLChat
local M = {}

local data_path = vim.fn.stdpath("data"):gsub("/$", "")
local chat_dir = data_path .. "/chatml/chats"
M.chat_dir = chat_dir

---@return nil
M.picker = function()
  local is_snacks, snacks = pcall(require, "snacks")
  if is_snacks then
    -- list files sorted by modification time using vim.system
    local dir_cmd = { "ls", "-t", chat_dir }
    -- We will run the vim.system asynchronously
    vim.system(dir_cmd, { text = true }, function(obj)
      if obj.code ~= 0 then
        error("Failed to list chat files: " .. (obj.stderr or "Unknown error"))
        return
      end

      -- Split output lines asynchronously
      local md_files = vim.split(obj.stdout, "\n")
      -- Remove empty entries
      md_files = vim.tbl_filter(function(file)
        return file ~= ""
      end, md_files)

      --- @type snacks.picker.finder.Item[]
      local items = {}
      for i, filename in ipairs(md_files) do
        --- @type snacks.picker.finder.Item
        local item = {
          idx = i,
          score = i,
          text = filename,
          file = chat_dir .. "/" .. filename,
        }
        table.insert(items, item)
      end

      vim.schedule(function()
        -- Open snacks picker with items
        snacks.picker.pick({
          items = items,
          prompt = "Select a chat file: ",
          confirm = function(picker, item)
            picker:close()
            M.open_chat(item.file)
          end,
        })
      end)
    end)
    return
  end

  -- Fallback to vim.ui.select
  local chats = vim.fn.glob(chat_dir .. "/*.md", false, true)
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

M.search = function()
  local is_snacks, snacks = pcall(require, "snacks")
  if not is_snacks then
    vim.notify("Snacks not found", vim.log.levels.WARN)
  end

  snacks.picker.grep({
    cwd = chat_dir,
    prompt = "Search ChatML Chats: ",
  })
end

--- Creates a new chat file with a template and opens it
--- @return nil
M.new_chat = function()
  local is_created = vim.fn.mkdir(chat_dir, "p")
  if is_created == 0 then
    error("Failed to create chat directory: " .. chat_dir)
  end

  local filename = chat_dir .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".md"
  local template = {
    "---",
    "model: openai/gpt-5-mini",
    "stream: true",
    "---",
    "",
    "# system",
    "",
    "You are an AI Assistant for software engineering tasks",
    "",
    "- **Security Constraint**: Refuse malicious code; allow security analysis, detection rules, vulnerability explanations, and defensive tools",
    "- **Direct Communication**: Answer questions directly without elaboration; one-word answers preferred when appropriate",
    "- **Code Conventions**: Understand file styles before changes; verify library availability; mimic existing patterns and frameworks",
    "- **Proactivity Balance**: Take action when asked, but answer questions first before jumping into actions; avoid surprising the user",
    "- **Response Format**: Return responses in markdown format for better readability and structure",
    "",
    "# user",
    "",
    "",
  }

  -- Write the template to the file
  local success = vim.fn.writefile(template, filename)

  if success ~= 0 then
    error("Failed to write chat file: " .. filename)
  end

  M.open_chat(filename)
end

--- Opens a chat file in a new buffer and sets up keymaps
--- @param filename string The path to the chat file to open
--- @return nil
M.open_chat = function(filename)
  -- Open the file in a new buffer
  vim.cmd.edit(filename)

  -- Set up buffer-local configuration
  local bufnr = vim.api.nvim_get_current_buf()

  -- Move cursor to the end of the buffer
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(0, { line_count, 0 })
end

--- Parse models response and extract model IDs
--- @param response_str string The JSON response from /models endpoint
--- @return table model_ids List of model IDs
local function parse_models_response(response_str)
  local ok, data = pcall(vim.json.decode, response_str)
  if not ok then
    vim.notify("Failed to parse models response", vim.log.levels.ERROR)
    return {}
  end

  if not data or not data.data then
    vim.notify("Invalid models response format", vim.log.levels.ERROR)
    return {}
  end

  local model_ids = {}
  for _, model in ipairs(data.data) do
    if model.id then
      table.insert(model_ids, model.id)
    end
  end

  return model_ids
end

--- Update the model in the current buffer
--- @param bufnr number Buffer number
--- @param new_model string The new model name
--- @return nil
local function update_buffer_model(bufnr, new_model)
  local parse = require("chatml.parse")

  -- Get current buffer content
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local md_str = table.concat(lines, "\n")

  -- Convert markdown to JSON
  local ok, json_str = pcall(parse.md_to_json, md_str)
  if not ok then
    vim.notify("Failed to parse current buffer: " .. json_str, vim.log.levels.ERROR)
    return
  end

  -- Parse JSON and update model
  local json_ok, data = pcall(vim.json.decode, json_str)
  if not json_ok then
    vim.notify("Failed to decode JSON", vim.log.levels.ERROR)
    return
  end

  -- Update model
  data.model = new_model

  -- Encode back to JSON
  local updated_json = vim.json.encode(data)

  -- Convert JSON back to markdown
  local md_ok, updated_md = pcall(parse.json_to_md, updated_json)
  if not md_ok then
    vim.notify("Failed to convert back to markdown: " .. updated_md, vim.log.levels.ERROR)
    return
  end

  -- Update buffer
  local updated_lines = vim.split(updated_md, "\n")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, updated_lines)

  vim.notify("Model switched to: " .. new_model, vim.log.levels.INFO)
end

--- Switch the model in the current buffer by presenting a picker
--- Fetches available models from the API and allows user to select one
--- @return nil
M.switch_model = function()
  local config = require("chatml.config")

  local base_url = config.options.base_url or config.defaults.base_url
  local api_key = config.options.api_key or config.defaults.api_key

  if not api_key or api_key == "" then
    vim.notify("API key not configured", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  if ft ~= "markdown" then
    vim.notify("This command only works in markdown buffers", vim.log.levels.WARN)
    return
  end

  vim.notify("Fetching available models...", vim.log.levels.INFO)

  local url = base_url .. "/models"

  vim.system({
    "curl",
    "--silent",
    "--show-error",
    "--header",
    "Authorization: Bearer " .. api_key,
    "--header",
    "Content-Type: application/json",
    url,
  }, { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.notify("Failed to fetch models: " .. (obj.stderr or "Unknown error"), vim.log.levels.ERROR)
      return
    end

    local models = parse_models_response(obj.stdout)

    if #models == 0 then
      vim.notify("No models available", vim.log.levels.WARN)
      return
    end

    vim.schedule(function()
      vim.ui.select(models, {
        prompt = "Select a model: ",
      }, function(choice)
        if choice then
          update_buffer_model(bufnr, choice)
        end
      end)
    end)
  end)
end

return M
