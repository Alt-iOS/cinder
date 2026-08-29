defmodule Cinder.Renderers.InfiniteStreamTest do
  use ExUnit.Case, async: true

  alias Cinder.Renderers.InfiniteStream

  test "encodes selection state for the stable infinite-stream root" do
    assert InfiniteStream.encode_selected_ids(MapSet.new(["album-2", "album-1"])) ==
             ~s(["album-1","album-2"])

    assert InfiniteStream.encode_selected_classes(["selected", "ring-2"]) ==
             ~s(["selected","ring-2"])
  end

  test "encodes only selected IDs retained by the bounded browser window" do
    encoded =
      InfiniteStream.encode_selected_ids(
        MapSet.new(["product-1", "product-2", "outside-window"]),
        MapSet.new(["product-1", "product-2", "not-selected"])
      )

    assert encoded == ~s(["product-1","product-2"])
  end
end
