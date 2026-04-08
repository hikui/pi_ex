Code.require_file("../test_helpers/span_exporter.ex", __DIR__)
Code.require_file("../test_helpers/otel_test_helpers.ex", __DIR__)

{:ok, _pid} = PiEx.TestSpanExporter.start_link([])

rg_available = not is_nil(System.find_executable("rg"))

excludes =
  if rg_available do
    []
  else
    [:requires_rg]
  end

ExUnit.start(exclude: excludes)
