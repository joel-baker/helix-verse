; Verse scope and binding information for Helix editor
; Ported from taku25/tree-sitter-verse (MIT License)
; https://github.com/taku25/tree-sitter-verse

; ─────────────────────────────────────────────
; Scopes
; ─────────────────────────────────────────────

; Top-level module scope
(source_file) @local.scope

; Function bodies create a new scope
(function_definition
  body: (_) @local.scope)

; Block expressions create a scope
(brace_block) @local.scope
(colon_block) @local.scope

; Type bodies
(class_definition) @local.scope
(struct_definition) @local.scope
(enum_definition) @local.scope
(interface_definition) @local.scope
(module_definition) @local.scope

; Control flow creates scopes
(if_expression) @local.scope
(for_expression) @local.scope
(loop_expression) @local.scope
(block_expression) @local.scope
(case_expression) @local.scope
(sync_expression) @local.scope
(race_expression) @local.scope

; ─────────────────────────────────────────────
; Definitions (bindings)
; ─────────────────────────────────────────────

; Constant / value definition
(type_definition
  name: (identifier) @local.definition)

; Function definition
(function_definition
  name: (_) @local.definition)

; Variable declaration
(var_declaration
  name: (identifier) @local.definition)

; Field declaration (member binding)
(field_declaration
  name: (identifier) @local.definition)

; Enum variant
(enum_variant
  name: (identifier) @local.definition)

; Parameter bindings
(positional_parameter
  name: (identifier) @local.definition)

(named_parameter
  name: (identifier) @local.definition)

; For-loop iterator variable
(for_iterator
  variable: (identifier) @local.definition)

; ─────────────────────────────────────────────
; References
; ─────────────────────────────────────────────

(identifier) @local.reference
