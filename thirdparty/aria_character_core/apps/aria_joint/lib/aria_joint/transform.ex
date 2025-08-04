# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

defmodule AriaJoint.Transform do
  @moduledoc """
  Transform operations for Joint nodes.

  Handles local and global transform calculations, coordinate space
  conversions, and transform-related operations.
  """

  alias AriaMath.{Vector3, Matrix4}
  alias AriaJoint.{Registry, DirtyState, Hierarchy}

  @type transform() :: Matrix4.t()
  @type basis() :: Matrix4.t()

  @doc """
  Get the local transform of a node.

  Updates local transform from rotation and scale if dirty.

  ## Examples

      local_transform = Transform.get_local(node)

  """
  @spec get_local(AriaJoint.Joint.t()) :: transform()
  def get_local(node) do
    node = if DirtyState.has_dirty_flag?(node.dirty, DirtyState.dirty_local()) do
      update_local_transform(node)
    else
      node
    end

    node.local_transform
  end

  @doc """
  Get the global transform of a node.

  Computes global transform from hierarchy if dirty, with efficient caching.

  ## Examples

      global_transform = Transform.get_global(node)

  """
  @spec get_global(AriaJoint.Joint.t()) :: transform()
  def get_global(node) do
    # Always get the latest node from registry to ensure we have current state
    current_node = case Registry.get_node_by_id(node.id) do
      nil -> node
      registry_node -> registry_node
    end

    if DirtyState.has_dirty_flag?(current_node.dirty, DirtyState.dirty_global()) do
      updated_node = if DirtyState.has_dirty_flag?(current_node.dirty, DirtyState.dirty_local()) do
        update_local_transform(current_node)
      else
        current_node
      end

      global_transform = case Hierarchy.get_parent_node(updated_node) do
        nil ->
          updated_node.local_transform

        parent_node ->
          parent_global = get_global(parent_node)
          Matrix4.multiply(parent_global, updated_node.local_transform)
      end

      global_transform = if updated_node.disable_scale do
        Matrix4.orthogonalize(global_transform)
      else
        global_transform
      end

      final_node = %{updated_node |
        global_transform: global_transform,
        dirty: DirtyState.remove_dirty_flag(updated_node.dirty, DirtyState.dirty_global())
      }

      Registry.update_node(final_node)
      final_node.global_transform
    else
      current_node.global_transform
    end
  end

  @doc """
  Set the local transform of a node.

  Updates the local transform and marks appropriate dirty states for efficient
  recomputation of global transforms.

  ## Examples

      transform = Matrix4.translation({0.5, 1.0, 0.0})
      node = Transform.set_local(node, transform)

  """
  @spec set_local(AriaJoint.Joint.t(), transform()) :: AriaJoint.Joint.t() | {:error, term()}
  def set_local(node, transform) do
    # Get the latest node state from registry to ensure we have current children list
    current_node = case Registry.get_node_by_id(node.id) do
      nil -> node
      registry_node -> registry_node
    end

    if Matrix4.equal?(current_node.local_transform, transform) do
      current_node
    else
      updated_node = %{current_node |
        local_transform: transform,
        dirty: DirtyState.add_dirty_flag(current_node.dirty, DirtyState.dirty_global())
      }

      case Registry.update_node(updated_node) do
        :ok ->
          Hierarchy.propagate_transform_changed(updated_node)
          updated_node

        {:error, _reason} ->
          # Return updated node even if registry update fails
          updated_node
      end
    end
  end

  @doc """
  Set the global transform of a node.

  Automatically computes the appropriate local transform based on parent hierarchy.

  ## Examples

      global_transform = Matrix4.translation({1.0, 2.0, 3.0})
      node = Transform.set_global(node, global_transform)

  """
  @spec set_global(AriaJoint.Joint.t(), transform()) :: AriaJoint.Joint.t()
  def set_global(node, global_transform) do
    local_transform = case Hierarchy.get_parent_node(node) do
      nil ->
        global_transform

      parent_node ->
        parent_global = get_global(parent_node)
        {parent_inverse, _valid} = Matrix4.inverse(parent_global)
        Matrix4.multiply(parent_inverse, global_transform)
    end

    updated_node = %{node |
      local_transform: local_transform,
      global_transform: global_transform,
      dirty: DirtyState.remove_dirty_flag(node.dirty, DirtyState.dirty_global())
    }

    Registry.update_node(updated_node)
    Hierarchy.propagate_transform_changed(updated_node)
    updated_node
  end

  @doc """
  Convert a point from global space to local node space.

  ## Examples

      global_point = {1.0, 2.0, 3.0}
      local_point = Transform.to_local(node, global_point)

  """
  @spec to_local(AriaJoint.Joint.t(), Vector3.t()) :: Vector3.t()
  def to_local(node, global_point) do
    global_transform = get_global(node)
    {inverse_transform, _valid} = Matrix4.inverse(global_transform)
    Matrix4.transform_point(inverse_transform, global_point)
  end

  @doc """
  Convert a point from local node space to global space.

  ## Examples

      local_point = {0.5, 0.0, 0.0}
      global_point = Transform.to_global(node, local_point)

  """
  @spec to_global(AriaJoint.Joint.t(), Vector3.t()) :: Vector3.t()
  def to_global(node, local_point) do
    global_transform = get_global(node)
    Matrix4.transform_point(global_transform, local_point)
  end

  @doc """
  Rotate node locally using global basis.

  ## Parameters

  - `node` - The node to rotate
  - `basis` - Global rotation basis to apply
  - `propagate` - Whether to propagate changes to children (default: false)

  ## Examples

      rotation_basis = Matrix4.rotation_y(Math.pi / 4)
      node = Transform.rotate_local_with_global(node, rotation_basis, true)

  """
  @spec rotate_local_with_global(AriaJoint.Joint.t(), basis(), boolean()) :: AriaJoint.Joint.t()
  def rotate_local_with_global(node, basis, propagate \\ false) do
    case Hierarchy.get_parent_node(node) do
      nil -> node

      parent_node ->
        parent_global = get_global(parent_node)
        parent_basis = Matrix4.extract_basis(parent_global)
        parent_inverse = Matrix4.transpose(parent_basis)

        # new_rot = parent_inverse * basis * parent_basis * local_basis
        local_basis = Matrix4.extract_basis(node.local_transform)
        new_local_basis = parent_inverse
                         |> Matrix4.multiply(basis)
                         |> Matrix4.multiply(parent_basis)
                         |> Matrix4.multiply(local_basis)

        # Update local transform with new basis
        {translation, _rotation, scale} = Matrix4.decompose(node.local_transform)
        new_local_transform = Matrix4.compose(translation, new_local_basis, scale)

        updated_node = %{node |
          local_transform: new_local_transform,
          dirty: DirtyState.add_dirty_flag(node.dirty, DirtyState.dirty_global())
        }

        Registry.update_node(updated_node)

        if propagate do
          Hierarchy.propagate_transform_changed(updated_node)
        end

        updated_node
    end
  end

  @doc """
  Update local transform from rotation and scale components.
  """
  @spec update_local_transform(AriaJoint.Joint.t()) :: AriaJoint.Joint.t()
  def update_local_transform(node) do
    # local_transform.basis = rotation.scaled(scale)
    rotation_matrix = node.rotation
    {sx, sy, sz} = node.scale
    scale_matrix = Matrix4.scaling({sx, sy, sz})
    new_basis = Matrix4.multiply(rotation_matrix, scale_matrix)

    {translation, _old_rotation, _old_scale} = Matrix4.decompose(node.local_transform)
    new_local_transform = Matrix4.compose(translation, new_basis, {sx, sy, sz})

    updated_node = %{node |
      local_transform: new_local_transform,
      dirty: DirtyState.remove_dirty_flag(node.dirty, DirtyState.dirty_local())
    }

    Registry.update_node(updated_node)
    updated_node
  end
end
