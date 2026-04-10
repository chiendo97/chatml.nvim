---@class ChatMLConfig
local M = {}

-- Configuration for both ChatML and LLM client settings

---@class ChatMLDefaultOptions
M.defaults = {
  base_url = os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1",
  api_key = os.getenv("OPENAI_API_KEY") or "",
  default_model = "openai/gpt-5-mini",
}

---@class ChatMLOptions
M.options = {}

---Extend the defaults options table with the user options
---@param opts ChatMLOptions: plugin options
M.setup = function(opts)
  -- Merge user-provided options 'opts' with default options 'M.defaults'.
  -- 'vim.tbl_deep_extend' recursively merges tables, with 'force' prioritizing latter values.
  -- Resulting merged options are stored in 'M.options'.
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
