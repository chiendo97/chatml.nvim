local log = require("chatml.log")
local yaml = require("chatml.yaml")

---@class ChatMLParse
local M = {}

----------------------------------------------------------------------------------------------------
-- JSON to Markdown
----------------------------------------------------------------------------------------------------

---Convert JSON string of chat completion request to markdown
---It follow the specification of https://github.com/S1M0N38/chat-completion-md
---@param json_str string: JSON string of chat completion request
---@return string|nil: markdown string of chat completion request
M.json_to_md = function(json_str)
  -- Parse the JSON string
  local ok, json_data = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
  if not ok then
    log.debug("Invalid JSON string")
    error("Invalid JSON string")
  end

  if json_data == nil then
    log.debug("Parsed (json) data is nil")
    error("Parsed (json) data is nil")
  end

  -- Check for and extract the "messages" key
  local messages = json_data["messages"]
  if not messages then
    log.debug("Messages key not found in JSON")
    error("Messages key not found in JSON")
  end

  -- Check for "model" key
  if not json_data["model"] then
    log.debug("Model key not found in JSON")
    error("Model key not found in JSON")
  end

  -- Validate "messages" and roles
  local valid_roles = {
    assistant = true,
    developer = true,
    system = true,
    tool = true,
    user = true,
    ["function"] = true,
  }
  for _, msg in ipairs(messages) do
    if type(msg) ~= "table" or not msg.role then
      log.debug("Each message must be a table with a 'role' key")
      error("Each message must be a table with a 'role' key")
    end
    if not valid_roles[msg.role] then
      log.debug("Invalid role: " .. tostring(msg.role))
      error("Invalid role: " .. tostring(msg.role))
    end

    -- Require content or function_call or name (if role function)
    if msg.content == nil and msg.function_call == nil and not (msg.role == "function" and msg.name) then
      log.debug(
        "Each message must have 'content', or 'function_call', or 'name' (for role=function): " .. vim.inspect(msg)
      )
      error("Each message must have 'content', or 'function_call', or 'name' (for role=function)")
    end
  end

  --- Parse metadata as yaml
  json_data["messages"] = nil
  json_data["functions"] = nil
  local metadata_str = yaml.encode(json_data):gsub("^%s+", ""):gsub("%s+$", "")

  --- Generate markdown string
  local md_str = "---\n" .. metadata_str .. "\n---\n"
  for _, msg in ipairs(messages) do
    md_str = md_str .. "\n# " .. msg.role .. "\n\n"

    -- Add function_call if present
    if msg.function_call then
      md_str = md_str .. "### function_call: " .. tostring(msg.function_call.name) .. "\n\n"
      -- Pretty-print arguments, assuming JSON string - indent nicely
      local args = msg.function_call.arguments or ""
      args = args:gsub("%s+$", "")
      -- indent the arguments block for markdown code block
      md_str = md_str .. "```json\n" .. args .. "\n```\n\n"
    end

    -- Add function name if present and role is "function"
    if msg.role == "function" and msg.name then
      md_str = md_str .. "### function: " .. tostring(msg.name) .. "\n\n"
    end

    -- Add content if present
    if msg.content then
      md_str = md_str .. msg.content .. "\n\n"
    end

    md_str = md_str .. "---\n"
  end
  md_str = md_str:gsub("%s+$", "")

  return md_str
end

---Convert JSON buffer to markdown buffer using json_to_md
---@param in_buf number: input JSON buffer number
---@param out_buf number?: output markdown buffer number
---@return number|nil: output markdown buffer number
M.json_buf_to_md_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "json" then
    log.debug("Buffer is not a JSON buffer")
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
    log.debug("Generated md_str is nil")
    error("Generated md_str is nil")
  end
end

----------------------------------------------------------------------------------------------------
-- Markdown to JSON
----------------------------------------------------------------------------------------------------

