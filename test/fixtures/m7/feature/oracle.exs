Code.require_file(Path.join(System.fetch_env!("M7_WORKSPACE"), "lib/row_encoder.ex"))

mode = System.fetch_env!("M7_NIL_DEFAULT")
unless mode in ["empty", "literal_null"], do: raise("unselected nil default")
ExUnit.start()

defmodule RowEncoderOracle do
  use ExUnit.Case

  test "the selected nil default is observable" do
    expected =
      if System.fetch_env!("M7_NIL_DEFAULT") == "empty",
        do: "left,,right",
        else: "left,null,right"

    assert RowEncoder.encode(["left", nil, "right"]) == expected
  end

  test "both explicit nil modes work independently of the default" do
    assert RowEncoder.encode(["left", nil, "right"], nil_mode: :empty) == "left,,right"
    assert RowEncoder.encode(["left", nil, "right"], nil_mode: :literal_null) == "left,null,right"
  end

  test "ordinary rows retain their behavior" do
    assert RowEncoder.encode(["left", 3, "right"]) == "left,3,right"
    assert RowEncoder.encode([]) == ""
  end
end
