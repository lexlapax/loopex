defmodule Loopex.AppServer do
  @moduledoc """
  ## Concept

  The foreground server that speaks the experimental public session protocol
  over one connection. It is a client of a runtime, not a second runtime: it
  maps requests to the session contract core already owns, and owns no loop,
  no durable truth and no policy of its own.

  ## Technical depth

  Accepted ADR 0023 fixes what this application speaks and when: an exact
  generation, schema digest and limits are negotiated before any mutation, and
  a request that arrives before that, or that names a method this build does not
  implement, is refused before admission rather than answered by guess. One
  connection maps to one attachment, which is what lets a transfer, a
  subscription and a command all belong to the same caller without a second
  table to keep in step.

  This module is the application's entry point and carries no protocol logic of
  its own yet; the initialization, mapping and delivery paths land against their
  own bound witnesses.
  """

  @doc """
  ## Concept

  The protocol generation this build speaks.

  ## Technical depth

  Named here rather than derived, so a caller negotiating against it is matched
  against a value this application declares rather than one inferred from
  whatever schema happens to be on disk.
  """
  @spec generation() :: binary()
  def generation, do: "loopex.experimental/1"
end
