# The apps globs below are the effective formatter scope. `mix loopex.format_scope`
# proves they resolve to application sources rather than merely appearing here:
# an umbrella root formats nothing of its own, so a root-only configuration would
# report success having checked no application file.
[
  inputs: [
    "{mix,.formatter}.exs",
    "config/*.exs",
    "apps/*/mix.exs",
    "apps/*/{config,lib,test}/**/*.{ex,exs}"
  ]
]
