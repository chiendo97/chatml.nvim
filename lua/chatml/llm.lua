local log = require("chatml.log")
local parse = require("chatml.parse")
local ai = require("ai")
local hub = require("mcphub").get_hub_instance()

---@class ChatMLLLM
local M = {}

M.client = ai.Client:new()

--[[
The function `last` is from olimorris/codecompanion.nvim repo:
  https://github.com/olimorris/codecompanion.nvim/blob/f8db284e1197a8cc4235afa30dcc3e8d4f3f45a5/lua/codecompanion/strategies/chat.lua#L987

Check out NOTICE.md for more information about the original code.
--]]

---Get the last line, column and line count in the chat buffer
---@param buf integer: The buffer number
---@return integer: number of the last line
---@return integer: number of columns in the last line
local function last(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_line = line_count - 1
  if last_line < 0 then
    return 0, 0
  end
  local last_line_content = vim.api.nvim_buf_get_lines(buf, -2, -1, false)
  if not last_line_content or #last_line_content == 0 then
    return last_line, 0
  end
  local last_column = #last_line_content[1]
  return last_line, last_column
end

local function on_chat_completion(out_buf)
  local last_role = ""
  return function(chat_completion_obj)
    local message = chat_completion_obj.choices[1].message
    local role = message.role
    if role ~= nil and role ~= "" and last_role ~= role then
      local role_lines = { "", "# " .. role, "" }
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, role_lines)
      last_role = role
    end

    -- handle function_call, if present
    if message.function_call then
      local func_name = message.function_call.name or ""
      local args = message.function_call.arguments or ""
      local func_lines = {
        "### function_call: " .. func_name,
        "",
        "```json",
        args,
        "```",
        "",
      }
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_lines)
    end

    -- handle name if role == "function"
    if role == "function" and message.name then
      local func_name_lines = {
        "### function: " .. message.name,
        "",
      }
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_name_lines)
    end

    -- content (if any)
    if message.content and message.content ~= "" then
      local content_lines = vim.split(message.content, "\n", { plain = true, trimempty = false })
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, content_lines)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "" }) -- add empty line after content for better spacing
    end

    -- separator
    vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "---" })
  end
end

local function on_chat_completion_chunk(out_buf)
  -- We'll maintain state for function_call chunks across calls:
  local last_role = ""
  local func_call_name = nil
  local func_call_args = ""

  return function(chat_completion_chunk_obj)
    local choice = chat_completion_chunk_obj.choices[1]
    local delta = choice.delta

    -- write role header if present and changed
    local role = delta.role
    if role ~= nil and role ~= "" and last_role ~= role then
      local role_lines = { "", "# " .. role, "", "" }
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, role_lines)
      last_role = role
    end

    -- handle function_call field in delta
    if delta.function_call then
      -- function_call.name and function_call.arguments may arrive in pieces,
      -- so accumulate them safely.

      if delta.function_call.name then
        func_call_name = (func_call_name or "") .. delta.function_call.name
      end
      if delta.function_call.arguments then
        func_call_args = func_call_args .. delta.function_call.arguments
      end

      -- While streaming, just display content so far (optional)
      -- But to keep it simple, defer rendering function_call until finish_reason == "stop"
      -- So do nothing now.
      return
    end

    -- handle normal content in delta (non-function_call)
    if delta.content then
      local lines = vim.split(delta.content, "\n", { plain = true, trimempty = false })

      local last_line, last_column = last(out_buf)
      vim.api.nvim_buf_set_text(out_buf, last_line, last_column, last_line, last_column, lines)
    end

    local finish_reason = choice.finish_reason
    if finish_reason == "stop" then
      -- if we have accumulated function_call data, render it now
      if func_call_name ~= nil and func_call_args ~= "" then
        local func_lines = {
          "",
          "### function_call: " .. func_call_name,
          "",
          "```json",
          func_call_args,
          "```",
          "",
        }
        vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_lines)
      end

      -- add markdown separator
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "", "---" })
      vim.notify("Done.", vim.log.levels.INFO)

      -- reset state for next message
      func_call_name = nil
      func_call_args = ""
    elseif finish_reason ~= nil then
      -- something else: error maybe
      vim.notify("An error occured during text generation.", vim.log.levels.ERROR)
    end
  end
end

---Send chat completion request to LLM and add response to output buffer
---@param in_buf number: input markdown buffer number
---@param out_buf number?: output markdown buffer number
M.chat_completion = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "markdown" then
    log.debug("Input buffer is not a markdown buffer")
    error("Input buffer is not a markdown buffer")
  end
  if out_buf then
    local out_ft = vim.api.nvim_get_option_value("filetype", { buf = out_buf })
    if out_ft ~= "markdown" then
      log.debug("Output buffer is not a markdown buffer")
      error("Output buffer is not a markdown buffer")
    end
  end

  local md_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n"):gsub("%s+$", "")
  local json_str = parse.md_to_json(md_str)
  local ok, request = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
  local req_md_str = nil

  if not ok or type(request) ~= "table" then
    log.error("Cannot parse JSON string into request", request)
    error("Cannot parse JSON string into request")
  end

  -- Add tools
  local tools = hub:get_tools()

  request["functions"] = request["functions"] or {}
  for _, tool in ipairs(tools) do
    table.insert(request["functions"], {
      name = tool.name,
      description = tool.description,
      parameters = tool.inputSchema,
    })
  end

  for _, func in ipairs(request["functions"]) do
    if func.parameters and func.parameters.properties then
      for _, param in pairs(func.parameters.properties) do
        param.examples = nil
      end
    end
  end

  -- New part: handle last assistant.function_call if any
  local last_msg = request.messages[#request.messages]
  vim.notify("Last message in request: " .. vim.inspect(last_msg), vim.log.levels.DEBUG)

  if last_msg and last_msg.role == "assistant" and last_msg.function_call then
    local func_name = last_msg.function_call.name
    local func_args_str = last_msg.function_call.arguments or "{}"
    local func_args_table = nil
    local decode_ok, decoded_args = pcall(vim.json.decode, func_args_str)
    if decode_ok and type(decoded_args) == "table" then
      func_args_table = decoded_args
    else
      func_args_table = {}
    end

    local response, err = hub:call_tool("neovim", func_name, func_args_table)
    local result_content = "{}" -- default empty json object string

    if err then
      vim.notify("Tool call error: " .. err, vim.log.levels.ERROR)
      result_content = vim.json.encode({
        error = "Tool call error: " .. err,
      })
    else
      if response and response.result and response.result.content then
        local first_content = response.result.content[1]
        if first_content and first_content.text then
          -- Encode the text string as JSON string value (quoted)
          result_content = vim.json.encode(first_content.text)
        else
          -- fallback: encode whole content object as JSON string
          result_content = vim.json.encode(response.result.content)
        end
      end
    end

    table.insert(request.messages, {
      role = "function",
      name = func_name,
      content = result_content,
    })

    req_md_str = parse.json_to_md(vim.json.encode(request, { luanil = { object = true, array = true } }))
    if req_md_str then
      md_str = req_md_str
    end
  end

  out_buf = out_buf or in_buf
  vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(md_str, "\n"))

  log.debug("request: ", request)
  vim.notify(string.format("Sending request to %s...(%d messages)", M.client.base_url, #request.messages))

  M.client:chat_completion_create(request, on_chat_completion(out_buf), on_chat_completion_chunk(out_buf))
end

M.on_chat_completion = on_chat_completion
M.on_chat_completion_chunk = on_chat_completion_chunk

return M
