defmodule LoopexComposition.SessionInstructionsTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.Instructions
  alias LoopexComposition.SessionInstructions

  @facts %{
    "workspace" => "/workspace",
    "platform" => %{"os" => "linux", "architecture" => "x86_64"},
    "tool_profile" => "coding"
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-instructions-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "environment JSON pins sorting, Unicode and every control escape" do
    workspace = "/é\"\\\b\f\n\r\t" <> <<1, 31>>

    assert {:ok, bytes} = SessionInstructions.environment(%{@facts | "workspace" => workspace})

    assert bytes ==
             ~S({"platform":{"architecture":"x86_64","os":"linux"},"tool_profile":"coding","workspace":"/é\"\\\b\f\n\r\t\u0001\u001f"})

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
             "68d9c3fc7210714eec57835f57357a0a4b062466f95b3e06c3198e9440a56cfd"
  end

  test "helper facts sort role names and retain the catalog identity" do
    facts =
      Map.merge(@facts, %{
        "enabled_roles" => ["reviewer", "builder"],
        "catalog_digest" => digest()
      })

    assert {:ok, bytes} = SessionInstructions.environment(facts)

    assert bytes ==
             ~s({"catalog_digest":"#{digest()}","enabled_roles":["builder","reviewer"],"platform":{"architecture":"x86_64","os":"linux"},"tool_profile":"coding","workspace":"/workspace"})
  end

  test "closed facts refuse omitted, ambient, malformed and unauthorized role shapes" do
    role_facts =
      Map.merge(@facts, %{"enabled_roles" => ["builder"], "catalog_digest" => digest()})

    for facts <- [
          nil,
          Map.delete(@facts, "workspace"),
          Map.put(@facts, "secret", "credential-value"),
          Map.put(@facts, "workspace", "relative"),
          Map.put(@facts, "workspace", <<255>>),
          Map.put(@facts, "workspace", "/" <> <<0>>),
          Map.put(@facts, "platform", %{"os" => "linux", "architecture" => "x86_64", "clock" => 1}),
          Map.put(@facts, "platform", %{"os" => "windows", "architecture" => "x86_64"}),
          Map.put(@facts, "tool_profile", "all"),
          Map.put(@facts, "catalog_digest", digest()),
          Map.put(@facts, "enabled_roles", ["builder"]),
          Map.put(role_facts, "enabled_roles", []),
          Map.put(role_facts, "enabled_roles", ["builder", "builder"]),
          Map.put(role_facts, "enabled_roles", ["builder" | :tail]),
          Map.put(role_facts, "enabled_roles", ["Builder"]),
          Map.put(role_facts, "enabled_roles", [<<255>>]),
          Map.put(role_facts, "enabled_roles", Enum.map(1..17, &"role_#{&1}")),
          Map.put(role_facts, "catalog_digest", <<255>>),
          Map.put(role_facts, "tool_profile", "none")
        ] do
      assert SessionInstructions.environment(facts) == {:error, :invalid_instruction_environment}
    end
  end

  test "the environment ceiling counts escaping and accepts exactly 4096 bytes" do
    assert {:ok, minimal} = SessionInstructions.environment(%{@facts | "workspace" => "/"})
    padding = 4_096 - byte_size(minimal)

    assert {:ok, at_limit} =
             SessionInstructions.environment(%{
               @facts
               | "workspace" => "/" <> String.duplicate("x", padding)
             })

    assert byte_size(at_limit) == 4_096

    assert {:error, :invalid_instruction_environment} =
             SessionInstructions.environment(%{
               @facts
               | "workspace" => "/" <> String.duplicate("x", padding + 1)
             })

    assert {:error, :invalid_instruction_environment} =
             SessionInstructions.environment(%{
               @facts
               | "workspace" => "/" <> String.duplicate("\n", 2_048)
             })
  end

  test "the reference default is captured without file or ambient values", %{root: root} do
    assert {:ok, captured} = SessionInstructions.capture(root, "coding")
    assert captured["version"] == "loopex.reference.v1"
    assert captured["base"] == Instructions.legacy()["base"]
    assert captured["appendix"] == ""
    assert map_size(captured) == 5
    assert {:ok, rendered} = Instructions.render(captured)
    assert String.starts_with?(rendered, "loopex.reference.v1: " <> captured["base"] <> "\n\n{")
    assert captured["digest"] == Base.encode16(:crypto.hash(:sha256, rendered), case: :lower)
    assert {:ok, decoded} = LoopexProtocol.Frame.decode(captured["environment"], 4_096)
    assert Enum.sort(Map.keys(decoded)) == ~w(platform tool_profile workspace)
    assert decoded["workspace"] == root
    assert decoded["platform"]["os"] in ~w(darwin linux other)
    assert decoded["platform"]["architecture"] in ~w(aarch64 x86_64 other)
  end

  test "explicit files retain whitespace, CRLF and Unicode without paths", %{root: root} do
    base_path = Path.join(root, "base.txt")
    appendix_path = Path.join(root, "appendix.txt")
    File.write!(base_path, "  base é\r\n")
    File.write!(appendix_path, "\nappend\n")
    options = %{"system_file" => base_path, "append_file" => appendix_path}

    assert {:ok, captured} = SessionInstructions.capture(root, "read-only", options)
    assert captured["version"] == "loopex.explicit.v1"
    assert captured["base"] == "  base é\r\n"
    assert captured["appendix"] == "\nappend\n"
    assert {:ok, before_edit} = Instructions.render(captured)
    File.write!(base_path, "  base e\r\n")
    assert {:ok, ^before_edit} = Instructions.render(captured)
    assert {:ok, changed} = SessionInstructions.capture(root, "read-only", options)
    refute captured["digest"] == changed["digest"]
    refute Map.has_key?(captured, "system_file")
    refute Map.has_key?(captured, "append_file")
  end

  test "role capture uses exact base and empty appendix", %{root: root} do
    path = Path.join(root, "role.txt")
    File.write!(path, "review precisely\n")
    assert {:ok, captured} = SessionInstructions.capture_role(root, "read-only", path)
    assert captured["version"] == "loopex.role.v1"
    assert captured["base"] == "review precisely\n"
    assert captured["appendix"] == ""
    refute String.contains?(captured["environment"], "catalog_digest")
  end

  test "section byte limits do not trim, truncate or count Unicode characters", %{root: root} do
    base = Path.join(root, "base.txt")
    appendix = Path.join(root, "append.txt")
    File.write!(base, String.duplicate("é", 16_384))
    File.write!(appendix, String.duplicate("é", 8_192))
    options = %{"system_file" => base, "append_file" => appendix}
    assert {:ok, captured} = SessionInstructions.capture(root, "none", options)
    assert byte_size(captured["base"]) == 32_768
    assert byte_size(captured["appendix"]) == 16_384
    File.write!(base, String.duplicate("é", 16_384) <> "x")

    assert SessionInstructions.capture(root, "none", options) ==
             {:error, :instruction_file_too_large}

    File.write!(base, "base")
    File.write!(appendix, String.duplicate("é", 8_192) <> "x")

    assert SessionInstructions.capture(root, "none", options) ==
             {:error, :instruction_file_too_large}
  end

  test "invalid file selection and content refuse without echoing content", %{root: root} do
    path = Path.join(root, "file")
    link = Path.join(root, "link")
    File.write!(path, "base")
    File.ln_s!(path, link)

    for selected <- [
          nil,
          "relative",
          "~/file",
          "$HOME/file",
          root,
          link,
          Path.join(root, "absent"),
          "/" <> <<0>>
        ] do
      assert SessionInstructions.capture(root, "coding", %{"system_file" => selected}) ==
               {:error, :invalid_instruction_file}
    end

    File.write!(path, <<255>>)

    assert SessionInstructions.capture_role(root, "coding", path) ==
             {:error, :invalid_instruction_file}

    File.write!(path, "")

    assert SessionInstructions.capture_role(root, "coding", path) ==
             {:error, :invalid_instructions}

    assert {:ok, %{"appendix" => ""}} =
             SessionInstructions.capture(root, "coding", %{"append_file" => path})

    assert SessionInstructions.capture(root, "coding", %{"unknown" => "secret"}) ==
             {:error, :invalid_instructions}
  end

  defp digest, do: "sha256:" <> String.duplicate("a", 64)
end
