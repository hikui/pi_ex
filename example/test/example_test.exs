defmodule ExampleTest do
  use ExUnit.Case
  doctest Example

  test "greets the world" do
    assert Example.hello() == :world
  end

  test "tool stream events demo runs without network access" do
    ExUnit.CaptureIO.capture_io(fn ->
      assert Example.ToolStreamEventsDemo.run() == :ok
    end)
  end
end
