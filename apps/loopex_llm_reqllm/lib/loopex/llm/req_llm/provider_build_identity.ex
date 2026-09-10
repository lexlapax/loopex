defmodule Loopex.LLM.ReqLLM.ProviderBuildIdentity do
  @moduledoc false

  # Concept: an ordinary compiled module is not a built provider companion.
  # Technical depth: the offline builder replaces this one BEAM in the archive
  # with its generated, clean-source manifest. An unbuilt entry cannot announce
  # readiness or resolve a credential. The generated BEAM is excluded from its
  # own packaged-input digest.
  @doc false
  def manifest, do: nil
end
