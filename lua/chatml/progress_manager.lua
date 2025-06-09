-- ============================================================================
-- PROGRESS MANAGEMENT
-- ============================================================================

local progress = require("fidget.progress")

---@class ProgressManager
---@field handles table<string, any> Active progress handles
local ProgressManager = {}
ProgressManager.__index = ProgressManager

---Create a new progress manager instance
---@return ProgressManager
function ProgressManager:new()
  return setmetatable({
    handles = {},
  }, self)
end

---Create a progress handle with consistent configuration
---@param id string Unique identifier for the progress
---@param title string Progress title
---@param message? string Initial message
---@return any handle Fidget progress handle
function ProgressManager:create_handle(id, title, message)
  -- Clean up any existing handle with same ID
  self:finish_handle(id)

  local handle = progress.handle.create({
    title = title,
    message = message or "Starting...",
    percentage = 0,
    lsp_client = { name = "chatml.nvim" },
  })

  self.handles[id] = handle
  return handle
end

---Update progress handle
---@param id string Progress identifier
---@param message string Progress message
---@param percentage? number Progress percentage (0-100)
function ProgressManager:update_handle(id, message, percentage)
  local handle = self.handles[id]
  if handle then
    handle:report({
      message = message,
      percentage = percentage,
    })
  end
end

---Finish and cleanup progress handle
---@param id string Progress identifier
---@param final_message? string Final message before completion
function ProgressManager:finish_handle(id, final_message)
  local handle = self.handles[id]
  if handle then
    if final_message then
      handle:report({
        message = final_message,
        percentage = 100,
      })
    end
    handle:finish()
    self.handles[id] = nil
  end
end

---Check if handle exists
---@param id string Progress identifier
---@return boolean exists Whether handle exists
function ProgressManager:has_handle(id)
  return self.handles[id] ~= nil
end

-- Create and export singleton instance
local progress_manager = ProgressManager:new()

return progress_manager
