defmodule Cinder.Renderers.SelectAllTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cinder.Renderers.SelectAll

  test "page mode targets the visible-page event and label" do
    html =
      render_component(&SelectAll.render/1,
        data: [%{id: "product-1"}],
        id_field: :id,
        loading: false,
        myself: nil,
        selectable: true,
        selected_ids: MapSet.new(),
        theme: %{
          select_all_container_class: "select-all",
          selection_checkbox_class: "checkbox",
          selection_indeterminate_class: "indeterminate"
        }
      )

    assert html =~ ~s(phx-click="toggle_select_all_page")
    assert html =~ "Select all visible items"
  end

  test "partially selected pages have a mixed checkbox, and loading disables it" do
    html =
      render_component(&SelectAll.render/1,
        data: [%{id: "a"}, %{id: "b"}],
        id_field: :id,
        loading: true,
        myself: nil,
        selectable: true,
        selected_ids: MapSet.new(["a"]),
        theme: Cinder.Theme.default()
      )

    assert html =~ ~s(aria-checked="mixed")
    assert html =~ ~s(data-selection-state="some")
    assert html =~ "disabled"
  end
end
