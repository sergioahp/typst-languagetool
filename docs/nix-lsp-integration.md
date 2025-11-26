# Nix LSP Integration: Problem Analysis and Resolution

## Executive Summary

This document provides a detailed technical analysis of the challenges encountered while integrating the typst-languagetool Language Server Protocol (LSP) implementation with Neovim through Nix packaging. The integration revealed three critical issues: (1) JSON deserialization failures due to Lua's ambiguous empty table semantics, (2) incorrect JAR file selection from the nixpkgs LanguageTool distribution, and (3) stderr contamination in dynamic configuration evaluation. Each issue required systematic investigation through iterative debugging, test harness development, and careful analysis of serialization boundaries between Lua, JSON, and Rust.

## Background

The typst-languagetool project provides grammar and spell checking for Typst documents via LanguageTool integration. The LSP server (`typst-languagetool-lsp`) requires initialization options that specify the LanguageTool backend configuration, including JAR file locations for the JNI-based backend. The Nix package manager was used to provide reproducible builds with automatic dependency management, while Neovim's nvim-lspconfig plugin managed LSP client configuration.

## Problem 1: JSON Deserialization Failure

### Symptom

The LSP server immediately crashed upon initialization with the error:
```
Error: invalid type: sequence, expected a map
```

The error occurred during deserialization of the `InitializeParams.initialization_options` from the Neovim LSP client.

### Root Cause Analysis

The Rust LSP server defined initialization options with the following structure:

```rust
#[derive(serde::Deserialize, Debug, Clone, Default)]
#[serde(default)]
struct InitOptions {
    on_change: Option<std::time::Duration>,
    options: Option<PathBuf>,
    #[serde(flatten)]
    lt: LanguageToolOptions,
}

#[derive(serde::Deserialize, Debug, Clone)]
#[serde(default)]
pub struct LanguageToolOptions {
    pub root: Option<PathBuf>,
    pub main: Option<PathBuf>,
    pub chunk_size: usize,
    #[serde(flatten)]
    pub backend: Option<BackendOptions>,
    pub languages: HashMap<String, String>,
    pub dictionary: HashMap<String, Vec<String>>,
    pub disabled_checks: HashMap<String, Vec<String>>,
    pub ignore_functions: HashSet<String>,
}

#[derive(serde::Deserialize, Debug, Clone)]
#[serde(tag = "backend")]
pub enum BackendOptions {
    #[serde(rename = "jar")]
    Jar { jar_location: String },
    // ...
}
```

The critical detail: `BackendOptions` uses `#[serde(tag = "backend")]` (externally tagged enum) and is flattened into `LanguageToolOptions` via `#[serde(flatten)]`, which itself is flattened into `InitOptions`. This creates a flat JSON structure where the `backend` field acts as a discriminator.

Initial attempts used nested configuration in the nvim-lspconfig default options:

```lua
init_options = {
    chunk_size = 1000,
    languages = {},
    dictionary = {},
    disabled_checks = {},
    ignore_functions = {},
}
```

The error "sequence, expected a map" indicated that JSON arrays `[]` were being received where objects `{}` were expected. This pointed to the `HashMap` fields (`languages`, `dictionary`, `disabled_checks`) being serialized incorrectly.

### Investigation Methodology

To isolate the serialization issue from the full LSP stack, we developed a minimal Rust test harness:

```rust
// /tmp/test_init_options/src/main.rs
fn test_json(name: &str, json_str: &str) {
    match serde_json::from_str::<InitOptions>(json_str) {
        Ok(opts) => println!("✓ Success: {:#?}", opts),
        Err(e) => println!("✗ Error: {}", e),
    }
}
```

This allowed rapid iteration testing different JSON structures without requiring Neovim restarts. Tests revealed:

1. ✓ `{"backend": "jar", "jar_location": "...", "languages": {}}` - **Success**
2. ✗ `{"backend": "jar", "jar_location": "...", "languages": []}` - **Failure: "invalid type: sequence, expected a map"**
3. ✓ `{"backend": "jar", "jar_location": "..."}` - **Success** (omitted fields use `#[serde(default)]`)

This confirmed that empty objects `{}` were required for `HashMap` fields, but empty arrays `[]` were being sent.

### Lua Serialization Ambiguity

The fundamental issue stems from Lua's unified table datatype. In Lua, `{}` represents an empty table that can be interpreted as either:
- JSON array: `[]`
- JSON object: `{}`

