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

    {positions, next_x} =
      Enum.reduce(roots, {%{}, 0}, fn root, {acc, x0} ->
        assign(root, children, acc, x0)
      end)

    nodes =
      Enum.map(ideas, fn idea ->
        {col, depth} = Map.get(positions, idea.id, {0, idea.depth})

        idea
        |> Map.take([:id, :title, :score, :status, :depth, :parent_id])
        |> Map.merge(%{x: @margin + col * @x_gap, y: @margin + depth * @y_gap})
      end)

    node_pos = Map.new(nodes, &{&1.id, &1})

    edges =
      for idea <- ideas, idea.parent_id != nil, Map.has_key?(node_pos, idea.parent_id) do
        parent = node_pos[idea.parent_id]
        child = node_pos[idea.id]
        %{x1: parent.x, y1: parent.y, x2: child.x, y2: child.y}
      end

    width = @margin * 2 + max(next_x - 1, 0) * @x_gap + 40
    max_depth = ideas |> Enum.map(& &1.depth) |> Enum.max(fn -> 0 end)
    height = @margin * 2 + max_depth * @y_gap + 40

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
