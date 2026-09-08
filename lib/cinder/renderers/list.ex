defmodule Cinder.Renderers.List do
  @moduledoc "Renderer for the list layout."
  use Phoenix.Component
  import Cinder.Renderers.Helpers
  alias Cinder.Renderers.Items

  def render(assigns) do
    {item_class, item_data_key} = get_item_classes(assigns.theme, assigns.item_click)

    assigns
    |> prepare_renderer(:list)
    |> assign(:items_container_class, get_container_class(assigns.container_class, assigns.theme))
    |> assign(:items_container_key, "list_container_class")
    |> assign(:items_item_class, item_class)
    |> assign(:items_item_data_key, item_data_key)
    |> assign(:items_selection_class, Map.get(assigns.theme, :list_selection_container_class))
    |> assign(:items_selection_key, "list_selection_container_class")
    |> assign(:items_state_class, assigns.theme.empty_class)
    |> Items.render()
  end

  defp get_container_class(nil, theme) do
    Map.get(theme, :list_container_class, "divide-y divide-gray-200")
  end

  defp get_container_class(custom_class, _theme), do: custom_class

  defp get_item_classes(theme, item_click) do
    base = Map.get(theme, :list_item_class, "")

    if item_click do
      clickable =
        Map.get(
          theme,
          :list_item_clickable_class,
          "cursor-pointer hover:bg-gray-50 transition-colors"
        )

      {[base, clickable], "list_item_clickable_class"}
    else
      {base, "list_item_class"}
    end
  end
end
