-- Resalta brevemente el texto copiado/pegado.
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function()
    vim.highlight.on_yank({ timeout = 150 })
  end,
})

-- Angular/TS/web usan 2 espacios por convención, no 4 (Kotlin se queda con
-- el default de core/options.lua). Un .editorconfig en el proyecto pisa esto.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "typescript", "javascript", "html", "css", "scss", "json", "yaml" },
  callback = function()
    vim.bo.tabstop = 2
    vim.bo.shiftwidth = 2
  end,
})

-- Vuelve a la última posición del cursor al reabrir un archivo.
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function(args)
    local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
    local line_count = vim.api.nvim_buf_line_count(args.buf)
    if mark[1] > 0 and mark[1] <= line_count then
      vim.api.nvim_win_set_cursor(0, mark)
    end
  end,
})
