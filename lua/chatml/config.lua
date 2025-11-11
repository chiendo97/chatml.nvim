---@class ChatMLConfig
local M = {}

-- Configuration for both ChatML and LLM client settings

---@class ChatMLDefaultOptions
M.defaults = {
  base_url = "https://api.openai.com/v1",
  api_key = vim.fn.getenv("OPENAI_API_KEY"),
}

---@class ChatMLOptions
M.options = {}

---Extend the defaults options table with the user options
---@param opts ChatMLOptions: plugin options
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  vim.notify_once("ChatML configured with base_url: " .. M.options.base_url, vim.log.levels.INFO)
end

return M
