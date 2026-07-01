; Verse textobject queries for Helix editor
; Enables smart motions: ]f (next function), mif (select inside function), etc.

; ─────────────────────────────────────────────
; Functions
; ─────────────────────────────────────────────

; Entire function definition (signature + body)
(function_definition) @function.around
(extension_function_definition) @function.around

; Function body only (brace block, indented block, or inline expression)
(function_definition
  body: (_) @function.inside)

(extension_function_definition
  body: (_) @function.inside)

; ─────────────────────────────────────────────
; Classes / Types
; ─────────────────────────────────────────────

; Entire type definition (name + body)
(type_definition) @class.around

; Type body only (the class/struct/enum/interface/module definition)
(type_definition
  value: (class_definition) @class.inside)

(type_definition
  value: (struct_definition) @class.inside)

(type_definition
  value: (enum_definition) @class.inside)

(type_definition
  value: (interface_definition) @class.inside)

(type_definition
  value: (module_definition) @class.inside)

; ─────────────────────────────────────────────
; Parameters
; ─────────────────────────────────────────────

; Parameter name and type (without surrounding comma)
(positional_parameter) @parameter.inside
(named_parameter) @parameter.inside

; Parameter including surrounding delimiter context
(parameter_list
  (positional_parameter) @parameter.around)

(parameter_list
  (named_parameter) @parameter.around)

; ─────────────────────────────────────────────
; Comments
; ─────────────────────────────────────────────

(line_comment) @comment.around
(block_comment) @comment.around

; Comment text (inside the delimiters)
(line_comment) @comment.inside
(block_comment) @comment.inside
