Code.require_file("support/in_process_catalog_fixture.ex", __DIR__)

defmodule Loopex.LLM.ReqLLM.InProcessCatalogTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcessCatalogFixture, as: Fixture

  @tag timeout: 120_000
  test "a cold host-selected file supplies Anthropic metadata and retains its overlay" do
    {output, status} = Fixture.run_in_child(:file)
    assert status == 0, output
    assert output =~ "CATALOG_FILE_PROVED"
  end

  @tag timeout: 120_000
  test "a cold ReleaseStore load uses GH_TOKEN only for catalog traffic" do
    {output, status} = Fixture.run_in_child(:gh)
    assert status == 0, output
    assert output =~ "CATALOG_REMOTE_GH_PROVED"
  end

  @tag timeout: 120_000
  test "a cold ReleaseStore load falls back to GITHUB_TOKEN" do
    {output, status} = Fixture.run_in_child(:github)
    assert status == 0, output
    assert output =~ "CATALOG_REMOTE_GITHUB_PROVED"
  end

  @tag timeout: 120_000
  test "failed cold sources refuse before model dispatch and cannot cache failure" do
    {output, status} = Fixture.run_in_child(:failure)
    assert status == 0, output
    assert output =~ "CATALOG_FAILURE_PROVED"
  end

  @tag timeout: 120_000
  test "a caller waiting on the shared cold-load lock spends its model deadline" do
    {output, status} = Fixture.run_in_child(:lock)
    assert status == 0, output
    assert output =~ "CATALOG_LOCK_PROVED"
  end
end
