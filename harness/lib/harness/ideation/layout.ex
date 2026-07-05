defmodule Harness.Ideation.Layout do
  @moduledoc """
  Pure tree-layout math for the ideation SVG. A simple tidy layout: leaves are
  packed left-to-right at even x-spacing, each parent is centered over its
  children, and y is depth. Server-computed so the LiveView can render plain
  SVG with no client hook (same discipline as the gauges).
  """

  @x_gap 130
  @y_gap 90
  @margin 40

  @doc """
  Given the flat idea list, returns `%{nodes: [%{id, x, y, ...}], edges:
  [%{x1,y1,x2,y2}], width, height}`. Nodes carry the original fields plus x/y.
  """
  def compute(ideas) do
    by_id = Map.new(ideas, &{&1.id, &1})
    children = Enum.group_by(ideas, & &1.parent_id)
    roots = Map.get(children, nil, []) |> Enum.sort_by(& &1.id)

    {positions, _next_x} =
      Enum.reduce(roots, {%{}, 0}, fn root, {acc, x0} ->
        assign(root, children, acc, x0)
      end)

    nodes =
      Enum.map(ideas, fn idea ->
        {col, depth} = Map.get(positions, idea.id, {0, idea.depth})

        idea
        |> Map.take([:id, :title, :summary, :score, :status, :depth, :parent_id])
        |> Map.merge(%{x: @margin + col * @x_gap, y: @margin + depth * @y_gap})
      end)

    node_pos = Map.new(nodes, &{&1.id, &1})

    edges =
      for idea <- ideas, idea.parent_id != nil, Map.has_key?(node_pos, idea.parent_id) do
        parent = node_pos[idea.parent_id]
        child = node_pos[idea.id]
        %{x1: parent.x, y1: parent.y, x2: child.x, y2: child.y}
      end

    # Hug the content bounding box: viewBox = actual node extents + one margin on each side.
    # Label text sits at y+26 (baseline); with font-size 9 the rendered bottom ≈ y+28.
    # @margin (40) gives enough clearance above/right; y+@margin covers the label below.
    max_node_x = nodes |> Enum.map(& &1.x) |> Enum.max(fn -> @margin end)
    max_node_y = nodes |> Enum.map(& &1.y) |> Enum.max(fn -> @margin end)
    width = max_node_x + @margin
    height = max_node_y + @margin

    %{nodes: nodes, edges: edges, width: max(width, 200), height: max(height, 120), by_id: by_id}
  end

  # post-order: place children first, center parent over them
  defp assign(node, children_map, acc, next_x) do
    kids = children_map |> Map.get(node.id, []) |> Enum.sort_by(& &1.id)

    case kids do
      [] ->
        {Map.put(acc, node.id, {next_x, node.depth}), next_x + 1}

      _ ->
        {acc, last_x} =
          Enum.reduce(kids, {acc, next_x}, fn kid, {a, x} ->
            assign(kid, children_map, a, x)
          end)

        first_col = elem(acc[hd(kids).id] || {next_x, 0}, 0)
        last_col = elem(acc[List.last(kids).id] || {last_x - 1, 0}, 0)
        center = (first_col + last_col) / 2
        {Map.put(acc, node.id, {center, node.depth}), last_x}
    end
  end
end
