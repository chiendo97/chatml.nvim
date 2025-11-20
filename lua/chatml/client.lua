--- HTTP Client for LLM API requests
--- Migrated from ai.nvim into chatml.nvim

local M = {}

---Create curl command array to send request to the server
---@param url string url for the request
---@param api_key string environment variable used for API authentication
---@param request table The request to send to the server. This will be encoded as JSON and used as the request body.
---@return table cmd Command array for vim.system
---@return string json_request The encoded JSON request string
local function curl_command(url, api_key, request)
  local json_request = vim.json.encode(request)
  if type(json_request) ~= "string" then
    error("Error while parsing the request")
  end

  -- create temporary file for JSON data
  local tmpfile = vim.fn.tempname()
  local ok = vim.fn.writefile({ json_request }, tmpfile)
  if ok ~= 0 then
    error("Failed to write request to temp file")
  end

  local cmd = {
    "curl",
    "--silent",
    "--no-buffer",
    "--header",
    "Authorization: Bearer " .. api_key,
    "--header",
    "Content-Type: application/json",
    "--url",
    url,
    "--data-binary",
    "@" .. tmpfile,
  }

  return cmd, json_request
end

---@class ChatMLClient
local Client = {}

---Client constructor
---@param base_url string?: base url for all API requests
---@param api_key string?: environment variable used for API authentication
---@return ChatMLClient: client object
function Client:new(base_url, api_key)
  local instance = setmetatable({}, { __index = Client })
  local config = require("chatml.config")

  instance.base_url = base_url or config.options.base_url or config.defaults.base_url
  instance.api_key = api_key or config.options.api_key or config.defaults.api_key

  if not instance.api_key or instance.api_key == "" then
    error("API key is required.")
  end

  return instance
end

---@param request ChatMLRequest: request for chat completion create
---@param on_chat_completion? fun(ChatCompletionResponse) callback for job stdout when stream = false
---@param on_chat_completion_chunk? fun(ChatCompletionResponse) callback for job stdout when stream = true
---@param on_stdout function: override default callback for job stdout. See `:h on_stdout`.
---@param on_stderr? function: override default callback for job stderr. See `:h on_stderr`.
---@param on_exit function: override default callback for job exit. See `:h on_exit`.
---@return number: process id
function Client:chat_completion_create(
  request,
  on_chat_completion,
  on_chat_completion_chunk,
  on_stdout,
  on_stderr,
  on_exit
)
  if request.stream then
    if not on_chat_completion_chunk then
      error("on_chat_completion_chunk is required for stream=true")
    end
  else
    if not on_chat_completion then
      error("on_chat_completion is required for stream=false")
    end
  end

  local cmd, _ = curl_command(self.base_url .. "/chat/completions", self.api_key, request)

  -- Create adapter for stdout callback (convert vim.system format to jobstart format)
  local stdout_adapter = function(err, data)
    if err then
      vim.notify("Error reading stdout: " .. err, vim.log.levels.ERROR)
      return
    end
    if not data or type(data) == "nil" or data == nil then
      return
    end
    local data_array = vim.split(data, "\n", { plain = true })
    vim.schedule(function()
      on_stdout(data_array)
    end)
  end

  -- Create adapter for stderr callback (convert vim.system format to jobstart format)
  local stderr_adapter = function(err, data)
    if err then
      vim.notify("Error reading stderr: " .. err, vim.log.levels.ERROR)
      return
    end
    if not data or type(data) == "nil" or data == nil then
      return
    end
    local data_array = vim.split(data, "\n", { plain = true })
    local stderr_handler = on_stderr
      or function(data_lines)
        for _, str in ipairs(data_lines) do
          if str ~= "" then
            vim.notify("Error: " .. str, vim.log.levels.ERROR)
          end
        end
      end
    vim.schedule(function()
      stderr_handler(data_array)
    end)
  end

  -- Create adapter for exit callback (convert SystemCompleted to jobstart format)
  local exit_adapter = function(obj)
    vim.schedule(function()
      on_exit(nil, obj.code, obj.signal)
    end)
  end

  local system_obj = vim.system(cmd, {
    text = true,
    stdout = stdout_adapter,
    stderr = stderr_adapter,
  }, exit_adapter)

  return system_obj.pid
end

M.Client = Client

return M
