# Concept: a case whose claim is a real duration is kept whole and run where
# waiting minutes is the point.
#
# Technical depth: `:long_bound` marks a case that proves an old admission
# cutoff is absent by outlasting it. Shortening such a case would make it pass
# against exactly the reintroduced cutoff it exists to catch, so it keeps its
# duration and the ordinary suite skips it; the closure and release checks run
# it with `--include long_bound`.
ExUnit.start(exclude: [:real_provider, :long_bound])
