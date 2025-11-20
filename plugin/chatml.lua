local llm = require("chatml.llm")
local chat = require("chatml.chat")

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("ChatMLChat", { clear = true }),
  pattern = chat.chat_dir .. "/*.md",
  callback = function(event)
    local buf = event.buf

    -- Create buffer-local keymap for chat completion
    vim.keymap.set("n", "<leader>ll", function()
      llm.chat_completion(buf)
    end, {
      buffer = buf,
      silent = true,
      desc = "Trigger chat completion",
    })

    -- Create global keymap for stopping LLM generation
    vim.keymap.set("n", "<leader>ls", function()
      require("chatml.llm").cancel_last_job()
    end, {
      buffer = buf,
      silent = true,
      desc = "Stop LLM generation",
    })

    -- Create keymap for switching models
    vim.keymap.set("n", "<leader>lm", function()
      chat.switch_model()
    end, {
      buffer = buf,
      silent = true,
      desc = "Switch model",
    })
  end,
})
