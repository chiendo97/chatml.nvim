local data_path = vim.fn.stdpath("data"):gsub("/$", "")
local chat_dir = data_path .. "/chatml/chats"

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("ChatMLChat", { clear = true }),
  pattern = chat_dir .. "/*.md",
  callback = function(event)
    local buf = event.buf
    local config = require("chatml.config")
    vim.notify_once("ChatML configured with base_url: " .. (config.options.base_url or ""), vim.log.levels.INFO)

    -- Create buffer-local keymap for chat completion
    vim.keymap.set("n", "<leader>ll", function()
      require("chatml.llm").chat_completion(buf)
    end, {
      buffer = buf,
      silent = true,
      desc = "Trigger chat completion",
    })

    -- Create buffer-local keymap for stopping LLM generation
    vim.keymap.set("n", "<leader>ls", function()
      require("chatml.llm").cancel_last_job()
    end, {
      buffer = buf,
      silent = true,
      desc = "Stop LLM generation",
    })

    -- Create keymap for switching models
    vim.keymap.set("n", "<leader>lm", function()
      require("chatml.chat").switch_model()
    end, {
      buffer = buf,
      silent = true,
      desc = "Switch model",
    })

    -- Create keymap for showing JSON chat
    vim.keymap.set("n", "<leader>lj", function()
      require("chatml.chat").show_json_chat()
    end, {
      buffer = buf,
      silent = true,
      desc = "Show JSON representation",
    })
  end,
})

vim.keymap.set("n", "<leader>lc", function()
  require("chatml.chat").new_chat()
end, { desc = "Create new chatml chat" })

vim.keymap.set("n", "<leader>lp", function()
  require("chatml.chat").picker()
end, { desc = "Picker chatml chat" })

vim.keymap.set("n", "<leader>lg", function()
  require("chatml.chat").search()
end, { desc = "Search chatml chat" })