When Neovim's JSON encoder encounters `{}`, it must heuristically determine the JSON type. For empty tables, it defaults to arrays `[]`, which fails serde's `HashMap` deserialization.

Attempted solutions:
1. `vim.empty_dict()` - Should force object interpretation, but appeared ineffective
2. `vim.json.decode('{}')` - Explicit JSON parsing, still produced arrays
3. **Omitting fields entirely** - Successful, relies on Rust's `#[serde(default)]`

### Resolution

The nvim-lspconfig default configuration was modified to omit all optional `HashMap` fields:

```lua
-- Before (in nvim-lspconfig/lsp/typst_languagetool.lua)
init_options = {
    chunk_size = 1000,
    languages = {},        -- Serialized as [], caused failure
    dictionary = {},       -- Serialized as [], caused failure
    disabled_checks = {},  -- Serialized as [], caused failure
    ignore_functions = {},
}

-- After
init_options = {
    -- Optional fields omitted, use Rust defaults
}
```

User configurations only specify required fields:

```lua
-- User config (~/.config/nvim/lua/plugins/nvim-lspconfig.lua)
init_options = {
    backend = "jar",
    jar_location = "/nix/store/.../languagetool.jar",
    chunk_size = 1000,
}
```

This approach leverages Rust's `#[serde(default)]` attribute on `InitOptions` and `LanguageToolOptions`, which provides default values for omitted fields.

## Problem 2: Incorrect JAR File Selection

### Symptom

After resolving the deserialization issue, the LSP server initialized successfully but crashed when attempting to check text:

```
Exception in thread "Thread-0" java.lang.NoClassDefFoundError: org/languagetool/Languages
Caused by: java.lang.ClassNotFoundException: org.languagetool.Languages
```

The JNI integration could not find core LanguageTool classes.

### Root Cause Analysis

The nixpkgs `languagetool` package provides multiple JAR files:

```
/nix/store/.../LanguageTool-6.6/share/
├── languagetool-commandline.jar (34 KB)
├── languagetool-server.jar (203 KB)  ← Initially used
├── languagetool.jar (506 KB)         ← Correct choice
└── libs/
    ├── aho-corasick-double-array-trie.jar
    ├── ...
```

The initial flake.nix implementation incorrectly referenced `languagetool-server.jar`:

```nix
# flake.nix (incorrect)
postInstall = ''
  wrapProgram $out/bin/typst-languagetool \
    --add-flags "--jar-location ${pkgs.languagetool}/share/languagetool-server.jar"
'';

passthru = {
  languagetoolJar = "${pkgs.languagetool}/share/languagetool-server.jar";
};
```

The `languagetool-server.jar` contains only the HTTP server implementation and does not include the core LanguageTool classes required for JNI. The JNI backend (used by the `jar` backend option) requires the full `languagetool.jar` which includes:
- Core grammar checking engine (`org.languagetool.Languages`)
- Rule definitions
- Language models
- JNI-compatible interfaces

### Resolution

The flake.nix was updated to reference the correct JAR:

```nix
# flake.nix (corrected)
postInstall = ''
  wrapProgram $out/bin/typst-languagetool \
    --add-flags "--jar-location ${pkgs.languagetool}/share/languagetool.jar"
'';

passthru = {
  languagetoolJar = "${pkgs.languagetool}/share/languagetool.jar";
};
```

The `passthru.languagetoolJar` attribute allows downstream configurations to reference the correct JAR path via `nix eval`.

## Problem 3: Stderr Contamination in Configuration Evaluation

### Symptom

After correcting the JAR path, the LSP still failed with the same `ClassNotFoundException`. Log inspection revealed:

```
jar_location: "warning: Git tree '/home/admin/code/rust/typst-languagetool' is dirty/nix/store/g2l2y7mmq5fmp1gadmz4najim4phxwfv-LanguageTool-6.6/share/languagetool.jar"
```

The JAR path contained the Nix warning message, creating an invalid file path.

### Root Cause Analysis

The Neovim configuration dynamically evaluated the JAR path:

```lua
jar_location = vim.fn.system("nix eval ~/code/rust/typst-languagetool#default.languagetoolJar --raw"):gsub("\n", "")
```

The `vim.fn.system()` function captures both stdout and stderr. When the Nix working directory contained uncommitted changes, `nix eval` emitted a warning to stderr:

