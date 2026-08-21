defmodule Cinder.Renderers.InfiniteStream do
  @moduledoc false

  use Phoenix.Component
  use Cinder.Messages

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :theme, :map, required: true
  attr :show, :boolean, default: false

  def top_sentinel(assigns) do
    ~H"""
    <div
      :if={@show}
      id={"#{@id}-infinite-top-sentinel"}
      data-pagination-state="ready-previous"
      phx-viewport-top="load_previous"
      phx-target={@myself}
    >
      <button
        type="button"
        class={@theme.pagination_button_class}
        phx-click="load_previous"
        phx-target={@myself}
      >
        {dgettext("cinder", "Load previous")}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :selected_ids, :any, required: true
  attr :selected_classes, :list, default: []

  def selection_sync(assigns) do
    assigns =
      assigns
      |> assign(:encoded_selected_ids, Jason.encode!(MapSet.to_list(assigns.selected_ids)))
      |> assign(:encoded_selected_classes, Jason.encode!(assigns.selected_classes))

    ~H"""
    <span
      id={"#{@id}-stream-selection-state"}
      class="hidden"
      data-cinder-stream-selection
      data-selected-ids={@encoded_selected_ids}
      data-selected-classes={@encoded_selected_classes}
      phx-hook="CinderInfiniteStream"
    />
    """
  end

  def selected_classes(class) when is_binary(class), do: String.split(class)

  def selected_classes(classes) when is_list(classes) do
    classes
    |> List.flatten()
    |> Enum.flat_map(&selected_classes/1)
  end

  def selected_classes(_), do: []
end
