defmodule Cinder.Renderers.InfiniteStreamTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cinder.Renderers.InfiniteStream

  test "renders the selection state consumed by retained stream items" do
    html =
      render_component(&InfiniteStream.selection_sync/1,
        id: "albums",
        selected_ids: MapSet.new(["album-1", "album-2"]),
        selected_classes: ["selected", "ring-2"]
      )

    assert html =~ ~s(phx-hook="CinderInfiniteStream")
    assert html =~ ~s(data-cinder-stream-selection)
    assert html =~ "album-1"
    assert html =~ "album-2"
    assert html =~ "selected"
    assert html =~ "ring-2"
  end
end