---Convert markdown string of chat completion request to JSON
---It follow the specification of https://github.com/S1M0N38/chat-completion-md
---@param md_str string: markdown string of chat completion request
---@return string|nil: JSON string of chat completion request.
M.md_to_json = function(md_str)
  -- Extract front matter and content using pattern matching
  local front_matter, content = md_str:match("^%-%-%-\n(.-)\n%-%-%-(.*)$")
  if not front_matter or #front_matter == 0 then
    log.debug("Cannot parse Markdown string")
    error("Cannot parse Markdown string")
  end

  -- Parse YAML front matter
  local ok, config = pcall(yaml.decode, front_matter)
  if not ok then
    log.debug("Cannot parse front matter YAML")
    error("Cannot parse front matter YAML")
  end

  if config == nil then
    log.debug("Parsed (yaml) config is nil")
    error("Parsed (yaml) config is nil")
  end

  if config ~= nil and not config.model then
    log.debug("Model key not found in front matter")
    error("Model key not found in front matter")
  end

  if #content == 0 then
    log.debug("Content after front matter is empty")
    error("Content after front matter is empty")
  end

  -- Extract messages using pattern matching
  local messages = {}
  local valid_roles = {
    system = true,
    user = true,
    assistant = true,
    developer = true,
    tool = true,
    ["function"] = true,
  }
  -- Pattern matches blocks like:
  -- # <role>
  --
  -- <message content>
  --
  -- ---
  -- Including multiline content greedily (.-)
  local pattern = "\n# (%w+)\n\n(.-)\n\n%-%-%-"

  for role, msg_content in content:gmatch(pattern) do
    if not valid_roles[role] then
      log.debug("Invalid role: " .. role)
      error("Invalid role: " .. role)
    end

    -- Prepare message table
    local msg = {
      role = role,
    }

    local content_trim = msg_content:gsub("^%s+", ""):gsub("%s+$", "")

    -- Try to extract function_call block
    -- Pattern:
    -- ### function_call: <name>
    --
    -- ```json
    -- {json arguments}
    -- ```
    --
    -- This block may appear anywhere but normally at start of content if exists
    local func_call_name, func_call_args = content_trim:match("### function_call:%s*(%S+)%s-```json\n(.-)```")

    if func_call_name and func_call_args then
      -- Remove the function_call block from content
      -- Replace the entire function_call block with empty string
      local cleaned_content = content_trim
        :gsub("### function_call:%s*" .. vim.pesc(func_call_name) .. "%s-```json\n.-```%s*", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")

      -- Assign function_call field
      msg.function_call = {
        name = func_call_name,
        arguments = func_call_args,
      }
      -- Remaining content (if any) goes to content
      if #cleaned_content > 0 then
        msg.content = cleaned_content
      end
    else
      -- No function_call block, try function name block (only for role "function")
      if role == "function" then
        -- Pattern:
        -- ### function: <name>
        -- [newline]
        -- <content>
        local func_name, rest_content = content_trim:match("### function:%s*(%S+)%s*\n(.+)")
        if func_name then
          msg.name = func_name
          msg.content = rest_content and rest_content:gsub("^%s+", "") or ""
        else
          -- No function name detected, treat whole as content
          msg.content = content_trim
        end
      else
        -- For other roles, just content
        msg.content = content_trim
      end
    end

    table.insert(messages, msg)
  end

  if #messages == 0 then
    log.debug("No messages found")
    error("No messages found")
  end

  config.messages = messages

  -- Encode to JSON string
  local json_str_ok, json_str = pcall(vim.json.encode, config)
  if not json_str_ok then
    log.debug("Cannot encode table to json string")
    error("Cannot encode table to json string")
  end

  return json_str
end

---Convert markdown buffer to JSON buffer using md_to_json
---@param in_buf number: input markdown buffer number
---@param out_buf number?: output JSON buffer number
---@return number|nil: output JSON buffer number
M.md_buf_to_json_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "markdown" then
    log.debug("Buffer is not a markdown buffer")
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
    log.debug("Generated md_str is nil")
    error("Generated md_str is nil")
  end
end

----------------------------------------------------------------------------------------------------

return M
