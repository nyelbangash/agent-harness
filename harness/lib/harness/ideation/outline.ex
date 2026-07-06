defmodule Harness.Ideation.Outline do
  @moduledoc """
  Design decision (issue #70): the idea tree used to render as a pan/zoom SVG
  map — `Harness.Ideation.Layout` computed x/y positions for a tidy top-down
  layout, driven by a client `.TreeZoom` hook for wheel-zoom/drag-pan and a
  semantic-zoom mode. For sessions that branch 2-4 ideas per iteration over
  several hours, that tree grows wide and deep, and panning/zooming an SVG to
  find or compare nodes doesn't scale — the operator wants to scan and
  compare nodes, not navigate a spatial map.

  This module replaces that layout with a plain nested forest (no x/y, no
  client-side geometry). The LiveView renders it as a collapsible,
  depth-indented DOM outline that reuses the row/badge visual language of the
  existing "Top nodes" leaderboard. It scales to arbitrarily wide/deep
  sessions by scrolling instead of panning, needs no JS hook, and every
  branch can be collapsed independently once it's no longer of interest
  (e.g. a pruned dead end).
  """

  @doc """
  Given the flat idea list (as returned by `Ideation.tree/1`), builds a
  nested forest: `[%{idea: idea, children: [...]}]`, one entry per root
  idea. Siblings are ordered by insertion (id) at every level, same order as
  the old layout's post-order packing.
  """
  def build(ideas) do
    children_by_parent = Enum.group_by(ideas, & &1.parent_id)
    roots = children_by_parent |> Map.get(nil, []) |> Enum.sort_by(& &1.id)

    Enum.map(roots, &build_node(&1, children_by_parent))
  end

  defp build_node(idea, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(idea.id, [])
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&build_node(&1, children_by_parent))

    %{idea: idea, children: children}
  end
end
