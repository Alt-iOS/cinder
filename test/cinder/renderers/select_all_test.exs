defmodule Cinder.Renderers.SelectAllTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Cinder.Renderers.SelectAll

  test "keeps the native checked state and disables the control while select-all is pending" do
    html =
      render_component(&SelectAll.render/1,
        data: [%{id: "product-1"}],
        id_field: :id,
        label: "Choose every matching row",
        loading: true,
        myself: nil,
        pending: true,
        selectable: true,
        selected_ids: MapSet.new(),
        theme: %{
          select_all_container_class: "select-all",
          selection_checkbox_class: "checkbox",
          selection_indeterminate_class: "indeterminate"
        }
      )

    assert html =~ ~s(checked)
    assert html =~ ~s(aria-checked="true")
    assert html =~ ~s(data-selection-state="all")
    assert html =~ ~s(disabled)
    assert html =~ "Choose every matching row"
    assert html =~ ~s(aria-label="Choose every matching row")
  end
end
