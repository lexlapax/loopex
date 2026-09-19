# Concept: a case whose claim is a real duration is kept whole and run where
# waiting minutes is the point.
#
# Technical depth: `:long_bound` marks a case that proves an old admission
# cutoff is absent by outlasting it. Shortening such a case would make it pass
# against exactly the reintroduced cutoff it exists to catch, so it keeps its
# duration and the ordinary suite skips it; the release check runs it in a pass
# of its own with `--only long_bound`.
ExUnit.start(exclude: [:real_provider, :long_bound])
