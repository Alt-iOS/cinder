defmodule Cinder.Renderers.Grid do
  @moduledoc "Renderer for the grid layout."
  use Phoenix.Component
  import Cinder.Renderers.Helpers
  alias Cinder.Renderers.Items

  def render(assigns) do
    {item_class, item_data_key} = get_item_classes(assigns.theme, assigns.item_click)

    assigns
    |> prepare_renderer(:grid)
    |> assign(
      :items_container_class,
      get_container_class(assigns.container_class, assigns.grid_columns, assigns.theme)
    )
    |> assign(:items_container_key, "grid_container_class")
    |> assign(:items_item_class, item_class)
    |> assign(:items_item_data_key, item_data_key)
    |> assign(:items_selection_class, Map.get(assigns.theme, :grid_selection_overlay_class))
    |> assign(:items_selection_key, "grid_selection_overlay_class")
    |> assign(:items_state_class, [assigns.theme.empty_class, "col-span-full"])
    |> Items.render()
  end

  defp get_container_class(custom_class, _grid_columns, _theme) when is_binary(custom_class) do
    custom_class
  end

  # Build from theme base + grid_columns
  defp get_container_class(nil, grid_columns, theme) do
    base = Map.get(theme, :grid_container_class, "grid gap-4")
    cols = build_grid_cols(grid_columns)
    [base, cols]
  end

  defp build_grid_cols(cols) when is_binary(cols) do
    build_grid_cols(String.to_integer(cols))
  end

  defp build_grid_cols(cols) when is_integer(cols) and cols in 1..12 do
    "grid grid-cols-#{cols}"
  end

  # If an invalid number is provided, default to 3
  defp build_grid_cols(cols) when is_integer(cols), do: "grid-cols-3"

  defp build_grid_cols(cols) when is_list(cols) do
    Enum.map(cols, &breakpoint_class/1)
  end

  defp build_grid_cols(_), do: "grid-cols-3"

  defp breakpoint_class({:xs, cols}), do: "grid-cols-#{cols}"
  defp breakpoint_class({:sm, cols}), do: "sm:grid-cols-#{cols}"
  defp breakpoint_class({:md, cols}), do: "md:grid-cols-#{cols}"
  defp breakpoint_class({:lg, cols}), do: "lg:grid-cols-#{cols}"
  defp breakpoint_class({:xl, cols}), do: "xl:grid-cols-#{cols}"
  defp breakpoint_class({:"2xl", cols}), do: "2xl:grid-cols-#{cols}"
  defp breakpoint_class(_), do: nil

  defp get_item_classes(theme, item_click) do
    base =
      Map.get(theme, :grid_item_class, "p-4 bg-white border border-gray-200 rounded-lg shadow-sm")

    if item_click do
      clickable =
        Map.get(
          theme,
          :grid_item_clickable_class,
          "cursor-pointer hover:shadow-md transition-shadow"
        )

      {[base, clickable], "grid_item_clickable_class"}
    else
      {base, "grid_item_class"}
    end
  end

  # Tailwind safelist - these classes are dynamically generated, keep them here for purge detection:
  # grid-cols-1 grid-cols-2 grid-cols-3 grid-cols-4 grid-cols-5 grid-cols-6 grid-cols-7 grid-cols-8 grid-cols-9 grid-cols-10 grid-cols-11 grid-cols-12
  # sm:grid-cols-1 sm:grid-cols-2 sm:grid-cols-3 sm:grid-cols-4 sm:grid-cols-5 sm:grid-cols-6
  # md:grid-cols-1 md:grid-cols-2 md:grid-cols-3 md:grid-cols-4 md:grid-cols-5 md:grid-cols-6
  # lg:grid-cols-1 lg:grid-cols-2 lg:grid-cols-3 lg:grid-cols-4 lg:grid-cols-5 lg:grid-cols-6
  # xl:grid-cols-1 xl:grid-cols-2 xl:grid-cols-3 xl:grid-cols-4 xl:grid-cols-5 xl:grid-cols-6
  # 2xl:grid-cols-1 2xl:grid-cols-2 2xl:grid-cols-3 2xl:grid-cols-4 2xl:grid-cols-5 2xl:grid-cols-6
end
