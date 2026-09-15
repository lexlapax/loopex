defmodule Loopex.AppServer.Fixture do
  @moduledoc """
  ## Concept

  The launch configuration a server process runs under in outcome 5's workflow:
  a real runtime with a scripted model, composed by the host before a single
  frame is read.

  ## Technical depth

  Accepted ADR 0023 keeps launch inputs outside the protocol, so this is where
  they live. The client driving this process cannot change any of it, which is
  as much a part of the demonstration as the workflow itself: a session runs
  under the store, model, executor and policy an operator chose at launch,
  whatever a later frame asks for.

  The model is scripted rather than real. The provider demonstration outcome 5
  also names is attended and spends a real key, so it stays the maintainer's to
  perform; everything a client can observe about the protocol is proved here
  without one.
  """

  @doc """
  ## Concept

  Composes the runtime and serves one connection on standard input and output.

  ## Technical depth

  Nothing is written to standard output but protocol records: the runtime's
  diagnostics sink is left unset, because a stray line would break every client
  parsing this stream by line. The process ends when its input ends, which makes
  the client's close a clean shutdown rather than a kill.
  """
  @spec serve() :: :ok
  def serve do
    fixture = Loopex.AgentLoopFixture.start(script: [%{text: "the task is done", calls: []}])
    Loopex.AppServer.Stdio.serve(fixture.runtime)
  end
end
