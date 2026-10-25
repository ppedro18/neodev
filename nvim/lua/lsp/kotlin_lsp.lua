-- Kotlin LSP oficial de JetBrains (github.com/Kotlin/kotlin-lsp).
-- Instalado vía Homebrew por install.sh, NO por Mason (su paquete está
-- roto, ver plugins/mason.lua). El default de nvim-lspconfig busca el
-- binario como "intellij-server", pero el tap de Homebrew lo deja en PATH
-- como "kotlin-lsp" (mismo binario, symlink con otro nombre) — hay que
-- decírselo explícito o nunca arranca.
-- Necesita contexto de proyecto (Gradle/Maven), por eso single_file_support
-- queda en false: abrir un .kt suelto sin build.gradle no lo activa.
return {
  cmd = { "kotlin-lsp", "--stdio" },
  single_file_support = false,
}
