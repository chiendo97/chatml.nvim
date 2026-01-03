local yaml = require("chatml.yaml")

---@class ChatMLParse
local M = {}

---Valid ChatML message roles
---@type table<string, boolean>
local VALID_ROLES = {
  assistant = true,
  developer = true,
  system = true,
  tool = true,
  user = true,
}

---Helper function to trim whitespace from a string
---@param s string
---@return string
local function trim(s)
  return s:match("^%s*(.-)%s*$") or s
end

---Read file content and return it, or error message on failure
---@param file_path string
---@return string content
local function read_file_content(file_path)
  file_path = trim(file_path)

  if vim.fn.filereadable(file_path) == 0 then
    return ""
  end

  local file = io.open(file_path, "r")
  if not file then
    vim.notify("Error reading file: " .. file_path .. " - Cannot open file", vim.log.levels.WARN)
    return "Error: Cannot open file: " .. file_path
  end

  local content = file:read("*all")
  file:close()

  if not content then
    vim.notify("Error reading file: " .. file_path .. " - Cannot read content", vim.log.levels.WARN)
    return "Error: Cannot read file content: " .. file_path
  end

  return content
end

---Convert JSON string of chat completion request to markdown
---@param json_str string JSON string of chat completion request
---@return string markdown Markdown string of chat completion request
M.json_to_md = function(json_str)
  -- Parse JSON string
  local ok, data = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
  if not ok then
    error("Invalid JSON string")
  end
  if data == nil then
    error("Parsed (json) data is nil")
  end

  -- Validate messages key exists
  if not data.messages then
    error("Messages key not found in JSON")
  end

  -- Validate model key exists
  if not data.model then
    error("Model key not found in JSON")
  end

  -- Validate each message: check type, role, and content
  for _, msg in ipairs(data.messages) do
    if type(msg) ~= "table" or not msg.role then
      error("Each message must be a table with a 'role' key")
    end

    if not VALID_ROLES[msg.role] then
      error("Invalid role: " .. tostring(msg.role))
    end

    if msg.content == nil then
      error("Each message must have 'content'")
    end
  end

  -- Extract metadata (all keys except messages and functions)
  local metadata = {}
  for key, value in pairs(data) do
    if key ~= "messages" and key ~= "functions" then
      metadata[key] = value
    end
  end
  -- Trim leading/trailing whitespace from YAML metadata
  local metadata_str = yaml.encode(metadata):gsub("^%s+", ""):gsub("%s+$", "")

  -- Build markdown output
  local parts = { "---\n" .. metadata_str .. "\n---\n" }

  for _, msg in ipairs(data.messages) do
    local msg_parts = { "\n# " .. msg.role .. "\n" }

    -- Add tool_calls if present (## tool_call: func (id=...) ```json...)
    if msg.tool_calls and #msg.tool_calls > 0 then
      for _, tool_call in ipairs(msg.tool_calls) do
        table.insert(msg_parts, "\n## tool_call: " .. tool_call["function"].name .. " (id=" .. tool_call.id .. ")\n\n")
        table.insert(msg_parts, "```json\n" .. tool_call["function"].arguments .. "\n```\n")
      end
    end

    -- Add tool_call_id for tool role messages (## tool: name (id=...) ````json...)
    if msg.role == "tool" and msg.tool_call_id then
      table.insert(msg_parts, "\n## tool: " .. (msg.name or "response") .. " (id=" .. msg.tool_call_id .. ")\n\n")
      table.insert(msg_parts, "````json\n" .. msg.content .. "\n````\n")
    elseif msg.content then
      -- Add content for regular messages
      table.insert(msg_parts, "\n" .. msg.content .. "\n")
    end

    table.insert(parts, table.concat(msg_parts))
  end

  -- Trim trailing whitespace from entire markdown output
  return table.concat(parts):gsub("%s+$", "")
end

---Parse markdown lines into config and messages using line-by-line state machine
---@param lines string[] Array of lines to parse
---@return table config Front matter configuration
---@return table messages Array of message objects
local function parse_lines(lines)
  local front_matter_lines = {}
  local messages = {}
  local mode = "front_matter" -- front_matter, content
  local current_role = nil
  local accumulator = {}
  local in_front_matter = false

  -- Track special blocks within messages
  local in_code_block = false
  local code_block_fence = nil

  local function flush()
    if current_role and #accumulator > 0 then
      local text = trim(table.concat(accumulator, "\n"))
      if text ~= "" then
        ---@type ChatMLMessage
        local msg = { role = current_role, content = text }

        -- Process file includes: @path pattern (@ at start of line)
        local search_content = "\n" .. text
        for file_path in search_content:gmatch("\n%s*@([^\n]+)") do
          local file_content = read_file_content(file_path)
          if file_content ~= "" then
            msg.content = string.format("%s\n\n```%s\n%s\n```", msg.content, trim(file_path), file_content)
          end
        end

        -- Parse tool_call_id: ## tool: name (id=...) ````json\n...\n````
        local _, tool_call_id, tool_content = text:match("## tool:%s*(%S+)%s*%(%s*id%s*=%s*([^%)]+)%)%s*````json\n(.-)\n````")
        if tool_call_id then
          msg.tool_call_id = tool_call_id
          msg.content = tool_content or ""
          -- Remove tool block from content
          local remaining = text:gsub("## tool:%s*%S+%s*%(%s*id%s*=%s*[^%)]+%)%s*````json\n.-\n````%s*", "")
          remaining = trim(remaining)
          if #remaining > 0 then
            msg.content = remaining
          end
        end

        -- Parse tool_calls: ## tool_call: func (id=...) ```json\n...\n```
        local tool_calls = {}
        for func, id, args in text:gmatch("## tool_call:%s*(%S+)%s*%(%s*id%s*=%s*([^%)]+)%)%s*```json\n(.-)```") do
          table.insert(tool_calls, {
            id = id,
            type = "function",
            ["function"] = {
              name = func,
              arguments = args,
            },
          })
        end

        if #tool_calls > 0 then
          msg.tool_calls = tool_calls
          -- Remove tool_call blocks from content
          local remaining = text:gsub("\n?## tool_call:%s*%S+%s*%(%s*id%s*=%s*[^%)]+%)%s*```json\n.-```%s*", "")
          remaining = trim(remaining)
          if #remaining > 0 then
            msg.content = remaining
          else
            msg.content = nil
          end
        end

        table.insert(messages, msg)
      end
    end
    accumulator = {}
  end

  for _, line in ipairs(lines) do
    -- Track code blocks to avoid matching headers inside them
    if mode == "content" and not in_front_matter then
      local fence = line:match("^(`````*)")
      if fence then
        if not in_code_block then
          in_code_block = true
          code_block_fence = fence
        elseif fence == code_block_fence then
          in_code_block = false
          code_block_fence = nil
        end
      end
    end

    -- Handle front matter delimiters
    if line == "---" and not in_code_block then
      if mode == "front_matter" and not in_front_matter then
        in_front_matter = true
      elseif mode == "front_matter" and in_front_matter then
        in_front_matter = false
        mode = "content"
      end
    elseif in_front_matter then
      table.insert(front_matter_lines, line)
    elseif mode == "content" then
      -- Check for role headers: # role (only outside code blocks)
      local role = nil
      if not in_code_block then
        role = line:match("^#%s+(%w+)%s*$")
      end

      if role and VALID_ROLES[role] then
        flush()
        current_role = role
      elseif current_role then
        table.insert(accumulator, line)
      end
    end
  end

  flush()

  -- Parse front matter YAML
  local front_matter_str = table.concat(front_matter_lines, "\n")
  local config = {}
  if #front_matter_str > 0 then
    local ok, parsed = pcall(yaml.decode, front_matter_str)
    if ok and parsed then
      config = parsed
    end
  end

  return config, messages
end

---Convert markdown string of chat completion request to JSON
---@param md_str string Markdown string of chat completion request
---@return string json JSON string of chat completion request
M.md_to_json = function(md_str)
  local lines = vim.split(md_str, "\n")
  local config, messages = parse_lines(lines)

  if not config.model then
    error("Model key not found in front matter")
  end

  if #messages == 0 then
    error("No messages found")
  end

  config.messages = messages

  local ok, json_str = pcall(vim.json.encode, config)
  if not ok then
    error("Cannot encode table to json string")
  end

  return json_str
end

---Parse markdown buffer into config and messages
---Uses a line-by-line state machine approach for cleaner parsing
---@param bufnr number Buffer number to parse
---@return table config Front matter configuration
---@return table messages Array of message objects
M.parse_buffer = function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return parse_lines(lines)
end

---Convert parsed buffer to chat completion request table
---@param bufnr number Buffer number to parse
---@return table request Chat completion request table with model and messages
M.parse_buffer_to_request = function(bufnr)
  local config, messages = M.parse_buffer(bufnr)

  if not config.model then
    error("Model key not found in front matter")
  end

  if #messages == 0 then
    error("No messages found")
  end

  config.messages = messages
  return config
end

-- Buffer operations (external dependencies)

---Convert JSON buffer to markdown buffer using json_to_md
---@param in_buf number Input JSON buffer number
---@param out_buf number? Output markdown buffer number
---@return number? out_buf Output markdown buffer number
M.json_buf_to_md_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "json" then
    error("Buffer is not a JSON buffer")
  end
  local json_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n")
  local md_str = M.json_to_md(json_str)
  if md_str then
    out_buf = out_buf or vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = out_buf })
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(md_str, "\n"))
    return out_buf
  else
    error("Generated md_str is nil")
  end
end

---Convert markdown buffer to JSON buffer using md_to_json
---@param in_buf number Input markdown buffer number
---@param out_buf number? Output JSON buffer number
---@return number? out_buf Output JSON buffer number
M.md_buf_to_json_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "markdown" then
    error("Buffer is not a markdown buffer")
  end
  local md_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n")
  local json_str = M.md_to_json(md_str)
  if json_str then
    out_buf = out_buf or vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "json", { buf = out_buf })
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(json_str, "\n"))
    return out_buf
  else
    error("Generated md_str is nil")
  end
end

---Convert markdown file to JSON string using md_to_json
---@param file_path string Path to the input markdown file
---@return string|nil json_str JSON string representation of the markdown content, or nil on error
M.md_file_to_json_str = function(file_path)
  local fd = io.open(file_path, "r")
  if not fd then
    error("Cannot open file: " .. file_path)
  end
  local md_str = fd:read("*a")
  fd:close()
  if not md_str then
    error("Failed to read markdown file content")
  end
  return M.md_to_json(md_str)
end

return M
