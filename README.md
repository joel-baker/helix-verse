# helix-verse

Verse language support for the [Helix editor](https://helix-editor.com/), providing:

- **Syntax highlighting** — keywords, types, functions, strings, comments, operators, attributes, specifiers
- **Indentation** — auto-indent after `:`, `=`, and `{` blocks
- **Textobjects** — smart motions (`]f`, `mif`, `mac`, etc.) for functions, classes, and parameters
- **Local variable tracking** — scope-aware variable highlighting
- **LSP integration** — auto-connects to the `verse-lsp` server bundled with the VS Code Verse extension

Syntax highlighting is powered by the [taku25/tree-sitter-verse](https://github.com/taku25/tree-sitter-verse) grammar (MIT licensed).

---

## Prerequisites

| Requirement | Notes |
|---|---|
| [Helix](https://helix-editor.com/) with `hx` on PATH | Tested with v25.07+ |
| `git` on PATH | Used by `hx --grammar fetch` to download the grammar |
| C compiler on PATH | Used by `hx --grammar build` to compile the grammar. Run from a **Visual Studio Developer PowerShell** (provides `cl.exe`), or install standalone LLVM: `winget install LLVM.LLVM` |
| [Epic Games Verse VS Code extension](https://marketplace.visualstudio.com/items?itemName=EpicGames.verse) | Provides `verse-lsp.exe` for LSP features. The installer auto-detects it at `%USERPROFILE%\.vscode\extensions\epicgames.verse-*\bin\Win64\verse-lsp.exe` |

---

## Quick Install

Run from a **Visual Studio Developer PowerShell** (so the C compiler is on PATH):

```powershell
.\install.ps1
```

The script will:
1. Detect and configure `verse-lsp.exe` from your VS Code extension
2. Merge `languages.toml` into `%APPDATA%\helix\languages.toml`
3. Copy query files to `%APPDATA%\helix\runtime\queries\verse\`
4. Run `hx --grammar fetch` to download the grammar source
5. Run `hx --grammar build verse` to compile it

Use `-Force` to skip the overwrite prompt if a Verse config already exists:

```powershell
.\install.ps1 -Force
```

---

## Manual Installation

1. **Merge `languages.toml`** — append its contents to `%APPDATA%\helix\languages.toml`.
   Update the `verse-lsp` command to point to your `verse-lsp.exe`:
   ```toml
   [language-server.verse-lsp]
   command = "C:\\Users\\<you>\\.vscode\\extensions\\epicgames.verse-<version>\\bin\\Win64\\verse-lsp.exe"
   ```

2. **Copy query files** — copy the `queries\verse\` folder to `%APPDATA%\helix\runtime\queries\verse\`

3. **Fetch and build the grammar**:
   ```powershell
   hx --grammar fetch
   hx --grammar build verse
   ```

---

## File Extensions

| Extension | Description |
|---|---|
| `.verse` | Verse source files |
| `.versetest` | Verse test files |
| `.vson` | Verse object notation files |

---

## Credits

- Tree-sitter grammar: [taku25/tree-sitter-verse](https://github.com/taku25/tree-sitter-verse) (MIT License)
- Verse language: [Epic Games / UEFN](https://dev.epicgames.com/documentation/unreal-editor-fortnite/en/l5k/Verse/onboarding-guide-to-programming-with-verse-in-unreal-editor-for-fortnite)