```
warning: Git tree '/home/admin/code/rust/typst-languagetool' is dirty
```

This warning was concatenated with the stdout JAR path because `vim.fn.system()` merges output streams. The resulting string was not a valid file path, causing Java's JAR loader to fail silently (no file found) followed by class loading failures.

### Resolution

The `nix eval` invocation was modified to redirect stderr to `/dev/null`:

```lua
-- Before
jar_location = vim.fn.system("nix eval ~/code/rust/typst-languagetool#default.languagetoolJar --raw"):gsub("\n", "")

-- After
jar_location = vim.fn.system("nix eval ~/code/rust/typst-languagetool#default.languagetoolJar --raw 2>/dev/null"):gsub("\n", "")
```

This ensures only stdout (the JAR path) is captured, eliminating stderr contamination.

## Additional Fix: JAVA_HOME Configuration

During investigation, we identified that the JNI initialization also required `JAVA_HOME` to be set in the wrapper scripts:

```nix
postInstall = ''
  wrapProgram $out/bin/typst-languagetool \
    --set JAVA_HOME "${pkgs.jdk}" \
    --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.jdk ]}" \
    --add-flags "--jar-location ${pkgs.languagetool}/share/languagetool.jar"

  wrapProgram $out/bin/typst-languagetool-lsp \
    --set JAVA_HOME "${pkgs.jdk}" \
    --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.jdk ]}"
'';
```

Without `JAVA_HOME`, the JNI library could not locate the JVM shared libraries, resulting in:
```
Couldn't automatically discover the Java VM's location
```

## Lessons Learned

### 1. Cross-Language Serialization Boundaries

When data crosses language boundaries (Lua → JSON → Rust), type ambiguities in the source language can cause failures in the target language. Lua's unified table type creates semantic ambiguity that manifests as runtime deserialization errors. Solutions include:

- **Explicit type annotations**: Use language-specific hints (`vim.empty_dict()`)
- **Omit optional fields**: Rely on target language defaults when possible
- **Test harness development**: Isolate serialization from application logic for rapid iteration

### 2. Package Structure Investigation

Distribution packages may contain multiple artifacts with similar names serving different purposes. The LanguageTool package provides:
- `languagetool.jar` - Full library for embedding
- `languagetool-server.jar` - Standalone HTTP server
- `languagetool-commandline.jar` - CLI interface

Always inspect package contents and understand the purpose of each artifact before selection.

### 3. Stream Separation in Dynamic Evaluation

When using shell command evaluation to obtain configuration values, ensure stderr is properly handled:
- Redirect stderr if warnings are expected and irrelevant
- Parse stderr separately if errors must be handled
- Use explicit output formats (e.g., `--raw` in Nix) to avoid additional formatting

### 4. Wrapper Script Completeness

JNI applications require both:
- Correct JAR classpath
- JVM library path (`LD_LIBRARY_PATH` on Linux)
- JDK location (`JAVA_HOME`)

Missing any component results in runtime failures that may not be immediately obvious.

## Technical Artifacts

### Test Harness

The deserialization test harness is available at `/tmp/test_init_options/`:

```bash
cd /tmp/test_init_options
cargo run
```

This allows testing JSON structures against the Rust types without LSP overhead.

### Verification Commands

```bash
# Verify JAR path evaluation
nix eval ~/code/rust/typst-languagetool#default.languagetoolJar --raw 2>/dev/null

# Check LSP logs
tail -f ~/.local/state/nvim/lsp.log | grep typst-languagetool

# Test LSP functionality
# Open a .typ file with grammatical errors in Neovim
# Expect diagnostics to appear
```

## Conclusion

The integration of typst-languagetool's LSP server with Neovim through Nix required resolving three distinct but interconnected issues: Lua-to-JSON serialization ambiguity, incorrect JAR selection, and stderr contamination in configuration evaluation. Each problem was systematically isolated through test harness development, log analysis, and incremental fixes. The final solution demonstrates the importance of understanding serialization boundaries, package structure, and stream handling in cross-language, multi-tool integrations.

The resulting configuration provides a reproducible, declarative setup where:
1. Nix manages dependencies and provides the correct LanguageTool JAR
2. Wrapper scripts ensure complete JNI environment configuration
3. Neovim configuration cleanly specifies only required options
4. Dynamic JAR path evaluation avoids hardcoded store paths

This architecture enables users to build and use typst-languagetool through Nix while maintaining compatibility with the upstream project structure.
