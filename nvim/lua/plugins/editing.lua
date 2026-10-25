-- Velocidad de edición pura: autopairs, surround y mejores text objects
-- (mini.nvim, un solo repo con varios módulos independientes) + salto
-- rápido a cualquier punto visible de la pantalla (flash.nvim).
return {
  {
    "nvim-mini/mini.nvim",
    version = false,
    event = "VeryLazy",
    config = function()
      require("mini.pairs").setup()
      require("mini.surround").setup()
      require("mini.ai").setup()
      -- Previsualiza colores hex (#RRGGBB) con su color real de fondo:
      -- útil al tocar colors.xml o cualquier CSS/Angular. Módulo de
      -- mini.nvim, ya instalado — sin plugin nuevo.
      require("mini.hipatterns").setup({
        highlighters = {
          hex_color = require("mini.hipatterns").gen_highlighter.hex_color(),
        },
      })
      -- Cerrar un buffer sin romper el layout de ventanas: :bdelete en un
      -- buffer abierto en un split lo cierra o salta a otro cualquiera;
      -- esto cambia ese split a un buffer alterno sensato y mantiene el
      -- layout. Lo usan <leader>bd (plugins/ui.lua) y hbac al autocerrar.
      require("mini.bufremove").setup()
    end,
  },

  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      { "s", function() require("flash").jump() end, mode = { "n", "x", "o" }, desc = "Flash: saltar" },
      { "S", function() require("flash").treesitter() end, mode = { "n", "x", "o" }, desc = "Flash: treesitter" },
    },
  },

  {
    -- Buscar Y reemplazar en todo el proyecto (no solo la línea actual, eso
    -- ya lo hace :s de vim). Preview antes de aplicar, por archivo o todo
    -- de una.
    "MagicDuck/grug-far.nvim",
    cmd = "GrugFar",
    keys = {
      { "<leader>fr", "<cmd>GrugFar<CR>", desc = "Reemplazar en el proyecto" },
    },
  },
}
